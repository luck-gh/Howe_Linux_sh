#!/usr/bin/env bash
# 服务选择 + 分布式位置分配 + 配置收集 + DNS 检查
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 服务选择（输入式菜单）
# 输入编号切换选中 | a 全选/取消 | 回车确认 | 0 返回
# ═══════════════════════════════════════════════════════════════════
select_services() {
  # INST变量|显示名|内存MB|磁盘GB|服务大小说明|描述|flag
  local -a SVCS=(
    "INST_SINGBOX|sing-box|64|1|很小，约几十 MB|AnyTLS 代理，供 Clash / Mihomo 使用|core"
    "INST_SUB2API|Sub2API|192|2|中等，含 PostgreSQL|将订阅包装成 OpenAI 兼容 API（需 PostgreSQL）|"
    "INST_NEWAPI|New-API|256|2|轻量，约数百 MB|API Key 管理 + 多渠道路由 + 用量计费（OpenWebUI 依赖）|core"
    "INST_LITELLM|LiteLLM|512|1|中等，约 1GB|多 Provider 负载均衡网关|overlap"
    "INST_WEBUI|OpenWebUI|512|2|中等，约 1-2GB|自托管 AI 对话界面（类 ChatGPT），依赖 New-API|"
    "INST_DIFY|Dify|4096|10|很大，镜像约 5GB+|LLM 工作流 / Agent / RAG 平台|"
    "INST_CADDY|Caddy|32|0.1|极小|HTTPS 反向代理 + 自动 Let's Encrypt 证书|"
    "INST_PGSQL|PostgreSQL|128|2|极小，约 200MB|数据库（Sub2API / New-API 自动依赖）|dep"
    "INST_REDIS|Redis|32|0.5|极小，约 50MB|缓存（Sub2API 自动依赖）|dep"
  )
  local _cnt=${#SVCS[@]}

  detect_installed_services

  # SEL 默认勾选 = 当前 INST_*（detect 已同步真实状态 + .env 历史值）
  # 这样"安装 / 更新"路径下，用户只需勾选"想新增/想去掉"的项；什么都不改回车就是"保持现状"。
  declare -A SEL=(
    [INST_NEWAPI]=${INST_NEWAPI:-false}   [INST_WEBUI]=${INST_WEBUI:-false}
    [INST_LITELLM]=${INST_LITELLM:-false} [INST_SUB2API]=${INST_SUB2API:-false}
    [INST_DIFY]=${INST_DIFY:-false}       [INST_SINGBOX]=${INST_SINGBOX:-false}
    [INST_CADDY]=${INST_CADDY:-false}     [INST_PGSQL]=${INST_PGSQL:-false}
    [INST_REDIS]=${INST_REDIS:-false}
  )

  local _msg=""

  # ── 预计算评估信息（只算一次）───────────────────────────────
  declare -a _ASSESS_LVL=() _ASSESS_HINT=()
  for (( i=0; i<_cnt; i++ )); do
    IFS='|' read -r _ _ _ _mem _disk _ _flag <<< "${SVCS[$i]}"
    local _a; _a=$(assess_svc "$_mem" "$_disk" "$_flag")
    _ASSESS_LVL+=("${_a%%|*}")
    _ASSESS_HINT+=("${_a##*|}")
  done

  # ── 主交互循环 ──────────────────────────────────────────────
  while true; do
    clear
    echo -e "${W}${C}"
    echo "  ╔═══════════════════════════════════════════════════════════════"
    echo "  ║                    选择要安装的服务"
    echo "  ╠═══════════════════════════════════════════════════════════════"
    printf "  ║  CPU %-3s核  │  RAM %-5sMB / %-5sGB  │  磁盘剩余 %-4sGB\n" \
           "$SYS_CPU" "$SYS_MEM_MB" "$SYS_MEM_GB" "$SYS_DISK_GB"
    echo "  ╚═══════════════════════════════════════════════════════════════"
    echo -e "${N}"

    # ── 绘制服务列表 ──────────────────────────────────────────
    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _var _name _mem _disk _size _desc _flag <<< "${SVCS[$i]}"

      # dep 类型：不可选的依赖服务，仅展示
      if [[ "$_flag" == "dep" ]]; then
        local _auto_tag="${DIM}[自动]${N}"
        local _auto_name="${DIM}${_name}${N}"
        local _show=false
        # 只在依赖方被选中时才显示
        [[ "$_var" == "INST_PGSQL" ]] && { [[ "${SEL[INST_SUB2API]}" == "true" ]] || [[ "${SEL[INST_NEWAPI]}" == "true" ]]; } && _show=true
        [[ "$_var" == "INST_REDIS" ]] && [[ "${SEL[INST_SUB2API]}" == "true" ]] && _show=true
        if $_show; then
          printf "    %b %b %b${_auto_name}  ${DIM}大小：%-18s RAM %-5sMB  磁盘 %-3sGB${N}\n" \
                 "$_auto_tag" "${DIM}$((i+1)).${N}" "" "$_size" "$_mem" "$_disk"
          printf "          ${DIM}${_desc}${N}\n"
          echo ""
        fi
        continue
      fi

      local _chk; [[ "${SEL[$_var]}" == "true" ]] && _chk="${G}[✓]${N}" || _chk="${DIM}[ ]${N}"
      local _installed _name_color
      _installed=$(svc_installed_var "$_var")
      $_installed && { _installed="${G}[已安装]${N}"; _name_color=$G; } || { _installed="${DIM}[未安装]${N}"; _name_color=$N; }

      local _lvl="${_ASSESS_LVL[$i]}" _hint="${_ASSESS_HINT[$i]}"
      local _ac _ap
      case "$_lvl" in
        ok)   _ac=$G; _ap="▶ 推荐" ;;
        warn) _ac=$Y; _ap="▶ 注意" ;;
        err)  _ac=$R; _ap="▶ 警告" ;;
      esac

      local _tag=""
      [[ "$_flag" == "core"    ]] && _tag=" ${Y}[核心]${N}"
      [[ "$_flag" == "overlap" ]] && _tag=" ${DIM}[与 New-API 重叠]${N}"

      printf "    %b %b %b${_name_color}${W}%-12s${N}  %b  ${DIM}大小：%-18s RAM %-5sMB  磁盘 %-3sGB${N}%b\n" \
             "$_chk" "${W}$((i+1)).${N}" "" "$_name" "$_installed" "$_size" "$_mem" "$_disk" "$_tag"
      printf "          ${DIM}${_desc}${N}\n"
      printf "          ${_ac}${_ap}：${_hint}${N}\n"
    done

    # 当前选择汇总
    local _prev=""
    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _var _name _ <<< "${SVCS[$i]}"
      [[ "${SEL[$_var]}" == "true" ]] && _prev+="${G}${_name}${N}  "
    done
    echo ""
    echo -e "  ${W}当前选择：${N}${_prev:-${R}无${N}}"

    [[ -n "$_msg" ]] && echo -e "  ${_msg}"

    echo ""
    echo -e "  ${DIM}输入编号切换 | a=全选 | 回车=确认 | 0=返回${N}"
    echo ""

    # ── 读取输入 ──────────────────────────────────────────────
    local _input
    read -erp "  选择：" _input

    _msg=""

    # 直接回车 = 确认
    if [[ -z "$_input" ]]; then
      break
    fi

    # 0 = 返回上一级
    if [[ "$_input" == "0" ]]; then
      return 1
    fi

    # a/A = 全选/取消全选（跳过 dep 类型）
    if [[ "${_input,,}" == "a" ]]; then
      local _all_on=true
      for (( i=0; i<_cnt; i++ )); do
        IFS='|' read -r _var _ _ _ _ _ _flag <<< "${SVCS[$i]}"
        [[ "$_flag" == "dep" ]] && continue
        [[ "${SEL[$_var]}" != "true" ]] && _all_on=false
      done
      for (( i=0; i<_cnt; i++ )); do
        IFS='|' read -r _var _ _ _ _ _ _flag <<< "${SVCS[$i]}"
        [[ "$_flag" == "dep" ]] && continue
        $_all_on && SEL[$_var]=false || SEL[$_var]=true
      done
      # dep 服务联动
      if [[ "${SEL[INST_SUB2API]}" == "true" ]] || [[ "${SEL[INST_NEWAPI]}" == "true" ]]; then
        SEL[INST_PGSQL]=true
      else
        SEL[INST_PGSQL]=false
      fi
      [[ "${SEL[INST_SUB2API]}" == "true" ]] && SEL[INST_REDIS]=true || SEL[INST_REDIS]=false
      continue
    fi

    # 数字 = 切换对应服务（跳过 dep 类型）
    if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _cnt )); then
      local _idx=$((_input - 1))
      IFS='|' read -r _var _ _ _ _ _ _flag <<< "${SVCS[$_idx]}"

      # dep 类型不可切换
      if [[ "$_flag" == "dep" ]]; then
        _msg="${DIM}PostgreSQL / Redis 为自动依赖，无需手动选择${N}"
        continue
      fi

      [[ "${SEL[$_var]}" == "true" ]] && SEL[$_var]=false || SEL[$_var]=true

      # 切换服务时自动联动
      if [[ "${SEL[$_var]}" == "true" ]]; then
        case "$_var" in
          INST_NEWAPI|INST_WEBUI|INST_LITELLM|INST_SUB2API|INST_DIFY)
            SEL[INST_CADDY]=true ;;
        esac
      fi

      # dep 服务联动
      if [[ "${SEL[INST_SUB2API]}" == "true" ]] || [[ "${SEL[INST_NEWAPI]}" == "true" ]]; then
        SEL[INST_PGSQL]=true
      else
        SEL[INST_PGSQL]=false
      fi
      [[ "${SEL[INST_SUB2API]}" == "true" ]] && SEL[INST_REDIS]=true || SEL[INST_REDIS]=false
    else
      _msg="${R}无效输入，请输入 1-${_cnt} 的数字、a 或 0${N}"
    fi
  done

  # OpenWebUI 依赖 New-API
  [[ "${SEL[INST_WEBUI]}" == "true" ]] && SEL[INST_NEWAPI]=true

  # 最终 dep 同步（OpenWebUI 联动 New-API 后需要重新检查）
  if [[ "${SEL[INST_SUB2API]}" == "true" ]] || [[ "${SEL[INST_NEWAPI]}" == "true" ]]; then
    SEL[INST_PGSQL]=true
  fi
  [[ "${SEL[INST_SUB2API]}" == "true" ]] && SEL[INST_REDIS]=true

  local _any=false
  for (( i=0; i<_cnt; i++ )); do
    IFS='|' read -r _var _ _ _ _ _ _flag <<< "${SVCS[$i]}"
    [[ "$_flag" == "dep" ]] && continue
    [[ "${SEL[$_var]}" == "true" ]] && _any=true
  done
  $_any || { _msg="${R}未选择任何服务${N}"; return 1; }

  INST_NEWAPI=${SEL[INST_NEWAPI]}  INST_WEBUI=${SEL[INST_WEBUI]}
  INST_LITELLM=${SEL[INST_LITELLM]}  INST_SUB2API=${SEL[INST_SUB2API]}
  INST_DIFY=${SEL[INST_DIFY]}  INST_SINGBOX=${SEL[INST_SINGBOX]}
  INST_CADDY=${SEL[INST_CADDY]}
  INST_PGSQL=${SEL[INST_PGSQL]}  INST_REDIS=${SEL[INST_REDIS]}
  log "服务选择完成"
  sleep 1
}

