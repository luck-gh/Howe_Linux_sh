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
  local _repo_doc="${_AI_STACK_DIR%/}/../doc"
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

  _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存（留空字段使用默认值）" || true

  local -a _args=(add "$_name") i
  for (( i=0; i<${#_labels[@]}; i++ )); do
    [[ -n "${_values[$i]}" ]] && _args+=("${_flags[$i]}" "${_values[$i]}")
  done
  if python3 "$(_clash_py)" --base "$(_clash_dir)" "${_args[@]}"; then
    python3 "$(_clash_py)" --base "$(_clash_dir)" render --name "$_name"
    write_caddyfile
    reload_clash_subscription
    _clash_print_url "$_name"
  fi
}

# 通用：以"输入字段编号"驱动的字段编辑循环
# 用法：
#   _values_var=收集结果的数组名（已在调用者声明 local -a，长度 = ${#_labels[@]}，初值空）
#   _labels_var=字段提示数组（label 列）
#   $3 = 头部说明文案
# 行为：
#   - 显示 [1..N] 字段当前暂存值
#   - 输入编号编辑该字段，编辑后光标自动到下一项
#   - 直接回车 = 编辑光标当前指向的字段
#   - 输入 0 = 完成；返回 0 表示有改动，1 表示未改任何字段
_clash_field_loop() {
  local _values_var=$1 _labels_var=$2 _hint=$3
  local -n _values_ref=$_values_var
  local -n _labels_ref=$_labels_var
  local _n=${#_labels_ref[@]}
  local _cursor=1
  while true; do
    echo ""
    echo -e "  ${W}选择要编辑的字段${N} ${DIM}（${_hint}）${N}"
    local i
    for (( i=0; i<_n; i++ )); do
      local _shown="${_values_ref[$i]:-${DIM}（保持原值）${N}}"
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
  local -a _flags=(--rename --traffic-gb --reset-day --expire --interval --password --port --external-url)
  local -a _values=("" "" "" "" "" "" "" "")

  if ! _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存"; then
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
  )
  local -a _flags=(
    --traffic-gb --reset-day --expire-days --interval
    --stats-refresh-minutes --port-min --port-max
    --external-url --external-name-prefix
  )
  local -a _values=("" "" "" "" "" "" "" "" "")

  if ! _clash_field_loop _values _labels "回车顺延到下一项 / 0 完成保存"; then
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
    echo -e "    ${W}[3]${N} 编辑订阅（流量 / 重置日 / 到期 / 拉取间隔 / 密码）"
    echo -e "    ${W}[4]${N} 删除订阅"
    echo -e "    ${W}[5]${N} 修改默认值"
    echo -e "    ${W}[6]${N} 同步配置（重渲染 yaml + 同步 Caddyfile / sing-box / nft，仅在变化时重启）"
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
      0|"") break ;;
      *) warn "无效选项" ;;
    esac
    echo ""
    read -erp "  按回车继续..." _
  done
}
