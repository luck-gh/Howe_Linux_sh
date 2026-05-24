#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 安全加固模块
#
# 功能：SSH 安全 / fail2ban / iptables 防火墙 / DDoS 防御 / 国家 IP 封锁
# 来源：kejilion.sh（已去除遥测和 gh_proxy）
# ═══════════════════════════════════════════════════════════════════

# ── SSH 相关 ─────────────────────────────────────────────────────

restart_ssh() {
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null
}

correct_ssh_config() {
  local sshd_config="/etc/ssh/sshd_config"
  if grep -Eq "^\s*PasswordAuthentication\s+no" "$sshd_config"; then
    sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/' \
           -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication no/' \
           -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' \
           -e 's/^\s*#\?\s*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$sshd_config"
  else
    sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin yes/' \
           -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication yes/' \
           -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' "$sshd_config"
  fi
  rm -rf /etc/ssh/sshd_config.d/* /etc/ssh/ssh_config.d/*
}

change_ssh_port() {
  local new_port=$1
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  sed -i '/^\s*#\?\s*Port\s\+/d' /etc/ssh/sshd_config
  echo "Port $new_port" >> /etc/ssh/sshd_config
  correct_ssh_config
  restart_ssh
  iptables_open_port "$new_port"
  log "SSH 端口已修改为: $new_port"
}

sshkey_on() {
  sed -i -e 's/^\s*#\?\s*PermitRootLogin .*/PermitRootLogin prohibit-password/' \
         -e 's/^\s*#\?\s*PasswordAuthentication .*/PasswordAuthentication no/' \
         -e 's/^\s*#\?\s*PubkeyAuthentication .*/PubkeyAuthentication yes/' \
         -e 's/^\s*#\?\s*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
  rm -rf /etc/ssh/sshd_config.d/* /etc/ssh/ssh_config.d/*
  restart_ssh
  log "密钥登录已开启，密码登录已关闭"
}

generate_ssh_key() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"

  ssh-keygen -t ed25519 -C "howe@$(hostname)" -f "${HOME}/.ssh/sshkey" -N ""
  cat "${HOME}/.ssh/sshkey.pub" >> "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"

  echo -e "\n  ${Y}私钥已生成，请务必复制保存：${N}"
  echo "  ─────────────────────────────────"
  cat "${HOME}/.ssh/sshkey"
  echo "  ─────────────────────────────────"
  sshkey_on
}

import_ssh_key() {
  local public_key="$1"
  if [[ -z "$public_key" ]]; then
    read -erp "请输入 SSH 公钥（ssh-rsa/ssh-ed25519 开头）：" public_key
  fi
  [[ -z "$public_key" ]] && { warn "未输入公钥"; return 1; }
  [[ ! "$public_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]] && { warn "格式不正确"; return 1; }

  local auth_keys="${HOME}/.ssh/authorized_keys"
  if grep -Fxq "$public_key" "$auth_keys" 2>/dev/null; then
    info "该公钥已存在"
    return 0
  fi

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "$auth_keys"
  echo "$public_key" >> "$auth_keys"
  chmod 600 "$auth_keys"
  sshkey_on
}

import_github_keys() {
  local username="$1"
  if [[ -z "$username" ]]; then
    read -erp "请输入 GitHub 用户名：" username
  fi
  [[ -z "$username" ]] && { warn "用户名不能为空"; return 1; }

  local keys_url="${URL_GITHUB_KEYS}/${username}.keys"
  local temp_file
  temp_file=$(mktemp)

  if ! curl -fsSL --connect-timeout 10 "$keys_url" -o "$temp_file"; then
    warn "无法下载公钥"
    rm -f "$temp_file"
    return 1
  fi

  [[ ! -s "$temp_file" ]] && { warn "下载内容为空"; rm -f "$temp_file"; return 1; }

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  local auth_keys="${HOME}/.ssh/authorized_keys"
  touch "$auth_keys"
  chmod 600 "$auth_keys"

  local added=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if ! grep -Fxq "$line" "$auth_keys" 2>/dev/null; then
      echo "$line" >> "$auth_keys"
      ((added++))
    fi
  done < "$temp_file"
  rm -f "$temp_file"

  if (( added > 0 )); then
    log "已添加 ${added} 条公钥"
    sshkey_on
  else
    info "没有新公钥需要添加"
  fi
}

# ── iptables 防火墙 ──────────────────────────────────────────────

save_iptables_rules() {
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  # 重启自动恢复
  crontab -l 2>/dev/null | grep -v 'iptables-restore' | crontab - 2>/dev/null
  (crontab -l 2>/dev/null; echo '@reboot iptables-restore < /etc/iptables/rules.v4') | crontab - 2>/dev/null
}

iptables_open_port() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
    fi
    if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT
    fi
  done
  save_iptables_rules
  log "已开放端口: ${ports[*]}"
}

iptables_close_port() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
    if ! iptables -C INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; then
      iptables -I INPUT 1 -p tcp --dport "$port" -j DROP
    fi
    if ! iptables -C INPUT -p udp --dport "$port" -j DROP 2>/dev/null; then
      iptables -I INPUT 1 -p udp --dport "$port" -j DROP
    fi
  done
  # 保持回环放行
  iptables -D INPUT -i lo -j ACCEPT 2>/dev/null
  iptables -I INPUT 1 -i lo -j ACCEPT
  save_iptables_rules
  log "已关闭端口: ${ports[*]}"
}

allow_ip() {
  local ips=("$@")
  for ip in "${ips[@]}"; do
    iptables -D INPUT -s "$ip" -j DROP 2>/dev/null
    if ! iptables -C INPUT -s "$ip" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT 1 -s "$ip" -j ACCEPT
    fi
  done
  save_iptables_rules
  log "已放行 IP: ${ips[*]}"
}

block_ip() {
  local ips=("$@")
  for ip in "${ips[@]}"; do
    iptables -D INPUT -s "$ip" -j ACCEPT 2>/dev/null
    if ! iptables -C INPUT -s "$ip" -j DROP 2>/dev/null; then
      iptables -I INPUT 1 -s "$ip" -j DROP
    fi
  done
  save_iptables_rules
  log "已封锁 IP: ${ips[*]}"
}

iptables_reset() {
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  ip6tables -P INPUT ACCEPT 2>/dev/null
  ip6tables -P FORWARD ACCEPT 2>/dev/null
  ip6tables -P OUTPUT ACCEPT 2>/dev/null
  ip6tables -F 2>/dev/null
  save_iptables_rules
  log "防火墙规则已重置"
}

# ── DDoS 防御 ────────────────────────────────────────────────────

enable_ddos_defense() {
  iptables -A DOCKER-USER -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT
  iptables -A DOCKER-USER -p tcp --syn -j DROP
  iptables -A DOCKER-USER -p udp -m limit --limit 3000/s -j ACCEPT
  iptables -A DOCKER-USER -p udp -j DROP
  iptables -A INPUT -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT
  iptables -A INPUT -p tcp --syn -j DROP
  iptables -A INPUT -p udp -m limit --limit 3000/s -j ACCEPT
  iptables -A INPUT -p udp -j DROP
  save_iptables_rules
  log "DDoS 防御已开启"
}

disable_ddos_defense() {
  iptables -D DOCKER-USER -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT 2>/dev/null
  iptables -D DOCKER-USER -p tcp --syn -j DROP 2>/dev/null
  iptables -D DOCKER-USER -p udp -m limit --limit 3000/s -j ACCEPT 2>/dev/null
  iptables -D DOCKER-USER -p udp -j DROP 2>/dev/null
  iptables -D INPUT -p tcp --syn -m limit --limit 500/s --limit-burst 100 -j ACCEPT 2>/dev/null
  iptables -D INPUT -p tcp --syn -j DROP 2>/dev/null
  iptables -D INPUT -p udp -m limit --limit 3000/s -j ACCEPT 2>/dev/null
  iptables -D INPUT -p udp -j DROP 2>/dev/null
  save_iptables_rules
  log "DDoS 防御已关闭"
}

# ── 国家 IP 封锁 ────────────────────────────────────────────────

manage_country_rules() {
  local action="$1"; shift
  for country_code in "$@"; do
    local ipset_name="${country_code,,}_block"
    local download_url="${URL_IPDENY}/${country_code,,}.zone"

    case "$action" in
      block)
        ipset create "$ipset_name" hash:net 2>/dev/null
        local tmpfile
        tmpfile=$(mktemp)
        if ! wget -q "$download_url" -O "$tmpfile"; then
          warn "下载 $country_code IP 区域文件失败"
          rm -f "$tmpfile"
          continue
        fi
        while IFS= read -r ip; do
          ipset add "$ipset_name" "$ip" 2>/dev/null
        done < "$tmpfile"
        rm -f "$tmpfile"
        iptables -I INPUT -m set --match-set "$ipset_name" src -j DROP
        log "已封锁 $country_code 的 IP"
        ;;
      allow)
        ipset create "$ipset_name" hash:net 2>/dev/null
        local tmpfile
        tmpfile=$(mktemp)
        if ! wget -q "$download_url" -O "$tmpfile"; then
          warn "下载 $country_code IP 区域文件失败"
          rm -f "$tmpfile"
          continue
        fi
        while IFS= read -r ip; do
          ipset add "$ipset_name" "$ip" 2>/dev/null
        done < "$tmpfile"
        rm -f "$tmpfile"
        iptables -I INPUT -m set --match-set "$ipset_name" src -j ACCEPT
        log "已放行 $country_code 的 IP"
        ;;
      unblock)
        iptables -D INPUT -m set --match-set "$ipset_name" src -j DROP 2>/dev/null
        iptables -D INPUT -m set --match-set "$ipset_name" src -j ACCEPT 2>/dev/null
        ipset destroy "$ipset_name" 2>/dev/null
        log "已解除 $country_code 的 IP 规则"
        ;;
    esac
  done
  save_iptables_rules
}

# ── fail2ban ─────────────────────────────────────────────────────

f2b_install() {
  if command -v apt &>/dev/null; then
    apt install -y fail2ban rsyslog
    systemctl start rsyslog && systemctl enable rsyslog
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    ${PKG_MGR:-dnf} install -y fail2ban
  else
    warn "当前系统暂不支持自动安装 fail2ban"
    return 1
  fi
  systemctl start fail2ban && systemctl enable fail2ban
  log "fail2ban 已安装并启动"
}

f2b_config_ssh() {
  if ! command -v fail2ban-client &>/dev/null; then
    warn "请先安装 fail2ban"
    return 1
  fi

  local bantime findtime maxretry
  read -erp "封禁时长 [默认 1h]：" bantime
  read -erp "时间窗口 [默认 10m]：" findtime
  read -erp "重试次数 [默认 5]：" maxretry
  bantime=${bantime:-1h}
  findtime=${findtime:-10m}
  maxretry=${maxretry:-5}

  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
bantime = $bantime
findtime = $findtime
maxretry = $maxretry
logpath = /var/log/auth.log
EOF

  fail2ban-client reload >/dev/null 2>&1 || true
  sleep 2
  fail2ban-client status sshd || true
  log "fail2ban SSH jail 已配置"
}

f2b_status() {
  if ! command -v fail2ban-client &>/dev/null; then
    warn "fail2ban 未安装"
    return 1
  fi
  fail2ban-client reload 2>/dev/null
  sleep 1
  fail2ban-client status
}

# ── Docker 容器端口访问控制 ──────────────────────────────────────

block_container_port() {
  local container_name=$1
  local allowed_ip=$2

  local container_ip
  container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null)
  [[ -z "$container_ip" ]] && { warn "无法获取容器 IP"; return 1; }

  # TCP 封锁 + 白名单
  iptables -C DOCKER-USER -p tcp -d "$container_ip" -j DROP 2>/dev/null || iptables -I DOCKER-USER -p tcp -d "$container_ip" -j DROP
  iptables -C DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p tcp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
  iptables -C DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p tcp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
  # UDP 封锁 + 白名单
  iptables -C DOCKER-USER -p udp -d "$container_ip" -j DROP 2>/dev/null || iptables -I DOCKER-USER -p udp -d "$container_ip" -j DROP
  iptables -C DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p udp -s "$allowed_ip" -d "$container_ip" -j ACCEPT
  iptables -C DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -p udp -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT
  # ESTABLISHED
  iptables -C DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT

  save_iptables_rules
  log "已限制容器 $container_name 的访问（仅允许 $allowed_ip）"
}

clear_container_rules() {
  local container_name=$1
  local allowed_ip=$2

  local container_ip
  container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null)
  [[ -z "$container_ip" ]] && { warn "无法获取容器 IP"; return 1; }

  # 清除所有相关规则
  for proto in tcp udp; do
    iptables -D DOCKER-USER -p "$proto" -d "$container_ip" -j DROP 2>/dev/null
    iptables -D DOCKER-USER -p "$proto" -s "$allowed_ip" -d "$container_ip" -j ACCEPT 2>/dev/null
    iptables -D DOCKER-USER -p "$proto" -s 127.0.0.0/8 -d "$container_ip" -j ACCEPT 2>/dev/null
  done
  iptables -D DOCKER-USER -m state --state ESTABLISHED,RELATED -d "$container_ip" -j ACCEPT 2>/dev/null

  save_iptables_rules
  log "已解除容器 $container_name 的端口限制"
}

# ── 安全加固主菜单 ───────────────────────────────────────────────
mod_security_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           安全加固                   ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    echo "  1. SSH 安全"
    echo "  2. fail2ban 管理"
    echo "  3. iptables 防火墙"
    echo "  4. DDoS 防御"
    echo "  5. 国家 IP 封锁"
    echo "  6. Docker 容器端口控制"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) _ssh_menu ;;
      2) _f2b_menu ;;
      3) _iptables_menu ;;
      4) _ddos_menu ;;
      5) _country_menu ;;
      6) _container_port_menu ;;
      0|*) break ;;
    esac
  done
}

_ssh_menu() {
  while true; do
    clear
    echo -e "${W}SSH 安全管理${N}"
    echo "  1. 生成新密钥对"
    echo "  2. 导入已有公钥"
    echo "  3. 从 GitHub 导入公钥"
    echo "  4. 修改 SSH 端口"
    echo "  5. 开启密钥登录（关闭密码）"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) generate_ssh_key; break_end ;;
      2) import_ssh_key; break_end ;;
      3) import_github_keys; break_end ;;
      4) local p; read -erp "新端口号：" p; [[ -n "$p" ]] && change_ssh_port "$p"; break_end ;;
      5) sshkey_on; break_end ;;
      0|*) break ;;
    esac
  done
}

_f2b_menu() {
  while true; do
    clear
    echo -e "${W}fail2ban 管理${N}"
    echo "  1. 安装 fail2ban"
    echo "  2. 配置 SSH jail"
    echo "  3. 查看状态"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) f2b_install; break_end ;;
      2) f2b_config_ssh; break_end ;;
      3) f2b_status; break_end ;;
      0|*) break ;;
    esac
  done
}

_iptables_menu() {
  while true; do
    clear
    echo -e "${W}iptables 防火墙管理${N}"
    echo "  1. 开放端口"
    echo "  2. 关闭端口"
    echo "  3. 放行 IP"
    echo "  4. 封锁 IP"
    echo "  5. 重置防火墙（开放所有）"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) local p; read -erp "端口号（多个空格分隔）：" p; iptables_open_port $p; break_end ;;
      2) local p; read -erp "端口号（多个空格分隔）：" p; iptables_close_port $p; break_end ;;
      3) local ip; read -erp "IP 地址：" ip; [[ -n "$ip" ]] && allow_ip "$ip"; break_end ;;
      4) local ip; read -erp "IP 地址：" ip; [[ -n "$ip" ]] && block_ip "$ip"; break_end ;;
      5) iptables_reset; break_end ;;
      0|*) break ;;
    esac
  done
}

_ddos_menu() {
  while true; do
    clear
    echo -e "${W}DDoS 防御${N}"
    echo "  1. 开启 DDoS 防御"
    echo "  2. 关闭 DDoS 防御"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) enable_ddos_defense; break_end ;;
      2) disable_ddos_defense; break_end ;;
      0|*) break ;;
    esac
  done
}

_country_menu() {
  while true; do
    clear
    echo -e "${W}国家 IP 封锁${N}"
    echo "  1. 封锁指定国家 IP"
    echo "  2. 放行指定国家 IP"
    echo "  3. 解除指定国家封锁"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) local cc; read -erp "国家代码（如 CN, RU, US）：" cc; [[ -n "$cc" ]] && { apt install -y ipset >/dev/null 2>&1 || true; manage_country_rules block "$cc"; }; break_end ;;
      2) local cc; read -erp "国家代码：" cc; [[ -n "$cc" ]] && { apt install -y ipset >/dev/null 2>&1 || true; manage_country_rules allow "$cc"; }; break_end ;;
      3) local cc; read -erp "国家代码：" cc; [[ -n "$cc" ]] && manage_country_rules unblock "$cc"; break_end ;;
      0|*) break ;;
    esac
  done
}

_container_port_menu() {
  while true; do
    clear
    echo -e "${W}Docker 容器端口控制${N}"
    echo "  1. 限制容器访问（仅允许指定 IP）"
    echo "  2. 解除容器端口限制"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1)
        local name ip
        read -erp "容器名：" name
        read -erp "允许的 IP：" ip
        [[ -n "$name" && -n "$ip" ]] && block_container_port "$name" "$ip"
        break_end ;;
      2)
        local name ip
        read -erp "容器名：" name
        read -erp "之前允许的 IP：" ip
        [[ -n "$name" && -n "$ip" ]] && clear_container_rules "$name" "$ip"
        break_end ;;
      0|*) break ;;
    esac
  done
}
