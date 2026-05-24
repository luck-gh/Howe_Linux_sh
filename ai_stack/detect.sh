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
# 模式选择
# ═══════════════════════════════════════════════════════════════════
choose_deploy_mode() {
  local _core=520
  local _avail=$(( SYS_MEM_MB - _core ))
  [[ $_avail -lt 0 ]] && _avail=0

  while true; do
    clear
    echo -e "${W}${C}"
    echo "  ╔═══════════════════════════════════════════════════════════════"
    echo "  ║                     选择安装模式"
    echo "  ╠═══════════════════════════════════════════════════════════════"
    printf "  ║  VPS：%-3s核 CPU  RAM %-5sMB  磁盘 %-4sGB  核心后剩余 %-5sMB\n" \
           "$SYS_CPU" "$SYS_MEM_MB" "$SYS_DISK_GB" "$_avail"
    echo "  ╚═══════════════════════════════════════════════════════════════"
    echo -e "${N}"

    local _aio_warn=""
    if [[ $_avail -lt 512 ]]; then
      _aio_warn="${R}（警告：核心后剩余 ${_avail}MB，此 VPS 可能 OOM）${N}"
    else
      _aio_warn="${Y}（内存裕量有限 ${_avail}MB，建议只装轻量服务）${N}"
    fi

    echo "    1. All-in-One   所有服务跑在 VPS"
    echo -e "       ${_aio_warn}"
    echo ""
    echo -e "    2. 分布式部署   重服务放本地，VPS 只跑核心 + 代理"
    echo -e "       ${G}（推荐：本 VPS 1GB RAM 下的最优方案）${N}"
    echo ""
    echo "    0. 退出脚本"
    echo ""
    local _choice
    read -erp "  选择：" _choice

    case "$_choice" in
      0) echo -e "  ${DIM}已退出${N}"; exit 0 ;;
      1) DEPLOY_MODE="allinone"; LOCAL_OS="" ; break ;;
      2) DEPLOY_MODE="distributed" ;;
      *) continue ;;
    esac

    # ── 本地系统选择（仅分布式）────────────────────────────────
    while true; do
      clear
      echo ""
      echo -e "  ${W}本地机器系统：${N}"
      echo ""
      echo "    1. Linux    生成 install-local.sh + docker-compose + frpc.toml"
      echo "    2. Windows  生成 docker-compose + frpc.toml + start.bat"
      echo ""
      echo "    0. 返回上一级"
      echo ""
      local _os_choice
      read -erp "  选择：" _os_choice

      case "$_os_choice" in
        0) continue 2 ;;  # 返回模式选择
        1) LOCAL_OS="linux";  break 2 ;;
        2) LOCAL_OS="windows"; break 2 ;;
      esac
    done
  done

  log "模式：$([[ "$DEPLOY_MODE" == "distributed" ]] && echo "分布式（本地 ${LOCAL_OS}）" || echo "All-in-One")"
  sleep 1
}

# ═══════════════════════════════════════════════════════════════════
# 服务安装状态探测（统一检测框架）
# ═══════════════════════════════════════════════════════════════════

# 确保常见安装路径在 PATH 中
_ensure_path() {
  [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
  [[ -d "/usr/local/bin" ]] && [[ ":$PATH:" != *":/usr/local/bin:"* ]] && export PATH="/usr/local/bin:$PATH"
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
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$_target"
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
      docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$_target"
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

