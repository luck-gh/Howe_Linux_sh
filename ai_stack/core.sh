#!/usr/bin/env bash
# 基础工具：颜色 / 日志 / ask / print_header / dc_cmd / 全局变量
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 颜色 / 日志工具
# ═══════════════════════════════════════════════════════════════════
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' DIM='\033[2m' N='\033[0m'

log()   { echo -e "${G}[✓]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
err()   { echo -e "${R}[✗]${N} $*"; exit 1; }
info()  { echo -e "${B}[·]${N} $*"; }

STEP=0; TOTAL_STEPS=12
step() {
  STEP=$((STEP+1))
  echo -e "\n${W}${C}── [${STEP}/${TOTAL_STEPS}] $* ──────────────────────────${N}"
}

ask() {
  local _v=$1 _p=$2 _d=${3:-}
  local __ask_i
  read -erp "$(echo -e "  ${W}${_p}${N}${_d:+ [${_d}]}: ")" __ask_i
  printf -v "$_v" '%s' "${__ask_i:-$_d}"
}

askyn() {
  local _v=$1 _p=$2 _d=${3:-y}
  local _h; [[ "$_d" == "y" ]] && _h="Y/n" || _h="y/N"
  local __ask_i
  read -erp "$(echo -e "  ${W}${_p}${N} [${_h}]: ")" __ask_i
  __ask_i=${__ask_i:-$_d}
  [[ "${__ask_i,,}" == "y" ]] && printf -v "$_v" true || printf -v "$_v" false
}

# ── 通用工具函数（input_choose / break_end 等）──────────────────
_AI_STACK_DIR="${BASH_SOURCE[0]%/*}"
# 拆分后 utils.sh 仍在 lib/，从 ai_stack/ 引入需要 ../lib
# shellcheck source=../lib/utils.sh
source "${_AI_STACK_DIR}/../lib/utils.sh" 2>/dev/null || {
  # 兜底：utils.sh 不存在时提供最小实现
  INPUT_RESULT=-1
  input_choose() {
    local _prompt="$1"; shift
    local -a _opts=("$@")
    local _cnt=${#_opts[@]}
    echo ""
    echo -e "  ${W}${_prompt}${N}"
    echo -e "  ${DIM}────────────────────────────────${N}"
    for (( i=0; i<_cnt; i++ )); do echo "    $((i+1)). ${_opts[$i]}"; done
    echo ""
    local _input
    read -erp "  选择：" _input
    if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _cnt )); then
      INPUT_RESULT=$((_input - 1))
    else
      INPUT_RESULT=-1
    fi
  }
  break_end() { echo ""; echo "按任意键继续..."; read -erp "" _; clear; }
}

# ── 通用 UI 工具 ─────────────────────────────────────────────────

# 打印菜单头部框
# 用法：print_header "标题文字"
print_header() {
  local _title="$1"
  clear
  echo -e "${W}${C}"
  echo "  ╔═════════════════════════════════════════"
  printf "  ║%*s%s%*s\n" $(( (39 - ${#_title}) / 2 )) "" "$_title" $(( (40 - ${#_title}) / 2 )) ""
  echo "  ╚═════════════════════════════════════════"
  echo -e "${N}"
}

# Docker Compose 操作包装
# 用法：dc_cmd <action> <service> [dir]
# action: start|stop|restart|up|down|logs|ps
dc_cmd() {
  local _action="$1" _svc="${2:-}" _dir="${3:-$BASE_DIR}"
  case "$_action" in
    start)
      (cd "$_dir" && docker compose start "$_svc" 2>&1) || \
        (cd "$_dir" && docker compose up -d "$_svc" 2>&1)
      ;;
    stop)
      (cd "$_dir" && docker compose stop "$_svc" 2>&1)
      ;;
    restart)
      (cd "$_dir" && docker compose restart "$_svc" 2>&1)
      ;;
    up)
      (cd "$_dir" && docker compose up -d ${_svc:+"$_svc"} 2>&1)
      ;;
    down)
      (cd "$_dir" && docker compose down ${_svc:+"$_svc"} 2>&1)
      ;;
    down-v)
      (cd "$_dir" && docker compose down -v 2>&1)
      ;;
    logs)
      (cd "$_dir" && docker compose logs -f "$_svc" 2>&1)
      ;;
    ps)
      (cd "$_dir" && docker compose ps 2>&1)
      ;;
    rm)
      (cd "$_dir" && docker compose stop "$_svc" 2>/dev/null && docker compose rm -f "$_svc" 2>/dev/null)
      ;;
  esac
}

