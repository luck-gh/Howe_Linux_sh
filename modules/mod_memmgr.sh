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

# ── 内存救援（mem_triage）────────────────────────────────────────
# 设计原则：脚本只诊断 + 列候选，杀谁、清什么由用户每项确认。
# 当前 SSH 会话祖先链上的 PID 会被显式标记，避免误杀自己。

# 计算当前 shell 的祖先 PID 链，输出空格分隔的 PID 列表
_triage_ancestor_pids() {
  local _pid=$$ _chain=""
  while [[ -n "$_pid" && "$_pid" != "0" && "$_pid" != "1" ]]; do
    _chain="$_chain $_pid"
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done
  echo "$_chain"
}

# 内存压力等级：HIGH / WARN / OK
_triage_pressure() {
  local _kind=$1  # mem 或 swap
  local _used _total _pct
  if [[ "$_kind" == "mem" ]]; then
    read -r _total _used < <(free -m | awk 'NR==2{print $2, $3}')
  else
    read -r _total _used < <(free -m | awk 'NR==3{print $2, $3}')
  fi
  if [[ -z "$_total" || "$_total" -eq 0 ]]; then
    echo "未启用"
    return
  fi
  _pct=$(( _used * 100 / _total ))
  if   (( _pct >= 90 )); then echo "${R}⚠ 紧张${N}"
  elif (( _pct >= 75 )); then echo "${Y}● 偏高${N}"
  else                        echo "${G}✓ 充足${N}"
  fi
}

# kill 进程：先 SIGTERM，5 秒不退由用户决定是否升 SIGKILL
_triage_kill_pid() {
  local _pid=$1 _name=$2
  if ! kill -0 "$_pid" 2>/dev/null; then
    warn "PID $_pid 已不存在"
    return 0
  fi
  info "向 PID $_pid ($_name) 发送 SIGTERM ..."
  kill "$_pid" 2>/dev/null
  local _i
  for _i in 1 2 3 4 5; do
    sleep 1
    kill -0 "$_pid" 2>/dev/null || { log "PID $_pid 已退出"; return 0; }
  done
  warn "PID $_pid 5 秒内仍未退出"
  local _yn
  askyn _yn "是否强制 kill -9 PID $_pid？" "n"
  if $_yn; then
    kill -9 "$_pid" 2>/dev/null
    sleep 1
    if kill -0 "$_pid" 2>/dev/null; then
      err "PID $_pid 仍存在（可能是 D 态等待 IO）"
    else
      log "PID $_pid 已强制退出"
    fi
  else
    info "已保留 PID $_pid"
  fi
}

# 释放 page cache（零风险）
_triage_drop_caches() {
  info "释放 page cache"
  sync
  echo 1 > /proc/sys/vm/drop_caches 2>/dev/null && log "已释放 page cache" \
    || warn "drop_caches 失败（需要 root）"
}

# 清 apt 包缓存
_triage_apt_clean() {
  info "清 apt 包缓存"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get clean -y >/dev/null 2>&1 && log "apt 包缓存已清"
  else
    info "未检测到 apt（非 Debian 系），跳过"
  fi
}

# 清 7 天前的 journal 日志
_triage_journal_vacuum() {
  info "清 7 天前的 journal 日志"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-time=7d 2>&1 | tail -3
    log "journal 已清理"
  else
    info "未检测到 journalctl，跳过"
  fi
}

