#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 交互式键盘菜单引擎
#
# 提供两个通用函数：
#   howe_menu_single  — 单选菜单（↑↓移动 + 回车确认）
#   howe_menu_multi   — 多选菜单（↑↓移动 + 空格切换 + 回车确认）
#
# 来源：ai-stack-setup.sh 的 choose_deploy_mode() / select_services()
# 机制：read -rsn1 + 3步 escape 序列解析 + printf 光标上移重绘
# ═══════════════════════════════════════════════════════════════════

# ── 单选菜单 ─────────────────────────────────────────────────────
# 用法：howe_menu_single "标题" "选项1描述" "选项2描述" ...
# 结果：$HOWE_MENU_RESULT  = 选中项的索引（0-based）
#       $HOWE_MENU_BACK    = true 如果用户选了返回
# 返回：0=确认  1=返回上一级
howe_menu_single() {
  local title="$1"; shift
  local -a items=("$@")
  local cnt=${#items[@]}
  local cur=0
  local first=true
  local menu_lines=0
  local menu_lines_saved=0

  while true; do
    local ml=0

    if $first; then
      clear; first=false
    else
      printf "\033[%dA" "$menu_lines_saved"
    fi

    # 标题
    echo -e "\n  ${W}${title}${N}\n"; ml=$((ml+3))

    # 选项
    for (( i=0; i<cnt; i++ )); do
      local hl=""; [[ $i -eq $cur ]] && hl="\033[7m"
      printf "  ${hl}  %s${N}\n" "${items[$i]}"
      ml=$((ml+1))
    done

    # 底部提示
    echo ""; ml=$((ml+1))
    printf "  ${DIM}↑↓ 移动  回车确认${N}\n"; ml=$((ml+1))

    menu_lines_saved=$ml

    # 读取按键
    IFS= read -rsn1 _hkey
    if [[ "$_hkey" == $'\e' ]]; then
      IFS= read -rsn1 -t 0.1 _hkey 2>/dev/null
      [[ "$_hkey" == '[' ]] && IFS= read -rsn1 _hkey
      case "$_hkey" in
        A) [[ $cur -gt 0 ]] && cur=$((cur-1)) ;;
        B) [[ $cur -lt $((cnt-1)) ]] && cur=$((cur+1)) ;;
      esac
      continue
    fi

    [[ "$_hkey" == '' ]] || continue

    # 回车确认
    HOWE_MENU_RESULT=$cur
    HOWE_MENU_BACK=false
    return 0
  done
}

# ── 多选菜单 ─────────────────────────────────────────────────────
# 用法：howe_menu_multi "标题" "选项1" "选项2" ...
#       可选参数：--back "返回文本"  添加返回选项
# 结果：$HOWE_MENU_RESULTS = 空格分隔的选中索引列表（0-based）
#       $HOWE_MENU_BACK    = true 如果用户选了返回
# 返回：0=确认  1=返回上一级
howe_menu_multi() {
  local title=""
  local back_text=""
  local -a items=()

  # 解析参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --back) back_text="$2"; shift 2 ;;
      *)      items+=("$1"); shift ;;
    esac
  done

  local cnt=${#items[@]}
  local cur=0
  local -a sel=()
  for (( i=0; i<cnt; i++ )); do sel+=(false); done

  local has_back=false
  [[ -n "$back_text" ]] && has_back=true

  local total=$cnt  # 选项总数（含返回）
  $has_back && total=$((cnt+1))

  local first=true
  local menu_lines=0
  local menu_lines_saved=0

  _draw() {
    local ml=0

    if $first; then
      clear; first=false
    else
      printf "\033[%dA" "$menu_lines_saved"
    fi

    echo -e "\n  ${W}${title}${N}\n"; ml=$((ml+3))

    # 选项
    for (( i=0; i<cnt; i++ )); do
      local hl=""; [[ $i -eq $cur ]] && hl="\033[7m"
      local chk; [[ "${sel[$i]}" == "true" ]] && chk="${G}[✓]${N}" || chk="${DIM}[ ]${N}"
      printf "  ${hl} %b  %s${N}\n" "$chk" "${items[$i]}"
      ml=$((ml+1))
    done

    # 返回选项
    if $has_back; then
      local bh=""; [[ $cur -eq $cnt ]] && bh="\033[7m"
      printf "  ${bh}  ${DIM}[←]  ${back_text}${N}\n"
      ml=$((ml+1))
    fi

    echo ""; ml=$((ml+1))
    printf "  ${DIM}↑↓ 移动  空格切换  a 全选/取消  回车确认${N}\n"
    ml=$((ml+1))

    menu_lines_saved=$ml
  }

  while true; do
    _draw

    # 读取按键
    IFS= read -rsn1 _hkey

    if [[ "$_hkey" == $'\e' ]]; then
      IFS= read -rsn1 -t 0.1 _hkey 2>/dev/null
      [[ "$_hkey" == '[' ]] && IFS= read -rsn1 _hkey
      case "$_hkey" in
        A) [[ $cur -gt 0 ]] && cur=$((cur-1)) ;;
        B) [[ $cur -lt $((total-1)) ]] && cur=$((cur+1)) ;;
      esac
      continue
    fi

    case "$_hkey" in
      ' ')
        [[ $cur -eq $cnt ]] && continue  # 返回选项不可切换
        [[ "${sel[$cur]}" == "true" ]] && sel[$cur]=false || sel[$cur]=true
        ;;
      a|A)
        local all_on=true
        for (( i=0; i<cnt; i++ )); do
          [[ "${sel[$i]}" != "true" ]] && all_on=false
        done
        for (( i=0; i<cnt; i++ )); do
          $all_on && sel[$i]=false || sel[$i]=true
        done
        ;;
      '')
        if [[ $cur -eq $cnt ]]; then
          HOWE_MENU_BACK=true
          return 1
        fi

        # 构建结果
        local results=""
        for (( i=0; i<cnt; i++ )); do
          [[ "${sel[$i]}" == "true" ]] && results+="$i "
        done
        HOWE_MENU_RESULTS="${results% }"
        HOWE_MENU_BACK=false
        return 0
        ;;
    esac
  done
}

