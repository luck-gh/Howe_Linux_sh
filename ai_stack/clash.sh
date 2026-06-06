#!/usr/bin/env bash
# Clash 多订阅子系统（路径 / 端口 / nft / ufw / 菜单）
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# Clash 订阅：多订阅管理
# ═══════════════════════════════════════════════════════════════════
# 目录结构：
#   $BASE_DIR/clash/
#     ├── nodes.yaml        节点池（纯节点，不含订阅元数据）
#     ├── template.yaml     Clash 配置模板（来自仓库 doc/vps.yaml）
#     ├── clash_subs.py     管理 + 渲染脚本（来自仓库 doc/clash_subs.py）
#     ├── subs.yaml         订阅列表（每条含 token / 流量 / 重置 / 到期）
#     ├── defaults.yaml     新增订阅默认值
#     └── output/<token>/clash.yaml   渲染产物
#
# 客户端订阅 URL：https://${PREFIX_VPS}.${DOMAIN}/sub/<token>
# Caddy 在响应中带 Subscription-Userinfo 头，客户端可显示剩余流量 / 到期
# ═══════════════════════════════════════════════════════════════════

_clash_dir() { echo "$BASE_DIR/clash"; }
_clash_py()  { echo "$(_clash_dir)/clash_subs.py"; }
_clash_stats_py() { echo "$(_clash_dir)/clash_subs_stats.py"; }
_clash_serve_py() { echo "$(_clash_dir)/clash_subs_serve.py"; }
CLASH_SERVE_PORT=13888

# 端口段（来自 clash_subs.py defaults，ufw allow 用）
_clash_port_range() {
  local _lo=13443 _hi=13458
  if [[ -x "$(_clash_py)" ]]; then
    local _v
    _v=$(python3 "$(_clash_py)" --base "$(_clash_dir)" get-setting port_min 2>/dev/null) && [[ -n "$_v" ]] && _lo=$_v
    _v=$(python3 "$(_clash_py)" --base "$(_clash_dir)" get-setting port_max 2>/dev/null) && [[ -n "$_v" ]] && _hi=$_v
  fi
  echo "${_lo}:${_hi}"
}

# 同步 Clash anytls 端口段到 ufw（幂等）
# - 删除 Phase 4 之前的单端口残留 8443/tcp
# - 删除已不匹配当前 port_min/port_max 的旧端口段
# - 加上当前端口段
# 配置查询/修改菜单里增删改订阅、刷新、改默认值都会触发
_sync_clash_ufw() {
  $INST_SINGBOX || return 0
  command -v ufw &>/dev/null || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0

  local _range; _range=$(_clash_port_range)

  # 清理 Phase 4 之前的单端口规则（SB_PORT=8443 时代）
  ufw delete allow 8443/tcp &>/dev/null || true

  # 清理已经不匹配的旧 Clash 端口段（用户调整过 port_min/port_max 时）
  local _old
  while read -r _old; do
    [[ -z "$_old" || "$_old" == "${_range}/tcp" ]] && continue
    ufw delete allow "$_old" &>/dev/null || true
  done < <(ufw status 2>/dev/null | awk '/Clash anytls subs/ && !/\(v6\)/ {print $1}')

  ufw allow "${_range}/tcp" comment 'Clash anytls subs' &>/dev/null || true
}

# 首次安装：拷贝模板 / 脚本，初始化 subs+defaults，写默认 nodes.yaml
setup_clash_subscription() {
  $INST_SINGBOX || return 0
  local _dir; _dir=$(_clash_dir)
  local _repo_doc="${_AI_STACK_DIR%/}/doc"
  mkdir -p "$_dir/output"

  if [[ ! -f "$_dir/template.yaml" ]]; then
    [[ -f "$_repo_doc/vps.yaml" ]] || { warn "未找到 $_repo_doc/vps.yaml"; return 1; }
    cp "$_repo_doc/vps.yaml" "$_dir/template.yaml"
    log "Clash 模板已就绪：$_dir/template.yaml"
  fi

  # 总是覆盖 clash_subs.py + clash_subs_stats.py + clash_subs_serve.py（脚本由仓库分发，用户不应改）
  [[ -f "$_repo_doc/clash_subs.py" ]] || { warn "未找到 $_repo_doc/clash_subs.py"; return 1; }
  cp "$_repo_doc/clash_subs.py" "$(_clash_py)"
  chmod 0755 "$(_clash_py)"
  [[ -f "$_repo_doc/clash_subs_stats.py" ]] || { warn "未找到 $_repo_doc/clash_subs_stats.py"; return 1; }
  cp "$_repo_doc/clash_subs_stats.py" "$(_clash_stats_py)"
  chmod 0755 "$(_clash_stats_py)"
  [[ -f "$_repo_doc/clash_subs_serve.py" ]] || { warn "未找到 $_repo_doc/clash_subs_serve.py"; return 1; }
  cp "$_repo_doc/clash_subs_serve.py" "$(_clash_serve_py)"
  chmod 0755 "$(_clash_serve_py)"
  rm -f "$_dir/render_clash_sub.py"   # 清理旧脚本

  if [[ ! -f "$_dir/nodes.yaml" ]]; then
    cat > "$_dir/nodes.yaml" <<NODESCFG
# Clash 节点池（订阅元数据已迁移到 subs.yaml）
# server / sni 决定 Clash 客户端连接的目标；port / password 在 render 时被订阅自身覆盖
# 编辑后运行：bash howe.sh → 配置查询与修改 → Clash 订阅管理 → 刷新
nodes:
  - name: vps-anytls
    server: ${VPS_IP:-YOUR_IP}
    port: 0
    password: PER_SUB
    type: anytls
    sni: ${VPS_IP:-YOUR_IP}
    skip_cert_verify: true
NODESCFG
    log "Clash 节点池已就绪：$_dir/nodes.yaml"
  fi

  python3 "$(_clash_py)" --base "$_dir" init >/dev/null

  # 把用户安装时填的端口段同步进 defaults.yaml
  if [[ -n "${CLASH_PORT_MIN:-}" ]] || [[ -n "${CLASH_PORT_MAX:-}" ]]; then
    local -a _da=(defaults)
    [[ -n "${CLASH_PORT_MIN:-}" ]] && _da+=(--port-min "$CLASH_PORT_MIN")
    [[ -n "${CLASH_PORT_MAX:-}" ]] && _da+=(--port-max "$CLASH_PORT_MAX")
    python3 "$(_clash_py)" --base "$_dir" "${_da[@]}" >/dev/null
  fi

  # 全新安装且无任何订阅：自动建一条 default
  # 不再传 --password，每订阅自动生成独立密码
  if [[ -z "$(python3 "$(_clash_py)" --base "$_dir" list --names 2>/dev/null)" ]]; then
    python3 "$(_clash_py)" --base "$_dir" add default \
      --traffic-gb 1000 --reset-day 1 --expire 2099-12-31 >/dev/null
    log "已创建默认订阅 default"
  fi

  setup_clash_stats_timer
  setup_clash_serve_service
}

# 部署流量统计 systemd unit + timer（每 stats_refresh_minutes 分钟运行）
setup_clash_stats_timer() {
  $INST_SINGBOX || return 0
  local _interval
  _interval=$(python3 "$(_clash_py)" --base "$(_clash_dir)" \
                get-setting stats_refresh_minutes 2>/dev/null || echo 1)
  [[ "$_interval" =~ ^[0-9]+$ ]] || _interval=1
  cat > /etc/systemd/system/clash-subs-stats.service <<UNIT
[Unit]
Description=Clash 订阅流量统计 + 限流执法
After=sing-box.service nftables.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $(_clash_stats_py) --base $(_clash_dir) --clash-subs $(_clash_py)
UNIT
  cat > /etc/systemd/system/clash-subs-stats.timer <<UNIT
[Unit]
Description=Clash 订阅流量统计定时器（每 ${_interval} 分钟）
[Timer]
OnBootSec=2min
OnUnitActiveSec=${_interval}min
AccuracySec=15s
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now clash-subs-stats.timer 2>/dev/null
  log "流量统计 timer 已启用（每 ${_interval} 分钟，按需刷新由 serve 主管）"
}

