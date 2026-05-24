#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 复杂工具管理
#
# 所有复杂脚本已存放在 lib/scripts/ 本地执行
# 本模块提供：查找、更新、状态查看功能
# ═══════════════════════════════════════════════════════════════════

SCRIPTS_DIR="${BASH_SOURCE[0]%/*}/../lib/scripts"

# ── 高风险脚本执行警告 ───────────────────────────────────────────
# 安全等级：●danger / ●warn 的脚本，执行前必须经用户确认
_warn_complex_tool_risk() {
  local key="$1"
  local accepted=1  # 默认拒绝

  case "$key" in
    ecs-fusion)
      echo ""
      echo -e "  ${R}╔══════════════════════════════════════════════════════╗${N}"
      echo -e "  ${R}║  ● 风险等级：危险 (danger)                          ║${N}"
      echo -e "  ${R}╚══════════════════════════════════════════════════════╝${N}"
      echo ""
      echo -e "  ${W}spiritysdx 融合怪测评 (ecs.sh)${N}"
      echo ""
      echo -e "  ${Y}检测到以下安全风险：${N}"
      echo ""
      echo -e "  ${R}1.${N} 使用 curl -k（禁用 SSL 证书验证），存在中间人攻击风险"
      echo -e "  ${R}2.${N} 包含自更新机制，可能在执行时修改自身代码"
      echo -e "  ${R}3.${N} 包含遥测/数据上报功能，会向第三方服务器发送信息"
      echo ""
      echo -e "  ${DIM}脚本路径：${_COMPLEX_SCRIPT}${N}"
      echo ""
      askyn accepted "我已了解风险，是否继续执行？" "n"
      ;;
    nodequality)
      echo ""
      echo -e "  ${Y}╔══════════════════════════════════════════════════════╗${N}"
      echo -e "  ${Y}║  ● 风险等级：警告 (warn)                            ║${N}"
      echo -e "  ${Y}╚══════════════════════════════════════════════════════╝${N}"
      echo ""
      echo -e "  ${W}nodequality 融合怪测评 (nodequality.sh)${N}"
      echo ""
      echo -e "  ${Y}检测到以下安全风险：${N}"
      echo ""
      echo -e "  ${Y}1.${N} 静默上传数据到第三方服务器（run.NodeQuality.com）"
      echo -e "  ${Y}2.${N} 内部包含 7 次 curl|bash 调用，执行链难以审计"
      echo ""
      echo -e "  ${DIM}脚本路径：${_COMPLEX_SCRIPT}${N}"
      echo ""
      askyn accepted "我已了解风险，是否继续执行？" "n"
      ;;
    *)
      # 安全/注意级别的脚本，直接放行
      return 0
      ;;
  esac

  if ! $accepted; then
    info "已取消执行"
    return 1
  fi
  return 0
}

# ── 工具注册表 ──────────────────────────────────────────────────
declare -gA _COMPLEX_TOOLS=(
  [yabs]="yabs.sh|yabs 综合性能测试（fio+iperf3+geekbench）"
  [gb5]="gb5.sh|Geekbench 5 CPU 性能测试（本地重写）"
  [nodequality]="nodequality.sh|nodequality 融合怪测评"
  [ecs-fusion]="ecs.sh|spiritysdx 融合怪测评"
)

# 从 urls.sh 获取更新源
declare -gA _COMPLEX_UPDATE_URLS=(
  [yabs]="${URL_YABS}"
  [gb5]=""  # 本地重写，无远程更新源
  [nodequality]="${URL_NODEQUALITY}"
  [ecs-fusion]="${URL_ECS_FUSION}"
)

# 获取本地脚本路径
# 用法: _ensure_complex <key> → 设置 _COMPLEX_SCRIPT
_ensure_complex() {
  local key="$1"
  local entry="${_COMPLEX_TOOLS[$key]:-}"
  [[ -z "$entry" ]] && { warn "未知工具: $key"; return 1; }

  local filename="${entry%%|*}"
  local dest="${SCRIPTS_DIR}/${filename}"

  if [[ ! -f "$dest" ]]; then
    warn "脚本不存在: ${filename}"
    info "请在主菜单 → 网络测试 → 工具管理 中检查"
    return 1
  fi

  _COMPLEX_SCRIPT="$dest"
}

# 更新单个工具（从远程重新下载）
_update_complex_tool() {
  local key="$1"
  local entry="${_COMPLEX_TOOLS[$key]:-}"
  [[ -z "$entry" ]] && return 1

  local filename="${entry%%|*}"
  local desc="${entry##*|}"
  local url="${_COMPLEX_UPDATE_URLS[$key]:-}"
  local dest="${SCRIPTS_DIR}/${filename}"

  if [[ -z "$url" ]]; then
    info "${desc} — 本地脚本，无远程更新源"
    return 0
  fi

  echo -ne "  ${DIM}更新 ${desc} ...${N} "
  if curl -sL --max-time 60 "$url" -o "$dest" 2>/dev/null; then
    chmod +x "$dest"
    echo -e "${G}完成${N}"
  else
    echo -e "${R}失败${N}"
  fi
}

# 列出所有工具状态
list_complex_tools() {
  section "本地测试工具状态"
  for key in "${!_COMPLEX_TOOLS[@]}"; do
    local entry="${_COMPLEX_TOOLS[$key]}"
    local filename="${entry%%|*}"
    local desc="${entry##*|}"
    local dest="${SCRIPTS_DIR}/${filename}"
    local status
    if [[ -f "$dest" ]]; then
      local size=$(wc -c < "$dest" 2>/dev/null)
      local age=$(( ($(date +%s) - $(stat -c %Y "$dest" 2>/dev/null || echo 0)) / 86400 ))
      status="${G}就绪${N} (${size}字节, ${age}天前)"
    else
      status="${R}缺失${N}"
    fi
    printf "  %-35s %b\n" "$desc" "$status"
  done
}

# 批量更新所有工具
update_all_complex() {
  section "更新本地测试工具"
  for key in "${!_COMPLEX_TOOLS[@]}"; do
    _update_complex_tool "$key"
  done
}
