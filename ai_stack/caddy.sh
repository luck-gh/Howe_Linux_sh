#!/usr/bin/env bash
# Caddy 安装 + Caddyfile 渲染 + 重新配置域名
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# Caddy
# ═══════════════════════════════════════════════════════════════════
install_caddy() {
  if ! command -v caddy &>/dev/null; then
    curl -fsSL "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] \
https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq || err "Caddy 源更新失败"
    apt-get install -y -qq caddy || err "Caddy 安装失败"
  fi
  # 首次安装时 setup_dirs 早于 caddy 用户创建, 此处再确定日志目录归属.
  install -d -o caddy -g caddy -m 0755 /var/log/caddy || return 1
  log "Caddy $(caddy version | head -1)"
}

# 本脚本只共享官方 systemd 服务的默认 FileStorage, 不猜测自定义存储位置.
_caddy_node_cert_dir() {
  local _domain=$1 _user _home _environment _envfiles _config
  _user=$(systemctl show caddy --property=User --value) || return 1
  _home=$(getent passwd caddy | cut -d: -f6) || return 1
  _environment=$(systemctl show caddy --property=Environment --value) || return 1
  _envfiles=$(systemctl show caddy --property=EnvironmentFiles --value) || return 1
  if [[ "$_user" != caddy || "$_home" != /var/lib/caddy || -n "$_envfiles" ]]; then
    warn "节点证书要求官方 caddy 用户、默认 HOME 和无自定义 EnvironmentFile 的 systemd 服务"
    return 1
  fi
  python3 - "$_environment" <<'PY' || return 1
import shlex
import sys
environment = dict(item.split("=", 1) for item in shlex.split(sys.argv[1]))
if (environment.get("HOME", "/var/lib/caddy") != "/var/lib/caddy"
        or environment.get("XDG_DATA_HOME", "/var/lib/caddy/.local/share") != "/var/lib/caddy/.local/share"):
    raise SystemExit("节点证书不支持自定义 Caddy HOME/XDG_DATA_HOME")
PY
  _config=$(caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile) || return 1
  if ! jq -e 'has("storage") | not' <<<"$_config" >/dev/null; then
    warn "节点证书不支持自定义 Caddy storage; 需使用官方默认 FileStorage"
    return 1
  fi
  printf '/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/%s\n' "$_domain"
}

# 证书来自外部文件: 检查 SAN、有效期、系统信任链和密钥配对, 不输出私钥.
_verify_clash_tls_certificate() {
  local _cert=$1 _key=$2 _domain=$3 _cert_pub _key_pub _san
  [[ -r "$_cert" && -r "$_key" ]] || { warn "节点受信任证书或私钥尚未就绪"; return 1; }
  _san=$(openssl x509 -in "$_cert" -noout -ext subjectAltName) || return 1
  [[ "$_san" == *"DNS:"* ]] || { warn "节点证书缺少 DNS SAN"; return 1; }
  openssl x509 -in "$_cert" -checkend 0 -noout >/dev/null || return 1
  openssl verify -purpose sslserver -verify_hostname "$_domain" -untrusted "$_cert" "$_cert" >/dev/null || return 1
  _cert_pub=$(openssl x509 -in "$_cert" -noout -pubkey) || return 1
  _key_pub=$(openssl pkey -in "$_key" -passin pass: -pubout) || return 1
  [[ "$_cert_pub" == "$_key_pub" ]] || { warn "节点证书与私钥不匹配"; return 1; }
}

wait_clash_tls_certificate() {
  local _domain _dir _attempt _error=""
  _domain=$(_clash_tls_domain) || return 1
  [[ -n "$_domain" ]] || return 0
  if ! ${INST_CADDY:-false}; then
    warn "严格 TLS 节点需要启用 Caddy 管理证书"
    return 1
  fi
  _dir=$(_caddy_node_cert_dir "$_domain") || return 1
  info "等待 Caddy 完成节点证书签发 (最多 120 秒)"
  for _attempt in {1..60}; do
    if _error=$(_verify_clash_tls_certificate "$_dir/$_domain.crt" "$_dir/$_domain.key" "$_domain" 2>&1); then
      return 0
    fi
    sleep 2
  done
  warn "节点证书校验未通过, 已停止安装; 请检查节点 DNS、80/443 和 Caddy 日志"
  printf '%s\n' "$_error" >&2
  return 1
}

