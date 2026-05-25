#!/usr/bin/env bash
# sing-box + Dify + frp + 防火墙 + 启动 / 健康检查
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# sing-box AnyTLS（幂等版本检查）
# ═══════════════════════════════════════════════════════════════════
install_singbox() {
  $INST_SINGBOX || return 0
  step "安装 sing-box"

  local _ver
  _ver=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | jq -r '.tag_name' | tr -d 'v') || true
  # 验证版本号格式（防止 jq 返回 null 或空值）
  [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || _ver="1.13.0"

  local _cur=""
  command -v sing-box &>/dev/null && \
    _cur=$(sing-box version 2>/dev/null | awk 'NR==1{print $NF}') || true

  if [[ "$_cur" == "$_ver" ]]; then
    log "sing-box $_ver 已是最新，跳过"
    return 0
  fi

  local _arch
  case $(uname -m) in
    x86_64)  _arch="amd64" ;;
    aarch64) _arch="arm64" ;;
    armv7l)  _arch="armv7" ;;
    *)       err "不支持的架构：$(uname -m)" ;;
  esac

  wget -qO /tmp/sb.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/download/v${_ver}/sing-box-${_ver}-linux-${_arch}.tar.gz" \
    || err "sing-box 下载失败"
  tar -xzf /tmp/sb.tar.gz -C /tmp/ || err "sing-box 解压失败"
  install -m 755 "/tmp/sing-box-${_ver}-linux-${_arch}/sing-box" "$SINGBOX_BIN" || err "sing-box 安装失败"
  rm -rf /tmp/sb.tar.gz "/tmp/sing-box-${_ver}-linux-${_arch}"
  log "sing-box $($SINGBOX_BIN version | awk '/sing-box/{print $2}')"
}

# 加载 nftables clash_subs 表（端口 counter + drop set）
# 由 clash_subs.py nft-config 输出规则集
# 幂等策略（避免清零 counter）：
#   - table 不存在     → 直接 -f 加载
#   - 端口集合未变化   → 不动 table，避免清零 counter；disabled_ports 由轮询/serve 增量维护
#   - 端口集合有变化   → 把当前 counter 值快照写到 .nft_state.yaml 再 reload
#     （让下次差分入账以「重置后的 0」为基准，不会把当前值整段误算成增量）
setup_clash_nft() {
  $INST_SINGBOX || return 0
  command -v nft &>/dev/null || { warn "nft 未安装，跳过流量统计"; return 1; }
  [[ -x "$(_clash_py)" ]] || return 1
  local _rules
  _rules=$(python3 "$(_clash_py)" --base "$(_clash_dir)" nft-config 2>/dev/null) || return 1

  # 解析期望端口集（来自 nft-config 输出的 c-in-<port> 计数器）
  local _want
  _want=$(grep -oE 'c-in-[0-9]+' <<<"$_rules" | sed 's/^c-in-//' | sort -un | tr '\n' ' ')

  if nft list table inet clash_subs &>/dev/null; then
    # 当前已有 table → 比较端口集
    local _have
    _have=$(nft list table inet clash_subs 2>/dev/null \
            | grep -oE 'counter c-in-[0-9]+' \
            | sed 's/^counter c-in-//' | sort -un | tr '\n' ' ')
    if [[ "$_have" == "$_want" ]]; then
      # 端口集未变 → 跳过 reload，counter 保留
      return 0
    fi
    # 端口集变了 → 在 reload 前把当前 counter 值同步进 .nft_state.yaml，
    # 防止下次轮询差分把"重置前的高值"误判为增量入账
    nft -j list table inet clash_subs 2>/dev/null \
      | python3 "$(_clash_py)" --base "$(_clash_dir)" usage-from-nft --json - >/dev/null 2>&1 || true
  fi

  # 重建 table
  nft delete table inet clash_subs 2>/dev/null || true
  echo "$_rules" | nft -f - || { warn "nft 加载 clash_subs 失败"; return 1; }
  return 0
}

# 重写 sing-box config 并 restart + 同步 nftables（订阅增/删/改密码 / disabled 后调用）
# 仅在 config 真的发生变化时才 restart sing-box（避免断开在线客户端连接）
reload_clash_subscription() {
  $INST_SINGBOX || return 0
  command -v sing-box &>/dev/null || return 0
  local _cfg=/etc/sing-box/config.json _old_hash=""
  [[ -f "$_cfg" ]] && _old_hash=$(sha256sum "$_cfg" | awk '{print $1}')
  write_singbox_config
  setup_clash_nft || true
  _sync_clash_ufw || true
  if systemctl is-active sing-box &>/dev/null; then
    local _new_hash=""
    [[ -f "$_cfg" ]] && _new_hash=$(sha256sum "$_cfg" | awk '{print $1}')
    if [[ "$_old_hash" != "$_new_hash" ]]; then
      systemctl restart sing-box || warn "sing-box restart 失败（配置已更新但服务未重启）"
    fi
  fi
}