# 部署按需刷新 HTTP 服务（监听 127.0.0.1:13888，由 caddy /sub/* 反代过来）
# 客户端每次拉订阅都会触发一次 5 秒防抖的 stats 流水线，header 永远是最新数据
setup_clash_serve_service() {
  $INST_SINGBOX || return 0
  cat > /etc/systemd/system/clash-subs-serve.service <<UNIT
[Unit]
Description=Clash 订阅按需刷新 HTTP 服务（127.0.0.1:${CLASH_SERVE_PORT}）
After=sing-box.service nftables.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 $(_clash_serve_py) --base $(_clash_dir) --stats-py $(_clash_stats_py) --clash-subs $(_clash_py) --listen 127.0.0.1 --port ${CLASH_SERVE_PORT}
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now clash-subs-serve.service 2>/dev/null
  systemctl restart clash-subs-serve.service 2>/dev/null
  log "按需刷新服务已启用（127.0.0.1:${CLASH_SERVE_PORT}）"
}

# 渲染所有订阅
render_clash_subscription() {
  $INST_SINGBOX || return 0
  python3 "$(_clash_py)" --base "$(_clash_dir)" render --all
}

# 显示某条订阅的 URL
_clash_print_url() {
  local _name="$1"
  local _token
  _token=$(python3 "$(_clash_py)" --base "$(_clash_dir)" show "$_name" 2>/dev/null \
            | awk '/token/ {print $3; exit}')
  [[ -z "$_token" ]] && return 1
  local _host="${PREFIX_VPS:-vps}.${DOMAIN}"
  [[ -n "$DOMAIN" ]] || _host="${VPS_IP:-YOUR_IP}"
  echo -e "  ${W}订阅 ${_name} URL：${N}"
  echo -e "  ${C}https://${_host}/sub/${_token}/${_name}.yaml${N}"
}

# 子菜单：列出（仅简表）
_clash_menu_list() {
  echo ""
  python3 "$(_clash_py)" --base "$(_clash_dir)" list --brief
  echo ""
  local _host="${PREFIX_VPS:-vps}.${DOMAIN}"
  [[ -n "$DOMAIN" ]] || _host="${VPS_IP:-YOUR_IP}"
  echo -e "  ${DIM}URL 模板：https://${_host}/sub/<token>/<订阅名>.yaml${N}"
}

