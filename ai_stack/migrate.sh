#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — VPS 迁移 菜单编排
#
# 入口：migrate_menu（被 main.sh::service_stack_menu 调用）
# 依赖：migrate_lib.sh 提供的低层函数；间接依赖 backup_lib.sh
#
# 三种传输：
#   pack_local       仅打包，人工中转
#   pack_and_push    打包 + rsync-over-ssh 推到新机
#   pull_from_old    新机主动 SSH+rsync 从旧机拉包
# 三种加密：
#   none / openssl / age（口令 或 密钥对）
# ═══════════════════════════════════════════════════════════════════

# ── 通用交互工具 ─────────────────────────────────────────────────

# 让用户选一个 cipher
# 结果写入 MIG_CIPHER；同时 MIG_AGE_KEYFILE（仅 age-keyfile）
_mig_pick_cipher() {
  MIG_CIPHER=""; MIG_AGE_KEYFILE=""
  local has_age=0; mig_has_age && has_age=1
  local has_ssl=0; mig_has_openssl && has_ssl=1

  local -a opts=() codes=()
  if (( has_ssl )); then
    opts+=("openssl AES-256（口令，零额外依赖）")
    codes+=("openssl")
  fi
  if (( has_age )); then
    opts+=("age 口令模式（现代对称加密）")
    codes+=("age-pass")
    opts+=("age 密钥文件模式（免口令，需 recipient 公钥）")
    codes+=("age-keyfile")
  else
    opts+=("age（未安装；选择后引导 apt install）")
    codes+=("age-install")
  fi
  opts+=("不加密（仅在链路已安全时用）")
  codes+=("none")

  input_choose "选择加密方式" "${opts[@]}"
  [[ $INPUT_RESULT -lt 0 ]] && return 1

  local pick=${codes[$INPUT_RESULT]}
  if [[ "$pick" == "age-install" ]]; then
    mig_ensure_dep age || return 1
    # 重新选一次
    _mig_pick_cipher; return $?
  fi

  if [[ "$pick" == "age-keyfile" ]]; then
    ask MIG_AGE_KEYFILE "recipient 公钥文件路径" ""
    [[ -f "$MIG_AGE_KEYFILE" ]] || { err "文件不存在：$MIG_AGE_KEYFILE"; return 1; }
  fi
  MIG_CIPHER="$pick"
  return 0
}