# ── 带数据的多选菜单 ─────────────────────────────────────────────
# 适用于需要携带额外数据（如变量名）的场景
# 用法：
#   local -a items=("VAR1|显示名1" "VAR2|显示名2")
#   howe_menu_multi_data "标题" items --back "返回"
# 结果：$HOWE_MENU_RESULTS  = 空格分隔的选中变量名
#       $HOWE_MENU_INDICES  = 空格分隔的选中索引
# 返回：0=确认  1=返回
howe_menu_multi_data() {
  local title="$1"
  local -n _items_ref=$2  # nameref 到数组
  shift 2

  local back_text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --back) back_text="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local cnt=${#_items_ref[@]}
  local cur=0
  local -a sel=()
  for (( i=0; i<cnt; i++ )); do sel+=(false); done

  local has_back=false
  [[ -n "$back_text" ]] && has_back=true
  local total=$cnt
  $has_back && total=$((cnt+1))

  local first=true
  local menu_lines_saved=0

  while true; do
    local ml=0
    if $first; then clear; first=false; else printf "\033[%dA" "$menu_lines_saved"; fi

    echo -e "\n  ${W}${title}${N}\n"; ml=$((ml+3))

    for (( i=0; i<cnt; i++ )); do
      IFS='|' read -r _var _label <<< "${_items_ref[$i]}"
      local hl=""; [[ $i -eq $cur ]] && hl="\033[7m"
      local chk; [[ "${sel[$i]}" == "true" ]] && chk="${G}[✓]${N}" || chk="${DIM}[ ]${N}"
      printf "  ${hl} %b  %s${N}\n" "$chk" "${_label:-$_var}"
      ml=$((ml+1))
    done

    if $has_back; then
      local bh=""; [[ $cur -eq $cnt ]] && bh="\033[7m"
      printf "  ${bh}  ${DIM}[←]  ${back_text}${N}\n"; ml=$((ml+1))
    fi
    echo ""; ml=$((ml+1))
    printf "  ${DIM}↑↓ 移动  空格切换  a 全选/取消  回车确认${N}\n"; ml=$((ml+1))
    menu_lines_saved=$ml

    IFS= read -rsn1 _hkey
    if [[ "$_hkey" == $'\e' ]]; then
      IFS= read -rsn1 -t 0.1 _hkey 2>/dev/null
      [[ "$_hkey" == '[' ]] && IFS= read -rsn1 _hkey
      case "$_hkey" in
        A) [[ $cur -gt 0 ]] && cur=$((cur-1)) ;;
        B) [[ $cur -lt $((total-1)) ]] && cur=$((cur+1)) ;;
      esac
      continue
    fi

    case "$_hkey" in
      ' ')
        [[ $cur -eq $cnt ]] && continue
        [[ "${sel[$cur]}" == "true" ]] && sel[$cur]=false || sel[$cur]=true
        ;;
      a|A)
        local all_on=true
        for (( i=0; i<cnt; i++ )); do [[ "${sel[$i]}" != "true" ]] && all_on=false; done
        for (( i=0; i<cnt; i++ )); do $all_on && sel[$i]=false || sel[$i]=true; done
        ;;
      '')
        if [[ $cur -eq $cnt ]]; then HOWE_MENU_BACK=true; return 1; fi
        local results="" indices=""
        for (( i=0; i<cnt; i++ )); do
          if [[ "${sel[$i]}" == "true" ]]; then
            IFS='|' read -r _var _ <<< "${_items_ref[$i]}"
            results+="$_var "
            indices+="$i "
          fi
        done
        HOWE_MENU_RESULTS="${results% }"
        HOWE_MENU_INDICES="${indices% }"
        HOWE_MENU_BACK=false
        return 0
        ;;
    esac
  done
}