# 收集救援候选数据，输出为内部状态变量供菜单使用
# 输出全局数组：_TRG_DUP_LINES / _TRG_HIGH_SWAP_LINES / _TRG_BAD_STATE_LINES
# 候选 kill PID 列表：_TRG_KILL_PIDS / _TRG_KILL_LABELS
_triage_collect() {
  _TRG_DUP_LINES=()
  _TRG_HIGH_SWAP_LINES=()
  _TRG_BAD_STATE_LINES=()
  _TRG_KILL_PIDS=()
  _TRG_KILL_LABELS=()

  local _ancestors
  _ancestors=" $(_triage_ancestor_pids) "

  # 进程的 swap 占用（来自 /proc/PID/status VmSwap，单位 KB）
  declare -A _swap_by_pid=()
  local _f _pid _swap
  for _f in /proc/[0-9]*/status; do
    _pid=$(awk '/^Pid:/{print $2; exit}' "$_f" 2>/dev/null)
    _swap=$(awk '/^VmSwap:/{print $2; exit}' "$_f" 2>/dev/null)
    [[ -n "$_pid" && -n "$_swap" && "$_swap" -gt 0 ]] && _swap_by_pid[$_pid]=$_swap
  done

  # 全量进程快照：用 | 分隔避免 args 里的空格污染字段切分
  # 字段：pid|stat|stime|rss|comm|args
  local _ps_data
  _ps_data=$(ps -eo pid=,stat=,stime=,rss=,comm=,args= 2>/dev/null \
    | awk '{
        pid=$1; stat=$2; stime=$3; rss=$4; comm=$5;
        args=""; for(i=6;i<=NF;i++) args=args (i>6?" ":"") $i;
        printf "%s|%s|%s|%s|%s|%s\n", pid, stat, stime, rss, comm, args
      }')

  # 1) 重复进程组：按 comm 分组，组内 ≥ 2 才报告
  # 过滤规则：
  #   - 内核线程：args 形如 [xxx] 或 RSS=0
  #   - 已知系统派生进程：sftp-server / containerd-shim / docker-proxy / postgres / sshd
  #     这些由父进程管理，单独 kill 通常会被立刻拉起，且 kill 错了会出问题
  declare -A _comm_count=()
  local _line _p _stat _stime _rss _comm _args
  while IFS= read -r _line; do
    IFS='|' read -r _p _stat _stime _rss _comm _args <<< "$_line"
    [[ -z "$_comm" ]] && continue
    # 跳过内核线程：[xxx] 形式或 RSS=0
    [[ "$_args" == \[*\] ]] && continue
    [[ "${_rss:-0}" == "0" ]] && continue
    # 跳过系统派生 / 基础设施进程（kill 后会被立刻拉起或导致系统异常）
    case "$_comm" in
      sftp-server|containerd-shim*|docker-proxy|postgres|sshd) continue ;;
      systemd|init|agetty|getty|login|cron|crond|atd) continue ;;
      dhcpcd|dhclient|systemd-*|networkd-*|wpa_supplicant) continue ;;
      rpcbind|rpc.*|nfsd|smbd|nmbd|winbindd) continue ;;
      udevd|udev|haveged|chronyd|ntpd|rsyslogd|journald) continue ;;
    esac
    _comm_count[$_comm]=$((${_comm_count[$_comm]:-0}+1))
  done <<< "$_ps_data"

  local _g_comm
  for _g_comm in "${!_comm_count[@]}"; do
    if (( _comm_count[$_g_comm] >= 2 )); then
      _TRG_DUP_LINES+=("__GROUP__:$_g_comm:${_comm_count[$_g_comm]}")
      while IFS= read -r _line; do
        IFS='|' read -r _p _stat _stime _rss _comm _args <<< "$_line"
        if [[ "$_comm" == "$_g_comm" ]]; then
          # 同样过滤
          [[ "$_args" == \[*\] ]] && continue
          [[ "${_rss:-0}" == "0" ]] && continue
          local _swap_kb=${_swap_by_pid[$_p]:-0}
          local _is_self=""
          [[ "$_ancestors" == *" $_p "* ]] && _is_self="SELF"
          local _args_short="${_args:0:60}"
          _TRG_DUP_LINES+=("$_p|$_rss|$_swap_kb|$_stat|$_stime|$_is_self|$_args_short")
        fi
      done <<< "$_ps_data"
    fi
  done

  # 2) 高 swap 进程（>50MB = 51200KB），按 swap 降序
  local _topswap
  _topswap=$(
    for _p in "${!_swap_by_pid[@]}"; do
      _swap=${_swap_by_pid[$_p]}
      if (( _swap > 51200 )); then
        local _name=$(awk '/^Name:/{print $2; exit}' /proc/$_p/status 2>/dev/null)
        echo "$_swap $_p $_name"
      fi
    done | sort -rn
  )
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    local _name
    _swap=$(echo "$_line" | awk '{print $1}')
    _p=$(echo "$_line"    | awk '{print $2}')
    _name=$(echo "$_line" | awk '{print $3}')
    local _is_self=""
    [[ "$_ancestors" == *" $_p "* ]] && _is_self="SELF"
    _TRG_HIGH_SWAP_LINES+=("$_p|$_name|$_swap|$_is_self")
  done <<< "$_topswap"

  # 3) 异常状态：D（不可中断睡眠）/ Z（僵尸）
  while IFS= read -r _line; do
    IFS='|' read -r _p _stat _stime _rss _comm _args <<< "$_line"
    case "$_stat" in
      D*|Z*)
        _TRG_BAD_STATE_LINES+=("$_p|$_comm|$_stat")
        ;;
    esac
  done <<< "$_ps_data"
}

