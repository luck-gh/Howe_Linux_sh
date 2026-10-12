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
      for _entry in "${SVC_REGISTRY_STACK[@]}"; do
        IFS='|' read -r _key _name _type _target <<< "$_entry"
        local _var="SVC_${_key}_INSTALLED"
        [[ "${!_var}" != "true" ]] && continue
        ((_total++))
        svc_running "$_type" "$_target" && ((_running++))
      done
      echo -e "  运行中：${_running}/${_total} 个服务"
    else
      echo -e "  ${DIM}未安装${N}"
    fi
    echo ""

    input_choose "服务栈操作" \
      "安装 / 重新生成配置" \
      "升级 / 回滚单服务（程序版本：镜像 / 二进制）" \
      "备份 / 恢复（数据 / 配置文件）" \
      "日志删除（释放磁盘空间）" \
      "配置查询与修改" \
      "服务管理" \
      "卸载"
    [[ $INPUT_RESULT -eq -1 ]] && break

    case $INPUT_RESULT in
      0) install_or_update ;;
      1) upgrade_rollback_menu ;;
      2) backup_menu ;;
      3) log_clean_menu ;;
      4) show_config ;;
      5) manage_services ;;
      6) uninstall_stack ;;
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
          docker pull ghcr.io/openclaw/openclaw:latest || { warn "镜像拉取失败"; return 1; }
          log "OpenClaw Docker 镜像已拉取，运行：docker run -it ghcr.io/openclaw/openclaw:latest"
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
    local _inst_var
    case $i in
      0) _inst_var=$AGENT_CLAUDE_CODE ;; 1) _inst_var=$AGENT_CODEX ;;
      2) _inst_var=$AGENT_OPENCODE ;;    3) _inst_var=$AGENT_OPENCLAW ;;
    esac
    if $_inst_var; then
      info "${_name} 已安装，跳过。升级或切换版本请用「更新 / 指定版本」"
      echo ""
      continue
    fi
    install_single_agent "$_name"
    echo ""
  done

  echo ""
  log "安装流程完成"
  read -erp "  按回车继续..." _
}

# ── AI 智能体更新 / 指定版本 ─────────────────────────────────────
# 命令|显示名|npm 包名
AGENT_PKGS=(
  "claude|Claude Code|@anthropic-ai/claude-code"
  "codex|OpenAI Codex|@openai/codex"
  "opencode|OpenCode|opencode-ai"
  "openclaw|OpenClaw|openclaw"
)

_agent_cur_ver() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -1
}