# 提示用户从 names 列表选择一条订阅，回显选中的名字
_clash_pick_one() {
  local _prompt="$1" _out_var="$2"
  local _names
  _names=$(python3 "$(_clash_py)" --base "$(_clash_dir)" list --names 2>/dev/null)
  if [[ -z "$_names" ]]; then
    warn "没有可用订阅"
    eval "$_out_var=''"
    return 1
  fi
  echo ""
  echo -e "  ${W}${_prompt}${N}"
  local -a _arr=()
  local _i=0
  while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    _arr+=("$_n")
    _i=$((_i+1))
    printf "    ${W}[%d]${N} %s\n" "$_i" "$_n"
  done <<< "$_names"
  echo ""
  local _in
  read -erp "  选择编号或直接输入名字（留空取消）：" _in
  if [[ -z "$_in" ]]; then
    eval "$_out_var=''"
    return 1
  fi
  if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 1 && _in <= ${#_arr[@]} )); then
    eval "$_out_var=\"\${_arr[$((_in-1))]}\""
    return 0
  fi
  # 精确匹配
  local _n
  for _n in "${_arr[@]}"; do
    if [[ "$_n" == "$_in" ]]; then
      eval "$_out_var=\"\$_in\""
      return 0
    fi
  done
  # 前缀匹配（唯一才接受）
  local -a _matches=()
  for _n in "${_arr[@]}"; do
    [[ "$_n" == "$_in"* ]] && _matches+=("$_n")
  done
  if (( ${#_matches[@]} == 1 )); then
    eval "$_out_var=\"\${_matches[0]}\""
    return 0
  elif (( ${#_matches[@]} > 1 )); then
    warn "前缀 ${_in} 匹配到多条：${_matches[*]}"
  else
    warn "未找到匹配的订阅：${_in}"
  fi
  eval "$_out_var=''"
  return 1
}

# 子菜单：查询单条
_clash_menu_show() {
  local _name
  _clash_pick_one "选择订阅查询" _name || return
  [[ -z "$_name" ]] && return
  echo ""
  python3 "$(_clash_py)" --base "$(_clash_dir)" show "$_name" || return
  echo ""
  _clash_print_url "$_name"
}

# 子菜单：新增
_clash_menu_add() {
  local _name
  ask _name "订阅名称（如 vip / cheap）"
  [[ -z "$_name" ]] && { warn "已取消"; return; }

  local -a _labels=(
    "流量上限 GB"
    "每月重置日 1-31"
    "到期日 YYYY-MM-DD"
    "客户端拉取间隔 小时"
    "AnyTLS 密码（留空自动生成）"
    "外购 Clash URL（留空继承全局，- 显式禁用）"
  )
  local -a _flags=(--traffic-gb --reset-day --expire --interval --password --external-url)
  local -a _values=("" "" "" "" "" "")
  local -a _hints=("" "" "" "" "" "")
  # 新增时显示"将继承的默认值"，用户能预知留空会得到什么
  local -a _originals=("" "" "" "" "" "")
  local -a _defs_keys=(traffic_gb reset_day "" interval "" external_url)
  declare -A _defs_kv=()
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _defs_kv[${_line%%=*}]=${_line#*=}
  done < <(python3 "$(_clash_py)" --base "$(_clash_dir)" field-values 2>/dev/null)
  local _i
  for (( _i=0; _i<${#_defs_keys[@]}; _i++ )); do
    local _k="${_defs_keys[$_i]}" _v=""
    if [[ -n "$_k" ]]; then
      _v=${_defs_kv[$_k]:-}
      [[ -n "$_v" ]] && _v="${DIM}默认: ${_v}${N}"
    fi
    _originals[$_i]="$_v"
  done

  _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存（留空字段使用默认值）" _hints _originals || true

  local -a _args=(add "$_name") i
  for (( i=0; i<${#_labels[@]}; i++ )); do
    [[ -n "${_values[$i]}" ]] && _args+=("${_flags[$i]}" "${_values[$i]}")
  done
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    python3 "$(_clash_py)" --base "$(_clash_dir)" render --name "$_name"
    write_caddyfile
    reload_clash_subscription
    _clash_print_url "$_name"
    info "如需配置静态 IP 策略与资源池，主菜单 → 静态 IP 资源管理"
  fi
}

# 解析 clash_subs.py field-values 输出 → 写入 originals 数组
# 用法：_clash_field_originals_from KEY1[,KEY2,...] [--name SUB] originals_var
# 返回：originals[i] = 各 key 对应的原值（按入参 keys 顺序）
_clash_field_originals_from() {
  local _keys=$1; shift
  local _name="" _out_var=""
  while (( $# > 0 )); do
    case "$1" in
      --name) _name=$2; shift 2 ;;
      *) _out_var=$1; shift ;;
    esac
  done
  [[ -z "$_out_var" ]] && return 1
  local -n _out_ref=$_out_var

  # 拉一次 field-values
  local _raw
  if [[ -n "$_name" ]]; then
    _raw=$(python3 "$(_clash_py)" --base "$(_clash_dir)" field-values --name "$_name" 2>/dev/null) || _raw=""
  else
    _raw=$(python3 "$(_clash_py)" --base "$(_clash_dir)" field-values 2>/dev/null) || _raw=""
  fi

  # key=value 解析进关联数组
  declare -A _kv=()
  local _line _k _v
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _k=${_line%%=*}
    _v=${_line#*=}
    _kv[$_k]=$_v
  done <<< "$_raw"

  # 按 _keys 顺序填 _out_ref
  local _key _i=0
  IFS=',' read -ra _arr <<< "$_keys"
  for _key in "${_arr[@]}"; do
    _out_ref[$_i]="${_kv[$_key]:-}"
    _i=$((_i+1))
  done
}


# 用法：
#   _values_var=收集结果的数组名（已在调用者声明 local -a，长度 = ${#_labels[@]}，初值空）
#   _labels_var=字段提示数组（label 列）
#   $3 = 头部说明文案
#   $4 = (可选) hints 数组名；hints[i] 非空时，选中字段 i 后会先弹一段说明
#   $5 = (可选) originals 数组名；originals[i] 非空时，未修改字段显示为原值
# 行为：
#   - 显示 [1..N] 字段当前暂存值；未改 = 原值（或 "(保持原值)"）；改了 = "[修改] xxx"
#   - 输入编号编辑该字段，编辑后光标自动到下一项
#   - 直接回车 = 编辑光标当前指向的字段
#   - 输入 0 = 完成；返回 0 表示有改动，1 表示未改任何字段
_clash_field_loop() {
  local _values_var=$1 _labels_var=$2 _hint=$3 _hints_var=${4:-} _originals_var=${5:-}
  local -n _values_ref=$_values_var
  local -n _labels_ref=$_labels_var
  local _n=${#_labels_ref[@]}
  local _cursor=1
  while true; do
    echo ""
    echo -e "  ${W}选择要编辑的字段${N} ${DIM}（${_hint}）${N}"
    local i
    for (( i=0; i<_n; i++ )); do
      local _shown
      if [[ -n "${_values_ref[$i]}" ]]; then
        # 用户已修改 → 高亮 [修改] 前缀
        _shown="${G}[修改]${N} ${_values_ref[$i]}"
      elif [[ -n "$_originals_var" ]]; then
        local _orig=""
        eval "_orig=\${${_originals_var}[$i]:-}"
        if [[ -n "$_orig" ]]; then
          _shown="$_orig"
        else
          _shown="${DIM}（保持原值）${N}"
        fi
      else
        _shown="${DIM}（保持原值）${N}"
      fi
      printf "    ${W}[%d]${N} %-22s : %b\n" "$((i+1))" "${_labels_ref[$i]}" "$_shown"
    done
    echo -e "    ${DIM}[0] 完成并保存${N}"
    echo ""

    local _input
    if ! read -erp "  字段编号（默认 [${_cursor}]）：" _input; then
      # stdin 关闭（非交互/heredoc 跑完）→ 视同 0 完成保存
      break
    fi

    local _idx
    if [[ -z "$_input" ]]; then
      _idx=$_cursor
    elif [[ "$_input" == "0" ]]; then
      break
    elif [[ "$_input" =~ ^[1-9][0-9]*$ ]] && (( _input >= 1 && _input <= _n )); then
      _idx=$_input
    else
      warn "无效编号"
      continue
    fi

    # 字段对应的扩展说明（可选；hints[idx-1] 非空时打印）
    if [[ -n "$_hints_var" ]]; then
      local _help=""
      eval "_help=\${${_hints_var}[$((_idx-1))]:-}"
      if [[ -n "$_help" ]]; then
        echo ""
        local _line
        while IFS= read -r _line; do
          echo -e "  ${DIM}${_line}${N}"
        done <<< "$_help"
        echo ""
      fi
    fi

    local _new
    ask _new "${_labels_ref[$((_idx-1))]}"
    _values_ref[$((_idx-1))]="$_new"

    _cursor=$(( _idx + 1 ))
    (( _cursor > _n )) && _cursor=1
  done

  local _i_chk _any=0
  for (( _i_chk=0; _i_chk<_n; _i_chk++ )); do
    [[ -n "${_values_ref[$_i_chk]}" ]] && { _any=1; break; }
  done
  (( _any == 1 ))
}

# 子菜单：编辑
_clash_menu_edit() {
  local _name
  _clash_pick_one "选择要编辑的订阅" _name || return
  [[ -z "$_name" ]] && { warn "已取消"; return; }
  python3 "$(_clash_py)" --base "$(_clash_dir)" show "$_name" || return

  local -a _labels=(
    "新名称"
    "流量上限 GB"
    "每月重置日 1-31"
    "到期日 YYYY-MM-DD"
    "客户端拉取间隔 小时"
    "AnyTLS 密码"
    "端口（必须在端口段内且未被占用）"
    "外购 Clash URL（- 清空回继承 / 留空保持原值）"
  )
  local -a _flags=(--rename --traffic-gb --reset-day --expire --interval --password --port \
                   --external-url)
  local -a _values=("" "" "" "" "" "" "" "")
  local -a _hints=("" "" "" "" "" "" "" "")
  # _labels 的字段顺序（8 项）→ field-values 的 key 顺序
  local -a _originals=("" "" "" "" "" "" "" "")
  _clash_field_originals_from \
    "rename,traffic_gb,reset_day,expire,interval,password,port,external_url" \
    --name "$_name" _originals

  if ! _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存" _hints _originals; then
    info "未修改任何字段"
    return
  fi

  local -a _args=(edit "$_name") i
  for (( i=0; i<${#_labels[@]}; i++ )); do
    [[ -n "${_values[$i]}" ]] && _args+=("${_flags[$i]}" "${_values[$i]}")
  done
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    local _final="${_values[0]:-$_name}"
    # 改完字段后跑一遍 stats 流水线：会做 enforce → render --all → 同步 nft
    # disabled_ports，让"扩额度/续期 → 立即恢复 / 缩额度 → 立即断网"即时生效
    python3 "$(_clash_stats_py)" --base "$(_clash_dir)" --clash-subs "$(_clash_py)" || \
      python3 "$(_clash_py)" --base "$(_clash_dir)" render --name "$_final"
    write_caddyfile
    reload_clash_subscription
    _clash_print_url "$_final"
  fi
}

# 子菜单：删除
_clash_menu_remove() {
  local _name _yn
  _clash_pick_one "选择要删除的订阅" _name || return
  [[ -z "$_name" ]] && { warn "已取消"; return; }
  askyn _yn "确认删除订阅 ${_name}？" "n"
  $_yn || { info "已取消"; return; }
  if python3 "$(_clash_py)" --base "$(_clash_dir)" remove "$_name"; then
    write_caddyfile
    reload_clash_subscription
  fi
}

# 子菜单：默认值
_clash_menu_defaults() {
  python3 "$(_clash_py)" --base "$(_clash_dir)" defaults
  local _old_s
  _old_s=$(python3 "$(_clash_py)" --base "$(_clash_dir)" get-setting stats_refresh_minutes 2>/dev/null)

  local -a _labels=(
    "默认流量 GB"
    "默认流量重置日 1-31"
    "默认到期天数（自今天起）"
    "默认客户端拉取间隔 小时"
    "默认流量统计刷新分钟数（serve 主管，timer 兜底）"
    "端口段下限（决定订阅可分配的最小端口）"
    "端口段上限（max - min + 1 = 最大订阅数）"
    "默认外购 Clash URL（留空 = 不启用）"
    "外购节点显示前缀"
    "静态 IP 节点显示前缀"
  )
  local -a _flags=(
    --traffic-gb --reset-day --expire-days --interval
    --stats-refresh-minutes --port-min --port-max
    --external-url --external-name-prefix
    --static-name-prefix
  )
  local -a _values=("" "" "" "" "" "" "" "" "" "")
  local -a _hints=("" "" "" "" "" "" "" "" "" "")
  local -a _originals=("" "" "" "" "" "" "" "" "" "")
  _clash_field_originals_from \
    "traffic_gb,reset_day,expire_days,interval,stats_refresh_minutes,port_min,port_max,external_url,external_name_prefix,static_name_prefix" \
    _originals

  if ! _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存" _hints _originals; then
    info "未修改任何字段"
    return
  fi

  local -a _args=(defaults) i
  for (( i=0; i<${#_labels[@]}; i++ )); do
    [[ -n "${_values[$i]}" ]] && _args+=("${_flags[$i]}" "${_values[$i]}")
  done
  python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"
  # stats_refresh_minutes 改了 → 重写 timer unit + restart
  local _new_s="${_values[4]}"
  if [[ -n "$_new_s" && "$_new_s" != "$_old_s" ]]; then
    setup_clash_stats_timer
  fi
}

# 子菜单：刷新所有
_clash_menu_refresh() {
  setup_clash_subscription || return 1
  python3 "$(_clash_py)" --base "$(_clash_dir)" clear-external-cache >/dev/null 2>&1 || true
  render_clash_subscription || return 1
  write_caddyfile
  reload_clash_subscription
  echo ""
  _clash_menu_list
}

# ═══════════════════════════════════════════════════════════════════
# 静态 IP 资源管理
# ═══════════════════════════════════════════════════════════════════
# 资源以 host:port:user:password 录入；同一份资源被多个订阅引用会自动去重。
# 修改后调用 reload_clash_subscription 触发 sing-box 重新加载（仅在 config 变化时 restart）。
# 录入对象有两层：
#   1) 全局默认池（defaults.yaml）—— 订阅 static_proxies 缺省时继承
#   2) 订阅独立池（subs.yaml.<sub>.static_proxies）—— 显式覆盖
# ═══════════════════════════════════════════════════════════════════
_static_input_hint() {
  echo -e "  ${DIM}格式：host:port:user:password（用户名留空时可写 host:port:password）${N}"
  echo -e "  ${DIM}多条：每行一条；或用逗号 / 分号在同一行隔开${N}"
  echo -e "  ${DIM}示例：1.2.3.4:1080:alice:s3cret${N}"
}

# 通用：选择目标（全局默认 / 某订阅）
# 把"全局默认"+所有订阅打成一个编号列表，只输一次编号就锁定目标
# 输出变量：STATIC_TARGET="" 表示默认；非空表示订阅名
_static_pick_target() {
  local _names
  _names=$(python3 "$(_clash_py)" --base "$(_clash_dir)" list --names 2>/dev/null)
  echo ""
  echo -e "  ${W}选择操作目标${N}"
  echo -e "    ${W}[1]${N} 全局默认池（所有订阅未自填时继承）"
  local -a _arr=()
  local _i=2 _n
  while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    _arr+=("$_n")
    printf "    ${W}[%d]${N} 订阅: %s\n" "$_i" "$_n"
    _i=$((_i+1))
  done <<< "$_names"
  echo -e "    ${DIM}[0 / 回车] 取消    [q] 退出菜单${N}"
  echo ""
  local _in
  read -erp "  编号：" _in
  case "$_in" in
    ""|0|y|Y|n|N) STATIC_TARGET=""; return 1 ;;
    q|Q) STATIC_TARGET=""; _STATIC_QUIT=1; return 1 ;;
    1) STATIC_TARGET=""; return 0 ;;
    *)
      if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 2 && _in - 1 <= ${#_arr[@]} )); then
        STATIC_TARGET="${_arr[$((_in-2))]}"
        return 0
      fi
      warn "无效编号"
      STATIC_TARGET=""
      return 1
      ;;
  esac
}

# 列出当前生效的资源池
_static_menu_list() {
  _static_pick_target || return
  echo ""
  if [[ -z "$STATIC_TARGET" ]]; then
    python3 "$(_clash_py)" --base "$(_clash_dir)" static-list
  else
    python3 "$(_clash_py)" --base "$(_clash_dir)" static-list --name "$STATIC_TARGET"
  fi
}

# 添加：单条 / 多条都用同一入口，blob 解析支持多行
_static_menu_add() {
  _static_pick_target || return
  echo ""
  _static_input_hint
  echo -e "  ${DIM}单条：直接粘贴一行；多条：粘贴多行后按 Ctrl-D 结束${N}"
  echo -e "  ${DIM}[0 / 直接 Ctrl-D] 取消    [q 后 Ctrl-D] 退出菜单${N}"
  echo ""
  echo -e "  ${W}请输入静态 IP（按 Ctrl-D 结束，留空取消）：${N}"
  local _blob
  _blob=$(cat) || true
  local _trim="${_blob//[[:space:]]/}"
  if [[ "$_trim" =~ ^[qQ]$ ]]; then
    _STATIC_QUIT=1; return
  fi
  if [[ -z "$_trim" || "$_trim" =~ ^[0yYnN]$ ]]; then
    info "已取消"
    return
  fi
  echo ""
  echo -e "  ${W}── 即将新增 ──${N}"
  python3 "$(_clash_py)" --base "$(_clash_dir)" parse-static-blob "$_blob" || {
    warn "解析后无有效条目,已取消"; return; }
  echo ""
  local _yn
  askyn _yn "确认追加?" "y"
  $_yn || { info "已取消"; return; }
  local -a _args
  if [[ -z "$STATIC_TARGET" ]]; then
    _args=(defaults --static-proxy-add "$_blob")
  else
    _args=(edit "$STATIC_TARGET" --static-proxy-add "$_blob")
  fi
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    log "已追加静态 IP"
    _static_apply_changes "$STATIC_TARGET"
  fi
}

# 删除：列表 → 选编号（支持多个，逗号 / 空格分隔）
_static_menu_remove() {
  _static_pick_target || return
  echo ""
  if [[ -z "$STATIC_TARGET" ]]; then
    python3 "$(_clash_py)" --base "$(_clash_dir)" static-list
  else
    python3 "$(_clash_py)" --base "$(_clash_dir)" static-list --name "$STATIC_TARGET"
  fi
  echo ""
  echo -e "  ${DIM}多个编号用空格或逗号分隔，例如：1 3 / 1,3 / 1-5 (区间)${N}"
  echo -e "  ${DIM}[0 / 回车] 取消    [q] 退出菜单${N}"
  local _in
  ask _in "要删除的编号"
  if [[ "$_in" =~ ^[qQ]$ ]]; then
    _STATIC_QUIT=1; return
  fi
  if [[ -z "$_in" || "$_in" == "0" || "$_in" =~ ^[yYnN]$ ]]; then
    info "已取消"; return
  fi
  # 展开 token: 单数字保留,a-b 展开为 a a+1 ... b
  local _tok _expanded=""
  for _tok in $(echo "$_in" | tr ',;' ' '); do
    [[ -z "$_tok" ]] && continue
    if [[ "$_tok" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
      local _a=${BASH_REMATCH[1]} _b=${BASH_REMATCH[2]} _i
      if (( _a > _b )); then warn "无效区间: $_tok（起>终）"; return; fi
      for (( _i=_a; _i<=_b; _i++ )); do _expanded+="$_i "; done
    elif [[ "$_tok" =~ ^[1-9][0-9]*$ ]]; then
      _expanded+="$_tok "
    else
      warn "无效编号: $_tok（必须是整数或 1-5 区间）"
      return
    fi
  done
  local -a _args
  if [[ -z "$STATIC_TARGET" ]]; then
    _args=(defaults)
  else
    _args=(edit "$STATIC_TARGET")
  fi
  for _tok in $_expanded; do
    _args+=(--static-proxy-remove "$_tok")
  done
  # 预览:列出将被删除的条目(根据展开后的编号筛 static-list 行)
  echo ""
  echo -e "  ${W}── 即将删除 ──${N}"
  local _list
  if [[ -z "$STATIC_TARGET" ]]; then
    _list=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list 2>&1)
  else
    _list=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list --name "$STATIC_TARGET" 2>&1)
  fi
  echo "$_list" | awk -v IDS="$_expanded" 'BEGIN{n=split(IDS,a," "); for(i=1;i<=n;i++) keep[a[i]]=1}
    /^  [0-9]+ / { if(keep[$1]) print "  -> "$0 }'
  echo ""
  local _yn
  askyn _yn "确认删除以上 $(echo $_expanded | wc -w) 条?" "y"
  $_yn || { info "已取消"; return; }
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    log "已删除静态 IP"
    _static_apply_changes "$STATIC_TARGET"
  fi
}

# 修改：批量累积 → 最后统一预览 → 确认后一次 CLI 下发
_static_menu_modify() {
  _static_pick_target || return
  echo ""
  local _list
  if [[ -z "$STATIC_TARGET" ]]; then
    _list=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list)
  else
    _list=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list --name "$STATIC_TARGET")
  fi
  echo "$_list"
  echo ""
  declare -A _changes=()
  while true; do
    local _idx
    echo -e "  ${DIM}已暂存 ${#_changes[@]} 项变更    [0 / 回车] 完成    [c] 清空暂存    [q] 退出菜单${N}"
    ask _idx "要修改的编号"
    if [[ "$_idx" =~ ^[qQ]$ ]]; then
      _STATIC_QUIT=1; return
    fi
    if [[ "$_idx" =~ ^[cC]$ ]]; then
      _changes=(); info "已清空暂存"; continue
    fi
    if [[ -z "$_idx" || "$_idx" == "0" || "$_idx" =~ ^[yYnN]$ ]]; then
      break
    fi
    if ! [[ "$_idx" =~ ^[1-9][0-9]*$ ]]; then
      warn "无效编号"; continue
    fi
    echo -e "  ${DIM}格式 [annotation:]host:port:user:password    [0] 取消该项${N}"
    local _line
    ask _line "新内容"
    if [[ -z "$_line" || "$_line" == "0" ]]; then
      info "已取消该项"; continue
    fi
    # 验证可解析
    local _parsed
    _parsed=$(python3 "$(_clash_py)" --base "$(_clash_dir)" parse-static-blob "$_line" 2>&1)
    if [[ "$_parsed" != 共\ 1\ 条* ]]; then
      warn "解析失败,跳过该项"; echo "$_parsed"; continue
    fi
    _changes[$_idx]="$_line"
    info "已暂存 [${_idx}] → ${_line}"
  done

  if [[ ${#_changes[@]} -eq 0 ]]; then
    info "无变更,已取消"; return
  fi

  # 统一 diff 预览
  echo ""
  echo -e "  ${W}── 改动预览 (${#_changes[@]} 项) ──${N}"
  local _idx _line
  for _idx in $(echo "${!_changes[@]}" | tr ' ' '\n' | sort -n); do
    _line="${_changes[$_idx]}"
    echo -e "  ${W}[${_idx}]${N}"
    echo -e "    ${DIM}原:${N} $(echo "$_list" | awk -v ID="$_idx" '$1==ID')"
    echo -e "    ${G}新:${N}    $(python3 "$(_clash_py)" --base "$(_clash_dir)" parse-static-blob "$_line" | tail -1)"
  done
  echo ""
  local _yn
  askyn _yn "确认提交以上 ${#_changes[@]} 项变更?" "y"
  $_yn || { info "已取消"; return; }

  # 一次 CLI: 所有 remove + 所有 add (Python 端 cmd_edit 先处理 rems 再 adds,且降序删避免漂移)
  local -a _args
  if [[ -z "$STATIC_TARGET" ]]; then
    _args=(defaults)
  else
    _args=(edit "$STATIC_TARGET")
  fi
  for _idx in "${!_changes[@]}"; do
    _args+=(--static-proxy-remove "$_idx" --static-proxy-add "${_changes[$_idx]}")
  done
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    log "已修改 ${#_changes[@]} 条静态 IP"
    _static_apply_changes "$STATIC_TARGET"
  fi
}

# 替换：粘贴新资源池整体覆盖
_static_menu_replace() {
  _static_pick_target || return
  echo ""
  echo -e "  ${W}替换静态 IP 资源池（覆盖现有）${N}"
  _static_input_hint
  echo -e "  ${DIM}[0 / 直接 Ctrl-D] 取消    [q 后 Ctrl-D] 退出菜单${N}"
  echo ""
  echo -e "  ${W}请输入新资源（按 Ctrl-D 结束，留空取消）：${N}"
  local _blob
  _blob=$(cat) || true
  local _trim="${_blob//[[:space:]]/}"
  if [[ "$_trim" =~ ^[qQ]$ ]]; then
    _STATIC_QUIT=1; return
  fi
  if [[ -z "$_trim" || "$_trim" =~ ^[0yYnN]$ ]]; then
    info "已取消"
    return
  fi
  echo ""
  echo -e "  ${W}── 整体替换为以下资源池 ──${N}"
  python3 "$(_clash_py)" --base "$(_clash_dir)" parse-static-blob "$_blob" || {
    warn "解析后无有效条目,已取消"; return; }
  echo ""
  local _yn
  askyn _yn "确认整体替换? (现有资源池将被覆盖)" "n"
  $_yn || { info "已取消"; return; }
  local -a _args
  if [[ -z "$STATIC_TARGET" ]]; then
    _args=(defaults --static-proxies "$_blob")
  else
    _args=(edit "$STATIC_TARGET" --static-proxies "$_blob")
  fi
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    log "已替换静态 IP 资源池"
    _static_apply_changes "$STATIC_TARGET"
  fi
}

# 清空：订阅级 = 回继承默认；默认级 = 全部清空
_static_menu_clear() {
  _static_pick_target || return
  local _yn
  if [[ -z "$STATIC_TARGET" ]]; then
    askyn _yn "确认清空全局默认资源池？（所有订阅的继承会变为空）" "n"
  else
    askyn _yn "确认让 ${STATIC_TARGET} 回到继承全局默认？" "n"
  fi
  $_yn || { info "已取消"; return; }
  local -a _args
  if [[ -z "$STATIC_TARGET" ]]; then
    _args=(defaults --static-proxies "")
  else
    _args=(edit "$STATIC_TARGET" --static-proxies "-")
  fi
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    log "已清空"
    _static_apply_changes "$STATIC_TARGET"
  fi
}

# 改完资源后：重渲染 + reload sing-box（资源变 → outbounds 变 → 必须 restart）
_static_apply_changes() {
  local _name="${1:-}"
  if [[ -n "$_name" ]]; then
    python3 "$(_clash_py)" --base "$(_clash_dir)" render --name "$_name" >/dev/null 2>&1 || true
  else
    # 默认池变了 → 所有"继承默认"的订阅都需要重渲染
    python3 "$(_clash_py)" --base "$(_clash_dir)" render --all >/dev/null 2>&1 || true
  fi
  write_caddyfile
  reload_clash_subscription
}

# 静态 IP 总览：打印全局默认 + 各订阅的策略 / 服务包 / 关键词 / 资源数
_static_print_overview() {
  local _kv _line
  echo -e "  ${W}── 全局默认 ──${N}"
  declare -A _g=()
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _g[${_line%%=*}]=${_line#*=}
  done < <(python3 "$(_clash_py)" --base "$(_clash_dir)" field-values 2>/dev/null)
  local _g_pool_n
  _g_pool_n=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list 2>/dev/null \
              | awk 'NR==1{print $0}')
  printf "    策略       : %s\n"   "${_g[static_strategy]:-?}"
  printf "    服务包     : %s\n"   "${_g[static_service_packs]:-(空)}"
  printf "    自定义关键词: %s\n"  "${_g[static_custom_keywords]:-(空)}"
  printf "    资源池     : %s\n"   "${_g_pool_n:-(无)}"
  echo ""
  # 各订阅
  local _names
  _names=$(python3 "$(_clash_py)" --base "$(_clash_dir)" list --names 2>/dev/null)
  if [[ -z "$_names" ]]; then
    echo -e "  ${DIM}(尚无订阅)${N}"
    return
  fi
  echo -e "  ${W}── 各订阅 ──${N}"
  local _n
  while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    declare -A _s=()
    while IFS= read -r _line; do
      [[ -z "$_line" ]] && continue
      _s[${_line%%=*}]=${_line#*=}
    done < <(python3 "$(_clash_py)" --base "$(_clash_dir)" field-values --name "$_n" 2>/dev/null)
    local _pool
    _pool=$(python3 "$(_clash_py)" --base "$(_clash_dir)" static-list --name "$_n" 2>/dev/null \
            | awk 'NR==1{print $0}')
    printf "    %-16s 策略=%s  服务包=%s  关键词=%s  资源=%s\n" \
      "$_n" \
      "${_s[static_strategy]:-?}" \
      "${_s[static_service_packs]:-(空)}" \
      "${_s[static_custom_keywords]:-(空)}" \
      "${_pool:-(无)}"
  done <<< "$_names"
}

# 编辑某目标（默认 / 订阅）的静态 IP 策略字段（策略 / 服务包 / 关键词）
# 字段循环：[1] 策略  [2] 服务包  [3] 自定义关键词；[1][2] 走 ID 选择器，[3] 文本输入
_static_menu_strategy() {
  _static_pick_target || return
  local _target="$STATIC_TARGET"
  local _label
  if [[ -z "$_target" ]]; then _label="全局默认"; else _label="订阅 ${_target}"; fi

  # 读取原值用于显示
  declare -A _cur=()
  local _line
  local -a _fv_args=(field-values)
  [[ -n "$_target" ]] && _fv_args+=(--name "$_target")
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _cur[${_line%%=*}]=${_line#*=}
  done < <(python3 "$(_clash_py)" --base "$(_clash_dir)" "${_fv_args[@]}" 2>/dev/null)

  # 待提交值（空 = 不修改；"-" = 清空回继承）
  local _strat="" _packs="" _kws=""

  while true; do
    clear
    echo -e "  ${W}── 静态 IP 策略：${_label} ──${N}"
    echo ""
    local _v1 _v2 _v3
    if [[ -n "$_strat" ]]; then _v1="${G}[修改]${N} $_strat"
    else _v1="${DIM}${_cur[static_strategy]:-?}${N}"; fi
    if [[ -n "$_packs" ]]; then _v2="${G}[修改]${N} $_packs"
    else _v2="${DIM}${_cur[static_service_packs]:-(空)}${N}"; fi
    if [[ -n "$_kws" ]]; then _v3="${G}[修改]${N} $_kws"
    else _v3="${DIM}${_cur[static_custom_keywords]:-(空)}${N}"; fi
    echo -e "    ${W}[1]${N} 静态 IP 策略 off/on                         : $_v1"
    echo -e "    ${W}[2]${N} 静态 IP 服务包 ai,streaming,banking,social,ip : $_v2"
    echo -e "    ${W}[3]${N} 静态 IP 自定义关键词（如 openai,claude）    : $_v3"
    echo -e "    ${DIM}[0/Y/回车] 完成并保存    [N] 放弃修改返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  编号：" _in

    case "$_in" in
      q|Q)
        if [[ -n "$_strat$_packs$_kws" ]]; then
          info "已放弃未保存的修改"
        fi
        _STATIC_QUIT=1
        return
        ;;
      n|N)
        if [[ -n "$_strat$_packs$_kws" ]]; then
          info "已放弃未保存的修改"
        fi
        return
        ;;
      0|y|Y|"")
        if [[ -z "$_strat" && -z "$_packs" && -z "$_kws" ]]; then
          info "未修改任何字段"
          return
        fi
        local -a _args
        if [[ -z "$_target" ]]; then _args=(defaults); else _args=(edit "$_target"); fi
        [[ -n "$_strat" ]] && _args+=(--static-strategy "$_strat")
        [[ -n "$_packs" ]] && _args+=(--static-service-packs "$_packs")
        [[ -n "$_kws"   ]] && _args+=(--static-custom-keywords "$_kws")
        if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
          log "策略已更新"
          _static_apply_changes "$_target"
        fi
        return
        ;;
      1)
        echo ""
        echo -e "    ${W}[1]${N} off  不启用静态 IP"
        echo -e "    ${W}[2]${N} on   启用静态 IP（生成 静态IP 子组并按关键词注入 rules）"
        [[ -n "$_target" ]] && echo -e "    ${W}[3]${N} 清空回继承默认"
        echo -e "    ${DIM}[0 / 回车] 取消    [q] 退出菜单${N}"
        echo ""
        local _x
        read -erp "  策略编号：" _x
        case "$_x" in
          1) _strat="off" ;;
          2) _strat="on" ;;
          3) [[ -n "$_target" ]] && _strat="-" || warn "全局默认无可继承对象" ;;
          q|Q) _STATIC_QUIT=1; return ;;
          0|y|Y|n|N|"") ;;
          *) warn "无效编号" ;;
        esac
        ;;
      2)
        echo ""
        echo -e "  ${DIM}选中后这些预设关键词会被注入 rules，命中即走 静态IP 组${N}"
        echo -e "  ${DIM}（DOMAIN-KEYWORD 子串匹配；多个服务包合并去重，原 rules 顺序保留在后）${N}"
        echo ""
        echo -e "    ${W}[1] ai${N}        AI 推理 / 助手类，按地区风控严格，常需固定海外住宅 IP"
        echo -e "        ${DIM}openai     ChatGPT / GPT API：账号封禁敏感，IP 跳变易触发风控${N}"
        echo -e "        ${DIM}anthropic  Claude API / claude.ai：地区限制 + IP 信誉检查${N}"
        echo -e "        ${DIM}claude     claude.ai 主域名${N}"
        echo -e "        ${DIM}chatgpt    chat.openai.com 历史域名${N}"
        echo -e "        ${DIM}perplexity perplexity.ai：部分功能要求稳定 IP${N}"
        echo -e "        ${DIM}googleapis Gemini / Vertex / Google Cloud API：账号常绑 IP${N}"
        echo ""
        echo -e "    ${W}[2] streaming${N} 流媒体平台，按授权地区放内容，IP 国别决定可看片库"
        echo -e "        ${DIM}netflix      Netflix：检测代理 IP 严，住宅 IP 才稳${N}"
        echo -e "        ${DIM}disneyplus   Disney+：地区授权严格${N}"
        echo -e "        ${DIM}hulu         Hulu：仅美国可看，必须美国 IP${N}"
        echo -e "        ${DIM}primevideo   Amazon Prime Video：按区放内容${N}"
        echo -e "        ${DIM}spotify      Spotify：账号注册地与 IP 绑定，跳区会被锁${N}"
        echo ""
        echo -e "    ${W}[3] banking${N}   支付 / 跨境金融，登录强校验 IP 一致性，跳变易冻结账户"
        echo -e "        ${DIM}paypal     PayPal：账号风控对 IP 漂移极敏感${N}"
        echo -e "        ${DIM}wise       Wise (TransferWise)：跨境汇款 KYC 验 IP${N}"
        echo -e "        ${DIM}stripe     Stripe Dashboard：商户后台、登录验 IP${N}"
        echo ""
        echo -e "    ${W}[4] social${N}    海外社交，账号注册期/敏感操作要求 IP 稳定不闪变"
        echo -e "        ${DIM}twitter    twitter.com / x.com：注册/改资料/发文易触发挑战${N}"
        echo -e "        ${DIM}facebook   facebook.com：登录验 IP 严，跨国跳易锁号${N}"
        echo -e "        ${DIM}instagram  instagram.com：与 facebook 共用风控基础设施${N}"
        echo ""
        echo -e "    ${W}[5] ip${N}        IP 检测站，专门用来验证当前出口 IP 是否真的走了静态"
        echo -e "        ${DIM}ippure / ipapi / ipinfo / myip / ip.sb / ipify${N}"
        echo -e "        ${DIM}icanhazip / ifconfig.me / ipchaxun / whatismyip${N}"
        echo -e "        ${DIM}选中后访问这些站点会自动走 静态IP 组，方便边切边验证${N}"
        echo ""
        [[ -n "$_target" ]] && echo -e "    ${W}[6]${N} 清空回继承默认"
        echo -e "    ${DIM}[0 / 回车] 取消    [q] 退出菜单${N}"
        echo ""
        local _x
        read -erp "  服务包编号：" _x
        if [[ "$_x" =~ ^[qQ]$ ]]; then
          _STATIC_QUIT=1; return
        fi
        if [[ -z "$_x" || "$_x" == "0" || "$_x" =~ ^[yYnN]$ ]]; then
          :
        else
          local -a _pn=(ai streaming banking social ip) _picked=()
          local _tok _has_clear=0 _has_bad=0
          for _tok in $(echo "$_x" | tr ',' ' '); do
            [[ -z "$_tok" ]] && continue
            if [[ "$_tok" == "6" && -n "$_target" ]]; then
              _has_clear=1
            elif [[ "$_tok" =~ ^[1-5]$ ]]; then
              _picked+=("${_pn[$((_tok-1))]}")
            else
              _has_bad=1; warn "无效编号: $_tok"
            fi
          done
          if (( _has_clear == 1 )); then
            _packs="-"
          elif (( ${#_picked[@]} > 0 )); then
            local -A _seen=()
            local -a _uniq=()
            for _tok in "${_picked[@]}"; do
              [[ -z "${_seen[$_tok]:-}" ]] && { _uniq+=("$_tok"); _seen[$_tok]=1; }
            done
            _packs=$(IFS=,; echo "${_uniq[*]}")
          elif (( _has_bad == 1 )); then
            warn "全部输入无效，未修改"
          fi
        fi
        ;;
      3)
        echo ""
        if [[ -n "$_target" ]]; then
          echo -e "  ${DIM}留空 = 不修改；输入 - = 清空回继承默认；输入 q = 退出菜单${N}"
        else
          echo -e "  ${DIM}留空 = 不修改；输入 q = 退出菜单${N}"
        fi
        local _x
        ask _x "自定义关键词（逗号分隔，如 openai,claude）"
        if [[ "$_x" =~ ^[qQ]$ ]]; then
          _STATIC_QUIT=1; return
        fi
        if [[ "$_x" =~ ^[yYnN]$ ]]; then
          :
        else
          _kws="$_x"
        fi
        ;;
      *) warn "无效编号" ;;
    esac
  done
}

# 静态 IP 资源管理子菜单
_clash_menu_static() {
  _STATIC_QUIT=0
  while true; do
    print_header "静态 IP 资源管理"
    _static_print_overview
    echo ""
    echo -e "    ${W}[1]${N} 编辑策略 / 服务包 / 关键词（默认 或 某订阅）"
    echo -e "    ${W}[2]${N} 列出资源（生效池）"
    echo -e "    ${W}[3]${N} 添加资源（[annotation:]host:port:user:password；预览后确认）"
    echo -e "    ${W}[4]${N} 修改资源（按编号选；输入完整新行；预览后确认）"
    echo -e "    ${W}[5]${N} 删除资源（按编号选；预览后确认）"
    echo -e "    ${W}[6]${N} 整体替换（覆盖；预览后确认）"
    echo -e "    ${W}[7]${N} 清空（订阅级 = 回继承）"
    echo ""
    echo -e "    ${DIM}[0 / 回车] 返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _static_menu_strategy ;;
      2) _static_menu_list ;;
      3) _static_menu_add ;;
      4) _static_menu_modify ;;
      5) _static_menu_remove ;;
      6) _static_menu_replace ;;
      7) _static_menu_clear ;;
      0|y|Y|n|N|"") break ;;
      q|Q) _STATIC_QUIT=1 ;;
      *) warn "无效选项" ;;
    esac
    (( _STATIC_QUIT == 1 )) && { _STATIC_QUIT=0; break; }
    echo ""
    read -erp "  按回车继续..." _
  done
}

# ═══════════════════════════════════════════════════════════════════
# IP 检测（节点名后缀 (宅/机-质量分)）
# ═══════════════════════════════════════════════════════════════════

_quality_get() {
  python3 "$(_clash_py)" --base "$(_clash_dir)" get-setting "$1" 2>/dev/null
}

_quality_set() {
  python3 "$(_clash_py)" --base "$(_clash_dir)" defaults "$@" >/dev/null
}

_quality_toggle() {
  local _key=$1 _label=$2
  local _cur; _cur=$(_quality_get "$_key")
  local _new; [[ "$_cur" == "on" ]] && _new="off" || _new="on"
  _quality_set "--${_key//_/-}" "$_new"
  info "${_label} 已切换为 ${_new}"
}

_quality_set_source() {
  echo ""
  echo -e "  ${W}选择 IP 质量检测数据源${N}"
  echo -e "  ${DIM}──────────────────────────────────${N}"
  echo -e "    [1] free          ${DIM}— proxycheck API,匿名 100/天 或带 key 1000/天${N}"
  echo -e "    [2] scamalytics   ${DIM}— 免费 5000/月,需自助申请 key,区分度高${N}"
  echo -e "    [3] lookup_scrape ${DIM}— 爬 proxycheck 网页,无 API 限额,与网页显示一致(33/53/96 之类)${N}"
  echo -e "    ${DIM}[0] 取消${N}"
  echo ""
  local _in
  read -erp "  选择：" _in
  case "$_in" in
    1) _quality_set --quality-source free; info "已切换为 free（proxycheck API）" ;;
    2)
      _quality_set --quality-source scamalytics
      info "已切换为 scamalytics"
      echo -e "  ${DIM}如未注册，请前往 https://scamalytics.com/pricing 注册免费 plan${N}"
      echo -e "  ${DIM}拿到完整 URL 后录入 scamalytics URL${N}"
      ;;
    3) _quality_set --quality-source lookup_scrape; info "已切换为 lookup_scrape（爬网页,与 https://proxycheck.io/lookup/IP 显示一致）" ;;
    0|"") info "未变更" ;;
    *) warn "无效选项" ;;
  esac
}

