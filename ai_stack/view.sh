#!/usr/bin/env bash
# show_secrets / show_db_connection / show_config / 服务管理
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 密钥信息查看
# ═══════════════════════════════════════════════════════════════════
show_secrets() {
  print_header "密钥信息"

  echo -e "  ${W}服务密钥${N}"
  [[ "${INST_NEWAPI:-false}"  == "true" ]] && echo "    New-API Token  : ${NEWAPI_TOKEN:-未设置}"
  [[ "${INST_LITELLM:-false}" == "true" ]] && echo "    LiteLLM Key    : ${LITELLM_KEY:-未设置}"
  [[ "${INST_DIFY:-false}"    == "true" ]] && echo "    Dify Secret    : ${DIFY_SECRET:-未设置}"
  echo ""

  if [[ "${INST_SINGBOX:-false}" == "true" ]]; then
    echo -e "  ${W}sing-box AnyTLS${N}"
    echo "    端口段         : ${CLASH_PORT_MIN:-13443}-${CLASH_PORT_MAX:-13458}（每订阅一个）"
    if [[ -x "$(_clash_py)" ]]; then
      python3 "$(_clash_py)" --base "$(_clash_dir)" list --brief 2>/dev/null | sed 's/^/  /'
    else
      echo "    订阅信息       : 见菜单 → Clash 订阅管理 → 查询单条"
    fi
    echo ""
  fi

  if [[ "${DEPLOY_MODE:-}" == "distributed" ]]; then
    echo -e "  ${W}frp 内网穿透${N}"
    echo "    端口           : ${FRP_PORT:-未设置}"
    echo "    Token          : ${FRP_TOKEN:-未设置}"
    echo ""
  fi

  echo -e "  ${DIM}完整配置文件：cat ${BASE_DIR}/.env${N}"
}

# ═══════════════════════════════════════════════════════════════════
# PostgreSQL / Redis 连接配置查看
# ═══════════════════════════════════════════════════════════════════
show_db_connection() {
  print_header "PostgreSQL / Redis 连接配置"

  if [[ "${INST_SUB2API:-false}" == "true" ]]; then
    echo -e "  ${C}┌─ Sub2API → PostgreSQL ────────────────────────────┐${N}"
    echo -e "  ${C}│${N}  主机        ${W}ai-db${N}        Docker 容器名，同网络内自动解析"
    echo -e "  ${C}│${N}  端口        ${W}5432${N}         PostgreSQL 默认端口"
    echo -e "  ${C}│${N}  用户名      ${W}ai${N}           安装脚本创建的用户"
    echo -e "  ${C}│${N}  密码        ${W}见下方${N}       安装时随机生成"
    echo -e "  ${C}│${N}  数据库名称  ${W}sub2api${N}      安装脚本已自动创建"
    echo -e "  ${C}│${N}  SSL 模式    ${W}disable${N}      容器间内网通信，无需加密"
    echo -e "  ${C}│${N}  启用 TLS    ${W}否${N}           同上"
    echo -e "  ${C}│${N}"
    echo -e "  ${C}│${N}  ${DIM}密码保存在 .env 文件中，运行以下命令查看：${N}"
    echo -e "  ${C}│${N}  ${G}grep AI_DB_PASS ${BASE_DIR}/.env${N}"
    echo -e "  ${C}│${N}  ${DIM}状态：已自动配置（config.yaml）${N}"
    echo -e "  ${C}└────────────────────────────────────────────────────┘${N}"
    echo ""

    echo -e "  ${C}┌─ Sub2API → Redis ─────────────────────────────────┐${N}"
    echo -e "  ${C}│${N}  地址        ${W}ai-redis${N}     Docker 容器名，同网络自动解析"
    echo -e "  ${C}│${N}  端口        ${W}6379${N}         Redis 默认端口"
    echo -e "  ${C}│${N}  密码        ${W}留空${N}         容器内网无需密码"
    echo -e "  ${C}│${N}  数据库      ${W}0${N}            默认 DB"
    echo -e "  ${C}│${N}"
    echo -e "  ${C}│${N}  ${DIM}状态：已自动配置（config.yaml）${N}"
    echo -e "  ${C}└────────────────────────────────────────────────────┘${N}"
    echo ""
  fi

  if [[ "${INST_NEWAPI:-false}" == "true" ]]; then
    echo -e "  ${C}┌─ New-API → PostgreSQL ────────────────────────────┐${N}"
    echo -e "  ${C}│${N}  数据库      ${W}newapi${N}       安装脚本已自动创建"
    echo -e "  ${C}│${N}  连接方式    ${W}SQL_DSN${N}      环境变量自动注入"
    echo -e "  ${C}│${N}"
    echo -e "  ${C}│${N}  ${G}状态：已自动配置，无需手动操作${N}"
    echo -e "  ${C}└────────────────────────────────────────────────────┘${N}"
    echo ""
  fi
}

