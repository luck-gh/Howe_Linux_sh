#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# AI 服务栈 — 备份 / 恢复菜单
#
# 入口：backup_menu（被 main.sh::service_stack_menu 调用）
# 依赖：backup_lib.sh 提供的底层函数
# ═══════════════════════════════════════════════════════════════════

# ── scope 选择（多选）────────────────────────────────────────────
# 输入：$1 标题
# 输出：BACKUP_PICKED_SCOPES 空格分隔的 scope key 列表（可能为空）
_backup_pick_scopes() {
  local _title=${1:-"选择备份范围"}
  local -a _avail=()
  mapfile -t _avail < <(backup_available_scopes)
  if [[ ${#_avail[@]} -eq 0 ]]; then
    warn "当前主机未检测到任何可备份的服务"
    BACKUP_PICKED_SCOPES=""
    return 1
  fi

  local _cnt=${#_avail[@]}
  declare -A _SEL
  local i
  # 按设置中的默认 scope 预选；未配置则全选
  local _default_csv; _default_csv=$(backup_conf_get DEFAULT_SCOPES "$BACKUP_DEFAULT_SCOPES_DEFAULT")
  if [[ -z "$_default_csv" ]]; then
    for (( i=0; i<_cnt; i++ )); do _SEL[$i]=true; done
  else
    local k
    for (( i=0; i<_cnt; i++ )); do
      _SEL[$i]=false
      for k in ${_default_csv//,/ }; do
        [[ "${_avail[$i]}" == "$k" ]] && _SEL[$i]=true
      done
    done
  fi

  local _msg=""
  while true; do
    print_header "$_title"
    echo -e "  ${DIM}选择要备份的项目（输入编号切换；默认全选）${N}"
    echo ""
    for (( i=0; i<_cnt; i++ )); do
      local _key=${_avail[$i]}
      local _desc; _desc=$(backup_scope_desc "$_key")
      local _chk; [[ "${_SEL[$i]}" == "true" ]] && _chk="${G}[✓]${N}" || _chk="${DIM}[ ]${N}"
      printf "    %b ${W}[%d]${N}  %-10s ${DIM}%s${N}\n" "$_chk" "$((i+1))" "$_key" "$_desc"
    done
    echo ""

    # 估算空间
    local _picked=""
    for (( i=0; i<_cnt; i++ )); do
      [[ "${_SEL[$i]}" == "true" ]] && _picked+="${_avail[$i]} "
    done
    if [[ -n "$_picked" ]]; then
      local _est; _est=$(backup_estimate_size $_picked)
      echo -e "  ${W}估算空间：${N}$(_bk_human "$_est")（压缩后实际可能更小）"
    else
      echo -e "  ${DIM}未选择${N}"
    fi
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "    ${DIM}[a] 全选/取消    [Enter] 确认    [0] 返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input
    _msg=""
    multi_select_input "$_input" _SEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      return)  BACKUP_PICKED_SCOPES=""; return 1 ;;
      invalid) _msg="${R}无效输入${N}"; continue ;;
      toggled) continue ;;
    esac

    # confirm
    BACKUP_PICKED_SCOPES="${_picked% }"
    [[ -z "$BACKUP_PICKED_SCOPES" ]] && { _msg="${R}至少选择一项${N}"; continue; }
    return 0
  done
}

# ── 立即备份 ─────────────────────────────────────────────────────
backup_action_create() {
  _backup_pick_scopes "立即备份 — 选择范围" || return 0
  echo ""
  local _note
  read -erp "  备注（可空，回车跳过）：" _note
  echo ""
  log "开始备份..."
  local _dir
  _dir=$(backup_create "$_note" $BACKUP_PICKED_SCOPES)
  if [[ -n "$_dir" ]]; then
    local _sz; _sz=$(du -sb "$_dir" 2>/dev/null | awk '{print $1}')
    log "备份完成：$(basename "$_dir")  大小：$(_bk_human "$_sz")"
  else
    warn "备份未生成（全部 scope 失败）"
  fi
  # 应用保留策略
  local _keep; _keep=$(_backup_get_keep)
  local _removed; _removed=$(backup_apply_retention "$_keep")
  (( _removed > 0 )) && info "保留策略：清理了 ${_removed} 个旧备份点"
  echo ""
  read -erp "  按回车返回..." _
}

# 计算字符串显示宽度（中文 2，ASCII 1）
_bk_dispwidth() {
  python3 -c '
import sys, unicodedata
s = sys.argv[1] if len(sys.argv)>1 else ""
w = 0
for ch in s:
    if unicodedata.east_asian_width(ch) in ("F","W"): w += 2
    else: w += 1
print(w)
' "$1" 2>/dev/null || echo "${#1}"
}

# 按显示宽度左对齐填充到 width
_bk_padr() {
  local s=$1 width=$2
  local w; w=$(_bk_dispwidth "$s")
  local pad=$((width - w))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ""
}
backup_action_list() {
  print_header "备份列表"
  local -a _entries=()
  mapfile -t _entries < <(backup_list)
  if [[ ${#_entries[@]} -eq 0 ]]; then
    echo -e "  ${DIM}暂无备份${N}"
    echo ""
    read -erp "  按回车返回..." _
    return 0
  fi

  # 表头（用 _bk_padr 处理中文宽度）
  echo -e "  ${W}$(_bk_padr "时间戳" 18)$(_bk_padr "大小" 10)$(_bk_padr "范围" 36)备注${N}"
  echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────────${N}"
  local _e _ts _size _scopes _note
  for _e in "${_entries[@]}"; do
    IFS='|' read -r _ts _size _scopes _note <<< "$_e"
    printf "  %s%s%s%s\n" \
      "$(_bk_padr "$_ts" 18)" \
      "$(_bk_padr "$(_bk_human "$_size")" 10)" \
      "$(_bk_padr "${_scopes:0:34}" 36)" \
      "$_note"
  done
  echo ""
  echo -e "  ${DIM}保留策略：每个 scope 最近 $(_backup_get_keep) 份${N}"
  echo ""
  read -erp "  按回车返回..." _
}

# ── 选择备份点（公共子流程）─────────────────────────────────────
# 输出：BACKUP_PICKED_TS
_backup_pick_point() {
  local _title=${1:-"选择备份点"}
  local -a _entries=()
  mapfile -t _entries < <(backup_list)
  if [[ ${#_entries[@]} -eq 0 ]]; then
    warn "暂无备份"
    BACKUP_PICKED_TS=""
    return 1
  fi

  local _cnt=${#_entries[@]}
  print_header "$_title"
  local i
  echo -e "  ${W}$(_bk_padr "#" 5)$(_bk_padr "时间戳" 18)$(_bk_padr "大小" 10)范围${N}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────────${N}"
  for (( i=0; i<_cnt; i++ )); do
    IFS='|' read -r _ts _size _scopes _note <<< "${_entries[$i]}"
    printf "  %s%s%s%s\n" \
      "$(_bk_padr "[$((i+1))]" 5)" \
      "$(_bk_padr "$_ts" 18)" \
      "$(_bk_padr "$(_bk_human "$_size")" 10)" \
      "${_scopes:0:50}"
  done
  echo ""
  local _input
  read -erp "  选择编号（0 返回）：" _input
  [[ -z "$_input" ]] || [[ "$_input" == "0" ]] && { BACKUP_PICKED_TS=""; return 1; }
  if ! [[ "$_input" =~ ^[0-9]+$ ]] || (( _input < 1 || _input > _cnt )); then
    warn "无效输入"
    BACKUP_PICKED_TS=""
    return 1
  fi
  IFS='|' read -r BACKUP_PICKED_TS _ <<< "${_entries[$((_input-1))]}"
  return 0
}

# ── 恢复 ────────────────────────────────────────────────────────
backup_action_restore() {
  _backup_pick_point "恢复 — 选择备份点" || return 0
  local _ts=$BACKUP_PICKED_TS

  # 校验
  echo ""
  info "校验备份点 $_ts ..."
  local _bad
  _bad=$(backup_verify "$_ts")
  if [[ -n "$_bad" ]]; then
    warn "以下 scope 校验失败，将无法恢复：$_bad"
  else
    log "校验通过"
  fi

  # 列出可恢复的 scope，多选
  local -a _avail=()
  mapfile -t _avail < <(backup_point_scopes "$_ts")
  local _cnt=${#_avail[@]}
  declare -A _SEL
  local i
  for (( i=0; i<_cnt; i++ )); do _SEL[$i]=false; done

  local _msg=""
  while true; do
    print_header "恢复 — 选择要恢复的内容"
    echo -e "  ${W}备份点：${N}$_ts"
    echo ""
    for (( i=0; i<_cnt; i++ )); do
      local _key=${_avail[$i]}
      local _desc; _desc=$(backup_scope_desc "$_key")
      local _chk; [[ "${_SEL[$i]}" == "true" ]] && _chk="${G}[✓]${N}" || _chk="${DIM}[ ]${N}"
      printf "    %b ${W}[%d]${N}  %-10s ${DIM}%s${N}\n" "$_chk" "$((i+1))" "$_key" "$_desc"
    done
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "    ${DIM}[a] 全选/取消    [Enter] 确认    [0] 返回${N}"
    echo ""
    local _input
    read -erp "  选择：" _input
    _msg=""
    multi_select_input "$_input" _SEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      return)  return 0 ;;
      invalid) _msg="${R}无效输入${N}"; continue ;;
      toggled) continue ;;
    esac
    local _picked=""
    for (( i=0; i<_cnt; i++ )); do
      [[ "${_SEL[$i]}" == "true" ]] && _picked+="${_avail[$i]} "
    done
    [[ -z "$_picked" ]] && { _msg="${R}至少选择一项${N}"; continue; }

    echo ""
    echo -e "  ${R}${W}警告：${N}恢复操作会覆盖现有数据！"
    echo -e "    将恢复：${C}${_picked}${N}"
    echo -e "    备份点：${C}$_ts${N}"
    echo ""
    local _confirm
    read -erp "  输入 yes 确认：" _confirm
    [[ "$_confirm" != "yes" ]] && { _msg="已取消"; continue; }

    echo ""
    backup_restore "$_ts" $_picked
    echo ""
    read -erp "  按回车返回..." _
    return 0
  done
}

# ── 删除备份 ────────────────────────────────────────────────────
backup_action_delete() {
  _backup_pick_point "删除 — 选择备份点" || return 0
  local _ts=$BACKUP_PICKED_TS
  echo ""
  echo -e "  ${R}将删除备份点：${N}$_ts"
  local _confirm
  read -erp "  输入 yes 确认：" _confirm
  if [[ "$_confirm" == "yes" ]]; then
    backup_delete "$_ts" && log "已删除：$_ts" || warn "删除失败"
  else
    info "已取消"
  fi
  echo ""
  read -erp "  按回车返回..." _
}

# ── 自动备份与保留策略设置 ─────────────────────────────────────
_backup_get_keep() { backup_conf_get KEEP "$BACKUP_KEEP_DEFAULT"; }

# 修改保留份数
_settings_change_keep() {
  print_header "修改保留份数"
  echo -e "  ${DIM}每个 scope 独立计数，超过的从最旧开始删${N}"
  echo ""
  local _cur; _cur=$(_backup_get_keep)
  echo -e "  当前值：${C}$_cur${N}"
  echo ""
  local _new
  read -erp "  新的保留份数（建议 3-30，回车取消）：" _new
  if [[ -z "$_new" ]]; then info "已取消"
  elif [[ "$_new" =~ ^[0-9]+$ ]] && (( _new >= 1 && _new <= 100 )); then
    backup_conf_set KEEP "$_new"
    log "保留份数已更新为 $_new"
  else
    warn "输入无效（必须 1-100 整数）"
  fi
  echo ""; read -erp "  按回车继续..." _
}

# 修改备份存储路径
_settings_change_root() {
  print_header "修改备份存储路径"
  local _cur; _cur=$(backup_root)
  echo -e "  当前路径：${C}$_cur${N}"
  if [[ -d "$_cur" ]]; then
    local _used; _used=$(du -sb "$_cur" 2>/dev/null | awk '{print $1}')
    echo -e "  已占用：$(_bk_human "${_used:-0}")"
  fi
  echo ""
  echo -e "  ${DIM}修改后会把已有备份点 mv 到新路径${N}"
  echo ""
  local _new
  read -erp "  新路径（绝对路径，回车取消）：" _new
  if [[ -z "$_new" ]]; then info "已取消"
  elif [[ "$_new" != /* ]]; then warn "必须是绝对路径"
  elif [[ "$_new" == "$_cur" ]]; then info "路径未变"
  else
    if backup_root_migrate "$_new"; then
      log "备份路径已更新为 $_new"
    else
      warn "迁移失败"
    fi
  fi
  echo ""; read -erp "  按回车继续..." _
}

# 默认备份范围（scope 预选）
_settings_change_default_scopes() {
  local -a _avail=()
  mapfile -t _avail < <(backup_available_scopes)
  if [[ ${#_avail[@]} -eq 0 ]]; then
    warn "当前主机未检测到任何可备份的服务"
    read -erp "  按回车继续..." _; return
  fi

  # 当前默认（解析 CSV）
  local _cur_csv; _cur_csv=$(backup_conf_get DEFAULT_SCOPES "$BACKUP_DEFAULT_SCOPES_DEFAULT")
  local _cnt=${#_avail[@]}
  declare -A _SEL
  local i k
  for (( i=0; i<_cnt; i++ )); do
    _SEL[$i]=false
    for k in ${_cur_csv//,/ }; do
      [[ "${_avail[$i]}" == "$k" ]] && _SEL[$i]=true
    done
  done

  local _msg=""
  while true; do
    print_header "默认备份范围"
    echo -e "  ${DIM}此设置同时控制 3 处：立即备份预选 / 升级前自动备份 / 定时备份${N}"
    echo ""
    for (( i=0; i<_cnt; i++ )); do
      local _key=${_avail[$i]}
      local _desc; _desc=$(backup_scope_desc "$_key")
      local _chk; [[ "${_SEL[$i]}" == "true" ]] && _chk="${G}[✓]${N}" || _chk="${DIM}[ ]${N}"
      printf "    %b ${W}[%d]${N}  %-10s ${DIM}%s${N}\n" "$_chk" "$((i+1))" "$_key" "$_desc"
    done
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "    ${DIM}[a] 全选/取消    [Enter] 保存并返回    [0] 不保存返回${N}"
    echo ""
    local _input; read -erp "  选择：" _input
    _msg=""
    multi_select_input "$_input" _SEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      return)  return 0 ;;
      invalid) _msg="${R}无效输入${N}"; continue ;;
      toggled) continue ;;
    esac
    local _csv=""
    for (( i=0; i<_cnt; i++ )); do
      [[ "${_SEL[$i]}" == "true" ]] && _csv+="${_avail[$i]},"
    done
    _csv="${_csv%,}"
    backup_conf_set DEFAULT_SCOPES "$_csv"
    log "默认 scope 已保存：${_csv:-（空）}"
    echo ""; read -erp "  按回车继续..." _
    return 0
  done
}

# 升级前自动备份开关
_settings_toggle_auto_upgrade() {
  print_header "升级前自动备份"
  local _cur; _cur=$(backup_conf_get AUTO_BEFORE_UPGRADE "$BACKUP_AUTO_BEFORE_UPGRADE_DEFAULT")
  echo -e "  当前状态：${C}$_cur${N}"
  echo -e "  ${DIM}开启后，「升级 / 回滚单服务」执行升级前会自动备份 ai-pg / ai-data / ai-config${N}"
  echo ""
  local _yn
  read -erp "  切换为 [y]开启 / [n]关闭 / [回车] 取消：" _yn
  case "${_yn,,}" in
    y) backup_conf_set AUTO_BEFORE_UPGRADE true; log "已开启" ;;
    n) backup_conf_set AUTO_BEFORE_UPGRADE false; log "已关闭" ;;
    *) info "已取消" ;;
  esac
  echo ""; read -erp "  按回车继续..." _
}

# 定时自动备份
_settings_timer() {
  while true; do
    print_header "定时自动备份"
    local _enabled _schedule _status _next _ds
    _enabled=$(backup_conf_get TIMER_ENABLED "$BACKUP_TIMER_ENABLED_DEFAULT")
    _schedule=$(backup_conf_get TIMER_SCHEDULE "$BACKUP_TIMER_SCHEDULE_DEFAULT")
    _ds=$(backup_conf_get DEFAULT_SCOPES "$BACKUP_DEFAULT_SCOPES_DEFAULT")
    _status=$(backup_timer_status)
    _next=$(backup_timer_next_run)

    echo -e "  ${W}启用状态${N}：${C}$_enabled${N} （systemd: ${_status:-inactive}）"
    echo -e "  ${W}频率${N}    ：${C}$_schedule${N}"
    echo -e "  ${W}范围${N}    ：${C}${_ds:-（空）}${N} ${DIM}（来自上一级「默认备份范围」）${N}"
    [[ -n "$_next" ]] && echo -e "  ${W}下次触发${N}：${C}$_next${N}"
    echo ""

    input_choose "定时备份操作" \
      "切换启用 / 禁用" \
      "修改频率（daily / weekly / hourly / 自定义 OnCalendar）"
    [[ $INPUT_RESULT -eq -1 ]] && return 0

    case $INPUT_RESULT in
      0)
        if [[ "$_enabled" == "true" ]]; then
          backup_timer_disable && log "已禁用 timer" || warn "禁用失败"
        else
          backup_timer_enable && log "已启用 timer（下次按计划触发）" || warn "启用失败"
        fi
        read -erp "  按回车继续..." _
        ;;
      1)
        echo ""
        echo "  可选预设：daily / weekly / hourly"
        echo "  也可输入 systemd OnCalendar 表达式，如：*-*-* 02:00:00"
        local _new
        read -erp "  新频率（回车取消）：" _new
        if [[ -n "$_new" ]]; then
          backup_conf_set TIMER_SCHEDULE "$_new"
          log "频率已保存为：$_new"
          if [[ "$_enabled" == "true" ]]; then
            backup_timer_enable && info "timer 已重新生成应用新频率"
          else
            info "需要启用 timer 才会生效"
          fi
        fi
        read -erp "  按回车继续..." _
        ;;
    esac
  done
}

backup_action_settings() {
  while true; do
    print_header "备份设置"
    local _keep _root _ds _au _te _ts
    _keep=$(_backup_get_keep)
    _root=$(backup_root)
    _ds=$(backup_conf_get DEFAULT_SCOPES "$BACKUP_DEFAULT_SCOPES_DEFAULT")
    _au=$(backup_conf_get AUTO_BEFORE_UPGRADE "$BACKUP_AUTO_BEFORE_UPGRADE_DEFAULT")
    _te=$(backup_conf_get TIMER_ENABLED "$BACKUP_TIMER_ENABLED_DEFAULT")
    _ts=$(backup_conf_get TIMER_SCHEDULE "$BACKUP_TIMER_SCHEDULE_DEFAULT")

    echo -e "  ${W}保留份数${N}      ：${C}${_keep}${N}"
    echo -e "  ${W}存储路径${N}      ：${C}${_root}${N}"
    if [[ -d "$_root" ]]; then
      local _used; _used=$(du -sb "$_root" 2>/dev/null | awk '{print $1}')
      echo -e "  ${W}已占用${N}        ：$(_bk_human "${_used:-0}")"
    fi
    local _free; _free=$(df -B1 "${_root%/*}" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -n "$_free" ]] && echo -e "  ${W}可用空间${N}      ：$(_bk_human "$_free")"
    echo -e "  ${W}默认备份范围${N}  ：${C}${_ds:-（未设置）}${N}"
    echo -e "  ${DIM}                  立即备份预选 / 升级前备份 / 定时备份 都用这个${N}"
    echo -e "  ${W}升级前自动备份${N}：${C}${_au}${N}"
    echo -e "  ${W}定时自动备份${N}  ：${C}${_te}${N} （${_ts}）"
    echo ""

    input_choose "备份设置操作" \
      "修改保留份数" \
      "修改存储路径" \
      "修改默认备份范围（影响：立即备份预选 / 升级前备份 / 定时备份）" \
      "升级前自动备份开关" \
      "定时自动备份配置" \
      "应用保留策略（清理超量备份）"
    [[ $INPUT_RESULT -eq -1 ]] && return 0

    case $INPUT_RESULT in
      0) _settings_change_keep ;;
      1) _settings_change_root ;;
      2) _settings_change_default_scopes ;;
      3) _settings_toggle_auto_upgrade ;;
      4) _settings_timer ;;
      5)
        print_header "应用保留策略"
        local _removed; _removed=$(backup_apply_retention "$_keep")
        log "已清理 ${_removed} 个超量备份点"
        echo ""; read -erp "  按回车继续..." _
        ;;
    esac
  done
}

# ── 顶层菜单 ─────────────────────────────────────────────────────
backup_menu() {
  while true; do
    print_header "备份 / 恢复（数据 / 配置文件）"
    echo -e "  ${DIM}本菜单仅备份数据与配置文件。程序版本（镜像 / 二进制）的回滚见上级菜单「升级 / 回滚单服务」${N}"
    echo ""

    local _count=0
    [[ -d "$BACKUP_ROOT" ]] && _count=$(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l)
    echo -e "  ${W}备份目录${N}：${C}${BACKUP_ROOT}${N}"
    echo -e "  ${W}已有备份${N}：${C}${_count}${N} 个备份点"
    echo ""

    input_choose "备份恢复操作" \
      "立即备份" \
      "恢复" \
      "备份列表" \
      "删除备份" \
      "设置（保留份数 / 应用保留策略）"
    [[ $INPUT_RESULT -eq -1 ]] && break

    case $INPUT_RESULT in
      0) backup_action_create ;;
      1) backup_action_restore ;;
      2) backup_action_list ;;
      3) backup_action_delete ;;
      4) backup_action_settings ;;
    esac
  done
}