_quality_set_scamalytics_url() {
  local _cur; _cur=$(_quality_get scamalytics_url)
  echo ""
  echo -e "  ${W}录入 scamalytics 完整查询 URL${N}"
  echo -e "  ${DIM}格式示例：https://api12.scamalytics.com/v3/?key=XXX&user=YYY${N}"
  echo -e "  ${DIM}注册地址：https://scamalytics.com/pricing （免费 plan 5K/月）${N}"
  if [[ -n "$_cur" ]]; then
    echo -e "  ${DIM}当前：${_cur}${N}"
    echo -e "  ${DIM}（直接回车保持不变；输入 - 清空）${N}"
  fi
  local _in
  read -erp "  URL：" _in
  if [[ -z "$_in" ]]; then info "未变更"; return; fi
  if [[ "$_in" == "-" ]]; then
    _quality_set --scamalytics-url ""
    info "已清空"
    return
  fi
  _quality_set --scamalytics-url "$_in"
  info "已保存"
}

_quality_set_proxycheck_key() {
  local _cur; _cur=$(_quality_get proxycheck_api_key)
  echo ""
  echo -e "  ${W}录入 proxycheck.io API key（可选，免费注册升级到 1000/天）${N}"
  echo -e "  ${DIM}注册地址：https://proxycheck.io/dashboard${N}"
  if [[ -n "$_cur" ]]; then
    echo -e "  ${DIM}当前：${_cur}${N}"
    echo -e "  ${DIM}（直接回车保持不变；输入 - 清空）${N}"
  fi
  local _in
  read -erp "  key：" _in
  if [[ -z "$_in" ]]; then info "未变更"; return; fi
  if [[ "$_in" == "-" ]]; then
    _quality_set --proxycheck-api-key ""
    info "已清空（回到免费匿名 100/天）"
    return
  fi
  _quality_set --proxycheck-api-key "$_in"
  info "已保存"
}