# ═══════════════════════════════════════════════════════════════════
# 配置查询与修改
# ═══════════════════════════════════════════════════════════════════
show_config() {
  while true; do
    print_header "配置查询与修改"

    if [[ ! -f "$BASE_DIR/.env" ]]; then
      warn "未找到 $BASE_DIR/.env，可能尚未安装"
      echo ""
      read -erp "  按回车返回..." _
      return 0
    fi

    source "$BASE_DIR/.env" 2>/dev/null
    detect_installed_services

    # 用实际检测结果同步 INST_* 变量（.env 可能缺失或过时）
    $SVC_NEWAPI_INSTALLED  && INST_NEWAPI=true
    $SVC_WEBUI_INSTALLED   && INST_WEBUI=true
    $SVC_LITELLM_INSTALLED && INST_LITELLM=true
    $SVC_SUB2API_INSTALLED && INST_SUB2API=true
    $SVC_DIFY_INSTALLED    && INST_DIFY=true
    $SVC_SINGBOX_INSTALLED && INST_SINGBOX=true
    $SVC_CADDY_INSTALLED   && INST_CADDY=true
    $SVC_PGSQL_INSTALLED   && INST_PGSQL=true
    $SVC_REDIS_INSTALLED   && INST_REDIS=true
    # VPS_IP 兜底
    [[ -z "${VPS_IP:-}" ]] && VPS_IP=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")

    # 运行状态
    echo -e "  ${W}运行状态${N}"
    for _entry in "${SVC_REGISTRY_STACK[@]}"; do
      IFS='|' read -r _key _name _type _target <<< "$_entry"
      local _var="SVC_${_key}_INSTALLED"
      local _status="${DIM}未安装${N}"
      if [[ "${!_var}" == "true" ]]; then
        if svc_running "$_type" "$_target"; then
          _status="${G}运行中${N}"
        else
          _status="${Y}已停止${N}"
        fi
      fi
      printf "    %-15s %b\n" "$_name" "$_status"
    done
    echo ""

    # 访问地址
    local _domain="${DOMAIN:-}"
    local _ip="${VPS_IP:-未知}"
    if [[ -n "$_domain" ]]; then
      echo -e "  ${W}访问地址${N}"
      [[ "${INST_NEWAPI:-false}"  == "true" ]] && printf "    %-10s → ${C}https://${PREFIX_NEWAPI}.${_domain}${N}  ${DIM}(${_ip}:13000)${N}\n" "New-API"
      [[ "${INST_WEBUI:-false}"   == "true" ]] && printf "    %-10s → ${C}https://${PREFIX_WEBUI}.${_domain}${N}   ${DIM}(${_ip}:13010)${N}\n" "OpenWebUI"
      [[ "${INST_LITELLM:-false}" == "true" ]] && printf "    %-10s → ${C}https://${PREFIX_LITELLM}.${_domain}${N}     ${DIM}(${_ip}:14000)${N}\n" "LiteLLM"
      [[ "${INST_SUB2API:-false}" == "true" ]] && printf "    %-10s → ${C}https://${PREFIX_SUB2API}.${_domain}${N}    ${DIM}(${_ip}:13001)${N}\n" "Sub2API"
      [[ "${INST_DIFY:-false}"    == "true" ]] && printf "    %-10s → ${C}https://${PREFIX_DIFY}.${_domain}${N}   ${DIM}(${_ip}:13080)${N}\n" "Dify"
    elif [[ -n "${VPS_IP:-}" ]]; then
      echo -e "  ${W}访问地址（HTTP 直连）${N}"
      [[ "${INST_NEWAPI:-false}"  == "true" ]] && echo "    New-API   → http://${_ip}:13000"
      [[ "${INST_WEBUI:-false}"   == "true" ]] && echo "    OpenWebUI → http://${_ip}:13010"
      [[ "${INST_LITELLM:-false}" == "true" ]] && echo "    LiteLLM   → http://${_ip}:14000"
      [[ "${INST_SUB2API:-false}" == "true" ]] && echo "    Sub2API   → http://${_ip}:13001"
      [[ "${INST_DIFY:-false}"    == "true" ]] && echo "    Dify      → http://${_ip}:13080"
    fi
    echo ""

    # 部署信息
    echo -e "  ${W}部署信息${N}"
    echo "    部署模式  : ${DEPLOY_MODE:-allinone}"
    [[ -n "$_domain" ]] && echo "    域名      : ${_domain}"
    [[ -n "${EMAIL:-}" ]] && echo "    LE 邮箱   : ${EMAIL}"
    echo "    配置文件  : ${BASE_DIR}/.env"
    echo ""

    # 菜单项（动态构建）
    local -a _menu_labels=()
    local -a _menu_actions=()
    _menu_labels+=("重新配置域名")
    _menu_actions+=("reconfig")
    _menu_labels+=("查看密钥信息")
    _menu_actions+=("secrets")
    if [[ "${INST_NEWAPI:-false}" == "true" ]]; then
      _menu_labels+=("刷新品牌资源（同步仓库 doc/ 下的 logo 等到 Caddy）")
      _menu_actions+=("brand")
    fi
    if [[ "${INST_SINGBOX:-false}" == "true" ]]; then
      _menu_labels+=("Clash 订阅管理（查询 / 新增 / 编辑 / 删除 / 默认值 / 刷新）")
      _menu_actions+=("clash_sub")
    fi
    if [[ "${INST_PGSQL:-false}" == "true" ]] || [[ "${INST_REDIS:-false}" == "true" ]]; then
      _menu_labels+=("查看 PostgreSQL / Redis 连接配置")
      _menu_actions+=("dbconn")
    fi
    local _m_cnt=${#_menu_labels[@]}

    for (( i=0; i<_m_cnt; i++ )); do
      printf "    ${W}[%d]${N} %s\n" "$((i+1))" "${_menu_labels[$i]}"
    done
    echo ""
    echo -e "    ${DIM}[0] 返回主菜单${N}"
    echo ""

    read -erp "  选择：" _input
    [[ -z "$_input" ]] && continue
    [[ "$_input" == "0" ]] && break

    if [[ "$_input" =~ ^[0-9]+$ ]] && [[ $_input -ge 1 ]] && [[ $_input -le $_m_cnt ]]; then
      case "${_menu_actions[$((_input-1))]}" in
        reconfig)
          reconfigure_domain ;;
        secrets)
          show_secrets
          echo ""
          read -erp "  按回车继续..." _ ;;
        brand)
          refresh_brand_assets
          echo ""
          read -erp "  按回车继续..." _ ;;
        clash_sub)
          refresh_clash_subscription
          echo ""
          read -erp "  按回车继续..." _ ;;
        dbconn)
          show_db_connection
          echo ""
          read -erp "  按回车继续..." _ ;;
      esac
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════
# 服务管理（启动 / 停止 / 重启）
# ═══════════════════════════════════════════════════════════════════
manage_services() {
  while true; do
    print_header "服务管理"

    if [[ ! -f "$BASE_DIR/.env" ]]; then
      warn "未找到配置文件，可能尚未安装"
      echo ""
      read -erp "  按回车返回..." _
      return 0
    fi

    source "$BASE_DIR/.env" 2>/dev/null
    detect_installed_services

    # 从注册表构建已安装的服务列表
    local -a _MSVCS=()
    for _entry in "${SVC_REGISTRY_STACK[@]}"; do
      IFS='|' read -r _key _name _type _target <<< "$_entry"
      local _var="SVC_${_key}_INSTALLED"
      [[ "${!_var}" == "true" ]] && _MSVCS+=("${_name}|${_type}|${_target}")
    done

    if [[ ${#_MSVCS[@]} -eq 0 ]]; then
      warn "未检测到已安装的服务"
      echo ""
      read -erp "  按回车返回..." _
      return 0
    fi

    # 构建带状态的菜单选项
    local -a _menu_opts=()
    local _scnt=${#_MSVCS[@]}
    for (( i=0; i<_scnt; i++ )); do
      IFS='|' read -r _name _type _svc <<< "${_MSVCS[$i]}"
      local _st="${DIM}未知${N}"
      if svc_running "$_type" "$_svc"; then
        _st="${G}运行中${N}"
      else
        _st="${Y}已停止${N}"
      fi
      _menu_opts+=("$(printf '%-15s  %b' "$_name" "$_st")")
    done

    echo -e "  ${DIM}选择服务后可启动/停止/重启${N}"
    echo ""
    echo -e "  ${DIM}────────────────────────────────${N}"
    for (( i=0; i<_scnt; i++ )); do
      echo -e "    $((i+1)). ${_menu_opts[$i]}"
    done
    echo ""
    echo -e "  ${DIM}输入编号（1-${_scnt}），或 0 返回${N}"
    echo ""

    local _input
    read -erp "  选择：" _input

    [[ "$_input" == "0" ]] || [[ -z "$_input" ]] && break

    if [[ "$_input" =~ ^[0-9]+$ ]] && (( _input >= 1 && _input <= _scnt )); then
      local _idx=$((_input - 1))
      IFS='|' read -r _name _type _svc <<< "${_MSVCS[$_idx]}"

      # 操作子菜单
      while true; do
        clear
        echo -e "${W}${C}  ── ${_name} ─────────────────────────────────────${N}"
        echo ""

        local _st_now="${DIM}未知${N}"
        if svc_running "$_type" "$_svc"; then
          _st_now="${G}运行中${N}"
        else
          _st_now="${Y}已停止${N}"
        fi
        echo -e "  当前状态：${_st_now}"
        echo ""

        input_choose "${_name} 操作" "启动" "停止" "重启"
        [[ $INPUT_RESULT -eq -1 ]] && break

        echo ""
        case $INPUT_RESULT in
          0)
            if [[ "$_type" == "docker" ]]; then
              dc_cmd start "$_svc"
            else
              systemctl start "$_svc" 2>&1
            fi
            log "$_name 已启动"
            ;;
          1)
            if [[ "$_type" == "docker" ]]; then
              dc_cmd stop "$_svc"
            else
              systemctl stop "$_svc" 2>&1
            fi
            log "$_name 已停止"
            ;;
          2)
            if [[ "$_type" == "docker" ]]; then
              dc_cmd restart "$_svc"
            else
              systemctl restart "$_svc" 2>&1
            fi
            log "$_name 已重启"
            ;;
        esac
        break_end
      done
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════
# 单服务镜像升级 / 回滚（仅 docker 类型服务）
# ═══════════════════════════════════════════════════════════════════
# 元数据布局（位于 BASE_DIR）：
#   upgrade/history/<svc>.log       每行：<UTC时间戳> <镜像引用> <镜像ID>
#   upgrade/db_backups/<svc>-*.sql.gz   pg_dump 自动备份（依赖 PG 的服务）
# 仅保留最近 5 代 image 记录与 5 份 DB 备份，避免磁盘膨胀。
# ═══════════════════════════════════════════════════════════════════

_UPGRADE_DIR()    { echo "${BASE_DIR}/upgrade"; }
_HISTORY_FILE()   { echo "$(_UPGRADE_DIR)/history/$1.log"; }
_DB_BACKUP_DIR()  { echo "$(_UPGRADE_DIR)/db_backups"; }
_KEEP_GENERATIONS=5

# 服务是否依赖 PostgreSQL（决定是否自动 pg_dump）
# new-api → newapi 库；sub2api → sub2api 库
_svc_pg_db() {
  case "$1" in
    new-api) echo "newapi" ;;
    sub2api) echo "sub2api" ;;
    *) echo "" ;;
  esac
}