# 多选输入解析：处理数字切换 / a全选 / 0返回 / 回车确认
# 用法：multi_select_input <input> <SEL数组名> <数量>
# 输出：MULTI_SELECT_ACTION = confirm | return | toggled | invalid
multi_select_input() {
  local _input="$1" _sel_name="$2" _cnt="$3"
  local -n _sel=$_sel_name

  if [[ -z "$_input" ]]; then
    MULTI_SELECT_ACTION="confirm"; return
  fi
  if [[ "$_input" == "0" ]]; then
    MULTI_SELECT_ACTION="return"; return
  fi
  if [[ "${_input,,}" == "a" ]]; then
    local _all_on=true _i
    for (( _i=0; _i<_cnt; _i++ )); do
      [[ "${_sel[$_i]}" != "true" ]] && _all_on=false
    done
    for (( _i=0; _i<_cnt; _i++ )); do
      $_all_on && _sel[$_i]=false || _sel[$_i]=true
    done
    MULTI_SELECT_ACTION="toggled"; return
  fi
  if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _cnt )); then
    local _idx=$((_input - 1))
    [[ "${_sel[$_idx]}" == "true" ]] && _sel[$_idx]=false || _sel[$_idx]=true
    MULTI_SELECT_ACTION="toggled"; return
  fi
  MULTI_SELECT_ACTION="invalid"
}

# ═══════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════
# 子域名前缀（修改此处即可全局生效）
# ═══════════════════════════════════════════════════════════════════
PREFIX_NEWAPI="aapi"         # New-API       → aapi.域名
PREFIX_WEBUI="chat"          # OpenWebUI     → chat.域名
PREFIX_LITELLM="lb"          # LiteLLM       → lb.域名
PREFIX_SUB2API="s2a"         # Sub2API       → s2a.域名
PREFIX_DIFY="dify"           # Dify          → dify.域名
PREFIX_VPS="vps"             # Clash 订阅    → vps.域名（仅当装了 sing-box）

# ═══════════════════════════════════════════════════════════════════
# 全局变量默认值（set -u 安全）
# ═══════════════════════════════════════════════════════════════════
DEPLOY_MODE="allinone"
LOCAL_OS=""
VPS_IP=""

INST_NEWAPI=true
INST_WEBUI=true
INST_LITELLM=false
INST_SUB2API=true
INST_DIFY=false
INST_SINGBOX=true
INST_CADDY=false
INST_PGSQL=false
INST_REDIS=false

LOC_WEBUI="vps"
LOC_LITELLM="vps"
LOC_SUB2API="vps"
LOC_DIFY="vps"

DOMAIN=""
EMAIL=""
NEWAPI_TOKEN=""
LITELLM_KEY=""
DIFY_SECRET=""
FRP_PORT="7000"
FRP_TOKEN=""

SYS_CPU=1
SYS_MEM_MB=1024
SYS_MEM_GB="1.0"
SYS_DISK_GB=20

BASE_DIR="/opt/ai-stack"
SINGBOX_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
LOCAL_PKG_DIR="/tmp/ai-stack-local"

SVC_NEWAPI_INSTALLED=false
SVC_WEBUI_INSTALLED=false
SVC_LITELLM_INSTALLED=false
SVC_SUB2API_INSTALLED=false
SVC_DIFY_INSTALLED=false
SVC_SINGBOX_INSTALLED=false

