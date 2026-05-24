#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 通用工具函数
# ═══════════════════════════════════════════════════════════════════

# 交互式输入（支持 readline 退格/左右键编辑）
ask() {
  local _v=$1 _p=$2 _d=${3:-}
  local __ask_i
  read -erp "$(echo -e "  ${W}${_p}${N}${_d:+ [${_d}]}: ")" __ask_i
  printf -v "$_v" '%s' "${__ask_i:-$_d}"
}

# 确认提示 (Y/n 或 y/N)
askyn() {
  local _v=$1 _p=$2 _d=${3:-y}
  local _h; [[ "$_d" == "y" ]] && _h="Y/n" || _h="y/N"
  local __ask_i
  read -erp "$(echo -e "  ${W}${_p}${N} [${_h}]: ")" __ask_i
  __ask_i=${__ask_i:-$_d}
  [[ "${__ask_i,,}" == "y" ]] && printf -v "$_v" true || printf -v "$_v" false
}

# 重置终端状态（外部脚本执行后调用，清除残留的 VT 转义序列）
reset_terminal() {
  tput sgr0 2>/dev/null || true
  stty sane 2>/dev/null || true
}

# 操作完成，按任意键继续
break_end() {
  reset_terminal
  echo ""
  echo -e "${G}操作完成${N}"
  echo "按任意键继续..."
  read -n 1 -s -r -p ""
  clear
}

# root 权限检查
root_use() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此功能"
    return 1
  fi
}

# 检查磁盘空间
check_disk_space() {
  local required_gb=$1
  local path=${2:-/}
  mkdir -p "$path" 2>/dev/null

  local avail_mb
  avail_mb=$(df -m "$path" | awk 'NR==2{print $4}')
  local avail_gb=$((avail_mb / 1024))

  if [[ $avail_gb -lt $required_gb ]]; then
    err "磁盘空间不足：需要 ${required_gb}GB，可用 ${avail_gb}GB（${path}）"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════
# 输入式菜单工具（SSH 友好，无刷新式重绘）
# ═══════════════════════════════════════════════════════════════════

# 单选菜单
# 用法: input_choose "提示" "选项1" "选项2" ...
#   可在选项前加 * 表示默认: "*选项3"
#   返回: INPUT_RESULT = 选中索引 (0-based)，按 Enter 无输入 = -1
INPUT_RESULT=-1
input_choose() {
  local _prompt="$1"; shift
  local -a _opts=("$@")
  local _cnt=${#_opts[@]}
  local _default=-1

  # 检测默认项
  for (( i=0; i<_cnt; i++ )); do
    if [[ "${_opts[i]}" == \** ]]; then
      _opts[i]="${_opts[i]#*}"
      _default=$i
    fi
  done

  echo ""
  echo -e "  ${W}${_prompt}${N}"
  echo -e "  ${DIM}────────────────────────────────${N}"
  for (( i=0; i<_cnt; i++ )); do
    echo "    $((i+1)). ${_opts[i]}"
  done
  echo ""
  local _hint="输入编号（1-${_cnt}）"
  if [[ $_default -ge 0 ]]; then
    _hint+="，直接回车选 $((_default+1))"
  else
    _hint+="，直接回车返回"
  fi
  echo -e "  ${DIM}${_hint}${N}"
  echo ""

  local _input
  read -erp "  选择：" _input

  if [[ -z "$_input" ]] && [[ $_default -ge 0 ]]; then
    INPUT_RESULT=$_default
  elif [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _cnt )); then
    INPUT_RESULT=$((_input - 1))
  else
    INPUT_RESULT=-1
  fi
}

# 多选菜单（带切换）
# 用法: input_multi "提示" "选项1" "选项2" ...
#   返回: INPUT_RESULTS = 数组，包含所有选中项的索引 (0-based)
#   空输入（回车）= 确认当前选择
#   a = 全选/取消全选
INPUT_RESULTS=()
input_multi() {
  local _prompt="$1"; shift
  local -a _opts=("$@")
  local _cnt=${#_opts[@]}
  local -a _sel=()
  for (( i=0; i<_cnt; i++ )); do _sel[i]=false; done

  while true; do
    clear
    echo -e "  ${W}${_prompt}${N}"
    echo -e "  ${DIM}────────────────────────────────${N}"
    for (( i=0; i<_cnt; i++ )); do
      local _chk="${DIM}[ ]${N}"
      ${_sel[i]} && _chk="${G}[✓]${N}"
      echo -e "    ${_chk} $((i+1)). ${_opts[i]}"
    done
    echo ""
    echo -e "  ${DIM}输入编号切换（可用逗号分隔: 1,3,5） | a=全选 | 直接回车=确认${N}"
    echo ""

    local _input
    read -erp "  选择：" _input

    if [[ -z "$_input" ]]; then
      break
    elif [[ "$_input" == "a" ]] || [[ "$_input" == "A" ]]; then
      local _all_on=true
      for (( i=0; i<_cnt; i++ )); do ${_sel[i]} || { _all_on=false; break; }; done
      for (( i=0; i<_cnt; i++ )); do
        $_all_on && _sel[i]=false || _sel[i]=true
      done
    else
      IFS=',' read -ra _nums <<< "$_input"
      for _n in "${_nums[@]}"; do
        _n="${_n// /}"
        if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n >= 1 && _n <= _cnt )); then
          _sel[_n-1]=$(${_sel[_n-1]} && echo false || echo true)
        fi
      done
    fi
  done

  INPUT_RESULTS=()
  for (( i=0; i<_cnt; i++ )); do
    ${_sel[i]} && INPUT_RESULTS+=("$i")
  done
}

# 是/否确认（输入式，无刷新）
# 用法: askyn_input "提示" [默认 y/n]
#   返回: INPUT_RESULT = true/false
askyn_input() {
  local _p="$1" _d="${2:-y}"
  local _h; [[ "$_d" == "y" ]] && _h="Y/n" || _h="y/N"
  local _i
  echo ""
  read -erp "  ${_p} [${_h}]: " _i
  _i="${_i:-$_d}"
  [[ "${_i,,}" == "y" ]] && INPUT_RESULT=true || INPUT_RESULT=false
}