# 取容器当前镜像引用（如 calciumion/new-api:latest）和镜像 ID
_svc_image_ref() {
  docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null
}
_svc_image_id() {
  docker inspect --format '{{.Image}}' "$1" 2>/dev/null
}

# 记录一代 image 历史；超过保留代数则截断（保留最近 N 行）
_record_image_history() {
  local _svc="$1" _ref="$2" _id="$3"
  local _f; _f=$(_HISTORY_FILE "$_svc")
  mkdir -p "$(dirname "$_f")"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ref" "$_id" >> "$_f"
  local _keep_lines=$_KEEP_GENERATIONS
  if [[ -s "$_f" ]] && (( $(wc -l < "$_f") > _keep_lines )); then
    tail -n "$_keep_lines" "$_f" > "${_f}.tmp" && mv "${_f}.tmp" "$_f"
  fi
}

# 自动 pg_dump（仅依赖 PG 的服务）。返回备份文件路径到全局 LAST_DB_BACKUP，无备份时为空。
LAST_DB_BACKUP=""
_dump_db_if_needed() {
  LAST_DB_BACKUP=""
  local _svc="$1"
  local _db; _db=$(_svc_pg_db "$_svc")
  [[ -z "$_db" ]] && return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq 'ai-db' || {
    warn "ai-db 容器未运行，跳过 ${_db} 数据库备份"
    return 0
  }
  local _dir; _dir=$(_DB_BACKUP_DIR)
  mkdir -p "$_dir"
  local _ts; _ts=$(date +%Y%m%d-%H%M%S)
  local _out="${_dir}/${_svc}-${_ts}.sql.gz"
  info "备份 ${_db} → ${_out}"
  if docker exec ai-db pg_dump -U ai "$_db" 2>/dev/null | gzip > "$_out"; then
    if [[ ! -s "$_out" ]]; then
      rm -f "$_out"
      warn "pg_dump 输出为空，已删除空文件"
      return 1
    fi
    LAST_DB_BACKUP="$_out"
    log "DB 备份完成：$(du -h "$_out" | awk '{print $1}')"
    # 清理过旧备份（按 mtime 倒序保留 N 份）
    ls -1t "$_dir"/${_svc}-*.sql.gz 2>/dev/null \
      | tail -n +$((_KEEP_GENERATIONS+1)) | xargs -r rm -f
  else
    rm -f "$_out"
    warn "pg_dump 失败，未生成备份"
    return 1
  fi
}