_quality_clear_cache() {
  local _f="$(_clash_dir)/.ip_quality_cache.yaml"
  if [[ -f "$_f" ]]; then
    rm -f "$_f"
    info "已清空 IP 质量缓存：${_f}"
    echo -e "  ${DIM}下次渲染会重新查询所有 IP（注意配额）${N}"
  else
    info "无缓存文件"
  fi
}

# IP 检测主菜单(风格 D 立即生效字段表):
# 9 个字段(布尔/枚举/文本)选号即生效,无暂存
_QUALITY_QUIT=0

# 二级菜单:风险评分开关
_clash_menu_quality_check() {
  while true; do
    print_header "Clash 订阅管理 / IP 检测 / 风险评分开关"
    local _en _self _sta
    _en=$(_quality_get quality_check_enabled)
    _self=$(_quality_get quality_check_for_self)
    _sta=$(_quality_get quality_check_for_static)
    local _onoff
    _onoff() { [[ "$1" == "on" ]] && echo "${G}on${N}" || echo "${DIM}off${N}"; }
    echo ""
    printf "    ${W}[1]${N} 评分总开关        : %b\n" "$(_onoff "$_en")"
    printf "    ${W}[2]${N} 自建评分          : %b\n" "$(_onoff "$_self")"
    printf "    ${W}[3]${N} 静态评分          : %b\n" "$(_onoff "$_sta")"
    echo ""
    echo -e "    ${DIM}[外购] 不评分(协议私有,server 是入口 LB,评分无意义)${N}"
    echo -e "    ${DIM}[0 / 回车] 返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _quality_toggle quality_check_enabled "评分总开关" ;;
      2) _quality_toggle quality_check_for_self "自建评分" ;;
      3) _quality_toggle quality_check_for_static "静态评分" ;;
      0|"") return 0 ;;
      q|Q) _QUALITY_QUIT=1; return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# 二级菜单:出口 IP 显示开关
