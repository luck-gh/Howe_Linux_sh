#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — VPS 管理工具箱 + AI 服务栈
#
# 主入口脚本
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail

# 终端编辑支持
if [[ -t 0 ]]; then
  _ORIG_STTY=$(stty -g 2>/dev/null || true)
  stty sane 2>/dev/null || true
  trap 'stty "$_ORIG_STTY" 2>/dev/null || true' EXIT
fi

# 定位脚本目录
HOWE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOWE_DIR" == "${BASH_SOURCE[0]}" ]] && HOWE_DIR="."
HOWE_DIR=$(cd "$HOWE_DIR" && pwd)

# 入口必须来自完整仓库, 单独下载入口文件无法加载其模块.
[[ -f "$HOWE_DIR/lib/colors.sh" ]] || {
  printf '缺少脚本模块, 请先 git clone https://github.com/luck-gh/Howe_Linux_sh.git 再运行 howe.sh\n' >&2
  exit 1
}

# 加载 lib
source "${HOWE_DIR}/lib/colors.sh" || exit 1
source "${HOWE_DIR}/lib/urls.sh" || exit 1
source "${HOWE_DIR}/lib/public_ip.sh" || exit 1
source "${HOWE_DIR}/lib/utils.sh" || exit 1
source "${HOWE_DIR}/lib/detect.sh" || exit 1
source "${HOWE_DIR}/lib/nettest.sh" || exit 1
source "${HOWE_DIR}/lib/menu.sh" || exit 1

# 加载 modules
source "${HOWE_DIR}/modules/mod_system.sh" || exit 1
source "${HOWE_DIR}/modules/mod_memmgr.sh" || exit 1
source "${HOWE_DIR}/modules/mod_security.sh" || exit 1
source "${HOWE_DIR}/modules/mod_network.sh" || exit 1
source "${HOWE_DIR}/modules/mod_docker.sh" || exit 1
source "${HOWE_DIR}/modules/mod_ai_stack.sh" || exit 1
source "${HOWE_DIR}/modules/mod_complex_tools.sh" || exit 1
source "${HOWE_DIR}/modules/mod_test.sh" || exit 1

# ── 主菜单 ───────────────────────────────────────────────────────
main() {
  # 初始检测（非交互模式直接执行功能）
  if [[ $# -gt 0 ]]; then
    case "$1" in
      system)   mod_system_main ;;
      memmgr)   mod_memmgr_main ;;
      docker)   mod_docker_main ;;
      security) mod_security_main ;;
      network)  mod_network_main ;;
      ai-stack) mod_ai_stack_main ;;
      test)     mod_test_main ;;
      info)     preflight; show_system_info ;;
      *)        echo "用法: $0 [system|memmgr|docker|security|network|ai-stack|test|info]" ;;
    esac
    return
  fi

  # 交互模式
  detect_distro
  detect_public_ips

  while true; do
    clear
    echo -e "${W}${C}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║         Howe Linux 管理工具箱 v1.0               ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    echo -e "${N}"

    # 系统概览
    local _mem=$(free -m | awk 'NR==2{printf "%d/%dMB (%.0f%%)", $3, $2, $3*100/$2}')
    local _disk=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    local _load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
    echo -e "  ${DIM}系统：${N}${DISTRO_PRETTY}"
    echo -e "  ${DIM}资源：${N}${_mem}  ${DIM}磁盘：${N}${_disk}  ${DIM}负载：${N}${_load}"
    show_public_ips
    echo ""

    echo "  1. 系统管理     （信息 / 更新 / 清理 / 备份）"
    echo "  2. 内存管理     （状态 / 救援 / Swap / zram / sysctl）"
    echo "  3. Docker 管理   （容器 / 镜像 / 网络 / IPv6）"
    echo "  4. 安全加固     （SSH / fail2ban / 防火墙 / DDoS）"
    echo "  5. 网络优化     （DNS / BBR / 内核调优）"
    echo "  6. AI 服务栈    （New-API / OpenWebUI / sing-box）"
    echo "  7. 网络测试     （IP 检测 / 回程路由 / 三网测速 / 性能）"
    echo ""
    echo "  0. 退出"
    echo ""
    local choice
    read -erp "  请输入选择：" choice || return 0

    case "$choice" in
      1) mod_system_main ;;
      2) mod_memmgr_main ;;
      3) mod_docker_main ;;
      4) mod_security_main ;;
      5) mod_network_main ;;
      6) mod_ai_stack_main ;;
      7) mod_test_main ;;
      0) echo -e "\n  ${DIM}已退出${N}"; exit 0 ;;
    esac
  done
}

main "$@"