upgrade_single_service() {
  local _name="$1" _svc="$2"

  # 容器存在性
  if ! docker inspect "$_svc" &>/dev/null; then
    warn "容器 ${_svc} 不存在，无法升级（请先安装）"
    return 1
  fi

  # compose 中是否还存在该 service（防止 compose 文件被覆盖成空）
  if ! (cd "$BASE_DIR" && docker compose config --services 2>/dev/null | grep -Fxq "$_svc"); then
    warn "${BASE_DIR}/docker-compose.yml 中找不到 service '${_svc}'"
    info "可能被覆盖成空文件。请先到主菜单 → 安装 / 更新 重新生成 compose"
    return 1
  fi

  local _cur_ref _cur_id
  _cur_ref=$(_svc_image_ref "$_svc")
  _cur_id=$(_svc_image_id "$_svc")

  echo ""
  echo -e "  ${W}升级 ${_name}${N}"
  echo -e "    当前镜像  : ${C}${_cur_ref}${N}"
  echo -e "    镜像 ID   : ${DIM}${_cur_id}${N}"
  local _db; _db=$(_svc_pg_db "$_svc")
  [[ -n "$_db" ]] && echo -e "    数据库    : ${C}${_db}${N}（升级前自动 pg_dump）"
  echo ""
  local _go
  askyn _go "确认拉取新镜像并重建容器？" "y"
  $_go || { info "已取消"; return 0; }

  # 1) 备份 DB
  if [[ -n "$_db" ]]; then
    _dump_db_if_needed "$_svc" || warn "数据库备份失败，仍可继续，但回滚将无法恢复 DB"
  fi

  # 2) 记录旧 image（升级成功与否都是有效的回滚锚点）
  _record_image_history "$_svc" "$_cur_ref" "$_cur_id"

  # 3) 拉新镜像
  step "docker compose pull ${_svc}"
  if ! (cd "$BASE_DIR" && docker compose pull "$_svc"); then
    warn "镜像拉取失败"
    [[ -n "$LAST_DB_BACKUP" ]] && \
      echo -e "  ${DIM}DB 备份保留在：${LAST_DB_BACKUP}${N}"
    return 1
  fi

  # 拉完后 ref 仍指向同一个 image ID，说明远端没有更新版本——跳过重建
  local _post_pull_id
  _post_pull_id=$(docker image inspect "$_cur_ref" --format '{{.Id}}' 2>/dev/null)
  if [[ -n "$_post_pull_id" && "$_post_pull_id" == "$_cur_id" ]]; then
    info "镜像已是最新（${_cur_id:0:19}），跳过容器重建"
    [[ -n "$LAST_DB_BACKUP" ]] && \
      echo -e "  ${DIM}DB 备份保留在：${LAST_DB_BACKUP}${N}"
    return 0
  fi

  # 4) up -d 重建（--no-deps 防止重建依赖容器，例如 ai-db）
  step "docker compose up -d --no-deps ${_svc}"
  if ! (cd "$BASE_DIR" && docker compose up -d --no-deps "$_svc"); then
    warn "容器启动失败，准备回滚提示"
    echo ""
    echo -e "  ${R}启动失败${N}，可执行回滚："
    echo -e "    服务管理 → ${_name} → 回滚版本"
    [[ -n "$LAST_DB_BACKUP" ]] && \
      echo -e "    DB 恢复    : gunzip -c ${LAST_DB_BACKUP} | docker exec -i ai-db psql -U ai ${_db}"
    return 1
  fi

  # 5) 等就绪
  info "等待容器就绪（最多 60s）..."
  local _waited=0
  while (( _waited < 60 )); do
    local _status
    _status=$(docker inspect --format '{{.State.Status}}' "$_svc" 2>/dev/null || echo "")
    [[ "$_status" == "running" ]] && break
    sleep 3
    _waited=$((_waited+3))
  done

  local _new_id
  _new_id=$(_svc_image_id "$_svc")
  echo ""
  echo -e "  ${W}升级完成${N}"
  echo -e "    旧镜像 ID : ${DIM}${_cur_id}${N}"
  echo -e "    新镜像 ID : ${G}${_new_id}${N}"
  [[ -n "$LAST_DB_BACKUP" ]] && \
    echo -e "    DB 备份    : ${C}${LAST_DB_BACKUP}${N}"
  echo ""
  echo -e "  ${W}最近日志${N}"
  docker logs --tail 30 "$_svc" 2>&1 | sed 's/^/    /'
  echo ""
  log "${_name} 升级完成"
}

