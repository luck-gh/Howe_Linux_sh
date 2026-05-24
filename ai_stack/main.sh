#!/usr/bin/env bash
# 顶级菜单：service_stack_menu / ai_agent_menu / main
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# AI 服务栈子菜单（原主菜单内容）
# ═══════════════════════════════════════════════════════════════════
service_stack_menu() {
  while true; do
    print_header "AI 服务栈管理"

    if [[ -f "$BASE_DIR/.env" ]]; then
      source "$BASE_DIR/.env" 2>/dev/null
      detect_installed_services
      echo -e "  ${G}已安装${N}"
      [[ -n "${DOMAIN:-}" ]] && echo -e "  域名：${C}${DOMAIN}${N}"
      local _running=0 _total=0
      for _cn in new-api openwebui litellm sub2api; do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_cn}$" && ((_running++)); ((_total++))
      done
      [[ "${INST_SINGBOX:-false}" == "true" ]] && { systemctl is-active sing-box &>/dev/null && ((_running++)); ((_total++)); }
      echo -e "  运行中：${_running}/${_total} 个服务"
    else
      echo -e "  ${DIM}未安装${N}"
    fi
    echo ""

    input_choose "服务栈操作" "安装 / 更新" "升级 / 回滚单服务" "卸载" "配置查询与修改" "服务管理"
    [[ $INPUT_RESULT -eq -1 ]] && break

    case $INPUT_RESULT in
      0) install_or_update ;;
      1) upgrade_rollback_menu ;;
      2) uninstall_stack ;;
      3) show_config ;;
      4) manage_services ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════
# AI 智能体 CLI 工具
# ═══════════════════════════════════════════════════════════════════

# ── Node.js 环境确保 ─────────────────────────────────────────────
ensure_nodejs() {
  if ! command -v node &>/dev/null; then
    warn "未检测到 Node.js，部分工具需要 npm 安装"
    echo ""
    input_choose "安装 Node.js" "NodeSource LTS（推荐）" "跳过（仅使用不依赖 npm 的安装方式）"
    case $INPUT_RESULT in
      0)
        log "安装 Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - || err "NodeSource 脚本失败"
        apt-get install -y -qq nodejs || err "Node.js 安装失败"
        ;;
      *)
        warn "跳过 Node.js 安装，npm 方式将不可用"
        return 1
        ;;
    esac
  fi

  log "Node.js $(node --version) 已就绪"

  # 确保 npm 全局前缀为 /usr/local，全局包装到 /usr/local/bin
  if command -v npm &>/dev/null; then
    local _prefix; _prefix=$(npm config get prefix 2>/dev/null)
    if [[ "$_prefix" != "/usr/local" ]] && [[ "$_prefix" != "/usr" ]]; then
      info "npm 当前前缀：${_prefix}，调整为 /usr/local"
      npm config set prefix /usr/local 2>/dev/null
    fi
  fi
}