write_singbox_config() {
  $INST_SINGBOX || return 0

  # 兜底：VPS_IP 若空，再尝试一次（写 config 前必须有可信值，否则证书 CN/SNI 会回退到 localhost）
  if [[ -z "${VPS_IP:-}" ]]; then
    VPS_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
          || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
          || echo "")
  fi
  [[ -n "$VPS_IP" ]] || warn "无法获取公网 IP，sing-box 证书 CN 将回退到 localhost（客户端连接需 skip-cert-verify=true）"

  # 确保日志目录可写
  touch /var/log/sing-box.log 2>/dev/null || true

  # 自签证书（Caddy 已占 80，sing-box 无法 ACME）
  # 只在缺失或 CN 与当前 VPS_IP 不一致时重新生成
  local _need_regen=true
  if [[ -f "$SINGBOX_DIR/cert.pem" ]] && [[ -n "$VPS_IP" ]]; then
    local _cur_cn
    _cur_cn=$(openssl x509 -in "$SINGBOX_DIR/cert.pem" -noout -subject 2>/dev/null \
            | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
    [[ "$_cur_cn" == "$VPS_IP" ]] && _need_regen=false
  fi
  if $_need_regen; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -keyout "$SINGBOX_DIR/key.pem" -out "$SINGBOX_DIR/cert.pem" \
      -days 3650 -nodes -subj "/CN=${VPS_IP:-localhost}" 2>/dev/null
    log "自签 TLS 证书已生成（CN=${VPS_IP:-localhost}, 10年）"
  else
    info "TLS 证书已存在（CN=${VPS_IP}），保持不变"
  fi

  # 多 inbound：每订阅独立 anytls 端口；clash_subs.py 输出 inbounds[] JSON
  local _inbounds_json="[]"
  if [[ -x "$(_clash_py)" ]] && [[ -f "$(_clash_dir)/subs.yaml" ]]; then
    _inbounds_json=$(python3 "$(_clash_py)" --base "$(_clash_dir)" \
                       sing-box-inbounds \
                       --tls-cert "$SINGBOX_DIR/cert.pem" \
                       --tls-key  "$SINGBOX_DIR/key.pem" \
                       --server-name "${VPS_IP:-localhost}" 2>/dev/null || echo "[]")
  fi
  # sing-box 至少要有一个 inbound 才能起。空时塞一个监听 127.0.0.1 的占位 inbound
  if ! echo "$_inbounds_json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    _inbounds_json=$(jq -nc --arg cert "$SINGBOX_DIR/cert.pem" --arg key "$SINGBOX_DIR/key.pem" \
      --arg sni "${VPS_IP:-localhost}" '[
      {"type":"direct","tag":"placeholder","listen":"127.0.0.1","listen_port":1}
    ]')
  fi

  cat > "$SINGBOX_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true, "output": "/var/log/sing-box.log" },
  "dns": {
    "servers": [
      { "tag": "cf",  "type": "tls", "server": "1.1.1.1" },
      { "tag": "ali", "type": "udp", "server": "223.5.5.5" }
    ],
    "final": "cf"
  },
  "inbounds": ${_inbounds_json},
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "default_domain_resolver": "cf",
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
  chmod 600 "$SINGBOX_DIR/config.json"

  cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box AnyTLS 代理（多订阅独立端口）
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now sing-box
  local _n
  _n=$(echo "$_inbounds_json" | jq 'length' 2>/dev/null || echo "?")
  log "sing-box 已启动（${_n} 个订阅 inbound）"
}

# ═══════════════════════════════════════════════════════════════════
# frp 服务端（分布式，幂等）
# ═══════════════════════════════════════════════════════════════════
install_frp_server() {
  [[ "$DEPLOY_MODE" != "distributed" ]] && return 0
  step "安装 frp 穿透服务端"

  if ! command -v frps &>/dev/null; then
    local _ver
    _ver=$(curl -fsSL "https://api.github.com/repos/fatedier/frp/releases/latest" \
      | jq -r '.tag_name' | tr -d 'v') || _ver="0.61.0"
    local _arch
    case $(uname -m) in
      x86_64)  _arch="amd64" ;;
      aarch64) _arch="arm64" ;;
      armv7l)  _arch="arm"   ;;
      *)       err "不支持的架构" ;;
    esac
    local _tb="frp_${_ver}_linux_${_arch}.tar.gz"
    log "下载 frp v${_ver}..."
    wget -qO /tmp/frp.tar.gz \
      "https://github.com/fatedier/frp/releases/download/v${_ver}/${_tb}" \
      || err "frp 下载失败"
    tar -xzf /tmp/frp.tar.gz -C /tmp/ || err "frp 解压失败"
    install -m 755 "/tmp/frp_${_ver}_linux_${_arch}/frps" /usr/local/bin/frps || err "frps 安装失败"
    rm -rf /tmp/frp.tar.gz "/tmp/frp_${_ver}_linux_${_arch}"
  else
    log "frps 已存在，跳过下载"
  fi

  mkdir -p /etc/frp
  cat > /etc/frp/frps.toml <<EOF