rollback_single_service() {
  local _name="$1" _svc="$2"
  local _f; _f=$(_HISTORY_FILE "$_svc")

  # compose 中是否还存在该 service
  if ! (cd "$BASE_DIR" && docker compose config --services 2>/dev/null | grep -Fxq "$_svc"); then
    warn "${BASE_DIR}/docker-compose.yml 中找不到 service '${_svc}'"
    info "请先到主菜单 → 安装 / 更新 重新生成 compose"
    return 1
  fi

  if [[ ! -s "$_f" ]]; then
    warn "无历史镜像记录（${_f} 不存在或为空）"
    info "首次回滚需先经历过一次升级。如需手动恢复，参考：docker images | grep ${_svc}"
    return 1
  fi

  echo ""
  echo -e "  ${W}回滚 ${_name}${N}"
  echo -e "    候选历史镜像（最新在下，最多 ${_KEEP_GENERATIONS} 代）："
  echo ""

  local -a _items=()
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _items+=("$_line")
  done < "$_f"

  local _cnt=${#_items[@]} _i
  for (( _i=0; _i<_cnt; _i++ )); do
    local _ts _ref _id
    read -r _ts _ref _id <<< "${_items[$_i]}"
    local _exists="${R}本地已删${N}"
    docker image inspect "$_id" &>/dev/null && _exists="${G}本地存在${N}"
    printf "    ${W}[%d]${N}  %s  %-40s  ${DIM}%s${N}  %b\n" \
      "$((_i+1))" "$_ts" "$_ref" "${_id:0:19}" "$_exists"
  done
  echo ""
  echo -e "    ${DIM}[0] 取消${N}"
  echo ""

  local _input
  read -erp "  选择回滚目标：" _input
  [[ "$_input" == "0" || -z "$_input" ]] && { info "已取消"; return 0; }

  if ! [[ "$_input" =~ ^[0-9]+$ ]] || (( _input < 1 || _input > _cnt )); then
    warn "无效编号"
    return 1
  fi

  local _target="${_items[$((_input-1))]}"
  local _ts _ref _id
  read -r _ts _ref _id <<< "$_target"

  if ! docker image inspect "$_id" &>/dev/null; then
    warn "本地已无该镜像（${_id:0:19}）。"
    echo -e "  ${DIM}如能从仓库重新拉取同一 digest，可手动 docker pull ${_ref} 后再试${N}"
    return 1
  fi

  # 取当前 image，作为"回滚的回滚"锚点
  local _cur_ref _cur_id
  _cur_ref=$(_svc_image_ref "$_svc")
  _cur_id=$(_svc_image_id "$_svc")

  echo ""
  echo -e "  将回滚到：${C}${_ref}${N}  ${DIM}(${_id:0:19})${N}"
  echo -e "  当前镜像：${C}${_cur_ref}${N}  ${DIM}(${_cur_id:0:19})${N}"
  echo ""

  # DB 恢复选项
  local _db; _db=$(_svc_pg_db "$_svc")
  local _restore_db=false
  local _backup=""
  if [[ -n "$_db" ]]; then
    local _dir; _dir=$(_DB_BACKUP_DIR)
    mapfile -t _bks < <(ls -1t "$_dir"/${_svc}-*.sql.gz 2>/dev/null || true)
    if (( ${#_bks[@]} > 0 )); then
      echo -e "  ${W}可用 DB 备份：${N}"
      local _j
      for (( _j=0; _j<${#_bks[@]}; _j++ )); do
        printf "    ${W}[%d]${N}  %s  ${DIM}%s${N}\n" \
          "$((_j+1))" "$(basename "${_bks[$_j]}")" \
          "$(date -r "${_bks[$_j]}" '+%F %T')"
      done
      echo -e "    ${DIM}[0] 不恢复 DB（仅切镜像）${N}"
      echo ""
      local _bin
      read -erp "  选择 DB 备份（默认 0）：" _bin
      _bin=${_bin:-0}
      if [[ "$_bin" =~ ^[0-9]+$ ]] && (( _bin >= 1 && _bin <= ${#_bks[@]} )); then
        _backup="${_bks[$((_bin-1))]}"
        _restore_db=true
      fi
    else
      info "无可用 DB 备份，仅切换镜像"
    fi
  fi

  local _go
  if $_restore_db; then
    warn "将覆盖 ${_db} 数据库内容（先 DROP 再 RESTORE），不可撤销"
    askyn _go "确认执行回滚？" "n"
  else
    askyn _go "确认切换镜像（不动数据库）？" "y"
  fi
  $_go || { info "已取消"; return 0; }

  # 把当前 image 也写一笔到历史，便于"回滚的回滚"
  _record_image_history "$_svc" "$_cur_ref" "$_cur_id"

  # 关键：不动 docker-compose.yml。
  # 用 docker tag 让当前 ref 重新指向旧 image ID。
  # compose up -d --force-recreate 重建容器即可加载到新 ref 指向的镜像。
  # 下次"升级镜像"会执行 docker compose pull，自然把 ref 拉回最新。
  if ! docker tag "$_id" "$_cur_ref"; then
    warn "docker tag 失败"
    return 1
  fi

  step "docker compose up -d --no-deps --force-recreate ${_svc}"
  if ! (cd "$BASE_DIR" && docker compose up -d --no-deps --force-recreate "$_svc"); then
    warn "容器重建失败"
    return 1
  fi

  # DB 恢复
  if $_restore_db; then
    step "恢复数据库 ${_db} ← ${_backup}"
    # 停服务，避免连接占用
    (cd "$BASE_DIR" && docker compose stop "$_svc") >/dev/null 2>&1
    if docker exec ai-db psql -U ai -d postgres -c \
      "DROP DATABASE IF EXISTS ${_db}; CREATE DATABASE ${_db} OWNER ai;" >/dev/null 2>&1; then
      if gunzip -c "$_backup" | docker exec -i ai-db psql -U ai -d "$_db" >/dev/null 2>&1; then
        log "数据库恢复完成"
      else
        warn "数据库恢复失败，请手动检查"
      fi
    else
      warn "无法重建库 ${_db}，跳过恢复"
    fi
    (cd "$BASE_DIR" && docker compose up -d --no-deps "$_svc") >/dev/null 2>&1
  fi

  echo ""
  log "${_name} 已回滚到 ${_ref}（${_id:0:19}）"
  echo -e "  ${DIM}本地 ref ${_cur_ref} 已重指向旧 image；下次执行升级会重新 pull 拉回最新版${N}"
  echo ""
  echo -e "  ${W}最近日志${N}"
  docker logs --tail 30 "$_svc" 2>&1 | sed 's/^/    /'
}

# ═══════════════════════════════════════════════════════════════════
# 顶层菜单：升级 / 回滚单服务
# 列出已安装的 docker 类服务，选服务 → 选升级或回滚
# ═══════════════════════════════════════════════════════════════════
upgrade_rollback_menu() {
  while true; do
    print_header "升级 / 回滚单服务"

    if [[ ! -f "$BASE_DIR/.env" ]]; then
      warn "未找到配置文件，可能尚未安装"
      echo ""
      read -erp "  按回车返回..." _
      return 0
    fi

    source "$BASE_DIR/.env" 2>/dev/null
    detect_installed_services

    # 列出所有已安装服务（docker + systemd）
    # docker 类：走 upgrade_single_service / rollback_single_service
    # systemd 类：走 upgrade_systemd_service / rollback_systemd_service
    local -a _SVCS=()
    for _entry in "${SVC_REGISTRY_STACK[@]}"; do
      IFS='|' read -r _key _name _type _target <<< "$_entry"
      [[ "$_type" != "docker" && "$_type" != "systemd" ]] && continue
      local _var="SVC_${_key}_INSTALLED"
      [[ "${!_var}" == "true" ]] && _SVCS+=("${_key}|${_name}|${_type}|${_target}")
    done

    if [[ ${#_SVCS[@]} -eq 0 ]]; then
      warn "未检测到已安装的服务"
      echo ""
      read -erp "  按回车返回..." _
      return 0
    fi

    local _scnt=${#_SVCS[@]} _i
    echo -e "  ${DIM}选择要升级或回滚的服务${N}"
    echo ""
    for (( _i=0; _i<_scnt; _i++ )); do
      local _key _name _type _svc
      IFS='|' read -r _key _name _type _svc <<< "${_SVCS[$_i]}"
      local _ver="${DIM}（未运行）${N}"
      if [[ "$_type" == "docker" ]]; then
        if docker inspect "$_svc" &>/dev/null; then
          local _r; _r=$(_svc_image_ref "$_svc")
          [[ -n "$_r" ]] && _ver="${C}${_r}${N}"
        fi
      else
        # systemd：取版本号
        case "$_svc" in
          sing-box)
            command -v sing-box &>/dev/null && \
              _ver="${C}sing-box $(sing-box version 2>/dev/null | awk '/sing-box/{print $2;exit}')${N}"
            ;;
          caddy)
            command -v caddy &>/dev/null && \
              _ver="${C}$(caddy version 2>/dev/null | head -1 | awk '{print $1}')${N}"
            ;;
        esac
      fi
      local _desc; _desc=$(svc_desc_by_key "$_key")
      printf "    ${W}[%d]${N}  %-12s  %b\n" "$((_i+1))" "$_name" "$_ver"
      [[ -n "$_desc" ]] && printf "         ${DIM}%s${N}\n" "$_desc"
    done
    echo ""
    echo -e "    ${DIM}[0] 返回上级菜单${N}"
    echo ""

    local _input
    read -erp "  选择服务：" _input
    [[ "$_input" == "0" || -z "$_input" ]] && break

    if ! [[ "$_input" =~ ^[0-9]+$ ]] || (( _input < 1 || _input > _scnt )); then
      warn "无效编号"
      sleep 1
      continue
    fi

    local _idx=$((_input - 1))
    local _key _name _type _svc
    IFS='|' read -r _key _name _type _svc <<< "${_SVCS[$_idx]}"

    while true; do
      clear
      echo -e "${W}${C}  ── ${_name} ─────────────────────────────────────${N}"
      echo ""
      if [[ "$_type" == "docker" ]]; then
        if docker inspect "$_svc" &>/dev/null; then
          echo -e "  当前镜像：${C}$(_svc_image_ref "$_svc")${N}"
          echo -e "  镜像 ID  ：${DIM}$(_svc_image_id "$_svc")${N}"
        else
          echo -e "  ${Y}容器不存在${N}"
        fi
      else
        # systemd
        case "$_svc" in
          sing-box)
            local _v; _v=$(sing-box version 2>/dev/null | awk '/sing-box/{print $2;exit}')
            [[ -n "$_v" ]] && echo -e "  当前版本：${C}sing-box ${_v}${N}" || echo -e "  ${Y}sing-box 未安装${N}"
            ;;
          caddy)
            local _v; _v=$(caddy version 2>/dev/null | head -1)
            [[ -n "$_v" ]] && echo -e "  当前版本：${C}${_v}${N}" || echo -e "  ${Y}caddy 未安装${N}"
            ;;
        esac
      fi

      local _hist; _hist=$(_HISTORY_FILE "$_svc")
      if [[ -s "$_hist" ]]; then
        echo -e "  历史代数：${G}$(wc -l < "$_hist")${N} 代可回滚"
      else
        echo -e "  历史代数：${DIM}0（升级一次后即可回滚）${N}"
      fi
      echo ""

      if [[ "$_type" == "docker" ]]; then
        input_choose "${_name} 操作" "升级镜像" "回滚版本"
      else
        input_choose "${_name} 操作" "升级版本" "回滚版本"
      fi
      [[ $INPUT_RESULT -eq -1 ]] && break

      echo ""
      case $INPUT_RESULT in
        0)
          if [[ "$_type" == "docker" ]]; then
            upgrade_single_service "$_name" "$_svc" || true
          else
            upgrade_systemd_service "$_name" "$_svc" || true
          fi
          ;;
        1)
          if [[ "$_type" == "docker" ]]; then
            rollback_single_service "$_name" "$_svc" || true
          else
            rollback_systemd_service "$_name" "$_svc" || true
          fi
          ;;
      esac
      break_end
    done
  done
}

# ═══════════════════════════════════════════════════════════════════
# systemd 类服务升级 / 回滚（sing-box / caddy）
# 元数据布局：
#   upgrade/history/<svc>.log     每行：<UTC时间> <旧版本> <备份引用>
#     - sing-box：备份引用 = 备份二进制路径
#     - caddy：备份引用 = apt 版本号字符串
#   upgrade/bin/sing-box-<ver>-<时间戳>   旧 sing-box 二进制
# ═══════════════════════════════════════════════════════════════════

_BIN_BACKUP_DIR() { echo "$(_UPGRADE_DIR)/bin"; }

_singbox_cur_ver() {
  command -v sing-box &>/dev/null || return 1
  sing-box version 2>/dev/null | awk '/sing-box/{print $2;exit}'
}
_singbox_latest_ver() {
  curl -fsSL --max-time 8 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
    | jq -r '.tag_name' 2>/dev/null | tr -d 'v'
}
_caddy_cur_ver() {
  command -v caddy &>/dev/null || return 1
  caddy version 2>/dev/null | head -1 | awk '{print $1}'
}

upgrade_systemd_service() {
  local _name="$1" _svc="$2"
  case "$_svc" in
    sing-box) _upgrade_singbox "$_name" ;;
    caddy)    _upgrade_caddy "$_name" ;;
    *) warn "未知 systemd 服务：${_svc}"; return 1 ;;
  esac
}

rollback_systemd_service() {
  local _name="$1" _svc="$2"
  case "$_svc" in
    sing-box) _rollback_singbox "$_name" ;;
    caddy)    _rollback_caddy "$_name" ;;
    *) warn "未知 systemd 服务：${_svc}"; return 1 ;;
  esac
}

# ───────────────── sing-box ─────────────────
_upgrade_singbox() {
  local _name="$1"
  local _cur _latest _arch
  _cur=$(_singbox_cur_ver) || { warn "sing-box 未安装"; return 1; }

  echo ""
  echo -e "  ${W}升级 ${_name}${N}"
  echo -e "    当前版本  : ${C}${_cur}${N}"
  info "查询 GitHub 最新版本..."
  _latest=$(_singbox_latest_ver)
  if [[ -z "$_latest" || ! "$_latest" =~ ^[0-9] ]]; then
    warn "无法获取最新版本（GitHub API 不可达）"
    return 1
  fi
  echo -e "    最新版本  : ${C}${_latest}${N}"
  if [[ "$_cur" == "$_latest" ]]; then
    info "已是最新，无需升级"
    return 0
  fi
  echo ""
  local _go
  askyn _go "确认升级到 ${_latest}？" "y"
  $_go || { info "已取消"; return 0; }

  case $(uname -m) in
    x86_64)  _arch="amd64" ;;
    aarch64) _arch="arm64" ;;
    armv7l)  _arch="armv7" ;;
    *) warn "不支持的架构：$(uname -m)"; return 1 ;;
  esac

  # 备份旧二进制
  local _bdir; _bdir=$(_BIN_BACKUP_DIR)
  mkdir -p "$_bdir"
  local _bak="${_bdir}/sing-box-${_cur}-$(date +%Y%m%d-%H%M%S)"
  if ! cp "$SINGBOX_BIN" "$_bak"; then
    warn "备份旧二进制失败"
    return 1
  fi
  log "旧二进制已备份：${_bak}"

  # 写历史栈
  local _f; _f=$(_HISTORY_FILE "sing-box")
  mkdir -p "$(dirname "$_f")"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_cur" "$_bak" >> "$_f"
  if [[ -s "$_f" ]] && (( $(wc -l < "$_f") > _KEEP_GENERATIONS )); then
    tail -n "$_KEEP_GENERATIONS" "$_f" > "${_f}.tmp" && mv "${_f}.tmp" "$_f"
    # 历史栈外的备份二进制清掉
    ls -1t "$_bdir"/sing-box-* 2>/dev/null | tail -n +$((_KEEP_GENERATIONS+1)) | xargs -r rm -f
  fi

  # 下载并安装
  step "下载 sing-box ${_latest}"
  if ! wget -qO /tmp/sb.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/v${_latest}/sing-box-${_latest}-linux-${_arch}.tar.gz"; then
    warn "下载失败"
    return 1
  fi
  if ! tar -xzf /tmp/sb.tar.gz -C /tmp/; then
    warn "解压失败"
    rm -f /tmp/sb.tar.gz
    return 1
  fi
  if ! install -m 755 "/tmp/sing-box-${_latest}-linux-${_arch}/sing-box" "$SINGBOX_BIN"; then
    warn "安装失败"
    return 1
  fi
  rm -rf /tmp/sb.tar.gz "/tmp/sing-box-${_latest}-linux-${_arch}"

  step "重启 sing-box"
  if systemctl restart sing-box; then
    sleep 2
    if systemctl is-active sing-box &>/dev/null; then
      log "sing-box 已升级到 $(_singbox_cur_ver)"
    else
      warn "服务未起来，可执行回滚（菜单 → 升级 / 回滚 → sing-box → 回滚版本）"
      systemctl status sing-box --no-pager 2>&1 | tail -20 | sed 's/^/    /'
    fi
  else
    warn "restart 失败"
  fi
}