write_caddyfile() {
  $INST_CADDY || return 0
  local _target="$BASE_DIR/caddy/Caddyfile" _cf _node_domain=""
  if ${INST_SINGBOX:-false}; then
    _node_domain=$(_clash_tls_domain) || return 1
    if [[ -n "$_node_domain" ]]; then
      _caddy_node_cert_dir "$_node_domain" >/dev/null || return 1
    fi
  fi
  _cf=$(mktemp "$BASE_DIR/caddy/Caddyfile.XXXXXX") || return 1

  if [[ -z "$DOMAIN" ]]; then
    # HTTP 模式：多行 handle 块（Caddy v2.11+ 不支持单行内联写法）
    # catch-all (/) 必须放在最后
    cat > "$_cf" <<EOF
# HTTP 测试模式
:8080 {
EOF
    $INST_WEBUI   && echo "  handle /${PREFIX_WEBUI}/* {" >> "$_cf" && echo "    reverse_proxy 127.0.0.1:13010" >> "$_cf" && echo "  }" >> "$_cf"
    $INST_LITELLM && echo "  handle /${PREFIX_LITELLM}/* {" >> "$_cf" && echo "    reverse_proxy 127.0.0.1:14000" >> "$_cf" && echo "  }" >> "$_cf"
    $INST_SUB2API && echo "  handle /${PREFIX_SUB2API}/* {" >> "$_cf" && echo "    reverse_proxy 127.0.0.1:13001" >> "$_cf" && echo "  }" >> "$_cf"
    $INST_DIFY    && echo "  handle /${PREFIX_DIFY}/* {" >> "$_cf" && echo "    reverse_proxy 127.0.0.1:13080" >> "$_cf" && echo "  }" >> "$_cf"
    if $INST_NEWAPI; then
      cat >> "$_cf" <<'EOF'
  handle /api/* {
    reverse_proxy 127.0.0.1:13000
  }
  handle /v1/* {
    reverse_proxy 127.0.0.1:13000
  }
  handle / {
    reverse_proxy 127.0.0.1:13000
  }
EOF
    fi
    echo "}" >> "$_cf"
    warn "HTTP 模式，建议仅测试使用"
  else
    local _tls="tls ${EMAIL}"
    [[ -z "$EMAIL" ]] && _tls="# tls（未填邮箱）"
    # 分布式模式下 Caddyfile 无需区分服务在哪里：
    # VPS 上的服务由本地 Docker 提供端口；本地的服务由 frp 隧道提供同样端口
    cat > "$_cf" <<EOF
# Caddyfile — AI Stack HTTPS
# 分布式模式：frp 隧道将本地服务的端口透传到 VPS 的 127.0.0.1，Caddy 无需感知
EOF
    if $INST_NEWAPI; then cat >> "$_cf" <<EOF
${PREFIX_NEWAPI}.${DOMAIN} {
  ${_tls}
  # 品牌资源：放在 ${BASE_DIR}/caddy/static/ 下的文件可通过
  # https://${PREFIX_NEWAPI}.${DOMAIN}/brand/<file> 访问（用于 logo / favicon 等）
  # 注意：路径必须避开 /static/*，否则会和 New-API 前端的 /static/js/* 冲突导致白屏
  handle_path /brand/* {
    root * ${BASE_DIR}/caddy/static
    file_server
  }
  handle {
    reverse_proxy 127.0.0.1:13000
  }
  log {
    output file /var/log/caddy/new-api.log {
      roll_size 10mb
      roll_keep 3
    }
  }
}
EOF
    fi
    if $INST_WEBUI; then cat >> "$_cf" <<EOF

${PREFIX_WEBUI}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:13010
}
EOF
    fi
    if $INST_LITELLM; then cat >> "$_cf" <<EOF

${PREFIX_LITELLM}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:14000
}
EOF
    fi
    if $INST_SUB2API; then cat >> "$_cf" <<EOF

${PREFIX_SUB2API}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:13001
}
EOF
    fi
    if $INST_DIFY; then cat >> "$_cf" <<EOF

${PREFIX_DIFY}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:13080
}
EOF
    fi
    if [[ "${INST_KIRO:-false}" == "true" ]]; then cat >> "$_cf" <<EOF

${PREFIX_KIRO:-kiro}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:13002
}
EOF
    fi
    if [[ "${INST_9ROUTER:-false}" == "true" ]]; then cat >> "$_cf" <<EOF

${PREFIX_9ROUTER:-9r}.${DOMAIN} {
  ${_tls}
  reverse_proxy 127.0.0.1:13003
}
EOF
    fi
    if $INST_SINGBOX; then
      local _blocks=""
      if [[ -x "$(_clash_py)" ]]; then
        _blocks=$(python3 "$(_clash_py)" --base "$(_clash_dir)" caddy-blocks 2>/dev/null || true)
      fi
      if [[ -n "$_blocks" ]]; then
        cat >> "$_cf" <<EOF

${PREFIX_VPS}.${DOMAIN} {
  ${_tls}
  # Clash 订阅（多订阅）：/sub/* 反代给 127.0.0.1:13888 (clash-subs-serve.service)
  # 每次客户端拉取时按需刷新流量统计，Subscription-Userinfo / Profile-Update-Interval /
  # Content-Disposition 由 serve.py 实时下发
${_blocks}
  # 其他路径全部拒绝（避免目录扫描）
  respond 404
}
EOF
      fi
    fi
  fi

  if [[ -n "$_node_domain" ]]; then
    cat >> "$_cf" <<EOF

# 节点证书由 Caddy 自动续期, sing-box 直接监听证书文件变化.
${_node_domain} {
  tls {
    issuer acme https://acme-v02.api.letsencrypt.org/directory
  }
  respond 404
}
EOF
  fi
  chmod 0644 "$_cf" || return 1
  # 使用实际服务身份预检, 避免 root 预检创建 caddy 无权续写的日志/数据文件.
  if ! runuser -u caddy -- caddy validate --config "$_cf" --adapter caddyfile; then
    rm -f -- "$_cf"
    return 1
  fi
  mv -f -- "$_cf" "$_target" || return 1
  ln -sf "$_target" /etc/caddy/Caddyfile || return 1
  systemctl enable caddy || return 1
  if systemctl restart caddy 2>&1; then
    log "Caddyfile → $_target"
  else
    err "Caddy 启动失败，请检查日志：journalctl -u caddy -n 20 --no-pager"
    echo "  Caddyfile 路径：$_target"
    echo ""
    echo "  常见原因："
    echo "    1. 端口 80/443 被占用 → ss -tlnp | grep -E ':80|:443'"
    echo "    2. Caddyfile 语法错误 → caddy validate --config $_target"
    echo "    3. DNS 未解析到本机 → 确认 A 记录指向 ${VPS_IP:-本机 IP}"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════
# 重新配置域名（独立流程，复用 write_caddyfile / check_dns）
# ═══════════════════════════════════════════════════════════════════
reconfigure_domain() {
  clear
  echo -e "${W}${C}  ── 重新配置域名 ─────────────────────────────────────────${N}"
  echo ""

  if ! command -v caddy &>/dev/null; then
    warn "Caddy 未安装"
    local _yn; askyn _yn "是否安装 Caddy？" "y"
    if $_yn; then
      install_caddy
    else
      info "无 Caddy 无法配置域名"
      return 1
    fi
  fi

  # 加载现有配置
  [[ -f "$BASE_DIR/.env" ]] && source "$BASE_DIR/.env"
  refresh_current_ipv4 || return 1
  detect_installed_services
  INST_CADDY=true

  # 把真实安装状态回写到 .env，纠正可能存在的过时 INST_*=false
  if [[ -f "$BASE_DIR/.env" ]]; then
    local _flag _val
    for _flag in INST_NEWAPI INST_WEBUI INST_LITELLM INST_SUB2API \
                 INST_DIFY INST_SINGBOX INST_CADDY INST_PGSQL INST_REDIS \
                 INST_KIRO INST_9ROUTER; do
      _val="${!_flag:-false}"
      if grep -q "^${_flag}=" "$BASE_DIR/.env"; then
        sed -i "s|^${_flag}=.*|${_flag}=${_val}|" "$BASE_DIR/.env"
      else
        echo "${_flag}=${_val}" >> "$BASE_DIR/.env"
      fi
    done
  fi

  echo -e "  公网 IP：${C}${VPS_IP:-未知}${N}"
  echo ""
  [[ -n "$DOMAIN" ]] && echo -e "  当前域名：${C}${DOMAIN}${N}"
  [[ -n "$EMAIL" ]] && echo -e "  当前邮箱：${DIM}${EMAIL}${N}"
  echo ""

  local _new_domain _new_email
  ask _new_domain "新域名（留空保持不变）" ""
  if [[ -z "$_new_domain" ]]; then
    info "域名未变更，重新生成 Caddyfile 以匹配当前已安装服务"
    write_caddyfile
    return 0
  fi
  _new_email="admin@${_new_domain}"
  ask _new_email "Let's Encrypt 邮箱" "$_new_email"

  # 更新 .env
  if [[ -f "$BASE_DIR/.env" ]]; then
    sed -i "s|^DOMAIN=.*|DOMAIN=${_new_domain}|" "$BASE_DIR/.env"
    sed -i "s|^EMAIL=.*|EMAIL=${_new_email}|" "$BASE_DIR/.env"
  fi
  DOMAIN="$_new_domain"
  EMAIL="$_new_email"
  log "域名已更新：${DOMAIN}"

  # 重新生成 Caddyfile 并重启
  sync_brand_assets || true
  write_caddyfile
  log "Caddy 已重启"

  # 同步 New-API 数据库里的 Logo URL（如果用户设过）
  sync_newapi_logo

  # DNS 预检
  check_dns

  echo ""
  warn "如果使用 Cloudflare 橙色云朵（CF 代理）："
  info "  CF Edge 证书传播需要 5-15 分钟，期间访问可能出现 SSL 错误，属正常现象"
  info "  CF Universal SSL 的通配符覆盖如 *.example.com，不覆盖 *.ai.example.com"
  info "  建议使用根域名下的直接子域，避免二级子域证书问题"
}

# ═══════════════════════════════════════════════════════════════════
# 同步 New-API options.Logo 的 URL 域名部分到当前 DOMAIN
# 仅在以下条件全部满足时生效：
#   - INST_NEWAPI=true
#   - DOMAIN 非空
#   - new-api 容器在跑且数据库 (ai-db) 可达
#   - options.Logo 当前已有非空值（用户设过 logo，否则不要凭空创造）
#   - 该值是 https://<旧子域>.<旧域>/static/<file> 形式（典型脚本部署的 logo）
# 不满足任一条件就静默跳过，不阻断主流程
# ═══════════════════════════════════════════════════════════════════
sync_newapi_logo() {
  $INST_NEWAPI || return 0
  [[ -n "$DOMAIN" ]] || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$'  || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$' || return 0

  local _cur _new _file _prefix
  _prefix="${PREFIX_NEWAPI:-aapi}"
  _cur=$(docker exec ai-db psql -U ai -d newapi -tAc \
        "SELECT value FROM options WHERE key='Logo';" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$_cur" ]]; then
    info "New-API Logo 未设置，跳过 URL 同步"
    return 0
  fi

  # 仅识别 /brand/<file>（脚本生成的品牌资源 URL），避免误改用户填的外链
  if [[ "$_cur" =~ ^https?://[^/]+/brand/([^/]+)$ ]]; then
    _file="${BASH_REMATCH[1]}"
  else
    info "New-API Logo URL 非脚本生成格式（${_cur}），不动"
    return 0
  fi

  _new="https://${_prefix}.${DOMAIN}/brand/${_file}"
  if [[ "$_cur" == "$_new" ]]; then
    info "New-API Logo URL 已是最新，跳过"
    return 0
  fi

  if docker exec ai-db psql -U ai -d newapi -c \
        "UPDATE options SET value='${_new}' WHERE key='Logo';" >/dev/null 2>&1; then
    log "New-API Logo URL 更新：${_cur} → ${_new}"
    docker restart new-api >/dev/null 2>&1 \
      && info "new-api 已重启以刷新 Logo 缓存" \
      || warn "new-api 重启失败，请手动 docker restart new-api"
  else
    warn "更新 options.Logo 失败，请检查数据库连接"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# Dify（仅 VPS 侧；若分配到本地则跳过）
# ═══════════════════════════════════════════════════════════════════
setup_dify() {
  $INST_DIFY || return 0
  if [[ "${LOC_DIFY:-vps}" == "local" ]]; then
    info "Dify 已分配到本地，VPS 跳过安装（见 ${LOCAL_PKG_DIR}/README.md）"
    return 0
  fi
  step "安装 Dify（VPS）"
  if [[ -d /opt/dify ]]; then
    warn "Dify 目录已存在，更新中..."
    git -C /opt/dify pull -q
  else
    log "克隆 Dify..."
    git clone --depth=1 https://github.com/langgenius/dify /opt/dify 2>/dev/null || err "Dify 克隆失败"
  fi
  cd /opt/dify/docker
  [[ -f .env ]] || cp .env.example .env
  sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${DIFY_SECRET}|" .env
  sed -i 's|^EXPOSE_NGINX_PORT=.*|EXPOSE_NGINX_PORT=13080|' .env
  docker compose up -d
  log "Dify 已启动（→ 127.0.0.1:13080）"
  cd "$BASE_DIR"
}