# ── AI 智能体安装 ─────────────────────────────────────────────────
install_single_agent() {
  local _name="$1"

  case "$_name" in
    "Claude Code")
      echo ""
      input_choose "Claude Code 安装方式" \
        "npm 全局安装（推荐，装到 /usr/local/bin）" \
        "官方安装器（装到 ~/.local/bin，自动更新）" \
        "跳过"
      case $INPUT_RESULT in
        0)
          ensure_nodejs || return 1
          npm install -g @anthropic-ai/claude-code || { warn "npm 安装失败"; return 1; }
          ;;
        1)
          log "使用官方安装器..."
          curl -fsSL https://claude.ai/install.sh | bash || { warn "官方安装器失败"; return 1; }
          ;;
        *) return 0 ;;
      esac
      _verify_agent_install "claude" "Claude Code"
      ;;

    "OpenAI Codex")
      echo ""
      input_choose "OpenAI Codex 安装方式" \
        "npm 全局安装（推荐，装到 /usr/local/bin）" \
        "跳过"
      case $INPUT_RESULT in
        0)
          ensure_nodejs || return 1
          npm install -g @openai/codex || { warn "npm 安装失败"; return 1; }
          ;;
        *) return 0 ;;
      esac
      _verify_agent_install "codex" "OpenAI Codex"
      ;;

    "OpenCode")
      echo ""
      input_choose "OpenCode 安装方式" \
        "npm 全局安装（推荐，装到 /usr/local/bin）" \
        "官方安装脚本（装到 ~/.opencode）" \
        "跳过"
      case $INPUT_RESULT in
        0)
          ensure_nodejs || return 1
          npm install -g opencode-ai || { warn "npm 安装失败"; return 1; }
          ;;
        1)
          curl -fsSL https://opencode.ai/install.sh | bash || { warn "安装脚本失败"; return 1; }
          ;;
        *) return 0 ;;
      esac
      _verify_agent_install "opencode" "OpenCode"
      ;;

    "OpenClaw")
      echo ""
      input_choose "OpenClaw 安装方式" \
        "npm 全局安装（推荐，装到 /usr/local/bin）" \
        "Docker 部署" \
        "跳过"
      case $INPUT_RESULT in
        0)
          ensure_nodejs || return 1
          npm install -g openclaw || { warn "npm 安装失败"; return 1; }
          info "安装后运行 openclaw onboard 完成初始化"
          ;;
        1)
          command -v docker &>/dev/null || { warn "Docker 未安装"; return 1; }
          docker pull openclaw/openclaw:latest || { warn "镜像拉取失败"; return 1; }
          log "OpenClaw Docker 镜像已拉取，运行：docker run -it openclaw/openclaw"
          return 0
          ;;
        *) return 0 ;;
      esac
      _verify_agent_install "openclaw" "OpenClaw"
      ;;
  esac
}

# 安装后验证：刷新 PATH，搜索多个常见路径
_verify_agent_install() {
  local _cmd="$1" _display="$2"

  # 刷新命令缓存和 PATH
  hash -r 2>/dev/null
  local _search_paths=(
    "$HOME/.local/bin"
    "/root/.local/bin"
    "/usr/local/bin"
    "/usr/bin"
  )
  # npm 全局路径
  command -v npm &>/dev/null && _search_paths+=("$(npm prefix -g 2>/dev/null)/bin")

  for _p in "${_search_paths[@]}"; do
    [[ -d "$_p" ]] && [[ ":$PATH:" != *":${_p}:"* ]] && export PATH="${_p}:$PATH"
  done
  hash -r 2>/dev/null

  # 验证：找到二进制路径
  local _bin_path=""
  if command -v "$_cmd" &>/dev/null; then
    _bin_path=$(command -v "$_cmd")
  else
    for _p in "${_search_paths[@]}"; do
      if [[ -x "${_p}/${_cmd}" ]]; then
        _bin_path="${_p}/${_cmd}"
        export PATH="${_p}:$PATH"
        break
      fi
    done
  fi

  if [[ -z "$_bin_path" ]]; then
    warn "${_display} 安装后未检测到 ${_cmd} 命令"
    info "如安装成功，请手动执行：source ~/.bashrc 或重新登录终端"
    return 1
  fi

  local _ver; _ver=$("$_bin_path" --version 2>/dev/null | head -1 || echo "")
  log "${_display} 安装成功${_ver:+：${_ver}}"
  info "原始路径：${_bin_path}"

  # 创建系统级软链接，让所有用户/所有终端都能直接使用
  local _sys_link="/usr/local/bin/${_cmd}"
  if [[ "$_bin_path" != "$_sys_link" ]]; then
    if [[ -L "$_sys_link" ]] || [[ ! -e "$_sys_link" ]]; then
      ln -sf "$_bin_path" "$_sys_link" 2>/dev/null && \
        log "已创建系统软链接：${_sys_link} → ${_bin_path}" || \
        warn "无法创建 /usr/local/bin 软链接（权限不足？）"
    else
      warn "${_sys_link} 已存在且非软链接，跳过"
    fi
  fi

  # 同时把原始路径写入 ~/.bashrc，方便用户登录时也能找到
  local _dir; _dir=$(dirname "$_bin_path")
  if [[ "$_dir" == *".local/bin"* ]] && ! grep -q "$_dir" ~/.bashrc 2>/dev/null; then
    echo "export PATH=\"${_dir}:\$PATH\"" >> ~/.bashrc
    info "已将 ${_dir} 写入 ~/.bashrc"
  fi

  echo ""
  info "立即可用，无需重开终端：${G}${_cmd} --version${N}"
}

