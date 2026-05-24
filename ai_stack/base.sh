#!/usr/bin/env bash
# install_deps + setup_dirs + 品牌资产同步
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 安装系统依赖（幂等）
# ═══════════════════════════════════════════════════════════════════
install_deps() {
  step "安装系统依赖"
  apt-get update -qq || err "apt-get update 失败"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget jq unzip openssl ca-certificates gnupg ufw \
    dnsutils lsb-release apt-transport-https git || err "系统依赖安装失败"

  if ! command -v docker &>/dev/null; then
    log "安装 Docker..."
    curl -fsSL https://get.docker.com | bash -s -- --quiet || err "Docker 安装失败"
  else
    log "Docker 已存在：$(docker --version | cut -d' ' -f3 | tr -d ',')"
  fi
  if ! docker compose version &>/dev/null 2>&1; then
    apt-get install -y -qq docker-compose-plugin || err "docker-compose-plugin 安装失败"
  fi
  systemctl enable --now docker &>/dev/null || err "无法启动 Docker"
  log "Docker 就绪"
}

# ═══════════════════════════════════════════════════════════════════
# 目录初始化
# ═══════════════════════════════════════════════════════════════════
setup_dirs() {
  step "初始化目录"
  mkdir -p \
    "$BASE_DIR"/{new-api/data,openwebui/data,litellm,sub2api/data,caddy/clash,caddy/static,dify} \
    "$SINGBOX_DIR" /var/log/caddy
  # Caddy 日志目录权限
  getent group caddy &>/dev/null && chown -R caddy:caddy /var/log/caddy || true
  sync_brand_assets
  log "根目录：$BASE_DIR"
}

# ═══════════════════════════════════════════════════════════════════
# 同步仓库 doc/ 下的品牌资源（logo / favicon 等）到 caddy/static/
# - 文件不存在则跳过该项，不影响其他流程
# - 已存在的同名文件会被覆盖（用 cmp -s 判等避免无变更时改 mtime）
# - 返回值：0=同步过有变化或同步成功，1=没源文件可同步（用于上层判断是否要 reload Caddy）
# ═══════════════════════════════════════════════════════════════════
sync_brand_assets() {
  local _repo_doc="${_AI_STACK_DIR%/}/../doc"
  local _dst="$BASE_DIR/caddy/static"
  [[ -d "$_repo_doc" ]] || return 1
  mkdir -p "$_dst"
  local _f _bn _changed=0 _seen=0
  for _f in "$_repo_doc"/AAPI_LOGO.ico "$_repo_doc"/favicon.ico "$_repo_doc"/logo.png; do
    [[ -f "$_f" ]] || continue
    _seen=1
    _bn=$(basename "$_f")
    if [[ ! -f "$_dst/$_bn" ]] || ! cmp -s "$_f" "$_dst/$_bn"; then
      cp -f "$_f" "$_dst/$_bn"
      _changed=1
      log "品牌资源更新：$_bn"
    fi
  done
  [[ $_seen -eq 0 ]] && return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════════
# 用户入口：刷新品牌资源（菜单调用）
# - 把仓库 doc/ 下最新的 logo 等同步到 caddy/static/
# - 因为文件系统直接被 Caddy 的 file_server 读取，无需 reload Caddy
# - 浏览器侧需要清缓存才能看到（ico 通常会被缓存得很久）
# ═══════════════════════════════════════════════════════════════════
refresh_brand_assets() {
  step "刷新品牌资源"
  if sync_brand_assets; then
    log "已同步到 $BASE_DIR/caddy/static/"
    info "Caddy 直接从文件系统读取，无需 reload"
    info "浏览器有强缓存时请用 Ctrl+Shift+R 强刷"
  else
    warn "未在 ${_AI_STACK_DIR%/}/../doc 下找到任何品牌资源（AAPI_LOGO.ico / favicon.ico / logo.png）"
  fi
}