_rollback_singbox() {
  local _name="$1"
  local _f; _f=$(_HISTORY_FILE "sing-box")
  if [[ ! -s "$_f" ]]; then
    warn "无历史记录，无法回滚（${_f} 不存在）"
    return 1
  fi

  local -a _items=()
  while IFS= read -r _l; do
    [[ -z "$_l" ]] && continue
    _items+=("$_l")
  done < "$_f"

  echo ""
  echo -e "  ${W}回滚 ${_name}${N}    ${DIM}（候选为升级前的旧版本）${N}"
  local _cnt=${#_items[@]} _i
  for (( _i=0; _i<_cnt; _i++ )); do
    local _ts _ver _bak
    read -r _ts _ver _bak <<< "${_items[$_i]}"
    local _exists="${R}备份缺失${N}"
    [[ -f "$_bak" ]] && _exists="${G}可用${N}"
    printf "    ${W}[%d]${N}  %s  ${C}%s${N}  ${DIM}%s${N}  %b\n" \
      "$((_i+1))" "$_ts" "$_ver" "$_bak" "$_exists"
  done
  echo ""
  echo -e "    ${DIM}[0] 取消${N}"
  echo ""
  local _input
  read -erp "  选择回滚目标：" _input
  [[ "$_input" == "0" || -z "$_input" ]] && { info "已取消"; return 0; }
  if ! [[ "$_input" =~ ^[0-9]+$ ]] || (( _input < 1 || _input > _cnt )); then
    warn "无效编号"; return 1
  fi
  local _ts _ver _bak
  read -r _ts _ver _bak <<< "${_items[$((_input-1))]}"
  if [[ ! -f "$_bak" ]]; then
    warn "备份文件已不存在：${_bak}"
    return 1
  fi

  local _go
  askyn _go "确认把 sing-box 回滚到 ${_ver}？" "n"
  $_go || { info "已取消"; return 0; }

  # 把当前版本也写一笔，便于"回滚的回滚"
  local _cur; _cur=$(_singbox_cur_ver)
  if [[ -n "$_cur" ]]; then
    local _bdir; _bdir=$(_BIN_BACKUP_DIR)
    mkdir -p "$_bdir"
    local _curbak="${_bdir}/sing-box-${_cur}-$(date +%Y%m%d-%H%M%S)"
    cp "$SINGBOX_BIN" "$_curbak" 2>/dev/null && \
      printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_cur" "$_curbak" >> "$_f"
  fi

  if ! install -m 755 "$_bak" "$SINGBOX_BIN"; then
    warn "二进制覆盖失败"
    return 1
  fi
  if systemctl restart sing-box; then
    sleep 2
    if systemctl is-active sing-box &>/dev/null; then
      log "sing-box 已回滚到 $(_singbox_cur_ver)"
    else
      warn "服务未起来"
      systemctl status sing-box --no-pager 2>&1 | tail -20 | sed 's/^/    /'
    fi
  else
    warn "restart 失败"
  fi
}

# ───────────────── caddy ─────────────────
_upgrade_caddy() {
  local _name="$1"
  local _cur; _cur=$(_caddy_cur_ver) || { warn "caddy 未安装"; return 1; }

  echo ""
  echo -e "  ${W}升级 ${_name}${N}"
  echo -e "    当前版本  : ${C}${_cur}${N}"
  info "apt update（仅 caddy 源）..."
  apt-get update -qq -o Dir::Etc::sourcelist="sources.list.d/caddy-stable.list" \
                       -o Dir::Etc::sourceparts="-" \
                       -o APT::Get::List-Cleanup="0" 2>&1 | tail -5

  local _candidate
  _candidate=$(apt-cache policy caddy 2>/dev/null | awk '/Candidate:/{print $2;exit}')
  echo -e "    候选版本  : ${C}${_candidate:-未知}${N}"
  if [[ -z "$_candidate" || "$_candidate" == "(none)" ]]; then
    warn "apt 看不到候选版本"
    return 1
  fi

  if dpkg --compare-versions "$_candidate" le "$(dpkg -s caddy 2>/dev/null | awk '/^Version:/{print $2}')" 2>/dev/null; then
    info "已是最新或更高版本，无需升级"
    return 0
  fi

  local _go
  askyn _go "确认升级 caddy 到 ${_candidate}？" "y"
  $_go || { info "已取消"; return 0; }

  # 写历史栈（升级前版本号）
  local _f; _f=$(_HISTORY_FILE "caddy")
  mkdir -p "$(dirname "$_f")"
  local _cur_apt; _cur_apt=$(dpkg -s caddy 2>/dev/null | awk '/^Version:/{print $2}')
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_cur" "${_cur_apt:-unknown}" >> "$_f"
  if [[ -s "$_f" ]] && (( $(wc -l < "$_f") > _KEEP_GENERATIONS )); then
    tail -n "$_KEEP_GENERATIONS" "$_f" > "${_f}.tmp" && mv "${_f}.tmp" "$_f"
  fi

  # 解锁（如果之前回滚 hold 过）
  apt-mark unhold caddy >/dev/null 2>&1 || true

  step "apt-get install --only-upgrade caddy"
  if ! apt-get install -y -qq --only-upgrade caddy; then
    warn "升级失败"
    return 1
  fi

  step "重载 caddy"
  systemctl reload caddy 2>&1 || systemctl restart caddy 2>&1
  sleep 1
  if systemctl is-active caddy &>/dev/null; then
    log "caddy 已升级到 $(_caddy_cur_ver)"
  else
    warn "服务未起来"
    systemctl status caddy --no-pager 2>&1 | tail -20 | sed 's/^/    /'
  fi
}

_rollback_caddy() {
  local _name="$1"
  local _f; _f=$(_HISTORY_FILE "caddy")
  if [[ ! -s "$_f" ]]; then
    warn "无历史记录，无法回滚（${_f} 不存在）"
    return 1
  fi

  echo ""
  echo -e "  ${W}回滚 ${_name}${N}    ${DIM}（候选为升级前的 apt 版本号）${N}"
  local -a _items=()
  while IFS= read -r _l; do
    [[ -z "$_l" ]] && continue
    _items+=("$_l")
  done < "$_f"

  local _cnt=${#_items[@]} _i
  for (( _i=0; _i<_cnt; _i++ )); do
    local _ts _ver _apt
    read -r _ts _ver _apt <<< "${_items[$_i]}"
    printf "    ${W}[%d]${N}  %s  ${C}%s${N}  ${DIM}apt:%s${N}\n" \
      "$((_i+1))" "$_ts" "$_ver" "$_apt"
  done
  echo ""
  echo -e "  ${DIM}提示：apt 仓库不一定保留历史版本，可执行 apt-cache madison caddy 查看实际可用版本${N}"
  echo -e "    ${DIM}[0] 取消    [m] 显示 apt-cache madison caddy${N}"
  echo ""

  local _input
  read -erp "  选择回滚目标：" _input
  if [[ "${_input,,}" == "m" ]]; then
    apt-cache madison caddy 2>&1 | sed 's/^/    /'
    echo ""
    read -erp "  选择回滚目标：" _input
  fi
  [[ "$_input" == "0" || -z "$_input" ]] && { info "已取消"; return 0; }
  if ! [[ "$_input" =~ ^[0-9]+$ ]] || (( _input < 1 || _input > _cnt )); then
    warn "无效编号"; return 1
  fi

  local _ts _ver _apt
  read -r _ts _ver _apt <<< "${_items[$((_input-1))]}"
  if [[ "$_apt" == "unknown" ]]; then
    warn "历史栈缺少 apt 版本号，无法精确降级"
    return 1
  fi

  # 检查 apt 仓库是否还有该版本
  if ! apt-cache madison caddy 2>/dev/null | grep -q " ${_apt} "; then
    warn "apt 仓库已不再提供版本 ${_apt}"
    info "可用版本：" && apt-cache madison caddy 2>&1 | sed 's/^/    /'
    return 1
  fi

  local _go
  askyn _go "降级 caddy 到 ${_apt} 并 hold（防自动升级）？" "n"
  $_go || { info "已取消"; return 0; }

  # 把当前版本也写一笔
  local _cur; _cur=$(_caddy_cur_ver)
  local _cur_apt; _cur_apt=$(dpkg -s caddy 2>/dev/null | awk '/^Version:/{print $2}')
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_cur:-unknown}" "${_cur_apt:-unknown}" >> "$_f"

  step "apt-get install caddy=${_apt}"
  if ! apt-get install -y -qq --allow-downgrades "caddy=${_apt}"; then
    warn "降级失败（仓库可能未提供该版本）"
    return 1
  fi
  apt-mark hold caddy >/dev/null 2>&1 || true
  log "caddy 已锁定在 ${_apt}（apt-mark hold）。下次升级前请先 apt-mark unhold caddy"

  systemctl reload caddy 2>&1 || systemctl restart caddy 2>&1
  sleep 1
  if systemctl is-active caddy &>/dev/null; then
    log "caddy 已回滚到 $(_caddy_cur_ver)"
  else
    warn "服务未起来"
    systemctl status caddy --no-pager 2>&1 | tail -20 | sed 's/^/    /'
  fi
}

