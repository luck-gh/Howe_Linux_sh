#!/usr/bin/env bash
# print_clash_link / print_summary / 安装确认 / 安装 / 卸载
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# Clash / Mihomo 订阅入口（多订阅模式：列出每条 URL）
# ═══════════════════════════════════════════════════════════════════
print_clash_link() {
  $INST_SINGBOX || return 0
  [[ -x "$(_clash_py)" ]] || return 0
  local _names
  _names=$(python3 "$(_clash_py)" --base "$(_clash_dir)" list --names 2>/dev/null)
  [[ -z "$_names" ]] && return 0
  local _host="${PREFIX_VPS:-vps}.${DOMAIN}"
  [[ -n "$DOMAIN" ]] || _host="${VPS_IP:-YOUR_IP}"
  echo ""
  echo -e "${W}${C}── Clash / Mihomo 订阅 URL ───────────────────────────────${N}"
  echo ""
  while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    local _tok
    _tok=$(python3 "$(_clash_py)" --base "$(_clash_dir)" show "$_n" 2>/dev/null \
             | awk '/token/ {print $3; exit}')
    [[ -n "$_tok" ]] && echo -e "  ${W}${_n}${N}  →  ${C}https://${_host}/sub/${_tok}/${_n}.yaml${N}"
  done <<< "$_names"
  echo ""
  echo -e "  ${DIM}进入「Clash 订阅管理」菜单可查询单条订阅的端口 / 密码 / 实时用量${N}"
}