# 选一个已存在的备份点（backup_lib 生成的）
# 结果写入 MIG_BACKUP_TS
_mig_pick_backup_point() {
  MIG_BACKUP_TS=""
  local -a lines=()
  mapfile -t lines < <(backup_list)
  if (( ${#lines[@]} == 0 )); then
    warn "本机尚无备份点，先跑一次"
    return 1
  fi
  local -a labels=() tss=()
  local l ts size scopes note human
  for l in "${lines[@]}"; do
    IFS='|' read -r ts size scopes note <<< "$l"
    human=$(_bk_human "${size:-0}")
    labels+=("$ts  [$human]  ${scopes}  ${note:+// $note}")
    tss+=("$ts")
  done
  input_choose "选择要打包的备份点" "${labels[@]}"
  [[ $INPUT_RESULT -lt 0 ]] && return 1
  MIG_BACKUP_TS=${tss[$INPUT_RESULT]}
}

# 询问是否先创建新备份点
# 结果：若用户选是，回填 MIG_BACKUP_TS
_mig_maybe_create_backup() {
  local yn
  askyn yn "是否先创建一个新备份点（推荐）？" y
  $yn || return 0

  local -a avail=()
  mapfile -t avail < <(backup_available_scopes)
  if (( ${#avail[@]} == 0 )); then
    warn "本机未检测到可备份的服务"
    return 1
  fi
  echo -e "  ${DIM}将备份以下 scope：${avail[*]}${N}"
  local dir
  dir=$(backup_create "migrate-$(date +%Y%m%d-%H%M%S)" "${avail[@]}") \
    || { err "备份失败"; return 1; }
  MIG_BACKUP_TS=$(basename "$dir")
  log "已创建备份点：$MIG_BACKUP_TS"
}

# 选一个本地 bundle
# 结果写入 MIG_BUNDLE_PATH
_mig_pick_bundle() {
  MIG_BUNDLE_PATH=""
  local -a lines=()
  local mroot; mroot=$(migrate_root)
  mapfile -t lines < <(mig_list_bundles)
  if (( ${#lines[@]} == 0 )); then
    warn "$mroot 下没有找到 bundle"
    echo ""
    echo -e "  ${W}bundle 需要放在：${N}${mroot}/"
    echo -e "  ${DIM}识别规则：文件名以 migrate- 开头，扩展名为 .tar / .tar.enc / .tar.age${N}"
    echo ""
    echo -e "  ${W}从旧机传过来（在旧机执行）：${N}"
    echo "    scp /var/backups/howe-migrate/migrate-*.tar* root@$(hostname -I 2>/dev/null | awk '{print $1}'):${mroot}/"
    echo ""
    echo -e "  ${DIM}或用菜单 3「从旧机拉取」自动完成${N}"
    return 1
  fi
  local -a labels=() paths=()
  local l name size ext mtime human hd dir
  dir=$(migrate_root)
  for l in "${lines[@]}"; do
    IFS='|' read -r name size ext mtime <<< "$l"
    human=$(_bk_human "${size:-0}")
    hd=$(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null)
    labels+=("$name  [$human]  ${hd}  ${ext}")
    paths+=("$dir/$name")
  done
  input_choose "选择 bundle 文件" "${labels[@]}"
  [[ $INPUT_RESULT -lt 0 ]] && return 1
  MIG_BUNDLE_PATH=${paths[$INPUT_RESULT]}
}

# 根据文件扩展名猜 cipher（用户仍会被要求确认；age 因扩展名相同要问口令 vs 密钥）
_mig_guess_cipher_by_ext() {
  local f=$1
  case "$f" in
    *.tar.enc) echo "openssl" ;;
    *.tar.age) echo "age" ;;
    *.tar)     echo "none" ;;
    *)         echo "" ;;
  esac
}

# ── 统一打包（与传输方式无关）────────────────────────────────────────

# 多选 scope，处理 docker-images / custom 特殊配置
# 输出：MIG_SELECTED_SCOPES MIG_DOCKER_STRATEGY MIG_CUSTOM_PATHS
_mig_scope_multiselect() {
  MIG_SELECTED_SCOPES=()
  MIG_DOCKER_STRATEGY="record"
  MIG_CUSTOM_PATHS=""

  # 5 分类定义：name | scope 列表（空格分隔）| 是否默认勾选
  local -a CAT_NAMES=(
    "AI 服务数据"
    "服务运行时配置"
    "镜像 / 二进制（默认不选，体积大）"
    "主机系统配置（默认不选）"
    "工具与凭据（默认不选）"
  )
  local -a CAT_SCOPES=(
    "ai-pg ai-data ai-config clash nrouter kiro"
    "singbox caddy"
    "docker-images"
    "system-sec system-tune"
    "ai-cli custom"
  )
  local -a CAT_PRESELECT=(true true false false false)

  # 获取当前主机已安装的 scope（custom 总是可用）
  local -a avail=()
  mapfile -t avail < <(backup_available_scopes 2>/dev/null)
  [[ " ${avail[*]} " != *" custom "* ]] && avail+=("custom")

  # 按分类顺序构建 item 列表（只含可用 scope）
  local -a item_keys=() item_labels=() item_cat_idx=()
  local ci
  for ci in 0 1 2 3 4; do
    local -a cscopes=()
    read -ra cscopes <<< "${CAT_SCOPES[$ci]}"
    for sk in "${cscopes[@]}"; do
      [[ " ${avail[*]} " == *" $sk "* ]] || continue
      item_keys+=("$sk")
      item_labels+=("$(printf '%-14s %s' "$sk" "$(backup_scope_desc "$sk")")")
      item_cat_idx+=("$ci")
    done
  done

  if (( ${#item_keys[@]} == 0 )); then
    warn "当前主机未检测到任何可备份内容"; return 1
  fi

  # 初始化勾选状态（按分类默认值）
  local -a sel=()
  for i in "${!item_keys[@]}"; do
    sel+=("${CAT_PRESELECT[${item_cat_idx[$i]}]}")
  done

  local _msg=""
  while true; do
    clear
    echo ""
    echo -e "  ${W}选择要打包的内容${N}  ${DIM}输入编号切换 | 多个用逗号: 1,3,5 | a=全选/取消 | 回车确认${N}"
    echo ""

    local prev_ci=-1 num=0
    for i in "${!item_keys[@]}"; do
      local ci="${item_cat_idx[$i]}"
      if [[ "$ci" != "$prev_ci" ]]; then
        # 分类分割线
        echo -e "  ${DIM}── ${CAT_NAMES[$ci]} ──────────────────${N}"
        prev_ci="$ci"
      fi
      num=$((num + 1))
      local chk="${DIM}[ ]${N}"; [[ "${sel[$i]}" == "true" ]] && chk="${G}[✓]${N}"
      printf "  %b %2d. %s\n" "$chk" "$num" "${item_labels[$i]}"
    done
    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${Y}$_msg${N}"; _msg=""; echo ""; }

    local _input; read -erp "  选择: " _input
    [[ -z "$_input" ]] && break
    case "${_input,,}" in
      q|quit|exit) reset_terminal 2>/dev/null; exit 0 ;;
      a)
        local _all=true
        for i in "${!sel[@]}"; do [[ "${sel[$i]}" != "true" ]] && { _all=false; break; }; done
        for i in "${!sel[@]}"; do $_all && sel[$i]=false || sel[$i]=true; done
        ;;
      *)
        IFS=',' read -ra _nums <<< "$_input"
        for _n in "${_nums[@]}"; do
          _n="${_n// /}"
          if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n >= 1 && _n <= ${#item_keys[@]} )); then
            local idx=$((_n - 1))
            [[ "${sel[$idx]}" == "true" ]] && sel[$idx]=false || sel[$idx]=true
          else
            _msg="无效输入：$_n（编号范围 1-${#item_keys[@]}）"
          fi
        done
        ;;
    esac
  done

  local -a sel_keys=()
  for i in "${!item_keys[@]}"; do
    [[ "${sel[$i]}" == "true" ]] && sel_keys+=("${item_keys[$i]}")
  done
  (( ${#sel_keys[@]} == 0 )) && { warn "未选择任何内容"; return 1; }

  # docker-images 策略
  if [[ " ${sel_keys[*]} " == *" docker-images "* ]]; then
    echo ""
    input_choose "Docker 镜像打包方式" \
      "仅记录镜像名（小；解包时 docker pull 重拉）" \
      "docker save 打包（大；适合无网新机）"
    [[ $INPUT_RESULT -eq 1 ]] && MIG_DOCKER_STRATEGY="save" || MIG_DOCKER_STRATEGY="record"
    export MIG_DOCKER_STRATEGY
  fi

  # custom 路径录入
  if [[ " ${sel_keys[*]} " == *" custom "* ]]; then
    echo ""
    echo -e "  ${W}输入自定义路径（每行一个，空行结束）：${N}"
    local -a cpaths=()
    while true; do
      local p=""; read -erp "  路径（留空结束）: " p
      [[ -z "$p" ]] && break
      [[ -e "$p" ]] && { cpaths+=("$p"); log "已加入：$p"; } || warn "不存在：$p"
    done
    if (( ${#cpaths[@]} == 0 )); then
      warn "未输入有效路径，移除 custom scope"
      sel_keys=("${sel_keys[@]/custom}")
    else
      MIG_CUSTOM_PATHS="${cpaths[*]}"
      export MIG_CUSTOM_PATHS
    fi
  fi

  MIG_SELECTED_SCOPES=("${sel_keys[@]}")
}

# 提前收集加密口令（带3次重试），结果存入 MIG_PASSPHRASE
# age 模式由 age 自身在 tty 提示，无需预收集
_mig_collect_passphrase() {
  MIG_PASSPHRASE=""
  local cipher=$1
  [[ "$cipher" == "none" ]] && return 0
  [[ "$cipher" == age-pass || "$cipher" == age-keyfile ]] && return 0

  local attempt=0
  while (( attempt < 3 )); do
    attempt=$((attempt + 1))
    local pass
    pass=$(mig_prompt_passphrase_new) && {
      MIG_PASSPHRASE="$pass"
      export MIG_PASSPHRASE
      return 0
    }
    (( attempt < 3 )) && warn "口令不匹配，剩余 $((3 - attempt)) 次机会..."
  done
  err "口令输入失败 3 次，已取消打包"
  return 1
}

# 按磁盘实际情况重写 manifest 的 scopes_ok / scopes_fail
# 重试后需要同步 manifest，否则后续按 manifest 判断的地方仍看到旧状态
_mig_resync_manifest() {
  local bp_dir=$1
  local mf="$bp_dir/manifest.json"
  [[ -f "$mf" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$mf" "$bp_dir" <<'PY' 2>/dev/null
import json, os, sys
mf, d = sys.argv[1], sys.argv[2]
try:
    m = json.load(open(mf))
except Exception:
    sys.exit(0)
known = set(m.get("scopes_ok", [])) | set(m.get("scopes_fail", []))
ok, fail = [], []
for s in sorted(known):
    arc = os.path.join(d, f"{s}.tar.gz")
    # .sha256 只在 scope 成功后写入，是「这个归档可用」的唯一可靠标志
    (ok if os.path.exists(arc + ".sha256") else fail).append(s)
m["scopes_ok"], m["scopes_fail"] = ok, fail
json.dump(m, open(mf, "w"), ensure_ascii=False, indent=2)
PY
}

# 打包前的失败 scope 闸门
# $1 = 备份点目录
# 返回 0 = 可以继续打包；1 = 用户选择中止
#
# 动机：scope 失败时原流程直接继续打包，残缺归档随通配符进 bundle，
# 新机解包时校验失败导致整个恢复中止 —— 91MB 传过去全废。
# 这里停下来让用户决定，而不是替他做主。
_mig_gate_failed_scopes() {
  local bp_dir=$1
  local mf="$bp_dir/manifest.json"
  [[ -f "$mf" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  while true; do
    local -a failed=()
    mapfile -t failed < <(python3 -c "
import json,sys
try: print('\n'.join(json.load(open(sys.argv[1])).get('scopes_fail',[])))
except Exception: pass
" "$mf" 2>/dev/null)
    # 过滤空行
    local -a f2=(); local x
    for x in "${failed[@]}"; do [[ -n "$x" ]] && f2+=("$x"); done
    failed=("${f2[@]}")

    (( ${#failed[@]} == 0 )) && return 0

    echo ""
    warn "以下 ${#failed[@]} 个 scope 备份失败："
    local sk
    for sk in "${failed[@]}"; do
      echo -e "    ${R}✗${N} $(printf '%-14s' "$sk") $(backup_scope_desc "$sk")"
    done
    echo ""
    echo -e "  ${DIM}继续打包会得到不完整的 bundle：失败项不会进包，新机缺这部分数据${N}"
    echo ""

    input_choose "如何处理" \
      "重试失败的 scope" \
      "接受缺口，仅打包成功的 scope" \
      "中止打包（回菜单）"

    case $INPUT_RESULT in
      0)
        echo ""
        local fn rc
        for sk in "${failed[@]}"; do
          fn="_bk_do_${sk//-/_}"
          if ! declare -F "$fn" >/dev/null 2>&1; then
            warn "$sk 无对应实现，跳过"
            continue
          fi
          info "重试 $sk ..."
          if "$fn" "$bp_dir" >/dev/null 2>&1; then
            log "  ✓ $sk"
          else
            warn "  ✗ $sk 仍然失败"
            # 清掉本轮可能留下的残缺归档，避免它被误认为有效
            [[ -f "$bp_dir/$sk.tar.gz" && ! -f "$bp_dir/$sk.tar.gz.sha256" ]] \
              && rm -f "$bp_dir/$sk.tar.gz"
          fi
        done
        _mig_resync_manifest "$bp_dir"
        # 回到循环顶部重新读 manifest：全成功则自动返回，否则再问一轮
        ;;
      1)
        # 清掉所有无校验和的残缺归档，确保它们不进 bundle
        for sk in "${failed[@]}"; do
          [[ -f "$bp_dir/$sk.tar.gz" && ! -f "$bp_dir/$sk.tar.gz.sha256" ]] \
            && rm -f "$bp_dir/$sk.tar.gz"
        done
        warn "已接受缺口，失败项不会进入 bundle"
        return 0
        ;;
      *)
        info "已中止打包"
        return 1
        ;;
    esac
  done
}

migrate_action_pack() {
  print_header "打包迁移 bundle"
  echo -e "  ${DIM}所有传输方式（本地保存 / 推送 / 拉取）共用同一套打包逻辑${N}"
  echo ""

  # 1) 多选 scope
  _mig_scope_multiselect || return 1

  # 分离标准与特殊 scope
  local -a std_scopes=() special_scopes=()
  local sk
  for sk in "${MIG_SELECTED_SCOPES[@]}"; do
    case "$sk" in
      docker-images|custom) special_scopes+=("$sk") ;;
      "")                   ;;
      *)                    std_scopes+=("$sk") ;;
    esac
  done

  # 2) 提前选加密方式 + 收集口令（避免备份完才发现口令输错的无用功）
  echo ""
  _mig_pick_cipher || return 1
  _mig_collect_passphrase "$MIG_CIPHER" || return 1

  # 3) 标准 scope 打包 → 备份点
  local bk_ts bk_dir
  if (( ${#std_scopes[@]} > 0 )); then
    echo ""
    local yn; askyn yn "立即创建新备份点（推荐）？选否则选已有备份点" y
    if $yn; then
      bk_dir=$(backup_create "migrate-$(date +%Y%m%d-%H%M%S)" "${std_scopes[@]}") \
        || { unset MIG_PASSPHRASE; err "备份失败"; return 1; }
      bk_ts=$(basename "$bk_dir")
      log "备份点：$bk_ts"
    else
      _mig_pick_backup_point || { unset MIG_PASSPHRASE; return 1; }
      bk_ts="$MIG_BACKUP_TS"
      bk_dir="$(backup_root)/$bk_ts"
    fi
  else
    bk_ts=$(_bk_ts)
    bk_dir="$(backup_root)/$bk_ts"
    mkdir -p "$bk_dir" && chmod 0700 "$bk_dir"
    echo '{"timestamp":"'"$bk_ts"'","scopes_ok":[],"scopes_fail":[]}' > "$bk_dir/manifest.json"
  fi

  # 3.5) 失败 scope 闸门：有失败项时停下来问，不默默打出残缺 bundle
  _mig_gate_failed_scopes "$bk_dir" || { unset MIG_PASSPHRASE; return 1; }

  # 补齐环境清单与镜像版本锁。三条路径都要覆盖：
  #   仅选 docker-images/custom（未走 backup_create）、复用旧备份点（可能是
  #   本功能上线前创建的）、以及 backup_create 当时 docker 不可用的情况。
  # 缺了镜像锁，新机就无法按旧机的确切版本拉镜像。
  [[ -f "$bk_dir/host-inventory.json" ]]      || _bk_write_inventory  "$bk_dir" >&2 || true
  [[ -f "$bk_dir/docker-images.lock.json" ]]  || _bk_write_image_lock "$bk_dir" >&2 || true

  # 4) 特殊 scope 打入备份点目录
  local -a packed_scopes=()
  mapfile -t packed_scopes < <(backup_point_scopes "$bk_ts" 2>/dev/null || true)

  for sk in "${special_scopes[@]}"; do
    case "$sk" in
      docker-images)
        info "打包 docker-images（策略：$MIG_DOCKER_STRATEGY）..."
        _bk_do_docker_images "$bk_dir" 2>&1 && {
          packed_scopes+=("docker-images")
          log "docker-images 完成"
        } || warn "docker-images 打包失败，跳过"
        ;;
      custom)
        info "打包自定义路径..."
        _bk_do_custom "$bk_dir" 2>&1 && {
          packed_scopes+=("custom")
          log "custom 完成（$MIG_CUSTOM_PATHS）"
        } || warn "custom 打包失败，跳过"
        ;;
    esac
  done

  (( ${#packed_scopes[@]} == 0 )) && { unset MIG_PASSPHRASE; err "无任何内容打包成功"; return 1; }

  # 5) 写 manifest v2（cipher 已知）
  mig_write_manifest_v2 "$bk_dir" "$MIG_CIPHER" "${packed_scopes[@]}" 2>/dev/null || true

  # 6) 打包 bundle（MIG_PASSPHRASE 已预设，mig_prompt_passphrase_new 直接使用）
  info "打包 bundle（cipher: $MIG_CIPHER）..."
  local out
  out=$(mig_pack_bundle "$bk_ts" "$MIG_CIPHER" "" "${MIG_AGE_KEYFILE:-}") \
    || { unset MIG_PASSPHRASE; err "打包失败"; return 1; }
  unset MIG_PASSPHRASE  # 用完立即清除

  local size; size=$(stat -c '%s' "$out" 2>/dev/null || echo 0)
  echo ""
  log "bundle 已生成"
  echo -e "  ${W}路径：${N}$out"
  echo -e "  ${W}大小：${N}$(_bk_human "$size")"
  echo -e "  ${W}scope：${N}${packed_scopes[*]}"
  echo ""
  echo -e "  ${DIM}下一步：菜单 → ② 传递 bundle 到新机${N}"
  _MIG_LAST_BUNDLE="$out"
}

# ── ② 传递：把本机 bundle 发送到新机，或提示手动操作 ─────────────────

migrate_action_transfer() {
  print_header "传递 bundle 到新机"

  # 优先使用刚打好的 bundle，否则选一个已有的
  local bundle=""
  if [[ -n "${_MIG_LAST_BUNDLE:-}" && -f "$_MIG_LAST_BUNDLE" ]]; then
    echo -e "  ${DIM}将使用刚打好的 bundle：${N}$(basename "$_MIG_LAST_BUNDLE")"
    local yn; askyn yn "使用此 bundle？" y
    $yn && bundle="$_MIG_LAST_BUNDLE"
  fi
  if [[ -z "$bundle" ]]; then
    _mig_pick_bundle || return 1
    bundle="$MIG_BUNDLE_PATH"
  fi
  local size; size=$(stat -c '%s' "$bundle" 2>/dev/null || echo 0)
  echo -e "  ${W}bundle：${N}$(basename "$bundle")  $(_bk_human "$size")"
  echo -e "  ${W}本机路径：${N}$bundle"
  echo ""
  # 提前点明新机的落地目录：三种方式最终都要求 bundle 出现在这里，
  # 否则新机「③ 解包恢复」扫不到文件
  echo -e "  ${Y}新机必须把 bundle 放到：${N}$(migrate_root)/"
  echo -e "  ${DIM}（该目录不存在时新机会自动创建；放别处则解包菜单列不出来）${N}"
  echo ""

  input_choose "选择传递方式" \
    "推送到新机（旧机执行，新机有 SSH）" \
    "从旧机拉取（新机执行，在新机上运行此菜单）" \
    "下载到本地 / 手动 scp（两端都无直连时）"

  case $INPUT_RESULT in
    0)  # 推送：旧机 → 新机
      local ruser rhost rport rdir
      echo ""
      echo -e "  ${DIM}任一项留空可中止；全部填完后会先显示汇总再确认${N}"
      ask ruser "新机 SSH 用户名" "root"
      [[ -z "$ruser" ]] && { info "已取消"; return 0; }
      ask rhost "新机地址（IP 或域名）" ""
      [[ -z "$rhost" ]] && { info "已取消"; return 0; }
      ask rport "SSH 端口" "22"
      [[ -z "$rport" ]] && { info "已取消"; return 0; }
      ask rdir  "新机存放目录" "$(migrate_root)"
      [[ -z "$rdir" ]] && { info "已取消"; return 0; }

      # 汇总确认：填错信息时不必等 SSH 超时才发现
      echo ""
      echo -e "  ${W}请核对推送信息${N}"
      echo -e "  ${DIM}────────────────────────────────${N}"
      echo -e "    bundle    $(basename "$bundle")  $(_bk_human "$size")"
      echo -e "    目标      ${ruser}@${rhost}:${rport}"
      echo -e "    存放目录  ${rdir}"
      echo ""
      local yn2; askyn yn2 "信息正确，开始推送？" y
      $yn2 || { info "已取消，bundle 保留本地：$bundle"; return 0; }

      mig_ensure_dep rsync || return 1
      # 先预检连通性：避免 rsync 阶段无输出干等
      mig_ssh_check "${ruser}@${rhost}" "$rport" || {
        err "推送中止，bundle 保留本地：$bundle"; return 1
      }
      info "推送中..."
      mig_rsync_push "$bundle" "${ruser}@${rhost}" "$rdir" "$rport" \
        && log "推送完成 → ${rhost}:${rdir}/$(basename "$bundle")" \
        || { err "推送失败，bundle 保留本地：$bundle"; return 1; }
      echo -e "  ${DIM}新机操作：菜单 → ③ 解包恢复${N}"
      ;;
    1)  # 拉取：需要到新机上执行
      echo ""
      warn "此操作需要在【新机】上执行："
      echo "  1. 新机运行 howe.sh → AI 服务栈 → VPS 迁移"
      echo "  2. 选 「② 传递 bundle」→「从旧机拉取」"
      echo "  3. 输入旧机 SSH 信息"
      ;;
    2)  # 手动中转：给出 scp 命令
      local _mroot; _mroot=$(migrate_root)
      local _bname; _bname=$(basename "$bundle")
      echo ""
      echo -e "  ${W}要传输 2 个文件${N}（.sha256 是校验和，不传则新机跳过完整性校验）"
      echo -e "  ${DIM}────────────────────────────────${N}"
      echo "    ${bundle}"
      echo "    ${bundle}.sha256"
      echo ""
      echo -e "  ${W}① 下载到本地（在你自己的电脑执行）：${N}"
      echo "    scp -P 22 'root@<旧机IP>:${bundle}*' ./"
      echo ""
      echo -e "  ${W}② 上传到新机：${N}"
      echo "    ssh root@<新机IP> 'mkdir -p ${_mroot}'"
      echo "    scp -P 22 ${_bname}* root@<新机IP>:${_mroot}/"
      echo ""
      echo -e "  ${DIM}两端都有公网直连时，可跳过本地中转：${N}"
      echo "    scp -3 'root@<旧机>:${bundle}*' 'root@<新机>:${_mroot}/'"
      echo ""
      echo -e "  ${Y}注意：新机的目标目录必须是 ${_mroot}/${N}"
      echo -e "  ${DIM}放到别处，新机「③ 解包恢复」会提示无 bundle${N}"
      echo ""
      info "传输完成后，在新机菜单 → ③ 解包恢复"
      ;;
    *)
      info "已取消"
      ;;
  esac
}

# 拉取（在新机上执行）
migrate_action_pull_from_old() {
  print_header "从旧机拉取 bundle（新机操作）"

  local remote_user remote_host remote_port remote_path
  echo ""
  echo -e "  ${DIM}任一项留空可中止；填完后会先显示汇总再确认${N}"
  ask remote_user "旧机 SSH 用户名" "root"
  [[ -z "$remote_user" ]] && { info "已取消"; return 0; }
  ask remote_host "旧机地址（IP 或域名）" ""
  [[ -z "$remote_host" ]] && { info "已取消"; return 0; }
  ask remote_port "SSH 端口" "22"
  [[ -z "$remote_port" ]] && { info "已取消"; return 0; }

  echo ""
  echo -e "  ${W}请核对旧机信息${N}"
  echo -e "  ${DIM}────────────────────────────────${N}"
  echo -e "    源      ${remote_user}@${remote_host}:${remote_port}"
  echo -e "    落地到  $(migrate_root)/"
  echo ""
  local yn0; askyn yn0 "信息正确，开始连接？" y
  $yn0 || { info "已取消"; return 0; }

  # 预检：地址/端口错时 10s 内明确失败，不必等 TCP 超时
  mig_ssh_check "${remote_user}@${remote_host}" "$remote_port" || return 1

  # 尝试列出远端可用 bundle
  info "列出旧机 $(migrate_root) 下的 bundle..."
  local remote_root
  remote_root=$(migrate_root)
  local -a _sopts; read -ra _sopts <<< "$(mig_ssh_opts)"
  local remote_ls
  remote_ls=$(ssh -p "$remote_port" "${_sopts[@]}" "${remote_user}@${remote_host}" \
              "ls -1t ${remote_root}/migrate-*.tar ${remote_root}/migrate-*.tar.enc ${remote_root}/migrate-*.tar.age 2>/dev/null" \
              2>/dev/null || true)

  if [[ -n "$remote_ls" ]]; then
    local -a rlines=()
    mapfile -t rlines <<< "$remote_ls"
    local -a labels=()
    local rl
    for rl in "${rlines[@]}"; do labels+=("$(basename "$rl")"); done
    labels+=("手动输入远端路径")
    input_choose "选择旧机上的 bundle" "${labels[@]}"
    [[ $INPUT_RESULT -lt 0 ]] && return 1
    if (( INPUT_RESULT == ${#rlines[@]} )); then
      ask remote_path "远端 bundle 完整路径" ""
    else
      remote_path=${rlines[$INPUT_RESULT]}
    fi
  else
    warn "无法列出远端 bundle（可能未打包过或路径不同）"
    ask remote_path "远端 bundle 完整路径" ""
  fi
  [[ -z "$remote_path" ]] && { err "远端路径为空"; return 1; }

  # 拉取
  local local_bundle
  info "拉取中..."
  local_bundle=$(mig_rsync_pull "${remote_user}@${remote_host}" "$remote_path" "" "$remote_port") \
    || { err "拉取失败"; return 1; }
  log "拉取完成：$local_bundle"

  local yn
  askyn yn "立即解包并恢复？" y
  $yn || { info "已保存在 $local_bundle，稍后可通过「从本地文件恢复」处理"; return 0; }

  _mig_restore_from_bundle "$local_bundle"
}

# ── 动作：从本地文件恢复（新机）───────────────────────────────────

migrate_action_restore_local() {
  print_header "从本地 bundle 恢复"
  _mig_pick_bundle || return 1
  _mig_restore_from_bundle "$MIG_BUNDLE_PATH"
}

# 内部：解bundle → manifest v2 驱动 scope/策略选择 → 执行
# $1 = bundle 完整路径
_mig_restore_from_bundle() {
  local bundle=$1
  local guess; guess=$(_mig_guess_cipher_by_ext "$bundle")

  local cipher="" identity=""
  case "$guess" in
    none)    cipher="none" ;;
    openssl) cipher="openssl" ;;
    age)
      input_choose "age 加密包，选择解密方式" "age 口令模式" "age 密钥文件模式"
      [[ $INPUT_RESULT -lt 0 ]] && return 1
      if (( INPUT_RESULT == 0 )); then
        cipher="age-pass"
      else
        cipher="age-keyfile"
        ask identity "identity（私钥）文件路径" ""
        [[ -f "$identity" ]] || { err "文件不存在"; return 1; }
      fi
      ;;
    *) err "无法识别包格式"; return 1 ;;
  esac

  info "解包中..."
  local restored_ts
  restored_ts=$(mig_unpack_bundle "$bundle" "$cipher" "$identity") || return 1
  log "已解出备份点：$restored_ts"
  echo ""

  local bk_dir; bk_dir="$(backup_root)/$restored_ts"
  local mfile_v2="$bk_dir/migrate-manifest.json"

  # 判断是否 v2 manifest
  local is_v2=0
  if [[ -f "$mfile_v2" ]] && command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json,sys
d=json.load(open('$mfile_v2'))
sys.exit(0 if d.get('format_version',1)>=2 else 1)
" 2>/dev/null && is_v2=1
  fi

  if (( is_v2 )); then
    _mig_restore_v2 "$bk_dir" "$mfile_v2"
  else
    _mig_restore_v1_fallback "$bk_dir" "$restored_ts"
  fi
}

# manifest v2 驱动的恢复
_mig_restore_v2() {
  local bk_dir=$1 mfile=$2

  # 展示源主机信息
  python3 -c "
import json
d=json.load(open('$mfile'))
print(f'  源主机：{d[\"source_host\"]}  OS：{d[\"source_os\"]}')
scopes=d.get('scopes',[])
total=sum(s.get('size',0) for s in scopes)
import math
def h(b): return f'{round(b/1024/1024,1)}M' if b>1024*1024 else f'{round(b/1024,0):.0f}K'
print(f'  包含 {len(scopes)} 个 scope，合计 {h(total)}')
" 2>/dev/null
  echo ""

  # 读取 scope 列表
  local -a scope_rows=()
  mapfile -t scope_rows < <(mig_read_manifest_scopes "$mfile")
  (( ${#scope_rows[@]} == 0 )) && { err "manifest 无 scope"; return 1; }

  # 多选要恢复的 scope
  local -a labels=() scope_names=()
  local row
  for row in "${scope_rows[@]}"; do
    IFS='|' read -r sk _ size desc _ _ _ <<< "$row"
    local human; human=$(_bk_human "${size:-0}")
    labels+=("$(printf '%-14s %-8s  %s' "$sk" "$human" "$desc")")
    scope_names+=("$sk")
  done

  input_multi "选择要恢复的 scope（回车确认）" "${labels[@]}"
  (( ${#INPUT_RESULTS[@]} == 0 )) && { info "未选择任何 scope，取消"; return 0; }

  # 定策略。两条原则让这一步从「逐个弹窗」压缩成「一屏可改」：
  #   1) skip 不进候选——选中 scope 本身已表达「要恢复」，再问一次是冗余，
  #      且正是它让原来的「只剩 1 个策略就免问」判断永远不成立
  #   2) 剔除 skip 后只剩单一策略的 scope 直接采用，不打扰用户；
  #      只有 docker-images(save) / custom 这类存在真实分支的才需要决定
  local -a plan_scope=() plan_ids=() plan_labels=() plan_cur=()
  local i
  for i in "${INPUT_RESULTS[@]}"; do
    local sk="${scope_names[$i]}"
    local strats_json; IFS='|' read -r _ _ _ _ _ strats_json _ <<< "${scope_rows[$i]}"

    # 一次 python 调用同时取出 id 列表与 label 列表（label 含空格，用 \x1f 分隔）
    local pair
    pair=$(python3 - "$strats_json" <<'PY' 2>/dev/null
import json, sys
try:
    arr = [s for s in json.loads(sys.argv[1]) if s.get("id") != "skip"]
except Exception:
    arr = []
if not arr:
    arr = [{"id": "restore", "label": "恢复"}]
print(" ".join(s["id"] for s in arr))
print("\x1f".join(s.get("label", s["id"]) for s in arr))
PY
    )
    local ids_line labels_line
    ids_line=$(sed -n 1p <<< "$pair")
    labels_line=$(sed -n 2p <<< "$pair")
    [[ -z "$ids_line" ]] && { ids_line="restore"; labels_line="恢复"; }

    plan_scope+=("$sk")
    plan_ids+=("$ids_line")
    plan_labels+=("$labels_line")
    plan_cur+=(0)
  done

  (( ${#plan_scope[@]} == 0 )) && { info "无恢复计划，取消"; return 0; }

  # 统计有多少项真的存在可选分支。若一项都没有，这个界面没有任何可操作
  # 内容，展示「输入编号切换」只会误导用户去按编号、再收到「无需切换」的
  # 无效反馈。此时直接列出计划走确认即可。
  local switchable=0 z
  for z in "${!plan_scope[@]}"; do
    local -a _c=(); read -ra _c <<< "${plan_ids[$z]}"
    (( ${#_c[@]} > 1 )) && switchable=$((switchable + 1))
  done

  if (( switchable == 0 )); then
    clear
    echo ""
    echo -e "  ${W}恢复计划${N}  ${DIM}（各项均只有一种恢复方式）${N}"
    echo ""
    local n=0
    for z in "${!plan_scope[@]}"; do
      n=$((n + 1))
      local -a _labs=(); IFS=$'\x1f' read -ra _labs <<< "${plan_labels[$z]}"
      printf "  %2d. %-14s %s\n" "$n" "${plan_scope[$z]}" "${_labs[${plan_cur[$z]}]}"
    done
  else
    # 有可切换项才进入交互循环
    local _pmsg=""
    while true; do
      clear
      echo ""
      echo -e "  ${W}恢复计划${N}"
      echo -e "  ${DIM}输入编号切换策略（仅标注「可切换」的项）| 回车确认 | q 取消${N}"
      echo ""
      local n=0
      for z in "${!plan_scope[@]}"; do
        n=$((n + 1))
        local -a _ids=() _labs=()
        read -ra _ids <<< "${plan_ids[$z]}"
        IFS=$'\x1f' read -ra _labs <<< "${plan_labels[$z]}"
        local cur=${plan_cur[$z]}
        if (( ${#_ids[@]} > 1 )); then
          printf "  %2d. %-14s ${G}%s${N}  ${DIM}[%d/%d 可切换]${N}\n" \
            "$n" "${plan_scope[$z]}" "${_labs[$cur]}" "$((cur + 1))" "${#_ids[@]}"
        else
          printf "  %2d. %-14s %s\n" "$n" "${plan_scope[$z]}" "${_labs[$cur]}"
        fi
      done
      echo ""
      [[ -n "$_pmsg" ]] && { echo -e "  ${Y}$_pmsg${N}"; _pmsg=""; echo ""; }

      local _in; read -erp "  选择: " _in
      [[ -z "$_in" ]] && break
      case "${_in,,}" in
        q|quit) info "已取消"; return 0 ;;
      esac
      if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 1 && _in <= ${#plan_scope[@]} )); then
        z=$((_in - 1))
        local -a _ids=()
        read -ra _ids <<< "${plan_ids[$z]}"
        if (( ${#_ids[@]} > 1 )); then
          plan_cur[$z]=$(( (plan_cur[z] + 1) % ${#_ids[@]} ))
        else
          _pmsg="${plan_scope[$z]} 只有一种恢复方式，无需切换"
        fi
      else
        _pmsg="无效输入：$_in（编号范围 1-${#plan_scope[@]}）"
      fi
    done
  fi

  # 组装最终计划
  local -a restore_plan=()
  for z in "${!plan_scope[@]}"; do
    local -a _ids=()
    read -ra _ids <<< "${plan_ids[$z]}"
    restore_plan+=("${plan_scope[$z]}:${_ids[${plan_cur[$z]}]}")
  done

  # 计划仍在屏上，这里只补破坏性警告 + 显式确认
  echo ""
  warn "恢复将覆盖当前主机对应文件与数据库"
  local yn; askyn yn "确认执行以上 ${#restore_plan[@]} 项？" n
  $yn || { info "已取消"; return 0; }

  # 逐项执行
  echo ""
  local pair
  local restored_ai_config=0
  for pair in "${restore_plan[@]}"; do
    local sk="${pair%%:*}" strat="${pair##*:}"
    section "$sk → $strat"
    if mig_execute_strategy "$sk" "$strat" "$bk_dir"; then
      [[ "$sk" == "ai-config" ]] && restored_ai_config=1
    else
      warn "$sk 执行失败，继续"
    fi
  done

  # 镜像版本对账：恢复了 ai-config（compose 文件已就位）才有意义。
  # docker-images scope 走自己的 pull/load 策略，这里不重复处理。
  if (( restored_ai_config )) && [[ " ${restore_plan[*]} " != *" docker-images:"* ]]; then
    echo ""
    mig_reconcile_images "$bk_dir"
    _mig_offer_compose_up
  fi

  echo ""
  log "恢复流程完成"
  _mig_show_inventory "$bk_dir"
}

# 镜像就位后询问是否直接起容器
_mig_offer_compose_up() {
  local base="${BACKUP_AI_BASE:-/opt/ai-stack}"
  [[ -f "$base/docker-compose.yml" ]] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  echo ""
  local yn
  askyn yn "立即启动服务栈（docker compose up -d）？" y
  $yn || {
    info "稍后可手动执行：cd $base && docker compose up -d"
    return 0
  }
  info "启动容器..."
  ( cd "$base" && docker compose up -d ) \
    && log "服务栈已启动" \
    || warn "启动失败，可手动排查：cd $base && docker compose up -d"
}

# v1 兜底：无 manifest v2 的旧 bundle
_mig_restore_v1_fallback() {
  local bk_dir=$1 ts=$2
  warn "旧版 bundle（无 migrate-manifest.json v2），使用兼容模式"

  local -a scopes=()
  mapfile -t scopes < <(backup_point_scopes "$ts")
  (( ${#scopes[@]} == 0 )) && { err "包内无任何 scope"; return 1; }

  local -a slabels=()
  local sk
  for sk in "${scopes[@]}"; do slabels+=("$sk  $(backup_scope_desc "$sk")"); done

  input_multi "选择要恢复的 scope" "${slabels[@]}"
  local -a to_restore=()
  for i in "${INPUT_RESULTS[@]}"; do to_restore+=("${scopes[$i]}"); done
  (( ${#to_restore[@]} == 0 )) && { info "未选择任何 scope"; return 0; }

  local yn; askyn yn "确认恢复以上 ${#to_restore[@]} 个 scope？" n
  $yn || return 0
  backup_restore "$ts" "${to_restore[@]}"
  echo ""
  log "恢复完成"
  _mig_show_inventory "$bk_dir"
}

# inventory 摘要展示
_mig_show_inventory() {
  local bk_dir=$1
  local inv="$bk_dir/host-inventory.json"
  [[ -f "$inv" ]] || return 0
  echo ""
  echo -e "  ${W}${C}── 旧机环境清单 ──${N}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$inv" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(f"  源主机：{d.get('host','')}  OS：{d.get('os','')}  kernel：{d.get('kernel','')}")
    imgs = d.get('docker_images', [])
    if imgs:
        print(f"\n  Docker 镜像（{len(imgs)} 个，需 docker compose up -d）：")
        for img in imgs[:5]: print(f"    • {img}")
        if len(imgs) > 5: print(f"    ... 共 {len(imgs)} 个")
    nv = d.get('native_versions', {})
    native = [(k, v) for k, v in nv.items() if v]
    if native:
        print(f"\n  原生二进制：{', '.join(f'{k} v{v}' for k,v in native)}")
    todos = d.get('new_host_todos', [])
    if todos:
        print(f"\n  待办：")
        for i, t in enumerate(todos, 1): print(f"    {i}. {t}")
except Exception as e:
    print(f"  解析失败: {e}")
PY
  else
    grep -E '"host"|"os"|"new_host_todos"' "$inv" | head -10 | sed 's/^/    /'
  fi
  echo ""
}

# ── 管理 ─────────────────────────────────────────────────────────

migrate_action_list() {
  print_header "本机 bundle 列表"
  local -a lines=()
  mapfile -t lines < <(mig_list_bundles)
  if (( ${#lines[@]} == 0 )); then
    warn "无 bundle"; return 0
  fi
  echo -e "  ${W}目录：${N}$(migrate_root)"
  echo ""
  printf "  %-40s %10s %8s  %s\n" "FILENAME" "SIZE" "CIPHER" "MTIME"
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────${N}"
  local l name size ext mtime hd human
  for l in "${lines[@]}"; do
    IFS='|' read -r name size ext mtime <<< "$l"
    human=$(_bk_human "${size:-0}")
    hd=$(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null)
    printf "  %-40s %10s %8s  %s\n" "$name" "$human" "$ext" "$hd"
  done
}

migrate_action_delete() {
  print_header "删除 bundle"
  _mig_pick_bundle || return 1
  local yn
  askyn yn "确认删除 $(basename "$MIG_BUNDLE_PATH") ?" n
  $yn || return 0
  mig_delete_bundle "$(basename "$MIG_BUNDLE_PATH")"
}

# ── 迁移指引（bundle 内容 + 新机完整还原步骤）──────────────────────

migrate_show_guide() {
  echo -e "  ${W}${C}迁移 bundle 包含什么${N}"
  echo -e "  ${DIM}────────────────────────────────${N}"
  echo -e "  ${G}✓ 已打包${N}（跨机可直接还原）："
  echo "      ai-pg      PostgreSQL 全库 dump（sub2api / new-api）"
  echo "      ai-data    /opt/ai-stack/{sub2api,new-api,litellm,openwebui} 数据"
  echo "      ai-config  docker-compose.yml + .env"
  echo "      clash      订阅库 + token"
  echo "      singbox    /etc/sing-box 全套"
  echo "      caddy      /etc/caddy 全套"
  echo "      kiro / nrouter / ai-cli  AI CLI 凭据 & 其它数据"
  echo ""
  echo -e "  ${Y}✗ 未打包${N}（新机需重建）："
  echo "      Docker 镜像       —— docker compose up -d 重新拉"
  echo "      二进制/systemd    —— ai-stack-setup.sh 重装"
  echo "      主机加固/调优     —— mod_security / mod_memmgr / mod_network 手动重跑"
  echo "      SSH authorized_keys 与 crontab —— 手动"
  echo ""
  echo -e "  ${W}${C}新机完整还原流程${N}"
  echo -e "  ${DIM}────────────────────────────────${N}"
  echo "    1. 新机装好 OS，通过 SSH 上机；跑 howe.sh 完成基础加固"
  echo "       （SSH 密钥登录 / fail2ban / 防火墙 / BBR）"
  echo "    2. howe.sh → AI 服务栈 → 安装/重新生成配置"
  echo "       —— 装二进制、写 systemd unit、拉 Docker 镜像、起容器"
  echo "    3. 把旧机的 bundle 拷贝到新机（拉/推/本地中转 任选）"
  echo "    4. howe.sh → AI 服务栈 → VPS 迁移 → [新机] 从本地 bundle 恢复"
  echo "       —— 解包 → 落地 backup_root → 备份/恢复菜单跑 restore"
  echo "    5. 重启相关服务（Caddy / sing-box / docker compose restart）"
  echo "    6. DNS 切到新机 IP，验证订阅链接和业务端点"
  echo ""
  echo -e "  ${DIM}提示：迁移前建议在旧机先跑一次全量备份，防止半途失败。${N}"
  echo ""
}

# ── 主菜单 ───────────────────────────────────────────────────────

migrate_menu() {
  if [[ -z "${_MIGRATE_GUIDE_SHOWN:-}" ]]; then
    print_header "VPS 迁移"
    migrate_show_guide
    read -rsp "  阅读完成，按回车进入菜单..." _
    echo ""
    _MIGRATE_GUIDE_SHOWN=1
  fi

  while true; do
    print_header "VPS 迁移"
    echo -e "  ${DIM}备份根：${N}$(backup_root)   迁移根：$(migrate_root)"
    local -a caps=()
    mig_has_age     && caps+=("age") || caps+=("age(缺)")
    mig_has_openssl && caps+=("openssl") || caps+=("openssl(缺)")
    mig_has_rsync   && caps+=("rsync") || caps+=("rsync(缺)")
    echo -e "  ${DIM}能力：${N}${caps[*]}"
    [[ -n "${_MIG_LAST_BUNDLE:-}" ]] && \
      echo -e "  ${DIM}上次打包：${N}$(basename "$_MIG_LAST_BUNDLE")"
    echo ""
    echo -e "  ${DIM}── ① 打包（旧机）───────────────────${N}"
    echo "  1. 打包 bundle（多选 scope + 加密方式）"
    echo ""
    echo -e "  ${DIM}── ② 传递 ─────────────────────────${N}"
    echo "  2. 推送到新机 / 手动 scp 说明（旧机操作）"
    echo "  3. 从旧机拉取（新机操作，SSH+rsync）"
    echo ""
    echo -e "  ${DIM}── ③ 解包恢复（新机）───────────────${N}"
    echo "  4. 从本地 bundle 解包恢复"
    echo ""
    echo -e "  ${DIM}── 管理 ────────────────────────────${N}"
    echo "  5. 列出本机 bundle"
    echo "  6. 删除 bundle"
    echo "  7. 查看迁移指引"
    echo ""
    echo "  0. 返回"
    echo ""
    local choice
    read -erp "  请输入选择（0 返回）：" choice
    case "$choice" in
      1) migrate_action_pack ;;
      2) migrate_action_transfer ;;
      3) migrate_action_pull_from_old ;;
      4) migrate_action_restore_local ;;
      5) migrate_action_list ;;
      6) migrate_action_delete ;;
      7) migrate_show_guide ;;
      0) break ;;
      # 空输入 / 无效输入不退出菜单：迁移动作耗时长，期间误敲的回车会滞留
      # stdin，若这里 break 会连带退出上层菜单并 clear 掉执行结果
      "") continue ;;
      *)  warn "无效选择：$choice"; sleep 1; continue ;;
    esac
    echo ""
    flush_stdin
    read -rsp "  按回车继续..." _
    echo ""
  done
}
