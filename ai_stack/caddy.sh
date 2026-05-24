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
  log "Caddy $(caddy version | head -1)"
}

write_caddyfile() {
  $INST_CADDY || return 0
  local _cf="$BASE_DIR/caddy/Caddyfile"

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

  ln -sf "$_cf" /etc/caddy/Caddyfile
  systemctl enable caddy 2>/dev/null
  if systemctl restart caddy 2>&1; then
    log "Caddyfile → $_cf"
  else
    err "Caddy 启动失败，请检查日志：journalctl -u caddy -n 20 --no-pager"
    echo "  Caddyfile 路径：$_cf"
    echo ""
    echo "  常见原因："
    echo "    1. 端口 80/443 被占用 → ss -tlnp | grep -E ':80|:443'"
    echo "    2. Caddyfile 语法错误 → caddy validate --config $_cf"
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
  VPS_IP="${VPS_IP:-$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")}"
  detect_installed_services
  INST_CADDY=true

  # 把真实安装状态回写到 .env，纠正可能存在的过时 INST_*=false
  if [[ -f "$BASE_DIR/.env" ]]; then
    local _flag _val
    for _flag in INST_NEWAPI INST_WEBUI INST_LITELLM INST_SUB2API \
                 INST_DIFY INST_SINGBOX INST_CADDY INST_PGSQL INST_REDIS; do
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