_clash_menu_exit_ip_show() {
  while true; do
    print_header "Clash 订阅管理 / IP 检测 / 出口 IP 显示开关"
    local _en _self _sta
    _en=$(_quality_get exit_ip_show_enabled)
    _self=$(_quality_get exit_ip_show_for_self)
    _sta=$(_quality_get exit_ip_show_for_static)
    local _onoff
    _onoff() { [[ "$1" == "on" ]] && echo "${G}on${N}" || echo "${DIM}off${N}"; }
    echo ""
    printf "    ${W}[1]${N} 出口 IP 总开关     : %b\n" "$(_onoff "$_en")"
    printf "    ${W}[2]${N} 自建出口 IP 显示    : %b\n" "$(_onoff "$_self")"
    printf "    ${W}[3]${N} 静态出口 IP 显示    : %b\n" "$(_onoff "$_sta")"
    echo ""
    echo -e "    ${DIM}节点名末尾 (IP) 段;关闭则只显示 geo 标签${N}"
    echo -e "    ${DIM}[0 / 回车] 返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _quality_toggle exit_ip_show_enabled "出口 IP 总开关" ;;
      2) _quality_toggle exit_ip_show_for_self "自建出口 IP 显示" ;;
      3) _quality_toggle exit_ip_show_for_static "静态出口 IP 显示" ;;
      0|"") return 0 ;;
      q|Q) _QUALITY_QUIT=1; return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# 二级菜单:数据源配置(源选 / scamalytics URL / proxycheck key)