# 安装方式：claude 区分官方安装器（native）和 npm；其它工具各自的升级命令能自识别
_agent_install_method() {
  local _cmd="$1" _pkg="$2" _real
  _real=$(readlink -f "$(command -v "$_cmd")" 2>/dev/null)
  case "$_real" in
    */.local/share/claude/versions/*) echo "native"; return ;;
    */.opencode/*)                    echo "script"; return ;;
  esac
  command -v npm &>/dev/null && npm ls -g "$_pkg" --depth=0 &>/dev/null && { echo "npm"; return; }
  echo "unknown"
}

# 最近 N 个正式版（排除 alpha/beta/平台包等预发布），新的在前
_agent_recent_versions() {
  local _pkg="$1" _n="${2:-10}"
  command -v npm &>/dev/null || return 0
  timeout 30 npm view "$_pkg" versions --json 2>/dev/null \
    | tr -d '[]", ' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n "$_n" | sort -rV
}

_agent_dist_tag() {
  command -v npm &>/dev/null || return 0
  timeout 30 npm view "$1" "dist-tags.$2" 2>/dev/null
}

# 执行更新：_target 为 latest / stable / 具体版本号
_agent_run_update() {
  local _cmd="$1" _pkg="$2" _method="$3" _target="$4"
  case "$_cmd" in
    claude)
      if [[ "$_method" == "native" ]]; then
        if [[ "$_target" == "latest" ]]; then
          claude update
        else
          # --force：回退到旧版本或重装同版本时需要
          claude install "$_target" --force
        fi
      else
        npm install -g "${_pkg}@${_target}"
      fi
      ;;
    opencode)
      if [[ "$_target" == "latest" ]]; then
        opencode upgrade
      else
        opencode upgrade "v${_target#v}"
      fi
      ;;
    openclaw)
      # openclaw update 会顺带做 doctor 检查并重启 Gateway；失败再退回 npm
      if [[ "$_target" == "latest" ]]; then
        openclaw update --yes || npm install -g "${_pkg}@latest"
      else
        openclaw update --tag "$_target" --yes || npm install -g "${_pkg}@${_target}"
      fi
      ;;
    *)
      npm install -g "${_pkg}@${_target}"
      ;;
  esac
}

# 官方安装器装的 Claude Code 会后台自动更新，回退后需关掉，否则会被自动升回最新版
_claude_autoupdate_lock() {
  local _f="$HOME/.claude/settings.json" _tmp
  command -v jq &>/dev/null || { warn "未安装 jq，请手动在 ${_f} 的 env 中加入 \"DISABLE_AUTOUPDATER\": \"1\""; return 1; }
  mkdir -p "$(dirname "$_f")"
  [[ -s "$_f" ]] || echo '{}' > "$_f"
  _tmp=$(mktemp)
  if jq '.env = ((.env // {}) + {"DISABLE_AUTOUPDATER": "1"})' "$_f" > "$_tmp"; then
    cat "$_tmp" > "$_f"
    log "已关闭 Claude Code 自动更新（${_f} → env.DISABLE_AUTOUPDATER=1）"
  else
    warn "${_f} 不是合法 JSON，未修改"
  fi
  rm -f "$_tmp"
}

_claude_autoupdate_unlock() {
  local _f="$HOME/.claude/settings.json" _tmp
  [[ -s "$_f" ]] && command -v jq &>/dev/null || return 0
  jq -e '.env.DISABLE_AUTOUPDATER' "$_f" &>/dev/null || return 0
  _tmp=$(mktemp)
  if jq 'del(.env.DISABLE_AUTOUPDATER)' "$_f" > "$_tmp"; then
    cat "$_tmp" > "$_f"
    log "已恢复 Claude Code 自动更新"
  fi
  rm -f "$_tmp"
}

update_ai_agents() {
  detect_ai_agents

  local -a _U=() _labels=()
  local _e _cmd _name _pkg
  for _e in "${AGENT_PKGS[@]}"; do
    IFS='|' read -r _cmd _name _pkg <<< "$_e"
    command -v "$_cmd" &>/dev/null || continue
    _U+=("$_e")
    _labels+=("${_name}（当前 $(_agent_cur_ver "$_cmd")）")
  done

  if [[ ${#_U[@]} -eq 0 ]]; then
    warn "未检测到已安装的 AI 智能体工具，请先安装"
    echo ""
    read -erp "  按回车返回..." _
    return 0
  fi

  print_header "AI 智能体 CLI 工具 — 更新 / 指定版本"
  input_choose "选择要更新的工具" "${_labels[@]}"
  [[ $INPUT_RESULT -eq -1 ]] && return 0
  IFS='|' read -r _cmd _name _pkg <<< "${_U[$INPUT_RESULT]}"

  local _cur _method
  _cur=$(_agent_cur_ver "$_cmd")
  _method=$(_agent_install_method "$_cmd" "$_pkg")

  print_header "${_name} — 更新 / 指定版本"
  echo -e "  当前版本：${G}${_cur:-未知}${N}"
  echo -e "  安装方式：${_method}  ${DIM}($(command -v "$_cmd"))${N}"
  if [[ "$_method" == "unknown" ]]; then
    warn "无法识别安装方式，将按 npm 全局包处理"
    _method="npm"
  fi
  echo ""
  info "查询可用版本..."

  local _latest="" _stable=""
  _latest=$(_agent_dist_tag "$_pkg" latest)
  [[ "$_cmd" == "claude" ]] && _stable=$(_agent_dist_tag "$_pkg" stable)
  local -a _vers=()
  mapfile -t _vers < <(_agent_recent_versions "$_pkg" 10)

  # 选项与目标一一对应
  local -a _opts=() _targets=()
  _opts+=("最新版 latest${_latest:+（${_latest}）}"); _targets+=("latest")
  if [[ -n "$_stable" ]]; then
    _opts+=("稳定版 stable（${_stable}）"); _targets+=("stable")
  fi
  local _v _mark
  for _v in "${_vers[@]}"; do
    [[ -z "$_v" ]] && continue
    _mark=""; [[ "$_v" == "$_cur" ]] && _mark="  ← 当前"
    _opts+=("${_v}${_mark}"); _targets+=("$_v")
  done
  _opts+=("手动输入版本号（可回退到更早的版本）"); _targets+=("__manual__")
  [[ ${#_vers[@]} -eq 0 ]] && warn "未能从 npm 获取版本列表，可选最新版或手动输入"

  input_choose "选择目标版本" "${_opts[@]}"
  [[ $INPUT_RESULT -eq -1 ]] && return 0
  local _target="${_targets[$INPUT_RESULT]}"

  if [[ "$_target" == "__manual__" ]]; then
    ask _target "输入版本号（如 ${_vers[0]:-1.0.0}）"
    _target="${_target#v}"
    if [[ ! "$_target" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
      warn "版本号格式不正确：${_target}"
      read -erp "  按回车返回..." _
      return 0
    fi
    if command -v npm &>/dev/null && [[ -z "$(timeout 30 npm view "${_pkg}@${_target}" version 2>/dev/null)" ]]; then
      warn "npm 上不存在 ${_pkg}@${_target}"
      read -erp "  按回车返回..." _
      return 0
    fi
  fi

  echo ""
  local _go
  askyn _go "确认将 ${_name} 从 ${_cur:-未知} 切换到 ${_target}？" "y"
  $_go || return 0

  echo ""
  if _agent_run_update "$_cmd" "$_pkg" "$_method" "$_target"; then
    hash -r 2>/dev/null
    log "${_name}：${_cur:-未知} → $(_agent_cur_ver "$_cmd")"
    if [[ "$_cmd" == "claude" && "$_method" == "native" ]]; then
      if [[ "$_target" == "latest" ]]; then
        _claude_autoupdate_unlock
      else
        echo ""
        warn "官方安装器版本会后台自动更新，不关闭的话会被自动升回最新版"
        local _lock
        askyn _lock "关闭 Claude Code 自动更新，固定在当前版本？" "y"
        $_lock && _claude_autoupdate_lock
      fi
    fi
  else
    warn "${_name} 更新失败，请查看上面的输出"
  fi
  echo ""
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

    input_choose "智能体工具操作" "安装" "更新 / 指定版本（可回退）" "卸载" "状态查看"
    [[ $INPUT_RESULT -eq -1 ]] && break

    case $INPUT_RESULT in
      0) install_ai_agents ;;
      1) update_ai_agents ;;
      2) uninstall_ai_agents ;;
      3) show_ai_agents_status ;;
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
    print_header "AI 服务栈 一键安装脚本 V1.5"

    # 服务栈摘要
    if [[ -f "$BASE_DIR/.env" ]]; then
      source "$BASE_DIR/.env" 2>/dev/null
      detect_installed_services
      echo -e "  ${W}服务栈${N}  ${G}已安装${N}"
      [[ -n "${DOMAIN:-}" ]] && echo -e "  域名：${C}${DOMAIN}${N}"
      local _running=0 _total=0
      for _entry in "${SVC_REGISTRY_STACK[@]}"; do
        IFS='|' read -r _key _name _type _target <<< "$_entry"
        local _var="SVC_${_key}_INSTALLED"
        [[ "${!_var}" != "true" ]] && continue
        ((_total++))
        svc_running "$_type" "$_target" && ((_running++))
      done
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
      "AI 智能体 CLI 工具 — 在终端使用 Claude Code、Codex、OpenCode 等命令行工具" \
      "VPS 迁移 — 整机打包/传递/解包（服务栈 + CLI 凭据 + 系统配置全覆盖）"
    [[ $INPUT_RESULT -eq -1 ]] && { clear; break; }

    case $INPUT_RESULT in
      0) service_stack_menu ;;
      1) ai_agent_menu ;;
      2) migrate_menu ;;
    esac
  done
}
