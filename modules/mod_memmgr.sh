#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 内存管理模块
#
# 提供：
#   - 内存 / Swap 状态查看（mem_status，只读）
#   - 内存救援（待实装：mem_triage）
#   - 常规清理（待实装：mem_clean）
#   - sysctl 调优（待实装）
#   - /swap 文件管理（待实装）
#   - zram 启用/调整（待实装）
#   - earlyoom 安装（待实装，可选）
# ═══════════════════════════════════════════════════════════════════

# ── 内存 / Swap 状态 ─────────────────────────────────────────────
mem_status() {
  section "内存 / Swap 状态"

  # 总览
  free -h
  echo ""

  # Swap 设备明细
  if swapon --show 2>/dev/null | grep -q .; then
    section "Swap 设备"
    swapon --show
  else
    section "Swap 设备"
    info "未检测到任何 Swap 设备"
  fi

  # 关键内核参数
  section "内存参数"
  printf "  swappiness         : %s\n" "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
  printf "  vfs_cache_pressure : %s\n" "$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"
  if lsmod 2>/dev/null | grep -q '^zram'; then
    printf "  zram 内核模块      : ${G}已加载${N}\n"
  else
    printf "  zram 内核模块      : ${DIM}未加载${N}\n"
  fi

  # 缓存可回收估算
  section "可回收缓存估算"
  local _meminfo _buffers _cached _sreclaim
  _meminfo=$(cat /proc/meminfo 2>/dev/null)
  _buffers=$(echo "$_meminfo" | awk '/^Buffers:/ {print $2}')
  _cached=$(echo "$_meminfo"  | awk '/^Cached:/  {print $2}')
  _sreclaim=$(echo "$_meminfo" | awk '/^SReclaimable:/ {print $2}')
  printf "  page cache (Cached + Buffers) : %d MB\n" "$(( (_buffers + _cached) / 1024 ))"
  printf "  slab 可回收 (SReclaimable)    : %d MB\n" "$(( _sreclaim / 1024 ))"
  echo -e "  ${DIM}drop_caches 仅释放 page cache + slab，不影响 swap${N}"

  # Top 内存进程
  section "Top 内存占用进程（按 RSS）"
  ps -eo pid,user,%mem,rss,comm --sort=-rss --no-headers 2>/dev/null \
    | awk 'NR<=10 {printf "  %7d  %-10s  %5s%%  %8d KB  %s\n", $1, $2, $3, $4, $5}'

  # Top swap 占用进程
  section "Top Swap 占用进程"
  local _swap_lines
  _swap_lines=$(
    for f in /proc/[0-9]*/status; do
      awk '
        /^Name:/   {n=$2}
        /^Pid:/    {p=$2}
        /^VmSwap:/ {s=$2}
        END {if (s+0 > 0) printf "%d %d %s\n", s, p, n}
      ' "$f" 2>/dev/null
    done | sort -rn | head -10
  )
  if [[ -z "$_swap_lines" ]]; then
    info "当前没有进程使用 Swap"
  else
    printf "  %-8s  %-7s  %s\n" "SWAP_KB" "PID" "NAME"
    echo "$_swap_lines" | awk '{printf "  %-8s  %-7s  %s\n", $1, $2, $3}'
  fi

  # Docker 容器内存（若 docker 可用）
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    section "Docker 容器内存"
    local _docker_out
    _docker_out=$(docker stats --no-stream \
      --format "{{.Name}}|{{.MemUsage}}|{{.MemPerc}}" 2>/dev/null)
    if [[ -z "$_docker_out" ]]; then
      info "无运行中的容器"
    else
      printf "  %-20s  %-28s  %s\n" "NAME" "MEM_USAGE" "MEM%"
      echo "$_docker_out" | awk -F'|' '{printf "  %-20s  %-28s  %s\n", $1, $2, $3}'
    fi
  fi
}

# ── 内存管理主菜单 ───────────────────────────────────────────────
mod_memmgr_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           内存管理                   ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    # 概览：内存 / swap 一行式
    local _m _s
    _m=$(free -m | awk 'NR==2{printf "%d/%dMB (%d%%)", $3, $2, $3*100/$2}')
    _s=$(free -m | awk 'NR==3{if($2==0){print "未启用"}else{printf "%d/%dMB (%d%%)", $3, $2, $3*100/$2}}')
    echo -e "  ${DIM}内存：${N}$_m   ${DIM}Swap：${N}$_s"
    echo ""
    echo "  1. 内存 / Swap 状态"
    echo "  ─────────────────"
    echo -e "  2. 内存救援            ${DIM}(待实装)${N}"
    echo -e "  3. 常规清理            ${DIM}(待实装)${N}"
    echo "  ─────────────────"
    echo -e "  4. sysctl 调优         ${DIM}(待实装)${N}"
    echo -e "  5. /swap 文件管理      ${DIM}(待实装)${N}"
    echo -e "  6. zram 启用 / 调整    ${DIM}(待实装)${N}"
    echo -e "  7. earlyoom 安装       ${DIM}(待实装，可选)${N}"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) mem_status; break_end ;;
      2|3|4|5|6|7) info "该功能尚未实装，将在后续 PR 中加入"; break_end ;;
      0|"") break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}