_clash_menu_quality_source() {
  while true; do
    print_header "Clash 订阅管理 / IP 检测 / 数据源配置"
    local _src _scama _proxy
    _src=$(_quality_get quality_source)
    _scama=$(_quality_get scamalytics_url)
    _proxy=$(_quality_get proxycheck_api_key)
    local _src_show
    case "$_src" in
      scamalytics)   _src_show="${G}scamalytics${N}（5K/月）" ;;
      lookup_scrape) _src_show="${G}lookup_scrape${N}（爬网页，与 https://proxycheck.io/lookup 一致）" ;;
      *)             _src_show="${W}free${N}（proxycheck API）" ;;
    esac
    local _scama_show _proxy_show
    [[ -n "$_scama" ]] && _scama_show="${G}(已配置)${N}" || _scama_show="${DIM}(未配置)${N}"
    [[ -n "$_proxy" ]] && _proxy_show="${G}(已配置)${N}" || _proxy_show="${DIM}(未配置，匿名 100/天)${N}"
    echo ""
    printf "    ${W}[1]${N} 数据源              : %b\n" "$_src_show"
    printf "    ${W}[2]${N} scamalytics URL    : %b\n" "$_scama_show"
    printf "    ${W}[3]${N} proxycheck API key : %b\n" "$_proxy_show"
    echo ""
    echo -e "    ${DIM}[0 / 回车] 返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _quality_set_source ;;
      2) _quality_set_scamalytics_url ;;
      3) _quality_set_proxycheck_key ;;
      0|"") return 0 ;;
      q|Q) _QUALITY_QUIT=1; return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# 顶层 IP 检测菜单(风格 A 动作型;三个分类入口 + 缓存清理)
