#!/usr/bin/env bash
# 资源探测 + preflight + deploy_mode + 服务安装状态
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 资源探测 & 评估
# ═══════════════════════════════════════════════════════════════════
detect_resources() {
  SYS_CPU=$(nproc 2>/dev/null || echo 1)
  SYS_MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  SYS_MEM_GB=$(awk "BEGIN{printf \"%.1f\", ${SYS_MEM_MB}/1024}")
  SYS_DISK_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub("G","",$4); print int($4)}')
}

# assess_svc <内存MB> <磁盘GB> [flag]  →  echo "ok|warn|err|<提示>"
# 基线：OS(~200MB) + New-API(256MB) + sing-box(64MB) = 520MB 已被核心服务占用
# 对非核心服务，用"核心后剩余"做评估，避免 1GB VPS 上 OpenWebUI 误判为绿色
_CORE_OVERHEAD=520
assess_svc() {
  local mem=$1 disk=$2 flag=${3:-}

  [[ "$flag" == "dep" ]] && {
    echo "ok|自动随依赖项安装，无需手动选择"
    return
  }

  [[ "$flag" == "overlap" ]] && {
    echo "warn|与 New-API 功能重叠，仅大量 Key 轮转场景才需要"
    return
  }

  # 核心服务（New-API / sing-box）自身占用已计入 _CORE_OVERHEAD，直接检查总 RAM
  if [[ "$flag" == "locked" || "$flag" == "core" ]]; then
    [[ $SYS_MEM_MB -lt $mem ]] && {
      echo "err|内存不足（需 ${mem}MB，当前 ${SYS_MEM_MB}MB）"
      return
    }
    echo "ok|配置充裕，可安装"
    return
  fi

  # 非核心服务：基线 = 核心后剩余
  local _avail=$(( SYS_MEM_MB - _CORE_OVERHEAD ))
  [[ $_avail -lt 0 ]] && _avail=0

  [[ $_avail -lt $mem ]] && {
    echo "err|内存不足（核心后剩余 ${_avail}MB，此服务需 ${mem}MB）— 必须放本地"
    return
  }

  local _margin=$(( _avail - mem ))
  [[ $_margin -lt 200 ]] && {
    echo "warn|内存偏紧（核心后剩余 ${_avail}MB，安装后仅剩 ${_margin}MB）— 建议放本地"
    return
  }

  [[ $disk -gt 0 && $SYS_DISK_GB -lt $disk ]] && {
    echo "err|磁盘不足（需 ${disk}GB，剩余 ${SYS_DISK_GB}GB）"
    return
  }

  echo "ok|配置充裕，可安装"
}

# ═══════════════════════════════════════════════════════════════════
# 环境预检
# ═══════════════════════════════════════════════════════════════════
preflight() {
  [[ $EUID -ne 0 ]] && err "请用 root 运行：sudo bash $0"
  [[ -f /etc/os-release ]] || err "无法识别操作系统"
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "$ID" =~ ^(ubuntu|debian)$ ]] || err "仅支持 Ubuntu/Debian（当前：$ID）"
  log "操作系统：$PRETTY_NAME"
  detect_resources
  log "硬件：${SYS_CPU}核 CPU | ${SYS_MEM_MB}MB RAM | ${SYS_DISK_GB}GB 磁盘"
  curl -fs --max-time 8 https://github.com > /dev/null || err "无法访问外网，请检查网络"
  log "网络连通"
  VPS_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
  [[ -n "$VPS_IP" ]] && log "公网 IP：${VPS_IP}" || warn "无法获取公网 IP"
}

# ═══════════════════════════════════════════════════════════════════
# 服务安装状态探测（统一检测框架）
# ═══════════════════════════════════════════════════════════════════

