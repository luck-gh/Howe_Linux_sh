#!/usr/bin/env bash
# 日志删除：sing-box 日志 / Docker 容器日志 / systemd journal / 未使用镜像
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。
# 依赖 view.sh 的 _docker_history_references_image（保护升级回滚历史引用的镜像）。

SINGBOX_LOG="/var/log/sing-box.log"
JOURNAL_KEEP="100M"

_logclean_human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# sing-box 主日志 + logrotate 轮转出的旧文件
_logclean_singbox_bytes() {
  local _sum=0 _f _s
  for _f in "$SINGBOX_LOG" "$SINGBOX_LOG".*; do
    [[ -f "$_f" ]] || continue
    _s=$(stat -c %s "$_f" 2>/dev/null || echo 0)
    _sum=$((_sum + _s))
  done
  echo "$_sum"
}

# 所有容器（含已停止）的 json-file 日志路径
_logclean_container_logs() {
  command -v docker &>/dev/null || return 0
  docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.LogPath}}' 2>/dev/null
}

_logclean_docker_bytes() {
  local _sum=0 _name _path _s
  while read -r _name _path; do
    [[ -f "$_path" ]] || continue
    _s=$(stat -c %s "$_path" 2>/dev/null || echo 0)
    _sum=$((_sum + _s))
  done < <(_logclean_container_logs)
  echo "$_sum"
}

_logclean_journal_bytes() {
  du -sb /var/log/journal /run/log/journal 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

# 可删镜像：没有任何容器（含已停止）在用，且不在升级回滚历史里
_logclean_image_candidates() {
  command -v docker &>/dev/null || return 0
  local -A _used=()
  local _id
  while read -r _id; do
    [[ -n "$_id" ]] && _used[$_id]=1
  done < <(docker ps -aq 2>/dev/null | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null)
  while read -r _id; do
    [[ -z "$_id" || -n "${_used[$_id]:-}" ]] && continue
    _docker_history_references_image "$_id" && continue
    echo "$_id"
  done < <(docker images -a --no-trunc --format '{{.ID}}' 2>/dev/null | sort -u)
}

_logclean_images_bytes() {
  local _sum=0 _id _s
  while read -r _id; do
    [[ -z "$_id" ]] && continue
    _s=$(docker image inspect --format '{{.Size}}' "$_id" 2>/dev/null || echo 0)
    _sum=$((_sum + _s))
  done < <(_logclean_image_candidates)
  echo "$_sum"
}

# ── 执行 ─────────────────────────────────────────────────────────
# truncate 而不是 rm：进程持有的文件句柄不变，删除后空间立即释放，无需重启服务
_logclean_do_singbox() {
  [[ -f "$SINGBOX_LOG" ]] && truncate -s 0 "$SINGBOX_LOG"
  rm -f "$SINGBOX_LOG".* 2>/dev/null
  log "sing-box 日志已清空"
}

_logclean_do_docker() {
  local _name _path _n=0
  while read -r _name _path; do
    [[ -f "$_path" ]] || continue
    truncate -s 0 "$_path" && ((_n++))
  done < <(_logclean_container_logs)
  log "已清空 ${_n} 个容器的日志"
}

_logclean_do_journal() {
  journalctl --vacuum-size="$JOURNAL_KEEP" 2>&1 | tail -1
  log "journal 已压缩到 ${JOURNAL_KEEP} 以内"
}

_logclean_do_images() {
  local _id _n=0
  while read -r _id; do
    [[ -z "$_id" ]] && continue
    # 不加 -f：仍被引用的镜像（如 tag 共享）删除失败就跳过
    docker image rm "$_id" >/dev/null 2>&1 && ((_n++))
  done < <(_logclean_image_candidates)
  docker image prune -f >/dev/null 2>&1
  log "已删除 ${_n} 个未使用镜像（升级回滚历史引用的镜像已保留）"
}

# ── 菜单 ─────────────────────────────────────────────────────────
log_clean_menu() {
  local -a _ITEMS=(
    "singbox|sing-box 日志|${SINGBOX_LOG}（含轮转文件），清空不影响代理"
    "docker|Docker 容器日志|所有容器的 stdout 日志（docker logs 历史会消失）"
    "journal|systemd journal|压缩到 ${JOURNAL_KEEP}，保留最近的日志"
    "images|未使用的 Docker 镜像|不删正在用的镜像，也不删升级回滚需要的旧镜像"
  )
  local _cnt=${#_ITEMS[@]}
  declare -A _SEL=()
  local i _msg=""
  for (( i=0; i<_cnt; i++ )); do _SEL[$i]=false; done

  while true; do
    info "统计占用中..."
    local -a _sizes=(
      "$(_logclean_singbox_bytes)"
      "$(_logclean_docker_bytes)"
      "$(_logclean_journal_bytes)"
      "$(_logclean_images_bytes)"
    )
    print_header "日志删除"
    echo -e "  磁盘：$(df -h / | awk 'NR==2{print $3" / "$2"（"$5"），剩余 "$4}')"
    echo ""

    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _ _name _desc <<< "${_ITEMS[$i]}"
      local _chk; [[ "${_SEL[$i]}" == "true" ]] && _chk="${R}[✓]${N}" || _chk="${DIM}[ ]${N}"
      local _sz; _sz=$(_logclean_human "${_sizes[$i]}")
      [[ $i -eq 3 ]] && _sz="约 ${_sz}"
      # printf 宽度按字符算，中文占 2 列，按显示宽度手动补空格
      local _w; _w=$(printf '%s' "$_name" | wc -L)
      printf "    %b ${W}%d.${N} %s%*s ${Y}%s${N}\n" "$_chk" "$((i+1))" "$_name" $(( 22 - _w )) "" "$_sz"
      printf "       ${DIM}%s${N}\n" "$_desc"
    done
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "  ${DIM}输入编号切换 | a=全选 | 回车=确认删除 | 0=返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input
    _msg=""
    multi_select_input "$_input" _SEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      return) return 0 ;;
      invalid) _msg="${R}无效输入${N}"; continue ;;
      toggled) continue ;;
    esac

    local _any=false
    for (( i=0; i<_cnt; i++ )); do [[ "${_SEL[$i]}" == "true" ]] && _any=true; done
    $_any || { _msg="${R}未选择任何项目${N}"; continue; }

    local _go
    askyn _go "确认删除所选项目？删除后不可恢复" "n"
    $_go || { _msg="${DIM}已取消${N}"; continue; }

    local _before; _before=$(df -B1 --output=avail / | tail -1)
    echo ""
    for (( i=0; i<_cnt; i++ )); do
      [[ "${_SEL[$i]}" != "true" ]] && continue
      IFS='|' read -r _key _ _ <<< "${_ITEMS[$i]}"
      case "$_key" in
        singbox) _logclean_do_singbox ;;
        docker)  _logclean_do_docker ;;
        journal) _logclean_do_journal ;;
        images)  _logclean_do_images ;;
      esac
      _SEL[$i]=false
    done
    local _after; _after=$(df -B1 --output=avail / | tail -1)
    echo ""
    log "共释放 $(_logclean_human $(( _after > _before ? _after - _before : 0 )))，当前剩余 $(df -h --output=avail / | tail -1 | tr -d ' ')"
    echo ""
    read -erp "  按回车继续..." _
  done
}