install_ai_agents() {
  # 工具定义：显示名|描述
  local -a AGENTS=(
    "Claude Code|Anthropic 智能体 CLI（需 Pro 订阅或 API Key）"
    "OpenAI Codex|OpenAI 终端编程智能体（需 API Key）"
    "OpenCode|开源 AI 编程助手，支持 75+ LLM 提供商"
    "OpenClaw|本地 AI 自动化平台（支持 Claude/GPT-4/本地模型）"
  )
  local _cnt=${#AGENTS[@]}

  detect_ai_agents

  declare -A SEL=(
    [0]=false [1]=false [2]=false [3]=false
  )
  local _msg=""

  while true; do
    print_header "AI 智能体 CLI 工具 — 安装"

    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _name _desc <<< "${AGENTS[$i]}"
      local _chk; [[ "${SEL[$i]}" == "true" ]] && _chk="${G}[✓]${N}" || _chk="${DIM}[ ]${N}"

      local _installed=""
      case $i in
        0) $AGENT_CLAUDE_CODE && _installed="${G}[已安装]${N}" || _installed="${DIM}[未安装]${N}" ;;
        1) $AGENT_CODEX && _installed="${G}[已安装]${N}" || _installed="${DIM}[未安装]${N}" ;;
        2) $AGENT_OPENCODE && _installed="${G}[已安装]${N}" || _installed="${DIM}[未安装]${N}" ;;
        3) $AGENT_OPENCLAW && _installed="${G}[已安装]${N}" || _installed="${DIM}[未安装]${N}" ;;
      esac

      printf "    %b ${W}%d.${N} %-15s %b\n" "$_chk" "$((i+1))" "$_name" "$_installed"
      printf "       ${DIM}%s${N}\n" "$_desc"
      echo ""
    done

    local _prev=""
    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _name _ <<< "${AGENTS[$i]}"
      [[ "${SEL[$i]}" == "true" ]] && _prev+="${G}${_name}${N}  "
    done
    echo -e "  ${W}当前选择：${N}${_prev:-${DIM}无${N}}"

    [[ -n "$_msg" ]] && echo -e "  ${_msg}"
    echo ""
    echo -e "  ${DIM}输入编号切换 | a=全选 | 回车=确认安装 | 0=返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input
    _msg=""

    multi_select_input "$_input" SEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      confirm) break ;;
      return) return 0 ;;
      invalid) _msg="${R}无效输入${N}" ;;
    esac
  done

  # 执行安装
  local _any=false
  for (( i=0; i<_cnt; i++ )); do
    [[ "${SEL[$i]}" == "true" ]] && _any=true
  done
  $_any || { info "未选择任何工具"; return 0; }

  echo ""
  for (( i=0; i<_cnt; i++ )); do
    [[ "${SEL[$i]}" != "true" ]] && continue
    IFS='|' read -r _name _ <<< "${AGENTS[$i]}"
    echo -e "${W}${C}── 安装 ${_name} ──────────────────────────────────${N}"
    install_single_agent "$_name"
    echo ""
  done

  echo ""
  log "安装流程完成"
  read -erp "  按回车继续..." _
}