# frp 服务端
bindPort = ${FRP_PORT}
[auth]
method = "token"
token = "${FRP_TOKEN}"
[log]
to = "/var/log/frps.log"
level = "info"
maxDays = 3
EOF
  chmod 600 /etc/frp/frps.toml

  cat > /etc/systemd/system/frps.service <<'UNIT'
[Unit]
Description=frp 服务端（AI Stack 分布式穿透）
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now frps
  log "frps 已启动，监听端口 ${FRP_PORT}"
}

# ═══════════════════════════════════════════════════════════════════
# 防火墙（幂等，不 reset，逐条 allow）
# ═══════════════════════════════════════════════════════════════════
configure_firewall() {
  step "配置 UFW 防火墙"
  ufw default deny incoming  &>/dev/null
  ufw default allow outgoing &>/dev/null

  ufw allow ssh    comment 'SSH'   &>/dev/null
  ufw allow 80/tcp comment 'HTTP'  &>/dev/null
  ufw allow 443/tcp comment 'HTTPS' &>/dev/null
  $INST_SINGBOX && ufw allow "$(_clash_port_range)/tcp" comment 'Clash anytls subs' &>/dev/null

  if [[ "$DEPLOY_MODE" == "distributed" ]]; then
    ufw allow "${FRP_PORT}/tcp" comment 'frp tunnel' &>/dev/null
  fi

  # 无 Caddy 时：服务直接暴露端口，需开放防火墙
  if ! $INST_CADDY; then
    $INST_NEWAPI  && ufw allow 13000/tcp comment 'New-API direct' &>/dev/null
    $INST_WEBUI   && [[ "${LOC_WEBUI:-vps}" == "vps" ]] && ufw allow 13010/tcp comment 'OpenWebUI direct' &>/dev/null
    $INST_LITELLM && [[ "${LOC_LITELLM:-vps}" == "vps" ]] && ufw allow 14000/tcp comment 'LiteLLM direct' &>/dev/null
    $INST_SUB2API && [[ "${LOC_SUB2API:-vps}" == "vps" ]] && ufw allow 13001/tcp comment 'Sub2API direct' &>/dev/null
  fi

  ufw --force enable &>/dev/null
  log "防火墙已更新："
  ufw status | grep -E 'ALLOW|Status' | sed 's/^/  /'
}

# ═══════════════════════════════════════════════════════════════════
# 启动 VPS Docker 服务
# ═══════════════════════════════════════════════════════════════════
start_services() {
  step "拉取镜像并启动服务"
  if ! has_vps_compose_service; then
    info "本次没有 VPS Docker 服务需要启动"
    return 0
  fi
  cd "$BASE_DIR"

  # 验证 compose 文件
  if ! docker compose config -q 2>/dev/null; then
    err "docker-compose.yml 格式错误，请检查 $BASE_DIR/docker-compose.yml"
  fi

  info "即将拉取以下镜像："
  docker compose config --images 2>/dev/null | sed 's/^/    /'

  docker compose pull || err "镜像拉取失败（如在中国大陆，建议配置 Docker 镜像加速）"
  docker compose up -d || err "服务启动失败，查看日志：docker compose -f $BASE_DIR/docker-compose.yml logs"
  log "容器已启动"
}

# ═══════════════════════════════════════════════════════════════════
# 健康检查（等待容器就绪，最多 90s）
# ═══════════════════════════════════════════════════════════════════
health_check() {
  step "健康检查"
  if ! has_vps_compose_service; then
    info "本次没有 VPS Docker 服务，跳过 Docker 健康检查"
    return 0
  fi
  local _timeout=90 _waited=0 _interval=5

  while [[ $_waited -lt $_timeout ]]; do
    local _starting
    _starting=$(docker compose -f "$BASE_DIR/docker-compose.yml" ps \
      --format '{{.Status}}' 2>/dev/null | grep -c 'starting\|health: starting' || true)
    [[ "$_starting" -eq 0 ]] && break
    info "等待 ${_starting} 个容器就绪...（${_waited}s / ${_timeout}s）"
    sleep $_interval
    _waited=$((_waited+_interval))
  done

  echo ""
  docker compose -f "$BASE_DIR/docker-compose.yml" ps \
    --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | sed 's/^/  /' || true

  local _bad
  _bad=$(docker compose -f "$BASE_DIR/docker-compose.yml" ps \
    --format '{{.Service}} {{.Status}}' 2>/dev/null \
    | awk '$2~/unhealthy|Exit/' || true)

  if [[ -n "$_bad" ]]; then
    warn "以下服务异常："
    echo "$_bad" | sed 's/^/    /'
    warn "查看日志：cd $BASE_DIR && docker compose logs <服务名>"
  else
    log "所有 VPS 服务运行正常"
  fi
}