# ═══════════════════════════════════════════════════════════════════
# 安装摘要
# ═══════════════════════════════════════════════════════════════════
print_summary() {
  echo ""
  echo -e "${W}${C}"
  echo "  ╔═══════════════════════════════════════════════════════════════"
  echo "  ║                       安装完成 🎉"
  echo "  ╚═══════════════════════════════════════════════════════════════"
  echo -e "${N}"

  if has_web_service; then
    echo -e "  ${W}VPS 访问地址${N}"
  fi
  if [[ -n "$DOMAIN" ]]; then
    $INST_NEWAPI  && echo -e "    New-API   → ${C}https://${PREFIX_NEWAPI}.${DOMAIN}${N}  ${DIM}默认 root/123456，立即改密${N}"
    $INST_WEBUI   && echo -e "    OpenWebUI → ${C}https://${PREFIX_WEBUI}.${DOMAIN}${N}  ${DIM}[${LOC_WEBUI}]${N}"
    $INST_LITELLM && echo -e "    LiteLLM   → ${C}https://${PREFIX_LITELLM}.${DOMAIN}${N}    ${DIM}[${LOC_LITELLM}]${N}"
    $INST_SUB2API && echo -e "    Sub2API   → ${C}https://${PREFIX_SUB2API}.${DOMAIN}${N}   ${DIM}[${LOC_SUB2API}]${N}"
    $INST_DIFY    && echo -e "    Dify      → ${C}https://${PREFIX_DIFY}.${DOMAIN}${N}  ${DIM}[${LOC_DIFY}]${N}"
    echo ""
    warn "HTTPS 证书由 Caddy 自动申请，首次访问如见证书错误，等 1-2 分钟后刷新"
  elif has_web_service; then
    if $INST_CADDY; then
      # HTTP 模式：Caddy 在 :8080 做反代
      $INST_NEWAPI  && echo -e "    New-API   → ${C}http://${VPS_IP}:8080${N}（HTTP 测试模式）"
      $INST_WEBUI   && echo -e "    OpenWebUI → ${C}http://${VPS_IP}:8080/${PREFIX_WEBUI}${N}  ${DIM}[${LOC_WEBUI}]${N}"
      $INST_LITELLM && echo -e "    LiteLLM   → ${C}http://${VPS_IP}:8080/${PREFIX_LITELLM}${N}    ${DIM}[${LOC_LITELLM}]${N}"
      $INST_SUB2API && echo -e "    Sub2API   → ${C}http://${VPS_IP}:8080/${PREFIX_SUB2API}${N}   ${DIM}[${LOC_SUB2API}]${N}"
      $INST_DIFY    && echo -e "    Dify      → ${C}http://${VPS_IP}:8080/${PREFIX_DIFY}${N}  ${DIM}[${LOC_DIFY}]${N}"
    else
      # 无 Caddy：服务直连模式
      echo -e "  ${DIM}未使用 Caddy，服务通过独立端口直连${N}"
      $INST_NEWAPI  && echo -e "    New-API   → ${C}http://${VPS_IP}:13000${N}"
      $INST_WEBUI   && [[ "${LOC_WEBUI:-vps}" == "vps" ]] && echo -e "    OpenWebUI → ${C}http://${VPS_IP}:13010${N}"
      $INST_LITELLM && [[ "${LOC_LITELLM:-vps}" == "vps" ]] && echo -e "    LiteLLM   → ${C}http://${VPS_IP}:14000${N}"
      $INST_SUB2API && [[ "${LOC_SUB2API:-vps}" == "vps" ]] && echo -e "    Sub2API   → ${C}http://${VPS_IP}:13001${N}"
    fi
  fi

  echo ""
  echo -e "  ${W}密钥备份${N}  ${DIM}（完整配置：cat $BASE_DIR/.env）${N}"
  $INST_NEWAPI  && echo -e "    New-API Token  : ${NEWAPI_TOKEN}"
  $INST_LITELLM && echo -e "    LiteLLM Key    : ${LITELLM_KEY}"
  $INST_SINGBOX && {
    echo -e "    AnyTLS 端口段  : ${CLASH_PORT_MIN:-13443}-${CLASH_PORT_MAX:-13458}（每订阅一个）"
    echo -e "    ${DIM}订阅密码 / URL 见菜单 → 配置查询与修改 → Clash 订阅管理${N}"
  }
  [[ "$DEPLOY_MODE" == "distributed" ]] && {
    echo -e "    frp Token      : ${FRP_TOKEN}"
    echo -e "    frp 端口       : ${FRP_PORT}"
  }

  # 数据库 / Redis 连接配置提示
  if $INST_SUB2API || $INST_NEWAPI; then
    echo ""
    echo -e "  ${W}数据库连接配置${N}"
    if $INST_SUB2API; then
      echo -e "    ${C}Sub2API → PostgreSQL（已自动配置 config.yaml）${N}"
      echo -e "      主机: ai-db | 端口: 5432 | 用户: ai | 库: sub2api"
      echo -e "      SSL: disable | TLS: 否（容器内网通信）"
      echo -e "      密码查看: ${G}grep AI_DB_PASS ${BASE_DIR}/.env${N}"
      echo ""
      echo -e "    ${C}Sub2API → Redis（已自动配置 config.yaml）${N}"
      echo -e "      地址: ai-redis | 端口: 6379 | 密码: 留空 | DB: 0"
      echo ""
    fi
    if $INST_NEWAPI; then
      echo -e "    ${C}New-API → PostgreSQL（已自动配置 SQL_DSN 环境变量）${N}"
      echo -e "      库: newapi | 无需手动操作"
    fi
    echo ""
    echo -e "    ${DIM}所有服务均在 ai-stack Docker 网络内，容器名即主机名${N}"
  fi

  if [[ "$DEPLOY_MODE" == "distributed" ]]; then
    echo ""
    echo -e "  ${W}${Y}⚠  分布式模式：还需在本地台式机完成安装${N}"
    echo -e "    ${C}scp -r root@${VPS_IP}:${LOCAL_PKG_DIR} ~/ai-stack-local/${N}"
    echo -e "    ${C}cd ~/ai-stack-local/ && sudo bash install-local.sh${N}"
    echo ""
    echo -e "  ${W}服务分布${N}"
    local _vs=""
    local _ls=""
    $INST_NEWAPI  && _vs+=", New-API"
    $INST_WEBUI   && [[ "$LOC_WEBUI"   == "vps"   ]] && _vs+=", OpenWebUI"
    $INST_WEBUI   && [[ "$LOC_WEBUI"   == "local" ]] && _ls+=", OpenWebUI"
    $INST_LITELLM && [[ "$LOC_LITELLM" == "vps"   ]] && _vs+=", LiteLLM"
    $INST_LITELLM && [[ "$LOC_LITELLM" == "local" ]] && _ls+=", LiteLLM"
    $INST_SUB2API && [[ "$LOC_SUB2API" == "vps"   ]] && _vs+=", Sub2API"
    $INST_SUB2API && [[ "$LOC_SUB2API" == "local" ]] && _ls+=", Sub2API"
    $INST_DIFY    && [[ "$LOC_DIFY"    == "vps"   ]] && _vs+=", Dify"
    $INST_DIFY    && [[ "$LOC_DIFY"    == "local" ]] && _ls+=", Dify"
    $INST_SINGBOX && _vs+=", sing-box"
    $INST_CADDY  && _vs+=", Caddy"
    echo -e "    ${C}VPS 侧${N}  ：${_vs#, }"
    echo -e "    ${Y}本地侧${N}：${_ls#, }"
  fi

  echo ""
  echo -e "  ${W}常用命令${N}"
  echo -e "    ${C}cd $BASE_DIR${N}"
  has_vps_compose_service && {
    echo -e "    docker compose ps                 # 服务状态"
    $INST_NEWAPI && echo -e "    docker compose logs -f new-api    # 实时日志"
    echo -e "    docker compose restart <服务名>   # 重启单服务"
  }
  [[ "$DEPLOY_MODE" == "distributed" ]] && \
    echo -e "    systemctl status frps             # frp 穿透状态"
  $INST_SINGBOX && \
    echo -e "    systemctl status sing-box         # 代理状态"

  print_clash_link
}