# 确保常见安装路径在 PATH 中
_ensure_path() {
  [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
  [[ -d "/usr/local/bin" ]] && [[ ":$PATH:" != *":/usr/local/bin:"* ]] && export PATH="/usr/local/bin:$PATH"
}

# ── docker ps 快照缓存 ────────────────────────────────────────────
# 每个服务各 spawn 一次 docker 会造成进程风暴（一次菜单渲染约 18 次
# docker ps）。这里把容器名单快照到变量，同一波检测复用，避免反复
# CLI→daemon 往返。用 bash 内置 SECONDS（无子进程）做 TTL。
_DOCKER_PS_ALL=""      # 所有容器名（docker ps -a），换行分隔
_DOCKER_PS_RUN=""      # 运行中容器名（docker ps）
_DOCKER_PS_TS=-100     # 上次刷新时的 SECONDS；初值确保首次必刷
_DOCKER_PS_TTL=3       # 缓存有效期（秒）

# 强制刷新快照（状态变更后可显式调用以立即反映）
_docker_ps_refresh() {
  if command -v docker &>/dev/null; then
    _DOCKER_PS_ALL=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
    _DOCKER_PS_RUN=$(docker ps --format '{{.Names}}' 2>/dev/null)
  else
    _DOCKER_PS_ALL=""; _DOCKER_PS_RUN=""
  fi
  _DOCKER_PS_TS=$SECONDS
}

# 按 TTL 惰性刷新：新鲜则复用，过期才重新 spawn docker
_docker_ps_ensure() {
  (( SECONDS - _DOCKER_PS_TS < _DOCKER_PS_TTL )) && return 0
  _docker_ps_refresh
}

# 通用服务状态检测
# 用法：svc_check <检测方式> <目标>
# 检测方式：docker=容器名 | systemd=服务名 | binary=命令名 | dir=目录路径
# 返回：0=已安装/运行中  1=未安装
svc_check() {
  local _type="$1" _target="$2"
  case "$_type" in
    docker)
      command -v docker &>/dev/null || return 1
      _docker_ps_ensure
      grep -Fxq "$_target" <<< "$_DOCKER_PS_ALL"
      ;;
    systemd)
      command -v "$_target" &>/dev/null
      ;;
    binary)
      command -v "$_target" &>/dev/null
      ;;
    dir)
      [[ -d "$_target" ]]
      ;;
  esac
}

# 通用服务运行状态检测
# 用法：svc_running <检测方式> <目标>
# 返回：0=正在运行  1=未运行
svc_running() {
  local _type="$1" _target="$2"
  case "$_type" in
    docker)
      command -v docker &>/dev/null || return 1
      _docker_ps_ensure
      grep -Fxq "$_target" <<< "$_DOCKER_PS_RUN"
      ;;
    systemd)
      systemctl is-active "$_target" &>/dev/null
      ;;
    binary)
      command -v "$_target" &>/dev/null
      ;;
  esac
}

# ── 服务注册表 ────────────────────────────────────────────────────
# 格式：变量名|显示名|检测方式|检测目标
# AI 服务栈
SVC_REGISTRY_STACK=(
  "NEWAPI|New-API|docker|new-api"
  "WEBUI|OpenWebUI|docker|openwebui"
  "LITELLM|LiteLLM|docker|litellm"
  "SUB2API|Sub2API|docker|sub2api"
  "PGSQL|PostgreSQL|docker|ai-db"
  "REDIS|Redis|docker|ai-redis"
  "DIFY|Dify|docker|dify-nginx"
  "SINGBOX|sing-box|systemd|sing-box"
  "CADDY|Caddy|systemd|caddy"
  "KIRO|kiro-rs|docker|kiro-rs"
  "NROUTER|9router|docker|9router"
)

# 服务描述（升级菜单 / 选服务页面共用）
# key 用 INST_* 变量名，值用一句话说明
declare -A SVC_DESC=(
  [INST_SINGBOX]="AnyTLS 代理，供 Clash / Mihomo 使用"
  [INST_SUB2API]="将订阅包装成 OpenAI 兼容 API（需 PostgreSQL）"
  [INST_NEWAPI]="API Key 管理 + 多渠道路由 + 用量计费（OpenWebUI 依赖）"
  [INST_LITELLM]="多 Provider 负载均衡网关"
  [INST_WEBUI]="自托管 AI 对话界面（类 ChatGPT），依赖 New-API"
  [INST_DIFY]="LLM 工作流 / Agent / RAG 平台"
  [INST_CADDY]="HTTPS 反向代理 + 自动 Let's Encrypt 证书"
  [INST_PGSQL]="数据库（Sub2API / New-API 自动依赖）"
  [INST_REDIS]="缓存（Sub2API 自动依赖）"
  [INST_KIRO]="kiro-rs：Kiro IDE 订阅 → Anthropic API 兼容代理"
  [INST_9ROUTER]="9router：多 AI provider 聚合网关 + failover（类 sub2api）"
)