# ═══════════════════════════════════════════════════════════════════
# 分布式：服务位置分配（VPS or 本地）
# ═══════════════════════════════════════════════════════════════════
assign_service_locations() {
  if [[ "$DEPLOY_MODE" != "distributed" ]]; then
    LOC_WEBUI="vps"; LOC_LITELLM="vps"; LOC_SUB2API="vps"; LOC_DIFY="vps"
    return 0
  fi

  local _core=520
  # INST变量|LOC变量|显示名|内存MB|推荐位置
  local -a _T=(
    "INST_WEBUI|LOC_WEBUI|OpenWebUI|512|local"
    "INST_LITELLM|LOC_LITELLM|LiteLLM|512|local"
    "INST_SUB2API|LOC_SUB2API|Sub2API|192|vps"
    "INST_DIFY|LOC_DIFY|Dify|4096|local"
  )
  local _t_cnt=${#_T[@]}

  declare -A _L
  for _e in "${_T[@]}"; do
    IFS='|' read -r _ _lv _ _ _rec <<< "$_e"
    _L[$_lv]="$_rec"
  done

  while true; do
    # 计算 VPS 内存
    local _svc_used=0
    for _e in "${_T[@]}"; do
      IFS='|' read -r _iv _lv _ _mem _ <<< "$_e"
      local _on="${!_iv:-false}"
      $_on && [[ "${_L[$_lv]}" == "vps" ]] && _svc_used=$((_svc_used+_mem))
    done
    local _total=$((_core+_svc_used))
    local _remain=$((SYS_MEM_MB-_total))
    local _rc=$G
    [[ $_remain -lt 256 ]] && _rc=$Y
    [[ $_remain -lt 0   ]] && _rc=$R

    clear

    echo -e "${W}${C}"
    echo "  分配服务运行位置（分布式模式）"
    echo "  ─────────────────────────────────"
    printf "  VPS RAM：总 %-5sMB  已规划 %-5sMB  ${_rc}剩余 %-6sMB${N}\n" \
           "$SYS_MEM_MB" "$_total" "$_remain"
    echo -e "${N}"
    echo -e "  ${DIM}VPS ↔ 本地通过 frp 隧道透传，Caddy 对外统一 HTTPS${N}"

    # 固定 VPS 服务
    $INST_NEWAPI  && echo -e "  ${DIM}[─] [VPS] New-API       256MB  固定在 VPS${N}"
    $INST_SINGBOX && echo -e "  ${DIM}[─] [VPS] sing-box       64MB  固定在 VPS${N}"
    $INST_CADDY   && echo -e "  ${DIM}[─] [VPS] Caddy          32MB  固定在 VPS${N}"
    echo ""

    # 可切换服务
    for (( i=0; i<_t_cnt; i++ )); do
      IFS='|' read -r _iv _lv _name _mem _rec <<< "${_T[$i]}"
      local _on="${!_iv:-false}"

      if ! $_on; then
        printf "  ${DIM}  [%d] %-12s  --    未选择安装${N}\n" "$((i+1))" "$_name"
        continue
      fi

      local _loc="${_L[$_lv]}"
      local _ls _lc
      [[ "$_loc" == "vps" ]] && { _ls="[VPS] "; _lc=$C; } || { _ls="[本地]"; _lc=$Y; }

      local _hint _hc _rec_label
      local _avail=$((SYS_MEM_MB-_core))
      if [[ $_mem -gt $_avail ]]; then
        _hint="VPS 内存不足，必须放本地"; _hc=$R
      elif [[ $_mem -gt $((_avail-200)) ]]; then
        _hint="VPS 内存偏紧，建议放本地"; _hc=$Y
      elif [[ "$_rec" == "local" ]]; then
        _hint="本地资源更充裕，推荐本地"; _hc=$Y
      else
        _hint="轻量，VPS 足够";            _hc=$G
      fi
      [[ "$_rec" == "vps" ]] && _rec_label="推荐: VPS" || _rec_label="推荐: 本地"

      printf "    [%d] %-12s → ${_lc}%s${N} %4sMB  ${_hc}(%s)${N}\n" \
             "$((i+1))" "$_name" "$_ls" "$_mem" "$_rec_label"
    done

    [[ $_remain -lt 0 ]] && {
      echo ""
      echo -e "  ${R}[!] VPS 内存超分配 $((-_remain))MB，会 OOM！请将重服务移至本地${N}"
    }

    echo ""
    echo -e "  ${DIM}输入编号切换位置 | 回车=确认 | 0=返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input

    # 空输入 = 确认
    [[ -z "$_input" ]] && break

    # 0 = 返回
    [[ "$_input" == "0" ]] && return 1

    # 数字 = 切换对应服务
    if [[ "$_input" =~ ^[0-9]+$ ]] && [[ $_input -ge 1 ]] && [[ $_input -le $_t_cnt ]]; then
      local _idx=$((_input-1))
      IFS='|' read -r _iv _lv _name _ _ <<< "${_T[$_idx]}"
      local _on="${!_iv:-false}"
      if ! $_on; then continue; fi
      [[ "${_L[$_lv]}" == "vps" ]] && _L[$_lv]="local" || _L[$_lv]="vps"
    fi
  done

  LOC_WEBUI=${_L[LOC_WEBUI]}
  LOC_LITELLM=${_L[LOC_LITELLM]}
  LOC_SUB2API=${_L[LOC_SUB2API]}
  LOC_DIFY=${_L[LOC_DIFY]}
  return 0
}

# ═══════════════════════════════════════════════════════════════════
# 配置收集主流程
# ═══════════════════════════════════════════════════════════════════
collect_config() {
  # ── 阶段 1：模式选择 ──────────────────────────────────────
  # choose_deploy_mode 返回 1 表示用户选了"退出脚本"
  choose_deploy_mode || exit 0

  # ── 阶段 2：服务选择（可返回模式选择）────────────────────────
  while true; do
    select_services && break
    choose_deploy_mode || exit 0
  done

  # ── 阶段 3：位置分配（可返回服务选择）────────────────────────
  while true; do
    assign_service_locations && break
    # 返回上一级 → 重新选服务
    while true; do
      select_services && break 2
      choose_deploy_mode || exit 0
    done
  done

  # 域名配置（跟随 Caddy）
  clear
  echo -e "${W}${C}  ── 域名与 HTTPS 配置 ─────────────────────────────────────${N}"
  echo ""
  echo -e "  公网 IP：${C}${VPS_IP}${N}"
  if $INST_CADDY; then
    echo -e "  ${DIM}Caddy 自动向 Let's Encrypt 申请证书，无需手动操作${N}"
    echo -e "  ${DIM}Cloudflare 用户：DNS 代理须为灰色云朵（仅 DNS 模式）${N}"
    echo ""
    echo -e "  ${W}需在域名服务商添加以下 A 记录（均指向 ${VPS_IP}）：${N}"
    $INST_NEWAPI  && echo -e "    ${PREFIX_NEWAPI}.你的域名   → New-API"
    $INST_WEBUI   && echo -e "    ${PREFIX_WEBUI}.你的域名  → OpenWebUI"
    $INST_LITELLM && echo -e "    ${PREFIX_LITELLM}.你的域名    → LiteLLM"
    $INST_SUB2API && echo -e "    ${PREFIX_SUB2API}.你的域名   → Sub2API"
    $INST_DIFY    && echo -e "    ${PREFIX_DIFY}.你的域名  → Dify"
    echo ""
    ask DOMAIN "主域名（如 example.com），留空则 IP+HTTP 测试模式" ""
    if [[ -n "$DOMAIN" ]]; then
      ask EMAIL "Let's Encrypt 邮箱" "admin@${DOMAIN}"
    else
      EMAIL=""
      warn "未填域名，将使用 HTTP 模式（建议仅测试使用）"
    fi
  else
    echo -e "  ${DIM}未选择 Caddy，跳过域名与 HTTPS 配置${N}"
    DOMAIN=""
    EMAIL=""
  fi

  # frp 配置（分布式时）
  if [[ "$DEPLOY_MODE" == "distributed" ]]; then
    echo ""
    echo -e "  ${W}frp 穿透配置${N}"
    ask FRP_PORT "frp 监听端口" "7000"
    FRP_TOKEN=$(openssl rand -hex 20)
    info "frp Token（自动生成）：${FRP_TOKEN}"
  fi

  # 密钥
  echo ""
  echo -e "  ${W}密钥配置（回车接受自动生成值）${N}"
  local _g_na; _g_na=$(openssl rand -hex 16)
  local _g_ll; _g_ll="sk-$(openssl rand -hex 16)"
  local _g_dy; _g_dy=$(openssl rand -hex 16)
  local _g_sb; _g_sb=$(openssl rand -base64 18 | tr -d '=+/')

  $INST_NEWAPI && ask NEWAPI_TOKEN "New-API 会话密钥" "$_g_na" || NEWAPI_TOKEN=""
  $INST_LITELLM && ask LITELLM_KEY "LiteLLM 主密钥" "$_g_ll" || LITELLM_KEY=""
  $INST_DIFY    && ask DIFY_SECRET  "Dify 密钥"     "$_g_dy" || DIFY_SECRET=""
  if $INST_SINGBOX; then
    ask CLASH_PORT_MIN "AnyTLS 端口段起点（每个订阅占一个）" "13443"
    ask CLASH_PORT_MAX "AnyTLS 端口段终点" "13458"
  fi

  echo ""
  log "配置收集完成"

  # 动态计算总步骤
  TOTAL_STEPS=8
  $INST_DIFY    && [[ "$LOC_DIFY"    != "local" ]] && TOTAL_STEPS=$((TOTAL_STEPS+1))
  $INST_SINGBOX && TOTAL_STEPS=$((TOTAL_STEPS+1))
  [[ "$DEPLOY_MODE" == "distributed" ]] && TOTAL_STEPS=$((TOTAL_STEPS+2))
  [[ -n "$DOMAIN" ]] && TOTAL_STEPS=$((TOTAL_STEPS+1))
}

# ═══════════════════════════════════════════════════════════════════
# DNS 预检
# ═══════════════════════════════════════════════════════════════════
check_dns() {
  [[ -z "$DOMAIN" ]] && return 0
  step "DNS 预检"

  command -v dig &>/dev/null || apt-get install -y -qq dnsutils 2>/dev/null || true

  local _fail=false
  local _subs=()
  $INST_NEWAPI  && _subs+=("${PREFIX_NEWAPI}")
  $INST_WEBUI   && _subs+=("${PREFIX_WEBUI}")
  $INST_LITELLM && _subs+=("${PREFIX_LITELLM}")
  $INST_SUB2API && _subs+=("${PREFIX_SUB2API}")
  $INST_DIFY    && _subs+=("${PREFIX_DIFY}")
  [[ ${#_subs[@]} -eq 0 ]] && return 0

  for _sub_ in "${_subs[@]}"; do
    local _resolved
    _resolved=$(dig +short "${_sub_}.${DOMAIN}" A 2>/dev/null | tail -1 || true)
    if [[ "$_resolved" == "$VPS_IP" ]]; then
      log "${_sub_}.${DOMAIN} → ${_resolved} ✓"
    else
      warn "${_sub_}.${DOMAIN} → '${_resolved:-未解析}'（期望 ${VPS_IP}）"
      _fail=true
    fi
  done

  while $_fail; do
    warn "部分 DNS 未生效（可能仍在传播，通常 1-10 分钟）"
    warn "Caddy 申请证书需要 DNS 生效后才会成功"

    input_choose "DNS 未就绪，请选择" "再次检测" "继续安装（DNS 稍后生效）" "退出，稍后重试"
    case $INPUT_RESULT in
      0)  # 再次检测
        _fail=false
        for _sub_ in "${_subs[@]}"; do
          local _resolved
          _resolved=$(dig +short "${_sub_}.${DOMAIN}" A 2>/dev/null | tail -1 || true)
          if [[ "$_resolved" == "$VPS_IP" ]]; then
            log "${_sub_}.${DOMAIN} → ${_resolved} ✓"
          else
            warn "${_sub_}.${DOMAIN} → '${_resolved:-未解析}'（期望 ${VPS_IP}）"
            _fail=true
          fi
        done
        $_fail || log "所有 DNS 记录已就绪"
        ;;
      1) break ;;  # 继续安装
      2) info "请 DNS 生效后重新运行脚本"; exit 0 ;;  # 退出
    esac
  done
}