# ── AI 智能体卸载 ─────────────────────────────────────────────────
uninstall_ai_agents() {
  detect_ai_agents

  local -a _U=()
  $AGENT_CLAUDE_CODE && _U+=("claude|Claude Code|npm:@anthropic-ai/claude-code")
  $AGENT_CODEX       && _U+=("codex|OpenAI Codex|npm:@openai/codex")
  $AGENT_OPENCODE    && _U+=("opencode|OpenCode|npm:opencode-ai")
  $AGENT_OPENCLAW    && _U+=("openclaw|OpenClaw|npm:openclaw")

  if [[ ${#_U[@]} -eq 0 ]]; then
    warn "未检测到已安装的 AI 智能体工具"
    echo ""
    read -erp "  按回车返回..." _
    return 0
  fi

  local _cnt=${#_U[@]}
  declare -A _DEL
  for (( i=0; i<_cnt; i++ )); do
    _DEL[$i]=false
  done

  local _msg=""

  while true; do
    print_header "AI 智能体 CLI 工具 — 卸载"

    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _cmd _name _ <<< "${_U[$i]}"
      local _chk; [[ "${_DEL[$i]}" == "true" ]] && _chk="${R}[✓]${N}" || _chk="${DIM}[ ]${N}"
      printf "    %b ${W}%d.${N}  %s\n" "$_chk" "$((i+1))" "$_name"
    done
    echo ""

    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "  ${DIM}输入编号切换 | a=全选 | 回车=确认卸载 | 0=返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input
    _msg=""

    multi_select_input "$_input" _DEL "$_cnt"
    case "$MULTI_SELECT_ACTION" in
      return) return 0 ;;
      invalid) _msg="${R}无效输入${N}"; continue ;;
      toggled) continue ;;
    esac

    # confirm: 至少选中一项
    local _any=false
    for (( i=0; i<_cnt; i++ )); do [[ "${_DEL[$i]}" == "true" ]] && _any=true; done
    $_any || { _msg="${R}未选择任何工具${N}"; continue; }
    break
  done

  echo ""
  for (( i=0; i<_cnt; i++ )); do
    [[ "${_DEL[$i]}" != "true" ]] && continue
    IFS='|' read -r _cmd _name _pkg <<< "${_U[$i]}"

    # 尝试 npm 卸载
    local _npm_pkg="${_pkg#npm:}"
    if command -v npm &>/dev/null && npm list -g "$_npm_pkg" &>/dev/null 2>&1; then
      npm uninstall -g "$_npm_pkg" 2>/dev/null && log "${_name} 已通过 npm 卸载" && continue
    fi

    # 尝试删除二进制
    local _bin_path
    _bin_path=$(command -v "$_cmd" 2>/dev/null)
    if [[ -n "$_bin_path" ]]; then
      rm -f "$_bin_path" && log "${_name} 已删除：${_bin_path}" || warn "${_name} 删除失败：${_bin_path}"
    else
      warn "${_name} 未找到可执行文件"
    fi
    # 同时清理 /usr/local/bin 软链
    [[ -L "/usr/local/bin/${_cmd}" ]] && rm -f "/usr/local/bin/${_cmd}"
  done

  # 清理 ~/.bashrc 中已不再被任何 agent 用到的 .local/bin PATH 行
  if [[ -f ~/.bashrc ]]; then
    local -a _agent_cmds=(claude codex opencode openclaw)
    local -a _path_dirs=()
    while IFS= read -r _line; do
      [[ "$_line" =~ export[[:space:]]PATH=\"([^:\"]*\.local/bin)[:\"] ]] && _path_dirs+=("${BASH_REMATCH[1]}")
    done < ~/.bashrc
    local _d _bin _has
    for _d in "${_path_dirs[@]}"; do
      _has=false
      for _bin in "${_agent_cmds[@]}"; do
        [[ -x "${_d}/${_bin}" ]] && _has=true && break
      done
      if ! $_has; then
        # 该目录下已无 agent 二进制 → 安全删除该 PATH 行
        sed -i "\|export PATH=\"${_d}:|d" ~/.bashrc 2>/dev/null && \
          info "已从 ~/.bashrc 移除 ${_d} 的 PATH 行"
      fi
    done
  fi

  echo ""
  log "卸载完成"
  read -erp "  按回车继续..." _
}

# ── AI 智能体状态查看 ─────────────────────────────────────────────
show_ai_agents_status() {
  print_header "AI 智能体 CLI 工具 — 状态"

  detect_ai_agents

  local -a _TOOLS=("claude:Claude Code" "codex:OpenAI Codex" "opencode:OpenCode" "openclaw:OpenClaw")

  for _t in "${_TOOLS[@]}"; do
    local _cmd="${_t%%:*}" _name="${_t##*:}"
    local _status _ver _path

    if command -v "$_cmd" &>/dev/null; then
      _path=$(command -v "$_cmd")
      _ver=$("$_cmd" --version 2>/dev/null | head -1 || echo "未知")
      _status="${G}已安装${N}"
      printf "    %-15s %b\n" "$_name" "$_status"
      printf "      ${DIM}版本：%s${N}\n" "$_ver"
      printf "      ${DIM}路径：%s${N}\n" "$_path"
    else
      _status="${DIM}未安装${N}"
      printf "    %-15s %b\n" "$_name" "$_status"
    fi
    echo ""
  done

  echo -e "  ${DIM}提示：安装后需配置对应的 API Key 或登录账号才能使用${N}"
  echo ""
  read -erp "  按回车返回..." _
}

# ── AI 智能体子菜单 ───────────────────────────────────────────────
ai_agent_menu() {
  while true; do
    print_header "AI 智能体 CLI 工具管理"

    detect_ai_agents
    local _installed=0
    $AGENT_CLAUDE_CODE && ((_installed++))
    $AGENT_CODEX && ((_installed++))
    $AGENT_OPENCODE && ((_installed++))
    $AGENT_OPENCLAW && ((_installed++))

    if [[ $_installed -gt 0 ]]; then
      echo -e "  已安装 ${G}${_installed}${N} 个工具"
      $AGENT_CLAUDE_CODE && echo -e "    ${G}✓${N} Claude Code"
      $AGENT_CODEX       && echo -e "    ${G}✓${N} OpenAI Codex"
      $AGENT_OPENCODE    && echo -e "    ${G}✓${N} OpenCode"
      $AGENT_OPENCLAW    && echo -e "    ${G}✓${N} OpenClaw"
    else
      echo -e "  ${DIM}未安装任何 AI 智能体工具${N}"
    fi
    echo ""

    input_choose "智能体工具操作" "安装 / 更新" "卸载" "状态查看"
    [[ $INPUT_RESULT -eq -1 ]] && break

    case $INPUT_RESULT in
      0) install_ai_agents ;;
      1) uninstall_ai_agents ;;
      2) show_ai_agents_status ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════
# 主入口（第一页面）
# ═══════════════════════════════════════════════════════════════════
main() {
  [[ $EUID -ne 0 ]] && err "请用 root 运行：sudo bash $0"
  [[ -f /etc/os-release ]] || err "无法识别操作系统"

  while true; do
    print_header "AI 服务栈 一键安装脚本 v3"

    # 服务栈摘要
    if [[ -f "$BASE_DIR/.env" ]]; then
      source "$BASE_DIR/.env" 2>/dev/null
      detect_installed_services
      echo -e "  ${W}服务栈${N}  ${G}已安装${N}"
      [[ -n "${DOMAIN:-}" ]] && echo -e "  域名：${C}${DOMAIN}${N}"
      local _running=0 _total=0
      for _cn in new-api openwebui litellm sub2api; do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_cn}$" && ((_running++)); ((_total++))
      done
      [[ "${INST_SINGBOX:-false}" == "true" ]] && { systemctl is-active sing-box &>/dev/null && ((_running++)); ((_total++)); }
      echo -e "  运行中：${_running}/${_total} 个服务"
    else
      echo -e "  ${W}服务栈${N}  ${DIM}未安装${N}"
    fi

    # 智能体摘要
    detect_ai_agents
    local _agent_cnt=0
    $AGENT_CLAUDE_CODE && ((_agent_cnt++))
    $AGENT_CODEX && ((_agent_cnt++))
    $AGENT_OPENCODE && ((_agent_cnt++))
    $AGENT_OPENCLAW && ((_agent_cnt++))
    if [[ $_agent_cnt -gt 0 ]]; then
      echo -e "  ${W}智能体${N}  已安装 ${G}${_agent_cnt}${N} 个 CLI 工具"
    else
      echo -e "  ${W}智能体${N}  ${DIM}未安装${N}"
    fi
    echo ""

    input_choose "选择管理模块" \
      "AI 服务栈管理 — 部署/管理 New-API、Sub2API、sing-box 等服务（容器+系统服务）" \
      "AI 智能体 CLI 工具 — 在终端使用 Claude Code、Codex、OpenCode 等命令行工具"
    [[ $INPUT_RESULT -eq -1 ]] && { clear; break; }

    case $INPUT_RESULT in
      0) service_stack_menu ;;
      1) ai_agent_menu ;;
    esac
  done
}