# 渲染救援报告 + kill 候选菜单，并填充 _TRG_KILL_PIDS / _TRG_KILL_LABELS
_triage_render() {
  clear
  echo -e "${W}${C}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${W}${C}║              内存救援 — 当前状态诊断                 ║${N}"
  echo -e "${W}${C}╚══════════════════════════════════════════════════════╝${N}"
  echo ""

  # 头部状态条
  local _mem_p _swap_p _mem_t _swap_t
  _mem_p=$(_triage_pressure mem)
  _swap_p=$(_triage_pressure swap)
  _mem_t=$(free -m | awk 'NR==2{printf "%dMi / %dMi (%d%%)", $3, $2, $3*100/$2}')
  _swap_t=$(free -m | awk 'NR==3{if($2==0){print "未启用"}else{printf "%dMi / %dMi (%d%%)", $3, $2, $3*100/$2}}')
  echo -e "  内存：$_mem_t   $_mem_p"
  echo -e "  Swap：$_swap_t   $_swap_p"
  echo ""

  # ▶ 重复进程组
  if (( ${#_TRG_DUP_LINES[@]} > 0 )); then
    section "▶ 重复进程组（同一程序跑了多个，常见于残留会话）"
    local _line _label_idx=0
    for _line in "${_TRG_DUP_LINES[@]}"; do
      if [[ "$_line" == __GROUP__:* ]]; then
        local _g_comm _g_count
        _g_comm=$(echo "$_line" | cut -d: -f2)
        _g_count=$(echo "$_line" | cut -d: -f3)
        echo ""
        echo -e "  ${W}组: $_g_comm（$_g_count 个进程）${N}"
        printf "    %-7s  %-7s  %-7s  %-5s  %-5s  %-6s  %s\n" \
          "PID" "RSS_KB" "SWAP_KB" "STAT" "START" "标记" "命令"
      else
        local _p _rss _swap _stat _start _self _args
        IFS='|' read -r _p _rss _swap _stat _start _self _args <<< "$_line"
        local _mark="" _self_note=""
        if [[ "$_self" == "SELF" ]]; then
          _mark="${R}本会话${N}"
          _self_note="  ${R}← kill 会断你的连接${N}"
        else
          _label_idx=$((_label_idx+1))
          _mark="${G}[k$_label_idx]${N}"
          _TRG_KILL_PIDS+=("$_p")
          _TRG_KILL_LABELS+=("$_p ${_args:0:40} (RSS ${_rss}K, SWAP ${_swap}K, 启动 $_start)")
        fi
        printf "    %-7s  %-7s  %-7s  %-5s  %-5s  " \
          "$_p" "$_rss" "$_swap" "$_stat" "$_start"
        echo -e "$_mark  ${_args:0:40}$_self_note"
      fi
    done
    echo ""
  fi

  # ▶ 高 swap 进程
  if (( ${#_TRG_HIGH_SWAP_LINES[@]} > 0 )); then
    section "▶ 高 Swap 占用进程（> 50MB）"
    printf "    %-7s  %-15s  %-9s  %s\n" "PID" "NAME" "SWAP_KB" "标记"
    local _line _p _name _swap _self
    for _line in "${_TRG_HIGH_SWAP_LINES[@]}"; do
      IFS='|' read -r _p _name _swap _self <<< "$_line"
      local _mark=""
      [[ "$_self" == "SELF" ]] && _mark="${R}本会话${N}"
      printf "    %-7s  %-15s  %-9s  " "$_p" "$_name" "$_swap"
      echo -e "$_mark"
    done
    echo ""
  fi

  # ▶ 异常状态
  if (( ${#_TRG_BAD_STATE_LINES[@]} > 0 )); then
    section "▶ 异常状态进程"
    printf "    %-7s  %-15s  %-6s\n" "PID" "NAME" "STAT"
    local _line _p _name _stat
    for _line in "${_TRG_BAD_STATE_LINES[@]}"; do
      IFS='|' read -r _p _name _stat <<< "$_line"
      printf "    %-7s  %-15s  %-6s\n" "$_p" "$_name" "$_stat"
    done
    echo -e "  ${DIM}注: D 态 = 不可中断睡眠（通常 IO 卡住），Z 态 = 僵尸进程${N}"
    echo -e "  ${DIM}    D 态进程 kill 后可能仍要等 IO 完成才消失${N}"
    echo ""
  fi

  # ▶ 可清理的非进程数据
  section "▶ 可清理的非进程数据（零风险，不影响任何运行中的程序）"
  local _meminfo _buffers _cached _pc_mb _apt_kb _apt_mb _journal
  _meminfo=$(cat /proc/meminfo 2>/dev/null)
  _buffers=$(echo "$_meminfo" | awk '/^Buffers:/ {print $2}')
  _cached=$(echo "$_meminfo"  | awk '/^Cached:/  {print $2}')
  _pc_mb=$(( (_buffers + _cached) / 1024 ))
  _apt_kb=$(du -sk /var/cache/apt 2>/dev/null | awk '{print $1}')
  _apt_mb=$(( ${_apt_kb:-0} / 1024 ))
  _journal=$(journalctl --disk-usage 2>&1 | grep -oE '[0-9.]+[KMG]' | tail -1)
  printf "    [c1] page cache       约 %d MB   ${DIM}sync + drop_caches=1${N}\n" "$_pc_mb"
  printf "    [c2] apt 包缓存       约 %d MB   ${DIM}apt-get clean${N}\n" "$_apt_mb"
  printf "    [c3] journal 日志     %s         ${DIM}vacuum-time=7d（保留最近 7 天）${N}\n" "${_journal:-?}"
  echo ""
}

# 主交互循环
mem_triage() {
  while true; do
    _triage_collect
    _triage_render

    echo -e "${W}────────────────────────────────────────────────────────${N}"
    echo "  请选择处置项（多个用空格分隔，可混合，如：c1 c2 k1）："
    echo ""
    echo "  [c1] 释放 page cache    [c2] 清 apt 缓存    [c3] 清 journal"
    if (( ${#_TRG_KILL_PIDS[@]} > 0 )); then
      local _i
      for _i in "${!_TRG_KILL_PIDS[@]}"; do
        printf "  [k%d] kill %s\n" "$((_i+1))" "${_TRG_KILL_LABELS[$_i]}"
      done
    fi
    echo ""
    echo "  [r]  刷新诊断   [q] 退出救援"
    echo ""
    local _in
    read -erp "  你的选择：" _in
    [[ -z "$_in" ]] && continue
    case "$_in" in
      q|Q) info "退出救援"; return ;;
      r|R) continue ;;
    esac

    # 解析多选 token
    local _tok _did_anything=0
    for _tok in $_in; do
      case "$_tok" in
        c1) _triage_drop_caches; _did_anything=1 ;;
        c2) _triage_apt_clean; _did_anything=1 ;;
        c3) _triage_journal_vacuum; _did_anything=1 ;;
        k[0-9]*)
          local _idx=${_tok#k}
          if [[ "$_idx" =~ ^[0-9]+$ ]] && (( _idx >= 1 && _idx <= ${#_TRG_KILL_PIDS[@]} )); then
            local _p=${_TRG_KILL_PIDS[$((_idx-1))]}
            local _label=${_TRG_KILL_LABELS[$((_idx-1))]}
            local _yn
            askyn _yn "确认 kill: $_label?" "n"
            if $_yn; then
              local _name
              _name=$(awk '/^Name:/{print $2; exit}' /proc/$_p/status 2>/dev/null || echo "?")
              _triage_kill_pid "$_p" "$_name"
              _did_anything=1
            fi
          else
            warn "无效编号: $_tok"
          fi
          ;;
        *) warn "无效选项: $_tok" ;;
      esac
    done
    (( _did_anything == 1 )) && break_end
  done
}


# ── 常规清理（mem_clean）────────────────────────────────────────
# 与 mod_system.sh 的 system_clean 区分：
#   - system_clean: 偏包管理器维护（autoremove + clean + journal vacuum 1s）
#   - mem_clean:    偏内存压力下的稳健清理（drop_caches + apt clean
#                   + journal vacuum 7d，保守不删近期日志）
mem_clean() {
  section "常规清理"
  echo ""
  echo "  本次会执行（每项独立确认）："
  echo "    1) 释放 page cache       零风险，不影响任何运行进程"
  echo "    2) 清 apt 包缓存         零风险，下次 apt 会重新下载"
  echo "    3) 清 7 天前 journal     保留最近一周日志"
  echo ""
  local _yn

  echo ""
  free -h | head -2
  askyn _yn "1) 释放 page cache？" "y"
  $_yn && _triage_drop_caches

  if command -v apt-get >/dev/null 2>&1; then
    local _apt_kb _apt_mb
    _apt_kb=$(du -sk /var/cache/apt 2>/dev/null | awk '{print $1}')
    _apt_mb=$(( ${_apt_kb:-0} / 1024 ))
    echo ""
    info "apt 包缓存当前占用约 ${_apt_mb} MB"
    askyn _yn "2) 清 apt 包缓存？" "y"
    $_yn && _triage_apt_clean
  fi

  if command -v journalctl >/dev/null 2>&1; then
    echo ""
    info "journal 当前占用 $(journalctl --disk-usage 2>&1 | grep -oE '[0-9.]+[KMG]' | tail -1)"
    askyn _yn "3) 清 7 天前的 journal？" "y"
    $_yn && _triage_journal_vacuum
  fi

  echo ""
  log "常规清理完成"
  echo ""
  free -h | head -2
}

# ── sysctl 调优（sysctl_tune）────────────────────────────────────
# 写入 /etc/sysctl.d/99-howe-mem.conf 让设置在重启后仍然生效。
# 与 mod_network 的 BBR 调优分文件存放（99-howe-bbr.conf），互不覆盖。
#
# 推荐值：
#   vm.swappiness        = 30   1GB 等小内存机偏低更合适，避免过早换页
#   vm.vfs_cache_pressure = 150  默认 100；略提高让内核更愿意回收 inode/dentry

_SYSCTL_CONF=/etc/sysctl.d/99-howe-mem.conf

sysctl_tune() {
  section "sysctl 调优 (内存相关)"
  echo ""

  local _cur_swappiness _cur_pressure
  _cur_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  _cur_pressure=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)

  echo "  当前内核运行值："
  printf "    vm.swappiness         = %s   ${DIM}(默认 60，1GB 机推荐 30)${N}\n" "$_cur_swappiness"
  printf "    vm.vfs_cache_pressure = %s  ${DIM}(默认 100，推荐 150)${N}\n" "$_cur_pressure"
  echo ""

  if [[ -f "$_SYSCTL_CONF" ]]; then
    info "已存在配置文件: $_SYSCTL_CONF"
    echo ""
    sed 's/^/    /' "$_SYSCTL_CONF"
    echo ""
  else
    info "尚未配置 $_SYSCTL_CONF"
    echo ""
  fi

  local _new_swappiness _new_pressure
  ask _new_swappiness "新的 vm.swappiness（回车保持现值）" "$_cur_swappiness"
  ask _new_pressure   "新的 vm.vfs_cache_pressure（回车保持现值）" "$_cur_pressure"

  if ! [[ "$_new_swappiness" =~ ^[0-9]+$ ]] || (( _new_swappiness > 200 )); then
    err "swappiness 必须是 0-200 的整数"; return 1
  fi
  if ! [[ "$_new_pressure" =~ ^[0-9]+$ ]] || (( _new_pressure > 1000 )); then
    err "vfs_cache_pressure 必须是 0-1000 的整数"; return 1
  fi

  # 内容相同 → 跳过
  if [[ -f "$_SYSCTL_CONF" ]]; then
    local _old_sp _old_vp
    _old_sp=$(awk -F= '/^\s*vm\.swappiness/ {gsub(/[ \t]/,"",$2); print $2}' "$_SYSCTL_CONF")
    _old_vp=$(awk -F= '/^\s*vm\.vfs_cache_pressure/ {gsub(/[ \t]/,"",$2); print $2}' "$_SYSCTL_CONF")
    if [[ "$_old_sp" == "$_new_swappiness" && "$_old_vp" == "$_new_pressure" ]]; then
      info "配置未变化，跳过写入"
      return 0
    fi
  fi

  cat > "$_SYSCTL_CONF" <<EOF
# Howe_Linux_sh — 内存调优
# 由 modules/mod_memmgr.sh sysctl_tune 写入
# 与 99-howe-bbr.conf 分文件管理，避免覆盖

vm.swappiness = $_new_swappiness
vm.vfs_cache_pressure = $_new_pressure
EOF
  log "已写入 $_SYSCTL_CONF"

  if sysctl -p "$_SYSCTL_CONF" >/dev/null 2>&1; then
    log "已应用到运行内核"
  else
    warn "sysctl -p 失败，重启后仍会自动加载"
  fi

  echo ""
  echo "  当前生效值："
  printf "    vm.swappiness         = %s\n" "$(cat /proc/sys/vm/swappiness)"
  printf "    vm.vfs_cache_pressure = %s\n" "$(cat /proc/sys/vm/vfs_cache_pressure)"
}

# ── /swap 文件管理（swap_resize）─────────────────────────────────
# 自动检测当前 swap 文件位置（/swap 或 /swapfile），不强制单一文件名。
# 如果有 zram，单独提示用户：扩磁盘 swap 不一定是上策，zram 优先级更高。

# 找出当前所有"文件型 swap"路径（排除 zram 等设备）
_swap_files() {
  swapon --show=NAME,TYPE --noheadings 2>/dev/null \
    | awk '$2=="file"{print $1}'
}

swap_resize() {
  section "/swap 文件管理"
  echo ""

  # 现状
  echo "  当前 swap 设备："
  if swapon --show 2>/dev/null | grep -q .; then
    swapon --show | sed 's/^/    /'
  else
    echo "    （无）"
  fi
  echo ""

  # 提示 zram 存在
  if swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
    info "已启用 zram，常规换页会走 zram，磁盘 swap 主要作为兜底"
    echo "  ${DIM}如果只是想缓解内存压力，扩 zram 可能比扩 /swap 更有效${N}"
    echo ""
  fi

  # 找现有文件型 swap
  local _files
  mapfile -t _files < <(_swap_files)
  local _target=""
  if [[ ${#_files[@]} -eq 0 ]]; then
    info "未发现现有 swap 文件，将创建新文件"
    ask _target "新 swap 文件路径" "/swap"
  elif [[ ${#_files[@]} -eq 1 ]]; then
    _target="${_files[0]}"
    info "将操作现有 swap 文件: $_target"
  else
    echo "  发现多个 swap 文件："
    local _i
    for _i in "${!_files[@]}"; do
      echo "    [$((_i+1))] ${_files[$_i]}"
    done
    local _idx
    ask _idx "要操作哪一个（输入编号）" "1"
    if [[ "$_idx" =~ ^[0-9]+$ ]] && (( _idx >= 1 && _idx <= ${#_files[@]} )); then
      _target="${_files[$((_idx-1))]}"
    else
      err "无效编号"; return 1
    fi
  fi

  # 当前大小
  local _cur_mb=0
  if [[ -f "$_target" ]]; then
    _cur_mb=$(( $(stat -c%s "$_target" 2>/dev/null || echo 0) / 1024 / 1024 ))
  fi
  echo ""
  echo "  当前大小：${_cur_mb} MB"
  echo ""

  local _new_mb
  ask _new_mb "新大小（MB，0=禁用并删除该 swap 文件）" "$_cur_mb"
  if ! [[ "$_new_mb" =~ ^[0-9]+$ ]]; then
    err "必须输入整数 MB"; return 1
  fi

  # 等于现值 → 跳过
  if [[ "$_new_mb" == "$_cur_mb" ]]; then
    info "大小未变化，跳过"
    return 0
  fi

  # 磁盘空间检查（防止 dd 撑爆根）
  if (( _new_mb > 0 )); then
    local _avail_mb
    _avail_mb=$(df -m "$(dirname "$_target")" | awk 'NR==2{print $4}')
    if (( _avail_mb < _new_mb + 200 )); then
      err "目标分区可用 ${_avail_mb}MB，需要至少 $((_new_mb+200))MB（含 200MB 余量）"
      return 1
    fi
  fi

  local _yn
  if (( _new_mb == 0 )); then
    askyn _yn "确认禁用并删除 $_target？" "n"
  else
    askyn _yn "确认调整 $_target 为 ${_new_mb}MB？" "y"
  fi
  $_yn || { info "已取消"; return 0; }

  # 关 swap
  if [[ -f "$_target" ]]; then
    info "swapoff $_target"
    swapoff "$_target" 2>/dev/null || true
  fi

  if (( _new_mb == 0 )); then
    rm -f "$_target"
    sed -i "\|^${_target}[[:space:]]|d" /etc/fstab
    log "已禁用并删除 $_target，fstab 也已清理"
    return 0
  fi

  # 重建（dd 比 fallocate 更可靠，确保连续）
  info "重建 swap 文件（dd ${_new_mb}MB）..."
  rm -f "$_target"
  if ! dd if=/dev/zero of="$_target" bs=1M count="$_new_mb" status=none 2>/dev/null; then
    err "dd 失败"; return 1
  fi
  chmod 600 "$_target"
  mkswap "$_target" >/dev/null 2>&1
  swapon "$_target" -p -2  # 优先级 -2，让 zram 优先

  # 持久化到 fstab（幂等）
  if ! grep -qE "^${_target}[[:space:]]" /etc/fstab; then
    echo "$_target none swap sw 0 0" >> /etc/fstab
    log "已写入 /etc/fstab"
  fi

  echo ""
  swapon --show
  log "swap 已调整为 ${_new_mb}MB"
}

# ── zram 启用 / 调整（zram_setup）────────────────────────────────
# 用 zram-tools 包管理。配置文件 /etc/default/zramswap。
zram_setup() {
  section "zram 启用 / 调整"
  echo ""

  if ! dpkg -l zram-tools 2>/dev/null | grep -q '^ii'; then
    info "zram-tools 未安装"
    local _yn
    askyn _yn "现在安装 zram-tools？" "y"
    if $_yn; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools 2>&1 | tail -3
    else
      info "已取消"; return 0
    fi
  else
    info "zram-tools 已安装"
  fi

  # 当前 zram 状态
  echo ""
  echo "  当前 zram 设备："
  if swapon --show=NAME,TYPE,SIZE,PRIO --noheadings 2>/dev/null | grep -E '^/dev/zram'; then
    swapon --show=NAME,TYPE,SIZE,PRIO --noheadings | grep -E '^/dev/zram' | sed 's/^/    /'
  else
    echo "    （未启用）"
  fi
  echo ""

  # 当前配置
  local _cur_algo _cur_size _cur_prio
  _cur_algo=$(awk -F= '/^ALGO=/ {gsub(/[ \t]/,"",$2); print $2}' /etc/default/zramswap 2>/dev/null)
  _cur_size=$(awk -F= '/^SIZE=/ {gsub(/[ \t]/,"",$2); print $2}' /etc/default/zramswap 2>/dev/null)
  _cur_prio=$(awk -F= '/^PRIORITY=/ {gsub(/[ \t]/,"",$2); print $2}' /etc/default/zramswap 2>/dev/null)
  : "${_cur_algo:=lz4}"
  : "${_cur_size:=256}"
  : "${_cur_prio:=100}"
  echo "  当前配置（/etc/default/zramswap）："
  printf "    ALGO     = %s   ${DIM}(zstd 压缩比最好，lz4 最快)${N}\n" "$_cur_algo"
  printf "    SIZE     = %s MB\n" "$_cur_size"
  printf "    PRIORITY = %s   ${DIM}(100 = 高于磁盘 swap，先用 zram)${N}\n" "$_cur_prio"
  echo ""

  local _new_algo _new_size _new_prio
  ask _new_algo "ALGO（zstd / lz4 / lzo）" "$_cur_algo"
  ask _new_size "SIZE（MB，建议 RAM 的 50%~100%）" "$_cur_size"
  ask _new_prio "PRIORITY（建议 100 高于磁盘 swap）" "$_cur_prio"

  case "$_new_algo" in zstd|lz4|lzo) ;; *) err "ALGO 必须是 zstd/lz4/lzo"; return 1 ;; esac
  if ! [[ "$_new_size" =~ ^[0-9]+$ ]]; then err "SIZE 必须是整数"; return 1; fi
  if ! [[ "$_new_prio" =~ ^[0-9]+$ ]] || (( _new_prio > 32767 )); then
    err "PRIORITY 必须是 0-32767"; return 1
  fi

  if [[ "$_new_algo" == "$_cur_algo" && "$_new_size" == "$_cur_size" && "$_new_prio" == "$_cur_prio" ]]; then
    info "配置未变化，跳过"
    return 0
  fi

  # 写入配置（保留注释 + 替换/插入参数行）
  local _conf=/etc/default/zramswap
  if ! grep -qE '^\s*#?\s*ALGO=' "$_conf"; then
    echo "ALGO=$_new_algo" >> "$_conf"
  else
    sed -i "s|^\s*#\?\s*ALGO=.*|ALGO=$_new_algo|" "$_conf"
  fi
  if ! grep -qE '^\s*#?\s*SIZE=' "$_conf"; then
    echo "SIZE=$_new_size" >> "$_conf"
  else
    sed -i "s|^\s*#\?\s*SIZE=.*|SIZE=$_new_size|" "$_conf"
  fi
  if ! grep -qE '^\s*#?\s*PRIORITY=' "$_conf"; then
    echo "PRIORITY=$_new_prio" >> "$_conf"
  else
    sed -i "s|^\s*#\?\s*PRIORITY=.*|PRIORITY=$_new_prio|" "$_conf"
  fi
  log "已写入 $_conf"

  info "重启 zramswap 服务..."
  if systemctl restart zramswap 2>&1 | tee /dev/stderr | grep -q 'Failed'; then
    err "zramswap 重启失败，请手动 systemctl status zramswap 查看"
    return 1
  fi
  log "zramswap 已重启"
  echo ""
  swapon --show
}

# ── earlyoom 安装 / 配置（earlyoom_setup）───────────────────────
# 预防机制：内存 / swap 同时低于阈值时主动 kill 最大占用进程，
# 避免内核 OOM Killer 触发时整机卡死、SSH 也连不上。
#
# 默认阈值：MEM 10% + SWAP 10%（同时低于才触发；任一仍较高 = 不动作）
# 配置文件：/etc/default/earlyoom
earlyoom_setup() {
  section "earlyoom 安装 / 配置"
  echo ""
  echo "  earlyoom 是预防型 OOM 处理器："
  echo "    内存 + swap 同时降到阈值以下时，主动 kill 占用最多的进程"
  echo "    比内核 OOM Killer 提前触发，避免整机卡死、SSH 断连"
  echo ""

  if ! command -v earlyoom >/dev/null 2>&1; then
    info "earlyoom 未安装"
    local _yn
    askyn _yn "现在安装 earlyoom？" "y"
    if ! $_yn; then info "已取消"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom 2>&1 | tail -3
    if ! command -v earlyoom >/dev/null 2>&1; then
      err "安装失败"; return 1
    fi
  else
    info "earlyoom 已安装"
  fi

  # 当前服务状态
  echo ""
  echo "  当前服务状态："
  if systemctl is-active --quiet earlyoom; then
    log "运行中（systemctl status earlyoom 查看详情）"
  else
    warn "未运行"
  fi
  echo ""

  # 当前配置
  local _conf=/etc/default/earlyoom
  local _cur_args
  _cur_args=$(awk -F= '/^EARLYOOM_ARGS=/ {gsub(/"/,"",$2); print $2}' "$_conf" 2>/dev/null)
  echo "  当前 EARLYOOM_ARGS: ${_cur_args:-(默认空)}"
  echo ""
  echo "  ${DIM}常用参数：${N}"
  echo "  ${DIM}  -m 10        内存低于 10% 触发${N}"
  echo "  ${DIM}  -s 10        swap 低于 10% 触发（与 -m 同时满足）${N}"
  echo "  ${DIM}  -r 60        每 60 秒打印一次内存状态${N}"
  echo "  ${DIM}  --avoid 'sshd|systemd' 永远不杀这些进程${N}"
  echo "  ${DIM}  --prefer 'firefox|chrome'  优先杀这些进程${N}"
  echo ""

  local _new_args
  ask _new_args "EARLYOOM_ARGS（回车保持现值）" \
    "${_cur_args:--m 10 -s 10 -r 60 --avoid '(^|/)(sshd|systemd|init|bash|tmux|screen)$'}"

  if [[ "$_new_args" == "$_cur_args" ]]; then
    info "配置未变化，跳过"
    if ! systemctl is-active --quiet earlyoom; then
      askyn _yn "earlyoom 当前未运行，是否现在启用？" "y"
      if $_yn; then
        systemctl enable --now earlyoom
        log "已启用并启动"
      fi
    fi
    return 0
  fi

  # 写入配置（保留原文件其它行）
  if grep -qE '^EARLYOOM_ARGS=' "$_conf" 2>/dev/null; then
    sed -i "s|^EARLYOOM_ARGS=.*|EARLYOOM_ARGS=\"$_new_args\"|" "$_conf"
  else
    [[ -f "$_conf" ]] || touch "$_conf"
    echo "EARLYOOM_ARGS=\"$_new_args\"" >> "$_conf"
  fi
  log "已写入 $_conf"

  systemctl enable --now earlyoom 2>&1 | tail -2
  systemctl restart earlyoom
  if systemctl is-active --quiet earlyoom; then
    log "earlyoom 已启用并启动"
  else
    err "earlyoom 启动失败，运行 systemctl status earlyoom 查看"
    return 1
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
    echo "  2. 内存救援"
    echo "  3. 常规清理"
    echo "  ─────────────────"
    echo "  4. sysctl 调优"
    echo "  5. /swap 文件管理"
    echo "  6. zram 启用 / 调整"
    echo "  7. earlyoom 安装 / 配置（可选）"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) mem_status; break_end ;;
      2) mem_triage ;;
      3) mem_clean; break_end ;;
      4) sysctl_tune; break_end ;;
      5) swap_resize; break_end ;;
      6) zram_setup; break_end ;;
      7) earlyoom_setup; break_end ;;
      0|"") break ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}