# ═══════════════════════════════════════════════════════════════════
# 安装确认（↑↓ 选择 确认安装 / 返回修改）
# ═══════════════════════════════════════════════════════════════════
confirm_installation() {
  clear
  echo -e "${W}${C}"
  echo "  ╔═══════════════════════════════════════════════════════════════"
  echo "  ║                       安装确认"
  echo "  ╚═══════════════════════════════════════════════════════════════"
  echo -e "${N}"

  echo -e "  ${W}部署模式${N}  $([[ "$DEPLOY_MODE" == "distributed" ]] && echo "分布式（本地 ${LOCAL_OS}）" || echo "All-in-One")"
  [[ -n "$DOMAIN" ]] && echo -e "  ${W}域名${N}      ${C}${DOMAIN}${N}"
  echo ""

  echo -e "  ${W}服务列表${N}"
  $INST_SINGBOX && printf "    ${G}✓${N}  %-12s  %s\n" "sing-box" "AnyTLS 代理 → :${CLASH_PORT_MIN:-13443}-${CLASH_PORT_MAX:-13458}"
  $INST_NEWAPI  && printf "    ${G}✓${N}  %-12s  %s\n" "New-API" "API 网关 → :13000"
  $INST_SUB2API && {
    local _loc=""; [[ "$DEPLOY_MODE" == "distributed" ]] && _loc=" [${LOC_SUB2API}]"
    printf "    ${G}✓${N}  %-12s  %s%s\n" "Sub2API" "订阅转 API → :13001" "$_loc"
  }
  $INST_LITELLM && {
    local _loc=""; [[ "$DEPLOY_MODE" == "distributed" ]] && _loc=" [${LOC_LITELLM}]"
    printf "    ${G}✓${N}  %-12s  %s%s\n" "LiteLLM" "负载均衡 → :14000" "$_loc"
  }
  $INST_WEBUI && {
    local _loc=""; [[ "$DEPLOY_MODE" == "distributed" ]] && _loc=" [${LOC_WEBUI}]"
    printf "    ${G}✓${N}  %-12s  %s%s\n" "OpenWebUI" "对话界面 → :13010" "$_loc"
  }
  $INST_DIFY && {
    local _loc=""; [[ "$DEPLOY_MODE" == "distributed" ]] && _loc=" [${LOC_DIFY}]"
    printf "    ${G}✓${N}  %-12s  %s%s\n" "Dify" "工作流平台 → :13080" "$_loc"
  }
  $INST_CADDY && printf "    ${G}✓${N}  %-12s  %s\n" "Caddy" "HTTPS 反代 → :443"
  [[ "$DEPLOY_MODE" == "distributed" ]] && printf "    ${G}✓${N}  %-12s  %s\n" "frps" "穿透服务端 → :${FRP_PORT}"
  echo ""

  echo -e "  ${W}密钥${N}"
  $INST_NEWAPI  && echo -e "    New-API Token  : ${DIM}${NEWAPI_TOKEN}${N}"
  $INST_LITELLM && echo -e "    LiteLLM Key    : ${DIM}${LITELLM_KEY}${N}"
  $INST_SINGBOX && echo -e "    AnyTLS 端口段  : ${DIM}${CLASH_PORT_MIN:-13443}-${CLASH_PORT_MAX:-13458}（每订阅独立密码 / 端口）${N}"
  [[ "$DEPLOY_MODE" == "distributed" ]] && echo -e "    frp Token      : ${DIM}${FRP_TOKEN}${N}"

  input_choose "确认安装？" "开始安装" "返回修改"
  [[ $INPUT_RESULT -eq 0 ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════════
# 安装 / 更新（原 main 主流程）
# ═══════════════════════════════════════════════════════════════════
install_or_update() {
  STEP=0

  preflight      # 系统/网络预检，探测资源，获取 VPS IP

  # 配置收集 + 确认循环（Esc 可返回重新配置）
  while true; do
    collect_config
    confirm_installation && break
  done

  install_deps
  setup_dirs
  write_env
  write_compose
  write_litellm_config

  [[ -n "$DOMAIN" ]] && check_dns

  $INST_DIFY && [[ "${LOC_DIFY:-vps}" == "vps" ]] && setup_dify

  if $INST_SINGBOX; then
    install_singbox
    write_singbox_config
    setup_clash_subscription
    render_clash_subscription || true
  fi

  if $INST_CADDY; then
    step "安装 Caddy 反向代理"
    install_caddy
    write_caddyfile
  fi

  install_frp_server
  configure_firewall
  start_services
  health_check

  if [[ "$DEPLOY_MODE" == "distributed" ]]; then
    generate_local_package
  fi

  print_summary
  echo ""
  read -erp "  按回车继续..." _
}

# ═══════════════════════════════════════════════════════════════════
# 卸载（多选：选择要卸载的服务）
# ═══════════════════════════════════════════════════════════════════
uninstall_stack() {
  if [[ ! -f "$BASE_DIR/.env" ]]; then
    warn "未找到 $BASE_DIR/.env，可能尚未安装"
    echo ""
    read -erp "  按回车返回..." _
    return 0
  fi

  source "$BASE_DIR/.env" 2>/dev/null
  detect_installed_services

  # 构建已安装的服务列表
  local -a _U=()
  $SVC_NEWAPI_INSTALLED  && _U+=("new-api|New-API")
  $SVC_WEBUI_INSTALLED   && _U+=("openwebui|OpenWebUI")
  $SVC_LITELLM_INSTALLED && _U+=("litellm|LiteLLM")
  $SVC_SUB2API_INSTALLED && _U+=("sub2api|Sub2API")
  (docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^ai-db$") && _U+=("ai-db|PostgreSQL")
  (docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^ai-redis$") && _U+=("ai-redis|Redis")
  $SVC_DIFY_INSTALLED    && _U+=("dify-nginx|Dify")
  $SVC_SINGBOX_INSTALLED && _U+=("sing-box|sing-box")
  command -v caddy &>/dev/null && _U+=("caddy|Caddy")

  if [[ ${#_U[@]} -eq 0 ]]; then
    warn "未检测到已安装的服务"
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
    print_header "卸载 AI 服务栈"
    echo -e "  ${DIM}选择要卸载的服务（输入编号切换）${N}"
    echo ""

    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _key _name <<< "${_U[$i]}"
      local _chk; [[ "${_DEL[$i]}" == "true" ]] && _chk="${R}[✓]${N}" || _chk="${DIM}[ ]${N}"
      printf "    %b ${W}[%d]${N}  %-15s\n" "$_chk" "$((i+1))" "$_name"
    done
    echo ""

    # 当前选择汇总
    local _sel=""
    for (( i=0; i<_cnt; i++ )); do
      IFS='|' read -r _key _name <<< "${_U[$i]}"
      [[ "${_DEL[$i]}" == "true" ]] && _sel+="${R}${_name}${N}  "
    done
    echo -e "  ${W}将卸载：${N}${_sel:-${DIM}无${N}}"
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${_msg}"; echo ""; }
    echo -e "    ${DIM}[a] 全选/取消    [Enter] 确认卸载    [0] 返回主菜单${N}"
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
    for (( i=0; i<_cnt; i++ )); do
      [[ "${_DEL[$i]}" == "true" ]] && _any=true
    done
    if ! $_any; then
      _msg="${R}未选择任何服务${N}"
      continue
    fi
    break
  done

  # 执行卸载
  echo ""
  for (( i=0; i<_cnt; i++ )); do
    [[ "${_DEL[$i]}" != "true" ]] && continue
    IFS='|' read -r _key _name <<< "${_U[$i]}"

    case "$_key" in
      new-api|openwebui|litellm|sub2api|ai-db|ai-redis)
        dc_cmd rm "$_key" >/dev/null 2>&1 || true
        rm -rf "$BASE_DIR/$_key" 2>/dev/null
        log "$_name 容器已卸载"
        ;;
      dify-nginx)
        if [[ -d /opt/dify/docker ]]; then
          dc_cmd down-v "" /opt/dify/docker >/dev/null 2>&1 || true
          rm -rf /opt/dify
        fi
        log "Dify 已卸载"
        ;;
      sing-box)
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
        rm -rf /etc/sing-box
        systemctl daemon-reload 2>/dev/null
        log "sing-box 已卸载"
        ;;
      caddy)
        rm -f /etc/caddy/Caddyfile 2>/dev/null
        systemctl reload caddy 2>/dev/null || true
        log "Caddy 站点配置已清理"
        ;;
    esac
  done

  # 清理 frps（分布式模式下总是卸载）
  if [[ "${DEPLOY_MODE:-}" == "distributed" ]] && systemctl is-active frps &>/dev/null; then
    systemctl stop frps 2>/dev/null
    systemctl disable frps 2>/dev/null
    log "frps 已停止"
  fi

  # 询问是否保留 .env
  echo ""
  while true; do
    echo -e "  ${W}是否保留 $BASE_DIR/.env 配置备份？${N}"
    echo "    1. 保留 .env（推荐，方便重新安装）"
    echo "    2. 删除全部（连同 .env）"
    echo ""
    local _keep_input
    read -erp "  选择：" _keep_input

    if [[ "$_keep_input" == "1" ]]; then
      rm -f "$BASE_DIR/docker-compose.yml" "$BASE_DIR/Caddyfile" 2>/dev/null
      rm -rf "$BASE_DIR/local-pkg" 2>/dev/null
      log "容器数据已清理，.env 已保留"
      break
    elif [[ "$_keep_input" == "2" ]]; then
      rm -rf "$BASE_DIR"
      log "$BASE_DIR 已完全删除"
      break
    fi
  done

  echo ""
  log "卸载完成"
  read -erp "  按回车继续..." _
}

