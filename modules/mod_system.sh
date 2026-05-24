#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 系统管理模块
#
# 功能：系统信息 / 系统更新 / 系统清理 / Swap 管理 / 备份恢复 / dpkg 修复
# 来源：kejilion.sh（已去除遥测和安全隐患）
# ═══════════════════════════════════════════════════════════════════

# ── 修复 dpkg ─────────────────────────────────────────────────────
fix_dpkg() {
  pkill -9 -f 'apt|dpkg' 2>/dev/null || true
  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

# ── 系统更新 ─────────────────────────────────────────────────────
system_update() {
  section "系统更新"
  if command -v apt &>/dev/null; then
    fix_dpkg
    DEBIAN_FRONTEND=noninteractive apt update -y
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
  elif command -v dnf &>/dev/null; then
    dnf -y update
  elif command -v yum &>/dev/null; then
    yum -y update
  elif command -v apk &>/dev/null; then
    apk update && apk upgrade
  elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm
  elif command -v zypper &>/dev/null; then
    zypper refresh && zypper update
  else
    warn "未知的包管理器"
    return 1
  fi
  log "系统更新完成"
}

# ── 系统清理 ─────────────────────────────────────────────────────
system_clean() {
  section "系统清理"
  if command -v apt &>/dev/null; then
    fix_dpkg
    apt autoremove --purge -y
    apt clean -y
    apt autoclean -y
  elif command -v dnf &>/dev/null; then
    rpm --rebuilddb 2>/dev/null
    dnf autoremove -y
    dnf clean all
  elif command -v yum &>/dev/null; then
    rpm --rebuilddb 2>/dev/null
    yum autoremove -y
    yum clean all
  elif command -v apk &>/dev/null; then
    apk cache clean
    rm -rf /var/cache/apk/*
  elif command -v pacman &>/dev/null; then
    pacman -Rns $(pacman -Qdtq 2>/dev/null) --noconfirm 2>/dev/null
    pacman -Scc --noconfirm
  elif command -v zypper &>/dev/null; then
    zypper clean --all
  else
    warn "未知的包管理器"
    return 1
  fi

  # 通用清理
  journalctl --rotate 2>/dev/null
  journalctl --vacuum-time=1s 2>/dev/null
  journalctl --vacuum-size=500M 2>/dev/null
  log "系统清理完成"
}

# ── Swap 管理 ────────────────────────────────────────────────────
manage_swap() {
  local current_swap
  current_swap=$(free -m | awk 'NR==3{print $2}')

  section "Swap 管理"
  echo -e "  当前 Swap：${W}${current_swap}MB${N}"
  echo ""

  local new_swap
  ask new_swap "输入新的 Swap 大小（MB，0=禁用）" "${current_swap}"

  # 禁用现有 swap
  swapoff /swapfile 2>/dev/null
  rm -f /swapfile

  if [[ "$new_swap" -gt 0 ]]; then
    fallocate -l "${new_swap}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # 持久化
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab

    # Alpine 支持
    if [[ -f /etc/alpine-release ]]; then
      echo "nohup swapon /swapfile" > /etc/local.d/swap.start
      chmod +x /etc/local.d/swap.start
      rc-update add local 2>/dev/null
    fi

    log "Swap 已设置为 ${new_swap}MB"
  else
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
    log "Swap 已禁用"
  fi
}

# ── 系统信息展示 ─────────────────────────────────────────────────
show_system_info() {
  section "系统信息"

  get_network_traffic

  local cpu_info=$(lscpu 2>/dev/null | awk -F': +' '/Model name:/ {print $2; exit}')
  local cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' \
    <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat) 2>/dev/null || echo "N/A")
  local cpu_cores=$(nproc 2>/dev/null || echo "?")
  local mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')
  local swap_info=$(free -m | awk 'NR==3{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')
  local disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')
  local kernel_version=$(uname -r)
  local hostname=$(uname -n)
  local congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
  local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "N/A")
  local load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
  local runtime=$(cat /proc/uptime | awk -F. '{run_days=int($1/86400);run_hours=int(($1%86400)/3600);run_minutes=int(($1%3600)/60); if (run_days>0) printf("%d天 ",run_days); if (run_hours>0) printf("%d时 ",run_hours); printf("%d分\n",run_minutes)}')
  local dns_addr=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

  echo -e "${C}─────────────────────────────────────"
  echo -e "${C}主机名:       ${N}$hostname"
  echo -e "${C}系统版本:     ${N}${DISTRO_PRETTY}"
  echo -e "${C}Linux 内核:   ${N}$kernel_version"
  echo -e "${C}─────────────────────────────────────"
  echo -e "${C}CPU 型号:     ${N}$cpu_info"
  echo -e "${C}CPU 核心:     ${N}${cpu_cores}核"
  echo -e "${C}CPU 占用:     ${N}${cpu_usage}%"
  echo -e "${C}系统负载:     ${N}$load"
  echo -e "${C}─────────────────────────────────────"
  echo -e "${C}物理内存:     ${N}$mem_info"
  echo -e "${C}虚拟内存:     ${N}$swap_info"
  echo -e "${C}硬盘占用:     ${N}$disk_info"
  echo -e "${C}─────────────────────────────────────"
  echo -e "${C}总接收/发送:  ${N}${NET_RX} / ${NET_TX}"
  echo -e "${C}网络算法:     ${N}$congestion / $qdisc"
  echo -e "${C}─────────────────────────────────────"
  [[ -n "$PUBLIC_IP" ]] && echo -e "${C}公网 IP:      ${N}$PUBLIC_IP"
  [[ -n "$IPV6_ADDRESS" ]] && echo -e "${C}IPv6:         ${N}$IPV6_ADDRESS"
  [[ -n "$ISP_INFO" ]] && echo -e "${C}运营商:       ${N}$ISP_INFO"
  echo -e "${C}DNS:          ${N}$dns_addr"
  echo -e "${C}─────────────────────────────────────"
  echo -e "${C}运行时长:     ${N}$runtime"
  echo ""
}

# ── 备份管理 ─────────────────────────────────────────────────────
BACKUP_DIR="/backups"

create_backup() {
  local TIMESTAMP=$(date +"%Y%m%d%H%M%S")

  echo "创建备份示例："
  echo "  - 备份单个目录: /var/www"
  echo "  - 备份多个目录: /etc /home /var/log"
  echo "  - 直接回车将使用默认目录 (/etc /home)"
  local input
  read -erp "请输入要备份的目录（空格分隔，回车默认）：" input

  local -a BACKUP_PATHS
  if [[ -z "$input" ]]; then
    BACKUP_PATHS=("/etc" "/home")
  else
    IFS=' ' read -r -a BACKUP_PATHS <<< "$input"
  fi

  local PREFIX=""
  for path in "${BACKUP_PATHS[@]}"; do
    PREFIX+="$(basename "$path")_"
  done
  PREFIX=${PREFIX%_}

  local BACKUP_NAME="${PREFIX}_${TIMESTAMP}.tar.gz"
  mkdir -p "$BACKUP_DIR"

  echo "正在创建备份 $BACKUP_NAME..."
  if tar -czvf "$BACKUP_DIR/$BACKUP_NAME" "${BACKUP_PATHS[@]}"; then
    log "备份创建成功: $BACKUP_DIR/$BACKUP_NAME"
  else
    warn "备份创建失败"
    return 1
  fi
}

restore_backup() {
  list_backups
  echo ""
  local name
  read -erp "请输入要恢复的备份文件名：" name

  if [[ ! -f "$BACKUP_DIR/$name" ]]; then
    warn "备份文件不存在"
    return 1
  fi

  echo "正在恢复备份 $name..."
  if tar -xzvf "$BACKUP_DIR/$name" -C /; then
    log "备份恢复成功"
  else
    warn "备份恢复失败"
    return 1
  fi
}

list_backups() {
  mkdir -p "$BACKUP_DIR"
  echo -e "  ${W}可用备份：${N}"
  ls -lh "$BACKUP_DIR" 2>/dev/null || echo "  （空）"
}

delete_backup() {
  list_backups
  echo ""
  local name
  read -erp "请输入要删除的备份文件名：" name

  if [[ ! -f "$BACKUP_DIR/$name" ]]; then
    warn "备份文件不存在"
    return 1
  fi

  rm -f "$BACKUP_DIR/$name"
  log "备份已删除"
}

# ── 系统管理主菜单 ───────────────────────────────────────────────
mod_system_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           系统管理                   ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    echo "  1. 系统信息查看"
    echo "  2. 系统更新"
    echo "  3. 系统清理"
    echo "  4. Swap 管理"
    echo "  5. dpkg 修复（仅 Debian/Ubuntu）"
    echo "  ─────────────────"
    echo "  6. 系统备份"
    echo "  7. 系统恢复"
    echo "  8. 查看备份列表"
    echo "  9. 删除备份"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) show_system_info; break_end ;;
      2) system_update; break_end ;;
      3) system_clean; break_end ;;
      4) manage_swap; break_end ;;
      5) fix_dpkg && log "dpkg 修复完成"; break_end ;;
      6) create_backup; break_end ;;
      7) restore_backup; break_end ;;
      8) list_backups; break_end ;;
      9) delete_backup; break_end ;;
      0|*) break ;;
    esac
  done
}
