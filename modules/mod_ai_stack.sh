#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — AI 服务栈模块
#
# 功能：管理 AI 服务栈（New-API / OpenWebUI / LiteLLM / Sub2API / Dify / sing-box）
# 通过 BASH_SOURCE 守卫集成原始 ai-stack-setup.sh
# ═══════════════════════════════════════════════════════════════════

# 定位脚本目录（必须转为绝对路径，因为主脚本会 cd）
_mod_ai_stack_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir="${src%/*}"
  [[ "$dir" == "$src" ]] && dir="."
  cd "$dir" && cd ../ai_stack && pwd
}

AI_STACK_SCRIPT="$(_mod_ai_stack_dir)/ai-stack-setup.sh"

mod_ai_stack_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           AI 服务栈                  ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    echo "  服务：New-API / OpenWebUI / LiteLLM / Sub2API / Dify / sing-box"
    echo "  代理：Caddy (HTTPS) + frp (分布式穿透)"
    echo ""

    # 检测已安装状态
    local _installed=""
    if [[ -f /opt/ai-stack/.env ]]; then
      _installed="${G}已安装${N}"
    else
      _installed="${DIM}未安装${N}"
    fi
    echo -e "  状态：${_installed}"
    echo ""

    echo "  1. 打开 AI 服务栈管理"
    echo "  2. 快速查看运行状态"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1)
        if [[ ! -f "$AI_STACK_SCRIPT" ]]; then
          warn "未找到 ai-stack-setup.sh"
          break_end
          continue
        fi
        # 独立运行（非 source），脚本自带第一页面菜单
        # 脚本内部有完整菜单循环，退出时已清屏，无需再 break_end
        bash "$AI_STACK_SCRIPT"
        ;;
      2)
        _ai_stack_status
        break_end
        ;;
      0|*) break ;;
    esac
  done
}

_ai_stack_status() {
  section "AI 服务栈状态"

  if ! command -v docker &>/dev/null; then
    info "Docker 未安装"
    return
  fi

  local containers
  containers=$(howe_query "AI 容器状态" 10 docker ps -a --format '{{.Names}}|{{.State}}') || {
    warn "容器状态未知, 无法判断 AI 服务是否已安装或停止"
    return 1
  }

  local services=("new-api" "openwebui" "litellm" "sub2api" "ai-db" "ai-redis" "caddy")
  for svc in "${services[@]}"; do
    local status
    if grep -Fxq "${svc}|running" <<< "$containers"; then
      status="${G}运行中${N}"
    elif grep -q "^${svc}|" <<< "$containers"; then
      status="${Y}已停止${N}"
    else
      status="${DIM}未安装${N}"
    fi
    printf "  %-15s %b\n" "$svc" "$status"
  done

  local unit state
  for unit in sing-box frps; do
    if state=$(howe_query "$unit 运行状态" 5 systemctl show "$unit" --property=ActiveState --value); then
      case "$state" in
        active) status="${G}运行中${N}" ;;
        inactive|failed) status="${Y}已停止或未安装${N}" ;;
        activating|deactivating|reloading) status="${Y}状态转换中${N}" ;;
        *) status="${Y}状态未知${N}" ;;
      esac
    else
      status="${Y}状态未知${N}"
    fi
    printf "  %-15s %b\n" "$unit" "$status"
  done
}