_clash_menu_quality() {
  _QUALITY_QUIT=0
  while true; do
    print_header "Clash 订阅管理 / IP 检测"
    echo ""
    echo -e "    ${W}[1]${N} 风险评分开关 (总 / 自建 / 静态)"
    echo -e "    ${W}[2]${N} 出口 IP 显示开关 (总 / 自建 / 静态)"
    echo -e "    ${W}[3]${N} 数据源配置 (源选 / scamalytics URL / proxycheck key)"
    echo -e "    ${W}[c]${N} 清空 IP 质量缓存"
    echo ""
    echo -e "    ${DIM}[0 / 回车] 返回    [q] 退出菜单${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _clash_menu_quality_check ;;
      2) _clash_menu_exit_ip_show ;;
      3) _clash_menu_quality_source ;;
      c|C) _quality_clear_cache ;;
      0|"") break ;;
      q|Q) _QUALITY_QUIT=1 ;;
      *) warn "无效选项" ;;
    esac
    (( _QUALITY_QUIT == 1 )) && { _QUALITY_QUIT=0; break; }
  done
}

# 用户入口：菜单调用 → 订阅管理子菜单
refresh_clash_subscription() {
  if ! $INST_SINGBOX; then
    warn "未安装 sing-box，跳过"
    return 1
  fi
  setup_clash_subscription || return 1

  while true; do
    print_header "Clash 订阅管理"
    _clash_menu_list
    echo ""
    echo -e "    ${W}[1]${N} 查询单条订阅（含 token / URL / 实时用量）"
    echo -e "    ${W}[2]${N} 新增订阅"
    echo -e "    ${W}[3]${N} 编辑订阅（流量 / 重置日 / 到期 / 拉取间隔 / 密码 / 端口 / 外购）"
    echo -e "    ${W}[4]${N} 删除订阅"
    echo -e "    ${W}[5]${N} 修改默认值"
    echo -e "    ${W}[6]${N} 同步配置（重渲染 yaml + 同步 Caddyfile / sing-box / nft，仅在变化时重启）"
    echo -e "    ${W}[7]${N} 静态 IP 资源管理（默认池 / 订阅池，host:port:user:password）"
    echo -e "    ${W}[8]${N} IP 检测（[自建]/[外购]/[静态] 节点名后缀质量分）"
    echo ""
    echo -e "    ${DIM}[0] 返回${N}"
    echo ""
    local _in
    read -erp "  选择：" _in
    case "$_in" in
      1) _clash_menu_show ;;
      2) _clash_menu_add ;;
      3) _clash_menu_edit ;;
      4) _clash_menu_remove ;;
      5) _clash_menu_defaults ;;
      6) _clash_menu_refresh ;;
      7) _clash_menu_static ;;
      8) _clash_menu_quality ;;
      0|"") break ;;
      *) warn "无效选项" ;;
    esac
    echo ""
    read -erp "  按回车继续..." _
  done
}