# 通过 SVC_REGISTRY_STACK 的 KEY 取描述（如 NEWAPI → INST_NEWAPI）
svc_desc_by_key() { echo "${SVC_DESC[INST_$1]:-}"; }

# AI 智能体 CLI
SVC_REGISTRY_AGENT=(
  "CLAUDE_CODE|Claude Code|binary|claude"
  "CODEX|OpenAI Codex|binary|codex"
  "OPENCODE|OpenCode|binary|opencode"
  "OPENCLAW|OpenClaw|binary|openclaw"
)

# 统一检测函数：遍历注册表，设置 SVC_<KEY>_INSTALLED=true/false
# 用法：detect_from_registry <注册表数组名>
detect_from_registry() {
  local -n _registry=$1
  _ensure_path
  for _entry in "${_registry[@]}"; do
    IFS='|' read -r _key _name _type _target <<< "$_entry"
    local _var="SVC_${_key}_INSTALLED"
    if svc_check "$_type" "$_target"; then
      printf -v "$_var" '%s' "true"
    else
      printf -v "$_var" '%s' "false"
    fi
  done
}

# 便捷包装
detect_installed_services() {
  detect_from_registry SVC_REGISTRY_STACK
  # Dify 特殊：目录也算已安装
  [[ -d /opt/dify/docker ]] && SVC_DIFY_INSTALLED=true

  # 用实际检测结果同步 INST_* 变量。
  # .env 可能缺失或过时（曾经的 bug：reconfigure_domain 路径下读到 INST_*=false
  # 但容器实际在跑，导致 write_caddyfile 跳过站点块）。这里以真实环境为准。
  # 注意：仅置 true 不置 false——避免破坏 select_services 等需要"清零默认+用户勾选"
  # 语义的调用点（那些路径会自己重置 INST_*）。
  $SVC_NEWAPI_INSTALLED  && INST_NEWAPI=true
  $SVC_WEBUI_INSTALLED   && INST_WEBUI=true
  $SVC_LITELLM_INSTALLED && INST_LITELLM=true
  $SVC_SUB2API_INSTALLED && INST_SUB2API=true
  $SVC_DIFY_INSTALLED    && INST_DIFY=true
  $SVC_SINGBOX_INSTALLED && INST_SINGBOX=true
  $SVC_CADDY_INSTALLED   && INST_CADDY=true
  $SVC_PGSQL_INSTALLED   && INST_PGSQL=true
  $SVC_REDIS_INSTALLED   && INST_REDIS=true
  $SVC_KIRO_INSTALLED    && INST_KIRO=true
  $SVC_NROUTER_INSTALLED && INST_9ROUTER=true
  return 0
}

detect_ai_agents() {
  detect_from_registry SVC_REGISTRY_AGENT
  # 兼容旧变量名
  AGENT_CLAUDE_CODE=$SVC_CLAUDE_CODE_INSTALLED
  AGENT_CODEX=$SVC_CODEX_INSTALLED
  AGENT_OPENCODE=$SVC_OPENCODE_INSTALLED
  AGENT_OPENCLAW=$SVC_OPENCLAW_INSTALLED
}

# 查询单个服务安装状态
# 用法：svc_installed_var INST_NEWAPI → echo true/false
svc_installed_var() {
  local _key="${1#INST_}"
  # bash 变量名不能以数字开头，9ROUTER → NROUTER
  [[ "$_key" == "9ROUTER" ]] && _key="NROUTER"
  local _var="SVC_${_key}_INSTALLED"
  echo "${!_var:-false}"
}

has_web_service() {
  $INST_NEWAPI || $INST_WEBUI || $INST_LITELLM || $INST_SUB2API || $INST_DIFY
}

has_vps_compose_service() {
  $INST_NEWAPI && return 0
  $INST_WEBUI   && [[ "${LOC_WEBUI:-vps}"   == "vps" ]] && return 0
  $INST_LITELLM && [[ "${LOC_LITELLM:-vps}" == "vps" ]] && return 0
  $INST_SUB2API && [[ "${LOC_SUB2API:-vps}" == "vps" ]] && return 0
  return 1
}

