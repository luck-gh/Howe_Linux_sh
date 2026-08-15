#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 统一版本对账（原生二进制 + 镜像）
#
# 从 migrate.sh 和 migrate_lib.sh 拆分出来，避免主文件过长
# ═══════════════════════════════════════════════════════════════════

# 统一对账表 —— 将原生二进制和镜像版本合并成一张表
# 调用时机：Docker 本体检查完成后、数据落位之前
# $1 = 备份点目录（含 host-inventory.json 和 docker-images.lock.json）
_mig_reconcile_all() {
  local bp_dir=$1
  local inv="$bp_dir/host-inventory.json"
  local lock="$bp_dir/docker-images.lock.json"

  # 检查依赖
  command -v python3 >/dev/null 2>&1 || { info "无 python3，跳过版本对账"; return 0; }
  [[ -f "$inv" ]] || { info "备份点无环境清单，跳过版本对账"; return 0; }

  # ── 收集数据：原生二进制 + 镜像 ──
  local -a t_type=() t_name=() t_want=() t_have=() t_state=() t_ids=() t_labels=() t_cur=() t_meta=()

  # ① 读取原生二进制版本信息（caddy/sing-box/frps）
  local -a bin_rows=()
  mapfile -t bin_rows < <(python3 -c "
import json,sys
try: nv=json.load(open(sys.argv[1])).get('native_versions',{}) or {}
except Exception: nv={}
for k in ('caddy','sing_box','frps'):
    v=nv.get(k) or ''
    if v: print(f'{k}|{v}')
" "$inv" 2>/dev/null)

  local row
  for row in "${bin_rows[@]}"; do
    local k want; IFS='|' read -r k want <<< "$row"
    local name pinnable
    case "$k" in
      caddy)    name="caddy";    pinnable=0 ;;
      sing_box) name="sing-box"; pinnable=1 ;;
      frps)     name="frps";     pinnable=1 ;;
      *) continue ;;
    esac

    local have; have=$(mig_local_tool_version "$name")
    local state ids labels

    if (( ! pinnable )); then
      # caddy：apt 源，不可锁版本
      if [[ -z "$have" ]]; then
        state="未安装"
        ids="skip"
        labels="提示手动安装（不可锁版本）"
      else
        state="不可锁版本"
        ids="keep"
        labels="保持 ${have}（apt 管理，不锁版本）"
      fi
    else
      if [[ -z "$have" ]]; then
        state="未安装"
        ids="install skip"
        labels="安装 ${want}"$'\x1f'"跳过"
      elif [[ "$have" == "$want" ]]; then
        state="已一致"
        ids="keep upgrade"
        labels="保持 ${want}"$'\x1f'"更新到最新版（不推荐）"
      else
        # 版本号比较：简单字符串比较（对于语义版本号基本正确）
        if [[ "$have" < "$want" ]]; then
          state="需要更新"
          ids="upgrade keep skip"
          labels="更新到 ${want}"$'\x1f'"保持 ${have}"$'\x1f'"跳过"
        else
          state="需要回退"
          ids="downgrade keep skip"
          labels="回退到 ${want}"$'\x1f'"保持 ${have}"$'\x1f'"跳过"
        fi
      fi
    fi

    t_type+=("工具"); t_name+=("$name"); t_want+=("$want"); t_have+=("$have")
    t_state+=("$state"); t_ids+=("$ids"); t_labels+=("$labels"); t_cur+=(0)
    t_meta+=("pinnable=$pinnable")
  done

  # ② 读取镜像版本信息（docker-images.lock.json）
  if [[ -f "$lock" ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local -a img_rows=()
    mapfile -t img_rows < <(python3 - "$lock" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for i in d.get("images", []):
    print("|".join([
        i.get("service", "") or i.get("container", ""),
        i.get("ref", ""),
        i.get("digest", ""),
        i.get("tag", ""),
        "1" if i.get("mutable_tag") else "0",
    ]))
PY
    )

    for row in "${img_rows[@]}"; do
      local svc ref dg tag mut
      IFS='|' read -r svc ref dg tag mut <<< "$row"
      [[ -n "$ref" ]] || continue

      local local_dg; local_dg=$(_mig_img_local_digest "$ref")
      local state ids labels

      if [[ -z "$dg" ]]; then
        state="无digest"
        ids="pull_tag skip"
        labels="按 tag 拉取（无法锁版本）"$'\x1f'"跳过"
      elif [[ -n "$local_dg" && "${local_dg##*@}" == "${dg##*@}" ]]; then
        state="已一致"
        ids="keep pull_tag"
        labels="保持现状"$'\x1f'"拉 tag 最新版"
      elif [[ -n "$local_dg" ]]; then
        state="版本不同"
        ids="pin pull_tag keep"
        labels="用 bundle 版本"$'\x1f'"拉 tag 最新版"$'\x1f'"保持本机"
      elif _mig_img_has_digest "$dg"; then
        state="缺tag"
        ids="pin pull_tag"
        labels="用 bundle 版本并打 tag"$'\x1f'"按 tag 重新拉取"
      else
        state="未安装"
        ids="pin pull_tag skip"
        labels="拉 bundle 版本"$'\x1f'"拉 tag 最新"$'\x1f'"跳过"
      fi

      t_type+=("镜像"); t_name+=("${svc:0:14}"); t_want+=("${ref:0:28}"); t_have+=("${local_dg:0:28}")
      t_state+=("$state"); t_ids+=("$ids"); t_labels+=("$labels"); t_cur+=(0)
      t_meta+=("ref=$ref|digest=$dg")
    done
  fi

  (( ${#t_name[@]} == 0 )) && { info "无需对账的工具或镜像"; return 0; }

  # ── 交互界面 ──
  section "版本对账（工具 + 镜像）"
  echo -e "  ${DIM}统一检查二进制工具与镜像版本，确保与旧机一致${N}"

  local _msg=""
  while true; do
    echo ""
    echo -e "  ${W}版本对账表${N}"
    echo -e "  ${DIM}输入编号切换策略 | a=全部对齐 bundle | 回车执行 | q 跳过${N}"
    echo ""
    printf "  %-4s %-6s %-14s %-28s %-12s %s\n" "" "类型" "名称" "旧机/bundle" "状态" "将执行"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────────────────────────${N}"

    local n=0 z
    for z in "${!t_name[@]}"; do
      n=$((n + 1))
      local -a _ids=() _labs=()
      read -ra _ids <<< "${t_ids[$z]}"
      IFS=$'\x1f' read -ra _labs <<< "${t_labels[$z]}"
      local cur=${t_cur[$z]}
      local sc="${t_state[$z]}" scol="$N"
      case "$sc" in
        已一致)      scol="$G" ;;
        需要更新|需要回退|版本不同) scol="$Y" ;;
        未安装|缺tag) scol="$C" ;;
        不可锁版本)  scol="$DIM" ;;
      esac

      local pad=$(( 12 - ${#sc} * 2 )); (( pad < 1 )) && pad=1
      printf "  %2d.  %-6s %-14s %-28s ${scol}%s${N}%*s %s\n" \
        "$n" "${t_type[$z]}" "${t_name[$z]}" "${t_want[$z]}" "$sc" "$pad" "" "${_labs[$cur]}"
    done

    echo ""
    [[ -n "$_msg" ]] && { echo -e "  ${Y}$_msg${N}"; _msg=""; echo ""; }

    local _in; read -erp "  选择: " _in
    [[ -z "$_in" ]] && break
    case "${_in,,}" in
      q|quit) info "已跳过版本对账"; return 0 ;;
      a)
        local changed=0 already=0
        for z in "${!t_name[@]}"; do
          local -a _ids=(); read -ra _ids <<< "${t_ids[$z]}"
          local target="" k
          # 寻找对齐策略：install/upgrade/downgrade/pin
          for k in "${!_ids[@]}"; do
            case "${_ids[$k]}" in
              install|upgrade|downgrade|pin) target=$k; break ;;
            esac
          done
          if [[ -n "$target" ]]; then
            (( t_cur[z] != target )) && changed=$((changed + 1))
            t_cur[$z]=$target
          else
            [[ "${t_state[$z]}" == "已一致" ]] && already=$((already + 1))
          fi
        done
        _msg="已对齐 bundle 版本：${changed} 项调整"
        (( already > 0 )) && _msg+="，${already} 项本就一致"
        ;;
      *)
        if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 1 && _in <= ${#t_name[@]} )); then
          z=$((_in - 1))
          local -a _ids=(); read -ra _ids <<< "${t_ids[$z]}"
          t_cur[$z]=$(( (t_cur[z] + 1) % ${#_ids[@]} ))
        else
          _msg="无效输入：$_in"
        fi
        ;;
    esac
  done

  # ── 执行 ──
  echo ""
  section "执行版本对账"
  local ok=0 fail=0 skipped=0

  for z in "${!t_name[@]}"; do
    local -a _ids=(); read -ra _ids <<< "${t_ids[$z]}"
    local act="${_ids[${t_cur[$z]}]}"
    local typ="${t_type[$z]}" name="${t_name[$z]}" want="${t_want[$z]}" have="${t_have[$z]}"
    local meta="${t_meta[$z]}"

    case "$act" in
      keep|skip)
        [[ "$act" == "skip" ]] && info "[$name] 跳过" && skipped=$((skipped + 1))
        [[ "$act" == "keep" ]] && skipped=$((skipped + 1))
        ;;
      install|upgrade|downgrade)
        # 二进制工具安装/切换
        local pinnable=1
        [[ "$meta" == *"pinnable=0"* ]] && pinnable=0
        if _mig_install_native "$name" "$want" "$have" "$pinnable"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
        fi
        ;;
      pin)
        # 镜像：按 digest 拉取并 retag
        local ref dg
        ref=$(echo "$meta" | grep -oP 'ref=\K[^|]+')
        dg=$(echo "$meta" | grep -oP 'digest=\K[^|]+')
        if _mig_img_has_digest "$dg"; then
          info "[$name] 本地已有该版本，直接打 tag"
        else
          info "[$name] 拉取 bundle 版本 ${dg##*@}"
          if ! docker pull "$dg" >/dev/null 2>&1; then
            warn "  ✗ $dg 拉取失败"
            fail=$((fail + 1))
            continue
          fi
        fi
        if docker tag "$dg" "$ref" 2>/dev/null; then
          log "  ✓ $ref → ${dg##*@}"
          ok=$((ok + 1))
        else
          warn "  ✗ $ref retag 失败"
          fail=$((fail + 1))
        fi
        ;;
      pull_tag)
        # 镜像：按 tag 拉最新
        local ref; ref=$(echo "$meta" | grep -oP 'ref=\K[^|]+')
        info "[$name] 拉取 $ref 最新版"
        if docker pull "$ref" >/dev/null 2>&1; then
          log "  ✓ $ref"
          ok=$((ok + 1))
        else
          warn "  ✗ $ref 拉取失败"
          fail=$((fail + 1))
        fi
        ;;
    esac
  done

  echo ""
  echo -e "  ${W}版本对账完成${N}：${G}${ok} 成功${N} / ${R}${fail} 失败${N} / ${DIM}${skipped} 保持不变${N}"
  return 0
}
