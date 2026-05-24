#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 网络测试模块
#
# 简便工具：本地 bash 实现（lib/nettest.sh）
# 复杂工具：首次下载到 lib/scripts/ 后本地执行
# ═══════════════════════════════════════════════════════════════════

# ── 辅助函数 ─────────────────────────────────────────────────────

# 确保 swap 存在（性能测试前调用）
_ensure_swap() {
  local swap_total
  swap_total=$(free -m | awk 'NR==3{print $2}')
  if [[ "${swap_total:-0}" -gt 0 ]]; then
    return 0
  fi

  warn "未检测到 Swap，性能测试可能需要 Swap 空间"
  local yn
  askyn yn "是否创建 1GB Swap？" "y"
  if $yn; then
    local swapfile="/swapfile"
    fallocate -l 1G "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count=1024 2>/dev/null
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null 2>&1
    swapon "$swapfile"
    if ! grep -q "$swapfile" /etc/fstab; then
      echo "$swapfile none swap sw 0 0" >> /etc/fstab
    fi
    log "已创建 1GB Swap"
  fi
}

# ── IP 及解锁状态检测 ────────────────────────────────────────────

_ip_unlock_menu() {
  while true; do
    clear
    echo -e "${W}${C}IP 及解锁状态检测${N}"
    echo -e "${DIM}────────────────────────────────────${N}"
    echo ""
    echo "  1. ChatGPT 解锁状态检测"
    echo "  2. 流媒体解锁检测"
    echo "  3. IP 质量检测"
    echo ""
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1) check_chatgpt; break_end ;;
      2) check_streaming; break_end ;;
      3) check_ip_quality; break_end ;;
      0|*) break ;;
    esac
  done
}

# ── 网络线路测速 ─────────────────────────────────────────────────

_route_test_menu() {
  while true; do
    clear
    echo -e "${W}${C}网络线路测速${N}"
    echo -e "${DIM}────────────────────────────────────${N}"
    echo ""
    echo "  1. 三网回程路由测试"
    echo "  2. 指定 IP 回程测试"
    echo "  3. 三网测速"
    echo ""
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1) check_route; break_end ;;
      2) check_route_custom; break_end ;;
      3) check_speed; break_end ;;
      0|*) break ;;
    esac
  done
}

# ── 硬件性能测试 ─────────────────────────────────────────────────

_perf_test_menu() {
  while true; do
    clear
    echo -e "${W}${C}硬件性能测试${N}"
    echo -e "${DIM}────────────────────────────────────${N}"
    echo ""
    echo "  1. yabs 综合性能测试  ${G}★${N}"
    echo "  2. Geekbench 5 CPU 性能测试"
    echo ""
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1)
        _ensure_swap
        _ensure_complex "yabs" || { break_end; continue; }
        bash "$_COMPLEX_SCRIPT" -i -5
        reset_terminal
        break_end ;;
      2)
        _ensure_swap
        _ensure_complex "gb5" || { break_end; continue; }
        bash "$_COMPLEX_SCRIPT"
        reset_terminal
        break_end ;;
      0|*) break ;;
    esac
  done
}

# ── 综合性测试 ───────────────────────────────────────────────────

_comprehensive_test_menu() {
  while true; do
    clear
    echo -e "${W}${C}综合性测试${N}"
    echo -e "${DIM}────────────────────────────────────${N}"
    echo ""
    echo "  1. 服务器基准测试（本地）"
    echo "  2. spiritysdx 融合怪测评  ${G}★${N}"
    echo "  3. nodequality 融合怪测评  ${G}★${N}"
    echo ""
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1) check_bench; break_end ;;
      2)
        _ensure_complex "ecs-fusion" || { break_end; continue; }
        _warn_complex_tool_risk "ecs-fusion" || { break_end; continue; }
        bash "$_COMPLEX_SCRIPT"
        reset_terminal
        break_end ;;
      3)
        _ensure_complex "nodequality" || { break_end; continue; }
        _warn_complex_tool_risk "nodequality" || { break_end; continue; }
        bash "$_COMPLEX_SCRIPT"
        reset_terminal
        break_end ;;
      0|*) break ;;
    esac
  done
}

# ── 工具管理 ─────────────────────────────────────────────────────

_tools_manage_menu() {
  while true; do
    clear
    echo -e "${W}${C}测试工具管理${N}"
    echo -e "${DIM}────────────────────────────────────${N}"
    echo ""
    list_complex_tools
    echo ""
    echo "  1. 下载所有工具"
    echo "  2. 更新所有工具"
    echo ""
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c

    case "$c" in
      1) download_all_complex; break_end ;;
      2) update_all_complex; break_end ;;
      0|*) break ;;
    esac
  done
}

# ── 网络测试主菜单 ───────────────────────────────────────────────
mod_test_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           网络测试                   ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    echo "  1. IP 及解锁状态检测"
    echo "  2. 网络线路测速"
    echo "  3. 硬件性能测试"
    echo "  4. 综合性测试"
    echo "  ─────────────────"
    echo "  5. 工具管理（下载/更新复杂工具）"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) _ip_unlock_menu ;;
      2) _route_test_menu ;;
      3) _perf_test_menu ;;
      4) _comprehensive_test_menu ;;
      5) _tools_manage_menu ;;
      0|*) break ;;
    esac
  done
}
