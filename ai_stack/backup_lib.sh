#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 备份/恢复 低层函数库
#
# 由 ai_stack/backup.sh（菜单）和后续 lifecycle hooks 共同调用
# 备份单元（scope）：
#   ai-pg     PostgreSQL 数据库 dump（sub2api + newapi）
#   ai-data   /opt/ai-stack 各服务 data/config 目录
#   ai-config /opt/ai-stack 顶层 docker-compose.yml 和 .env
#   clash     /opt/ai-stack/clash 订阅子系统
#   singbox   /etc/sing-box
#   caddy     /etc/caddy
#   ai-cli    ~/.claude ~/.codex ~/.opencode ~/.openclaw
#
# 备份点目录结构：/var/backups/howe/<timestamp>/
#   <scope>.tar.gz
#   <scope>.sha256
#   manifest.json
# ═══════════════════════════════════════════════════════════════════

BACKUP_ROOT_DEFAULT=/var/backups/howe
BACKUP_KEEP_DEFAULT=7
BACKUP_DEFAULT_SCOPES_DEFAULT="ai-pg,ai-data,ai-config,clash,singbox,caddy"
BACKUP_AUTO_BEFORE_UPGRADE_DEFAULT=true
BACKUP_TIMER_ENABLED_DEFAULT=false
BACKUP_TIMER_SCHEDULE_DEFAULT=daily

BACKUP_CONF_FILE="${BACKUP_CONF_FILE:-/etc/howe-backup.conf}"
BACKUP_AI_BASE="${BACKUP_AI_BASE:-${BASE_DIR:-/opt/ai-stack}}"

# 读取配置（不存在则返回默认值）
backup_conf_get() {
  local key=$1 default=$2
  if [[ -f "$BACKUP_CONF_FILE" ]]; then
    local v; v=$(grep -E "^${key}=" "$BACKUP_CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "$default"
}

# 写配置
backup_conf_set() {
  local key=$1 value=$2
  mkdir -p "$(dirname "$BACKUP_CONF_FILE")"
  touch "$BACKUP_CONF_FILE"
  chmod 0600 "$BACKUP_CONF_FILE"
  if grep -qE "^${key}=" "$BACKUP_CONF_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$BACKUP_CONF_FILE"
  else
    echo "${key}=${value}" >> "$BACKUP_CONF_FILE"
  fi
}

# BACKUP_ROOT 是动态值（可改），用 getter 读取
backup_root() { backup_conf_get ROOT "$BACKUP_ROOT_DEFAULT"; }
# 兼容老代码：BACKUP_ROOT 变量在每次调用前由 getter 同步
BACKUP_ROOT="$(backup_root)"

# 全部 scope 定义：key|描述|检测函数
BACKUP_SCOPES=(
  "ai-pg|PostgreSQL 数据库（sub2api / new-api）|_bk_has_ai_pg"
  "ai-data|AI 服务栈数据目录（sub2api / new-api / litellm / openwebui）|_bk_has_ai_data"
  "ai-config|AI 服务栈顶层配置（docker-compose.yml / .env）|_bk_has_ai_config"
  "clash|Clash 多订阅子系统（订阅库 / nft 状态）|_bk_has_clash"
  "singbox|sing-box 配置（/etc/sing-box）|_bk_has_singbox"
  "caddy|Caddy 配置（/etc/caddy）|_bk_has_caddy"
  "ai-cli|AI CLI 配置（claude / codex / opencode / openclaw）|_bk_has_ai_cli"
)

# ── 检测函数（决定 scope 是否对当前主机可用）────────────────────────
_bk_has_ai_pg()     { docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$'; }
_bk_has_ai_data()   { [[ -d "$BACKUP_AI_BASE" ]] && find "$BACKUP_AI_BASE" -maxdepth 2 -name 'data' -type d 2>/dev/null | grep -q .; }
_bk_has_ai_config() { [[ -f "$BACKUP_AI_BASE/docker-compose.yml" ]] || [[ -f "$BACKUP_AI_BASE/.env" ]]; }
_bk_has_clash()     { [[ -f "$BACKUP_AI_BASE/clash/subs.yaml" ]]; }
_bk_has_singbox()   { [[ -d /etc/sing-box ]]; }
_bk_has_caddy()     { [[ -f /etc/caddy/Caddyfile ]] || [[ -d /etc/caddy ]]; }
_bk_has_ai_cli()    { local d; for d in ~/.claude ~/.codex ~/.opencode ~/.openclaw; do [[ -d "$d" ]] && return 0; done; return 1; }

# ── 工具函数 ─────────────────────────────────────────────────────
_bk_ts() { date +%Y%m%d-%H%M%S; }

# 字节数转人类可读
_bk_human() {
  local b=${1:-0}
  awk -v b="$b" 'BEGIN{
    if (b > 1073741824) printf "%.1fG", b/1073741824;
    else if (b > 1048576) printf "%.1fM", b/1048576;
    else if (b > 1024) printf "%.1fK", b/1024;
    else printf "%dB", b;
  }'
}

# 写 sha256 校验文件
_bk_seal() {
  local f=$1
  ( cd "$(dirname "$f")" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
}

# 校验 sha256
_bk_verify() {
  local f=$1
  [[ -f "$f.sha256" ]] || return 1
  ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null 2>&1 )
}

# 列出所有可用 scope key（按检测函数过滤）
backup_available_scopes() {
  local entry key desc fn
  for entry in "${BACKUP_SCOPES[@]}"; do
    IFS='|' read -r key desc fn <<< "$entry"
    if "$fn" 2>/dev/null; then echo "$key"; fi
  done
}

# 查询 scope 描述
backup_scope_desc() {
  local want=$1 entry key desc fn
  for entry in "${BACKUP_SCOPES[@]}"; do
    IFS='|' read -r key desc fn <<< "$entry"
    [[ "$key" == "$want" ]] && { echo "$desc"; return; }
  done
}

# ── 单 scope 备份实现 ────────────────────────────────────────────
# 输出 .tar.gz 到 $1（备份点目录），返回 0 成功 / 非 0 失败
# 失败时不留半成品。

_bk_do_ai_pg() {
  local out=$1/ai-pg.tar.gz
  local tmp; tmp=$(mktemp -d /tmp/howe-bk-pg.XXXXXX)
  trap "rm -rf '$tmp'" RETURN

  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$' || { warn "ai-db 容器未运行，跳过 ai-pg"; return 1; }

  local dbs db
  dbs=$(docker exec ai-db psql -U ai -d postgres -tAc "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1');" 2>/dev/null | tr -d '\r')
  [[ -z "$dbs" ]] && { warn "ai-db 内未找到业务库"; return 1; }

  for db in $dbs; do
    docker exec ai-db pg_dump -U ai -d "$db" -Fc > "$tmp/${db}.dump" 2>/dev/null \
      || { warn "pg_dump $db 失败"; return 1; }
  done

  ( cd "$tmp" && tar czf "$out" ./*.dump ) || return 1
  _bk_seal "$out"
}

_bk_do_ai_data() {
  local out=$1/ai-data.tar.gz
  [[ -d "$BACKUP_AI_BASE" ]] || return 1
  local -a inc=()
  local d
  for d in sub2api new-api litellm openwebui; do
    [[ -d "$BACKUP_AI_BASE/$d" ]] && inc+=("$d")
  done
  [[ ${#inc[@]} -eq 0 ]] && { warn "AI 服务栈数据目录为空"; return 1; }
  ( cd "$BACKUP_AI_BASE" && tar czf "$out" "${inc[@]}" ) || return 1
  _bk_seal "$out"
}

_bk_do_ai_config() {
  local out=$1/ai-config.tar.gz
  local -a inc=()
  [[ -f "$BACKUP_AI_BASE/docker-compose.yml" ]] && inc+=("docker-compose.yml")
  [[ -f "$BACKUP_AI_BASE/.env" ]]               && inc+=(".env")
  [[ ${#inc[@]} -eq 0 ]] && { warn "AI 服务栈顶层配置不存在"; return 1; }
  ( cd "$BACKUP_AI_BASE" && tar czf "$out" "${inc[@]}" ) || return 1
  _bk_seal "$out"
}

_bk_do_clash() {
  local out=$1/clash.tar.gz
  [[ -d "$BACKUP_AI_BASE/clash" ]] || return 1
  # 排除 __pycache__；output/ 含订阅 token 一并打入
  ( cd "$BACKUP_AI_BASE" && tar czf "$out" \
      --exclude='clash/__pycache__' \
      clash ) || return 1
  _bk_seal "$out"
}

_bk_do_singbox() {
  local out=$1/singbox.tar.gz
  [[ -d /etc/sing-box ]] || return 1
  ( cd /etc && tar czf "$out" sing-box ) || return 1
  _bk_seal "$out"
}

_bk_do_caddy() {
  local out=$1/caddy.tar.gz
  [[ -d /etc/caddy ]] || return 1
  ( cd /etc && tar czf "$out" caddy ) || return 1
  _bk_seal "$out"
}

_bk_do_ai_cli() {
  local out=$1/ai-cli.tar.gz
  local -a inc=()
  local d
  for d in .claude .codex .opencode .openclaw; do
    [[ -d "$HOME/$d" ]] && inc+=("$d")
  done
  [[ ${#inc[@]} -eq 0 ]] && { warn "AI CLI 配置目录均不存在"; return 1; }
  ( cd "$HOME" && tar czf "$out" "${inc[@]}" ) || return 1
  _bk_seal "$out"
}

# ── 单 scope 恢复实现 ────────────────────────────────────────────
# 输入 $1 = .tar.gz 文件路径
# 调用前必须 _bk_verify 通过

_bk_rs_ai_pg() {
  local arc=$1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$' \
    || { warn "ai-db 容器未运行，无法恢复 ai-pg"; return 1; }

  local tmp; tmp=$(mktemp -d /tmp/howe-rs-pg.XXXXXX)
  trap "rm -rf '$tmp'" RETURN

  tar xzf "$arc" -C "$tmp" || { warn "解包 ai-pg 失败"; return 1; }

  # 停掉所有连库的容器，避免 DROP 时被持有
  local -a using=()
  local svc
  for svc in sub2api new-api; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$" && using+=("$svc")
  done
  if [[ ${#using[@]} -gt 0 ]]; then
    info "暂停容器：${using[*]}"
    ( cd "$BACKUP_AI_BASE" && docker compose stop "${using[@]}" >/dev/null 2>&1 )
  fi

  local f db
  for f in "$tmp"/*.dump; do
    [[ -f "$f" ]] || continue
    db=$(basename "$f" .dump)
    info "恢复数据库 $db"
    docker cp "$f" ai-db:/tmp/restore.dump >/dev/null \
      || { warn "复制 dump 到容器失败"; return 1; }
    docker exec ai-db psql -U ai -d postgres -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" >/dev/null 2>&1 \
      || docker exec ai-db psql -U ai -d postgres -c "DROP DATABASE IF EXISTS \"$db\";" >/dev/null 2>&1
    docker exec ai-db psql -U ai -d postgres -c "CREATE DATABASE \"$db\" OWNER ai;" >/dev/null \
      || { warn "创建数据库 $db 失败"; return 1; }
    docker exec ai-db pg_restore -U ai -d "$db" /tmp/restore.dump >/dev/null 2>&1 \
      || { warn "pg_restore $db 失败"; return 1; }
    docker exec ai-db rm -f /tmp/restore.dump >/dev/null 2>&1
  done

  if [[ ${#using[@]} -gt 0 ]]; then
    info "重启容器：${using[*]}"
    ( cd "$BACKUP_AI_BASE" && docker compose start "${using[@]}" >/dev/null 2>&1 )
  fi
}

_bk_rs_ai_data() {
  [[ -d "$BACKUP_AI_BASE" ]] || mkdir -p "$BACKUP_AI_BASE"
  tar xzf "$1" -C "$BACKUP_AI_BASE"
}

_bk_rs_ai_config() {
  [[ -d "$BACKUP_AI_BASE" ]] || mkdir -p "$BACKUP_AI_BASE"
  tar xzf "$1" -C "$BACKUP_AI_BASE"
}

_bk_rs_clash() {
  [[ -d "$BACKUP_AI_BASE" ]] || mkdir -p "$BACKUP_AI_BASE"
  tar xzf "$1" -C "$BACKUP_AI_BASE"
}

_bk_rs_singbox() { tar xzf "$1" -C /etc; }
_bk_rs_caddy()   { tar xzf "$1" -C /etc; }
_bk_rs_ai_cli()  { tar xzf "$1" -C "$HOME"; }

# ── 顶层调度 ─────────────────────────────────────────────────────

# 创建一个备份点，备份指定 scope 列表
# $1 = 备注（可空）
# $2..$N = scope keys
# 输出：成功时 echo 备份点目录路径
backup_create() {
  BACKUP_ROOT=$(backup_root)
  local note=$1; shift
  local -a scopes=("$@")
  [[ ${#scopes[@]} -eq 0 ]] && { warn "未指定备份 scope"; return 1; }

  local ts; ts=$(_bk_ts)
  local dir=$BACKUP_ROOT/$ts
  mkdir -p "$dir" || { warn "创建备份目录失败：$dir"; return 1; }
  # 备份内含敏感数据（PG dump / JWT / 订阅 token），仅 root 可读
  chmod 0700 "$BACKUP_ROOT" 2>/dev/null
  chmod 0700 "$dir" 2>/dev/null

  local -a ok=() fail=()
  local sk fn
  for sk in "${scopes[@]}"; do
    fn=_bk_do_${sk//-/_}
    if declare -F "$fn" >/dev/null 2>&1 && "$fn" "$dir" >&2; then
      ok+=("$sk"); log "已备份：$sk" >&2
    else
      fail+=("$sk"); warn "备份失败：$sk" >&2
    fi
  done

  # 写 manifest（note 通过 python json.dumps 安全转义；缺 python 时退化为基础转义）
  local host kernel created_iso note_json
  host=$(hostname)
  kernel=$(uname -r)
  created_iso=$(date -Iseconds)
  if command -v python3 >/dev/null 2>&1; then
    note_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$note" 2>/dev/null)
  fi
  [[ -z "$note_json" ]] && note_json="\"${note//\\/\\\\}\"" && note_json="${note_json//\"/\\\"}" && note_json="\"${note_json#\"}" && note_json="${note_json%\"}\""
  # JSON 数组拼接（避免空数组输出 [""]）
  local ok_json fail_json
  ok_json="["
  if (( ${#ok[@]} > 0 )); then ok_json+="$(printf '"%s",' "${ok[@]}")"; ok_json="${ok_json%,}"; fi
  ok_json+="]"
  fail_json="["
  if (( ${#fail[@]} > 0 )); then fail_json+="$(printf '"%s",' "${fail[@]}")"; fail_json="${fail_json%,}"; fi
  fail_json+="]"
  {
    echo '{'
    echo "  \"timestamp\": \"$ts\","
    echo "  \"created_at\": \"$created_iso\","
    echo "  \"host\": \"$host\","
    echo "  \"kernel\": \"$kernel\","
    echo "  \"note\": $note_json,"
    echo "  \"scopes_ok\": $ok_json,"
    echo "  \"scopes_fail\": $fail_json"
    echo '}'
  } > "$dir/manifest.json"

  # 全部失败：清掉备份点
  if [[ ${#ok[@]} -eq 0 ]]; then
    rm -rf "$dir"
    return 1
  fi

  echo "$dir"
  return 0
}

# 列出所有备份点（按时间倒序）
# 输出每行：timestamp|size_bytes|scopes_csv|note
backup_list() {
  BACKUP_ROOT=$(backup_root)
  [[ -d "$BACKUP_ROOT" ]] || return 0
  local d ts size scopes note
  for d in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort -r); do
    [[ -d "$BACKUP_ROOT/$d" ]] || continue
    ts=$d
    size=$(du -sb "$BACKUP_ROOT/$d" 2>/dev/null | awk '{print $1}')
    scopes=$(ls "$BACKUP_ROOT/$d"/*.tar.gz 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.tar\.gz$//' | tr '\n' ',' | sed 's/,$//')
    # note：优先用 python 解出真实字符串（兼容旧 manifest 中的 \uXXXX）
    if [[ -f "$BACKUP_ROOT/$d/manifest.json" ]] && command -v python3 >/dev/null 2>&1; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$BACKUP_ROOT/$d/manifest.json" 2>/dev/null)
    else
      note=$(grep -oP '"note":\s*"\K[^"]*' "$BACKUP_ROOT/$d/manifest.json" 2>/dev/null)
    fi
    echo "$ts|$size|$scopes|$note"
  done
}

# 列出指定备份点内的 scope 列表（用于交互选择恢复）
backup_point_scopes() {
  BACKUP_ROOT=$(backup_root)
  local ts=$1
  local d=$BACKUP_ROOT/$ts
  [[ -d "$d" ]] || return 1
  ls "$d"/*.tar.gz 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.tar\.gz$//'
}

# 校验备份点完整性
# 返回 0=全部通过；输出失败的 scope
backup_verify() {
  BACKUP_ROOT=$(backup_root)
  local ts=$1
  local d=$BACKUP_ROOT/$ts
  [[ -d "$d" ]] || return 1
  local f bad=0
  for f in "$d"/*.tar.gz; do
    [[ -f "$f" ]] || continue
    if ! _bk_verify "$f"; then
      echo "$(basename "$f" .tar.gz)"
      bad=1
    fi
  done
  return $bad
}

# 从备份点恢复指定 scope
# $1 = timestamp
# $2..$N = scope keys
backup_restore() {
  BACKUP_ROOT=$(backup_root)
  local ts=$1; shift
  local d=$BACKUP_ROOT/$ts
  [[ -d "$d" ]] || { warn "备份点不存在：$ts"; return 1; }

  local sk fn arc
  for sk in "$@"; do
    arc=$d/$sk.tar.gz
    [[ -f "$arc" ]] || { warn "$sk 未在该备份点中"; continue; }
    if ! _bk_verify "$arc"; then
      warn "$sk 校验失败，跳过"
      continue
    fi
    fn=_bk_rs_${sk//-/_}
    if declare -F "$fn" >/dev/null 2>&1 && "$fn" "$arc"; then
      log "已恢复：$sk"
    else
      warn "恢复失败：$sk"
    fi
  done
}

# 删除备份点
backup_delete() {
  BACKUP_ROOT=$(backup_root)
  local ts=$1
  local d=$BACKUP_ROOT/$ts
  [[ -d "$d" ]] || return 1
  rm -rf "$d"
}

# 应用保留策略：每个 scope 独立计数，超过 N 份的从最旧删
# $1 = 保留份数
backup_apply_retention() {
  BACKUP_ROOT=$(backup_root)
  local keep=${1:-$BACKUP_KEEP_DEFAULT}
  [[ -d "$BACKUP_ROOT" ]] || return 0
  (( keep < 1 )) && return 0

  # 收集 (scope, timestamp) 对，按 scope 分组按时间倒序
  local entry sk
  declare -A seen
  declare -A keep_ts

  # 先把每个 scope 在每个备份点出现的时间戳列出来
  local d ts
  for d in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort -r); do
    [[ -d "$BACKUP_ROOT/$d" ]] || continue
    ts=$d
    for f in "$BACKUP_ROOT/$d"/*.tar.gz; do
      [[ -f "$f" ]] || continue
      sk=$(basename "$f" .tar.gz)
      seen[$sk]=$(( ${seen[$sk]:-0} + 1 ))
      if (( seen[$sk] <= keep )); then
        keep_ts[$ts]=1
      fi
    done
  done

  # 删除：备份点目录内没有任何 scope 仍在保留集合中的 → 整个删
  local removed=0
  for d in $(ls -1 "$BACKUP_ROOT" 2>/dev/null); do
    [[ -d "$BACKUP_ROOT/$d" ]] || continue
    if [[ -z "${keep_ts[$d]:-}" ]]; then
      rm -rf "$BACKUP_ROOT/$d"
      removed=$((removed+1))
    fi
  done
  echo "$removed"
}

# ── systemd timer 管理 ──────────────────────────────────────────
BACKUP_TIMER_NAME=howe-backup
BACKUP_TIMER_SVC_FILE=/etc/systemd/system/${BACKUP_TIMER_NAME}.service
BACKUP_TIMER_TIMER_FILE=/etc/systemd/system/${BACKUP_TIMER_NAME}.timer
BACKUP_RUNNER_PATH=/usr/local/bin/howe-backup-run

# 写入定时备份的 runner 脚本（systemd 调用它）
# 备份范围统一读 DEFAULT_SCOPES（与设置页「默认备份范围」一致）
_backup_install_runner() {
  cat > "$BACKUP_RUNNER_PATH" <<'RUNNER'
#!/usr/bin/env bash
# howe-backup 自动备份 runner（由 systemd timer 调用）
set -uo pipefail
SRC_DIR=__BACKUP_SRC_DIR__
source "$SRC_DIR/core.sh" 2>/dev/null || true
source "$SRC_DIR/backup_lib.sh"

SCOPES=$(backup_conf_get DEFAULT_SCOPES "$BACKUP_DEFAULT_SCOPES_DEFAULT")
KEEP=$(backup_conf_get KEEP "$BACKUP_KEEP_DEFAULT")
[[ -z "$SCOPES" ]] && exit 0
IFS=',' read -ra SCOPE_ARR <<< "$SCOPES"
backup_create "auto-$(date +%F)" "${SCOPE_ARR[@]}" >/dev/null 2>&1
backup_apply_retention "$KEEP" >/dev/null 2>&1
RUNNER
  local src_dir
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sed -i "s|__BACKUP_SRC_DIR__|$src_dir|" "$BACKUP_RUNNER_PATH"
  chmod 0755 "$BACKUP_RUNNER_PATH"
}

# 把 schedule 配置项转成 systemd OnCalendar
_backup_schedule_to_oncalendar() {
  case "$1" in
    daily)   echo "*-*-* 03:30:00" ;;
    weekly)  echo "Sun *-*-* 03:30:00" ;;
    hourly)  echo "*:00:00" ;;
    *)       echo "$1" ;;   # 自定义直接透传
  esac
}

# 启用 timer
backup_timer_enable() {
  local schedule; schedule=$(backup_conf_get TIMER_SCHEDULE "$BACKUP_TIMER_SCHEDULE_DEFAULT")
  local oncal; oncal=$(_backup_schedule_to_oncalendar "$schedule")

  _backup_install_runner

  cat > "$BACKUP_TIMER_SVC_FILE" <<UNIT
[Unit]
Description=Howe Linux 自动备份
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=$BACKUP_RUNNER_PATH
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT

  cat > "$BACKUP_TIMER_TIMER_FILE" <<UNIT
[Unit]
Description=Howe Linux 自动备份定时器

[Timer]
OnCalendar=$oncal
Persistent=true
Unit=${BACKUP_TIMER_NAME}.service

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${BACKUP_TIMER_NAME}.timer" >/dev/null 2>&1
  backup_conf_set TIMER_ENABLED true
}

# 禁用 timer
backup_timer_disable() {
  systemctl disable --now "${BACKUP_TIMER_NAME}.timer" >/dev/null 2>&1
  rm -f "$BACKUP_TIMER_TIMER_FILE" "$BACKUP_TIMER_SVC_FILE"
  systemctl daemon-reload
  backup_conf_set TIMER_ENABLED false
}

# 查询 timer 状态
backup_timer_status() {
  systemctl is-active "${BACKUP_TIMER_NAME}.timer" 2>/dev/null
}

# 下次触发时间
backup_timer_next_run() {
  systemctl list-timers --all 2>/dev/null | awk -v t="${BACKUP_TIMER_NAME}.timer" '$NF==t{for(i=1;i<=4;i++)printf "%s ",$i; print ""}' | sed 's/ *$//'
}

# ── 升级 hook：迁移到新存储路径 ──────────────────────────────────
backup_root_migrate() {
  local new_root=$1
  local old_root; old_root=$(backup_root)
  [[ "$old_root" == "$new_root" ]] && return 0
  if [[ -d "$old_root" ]]; then
    mkdir -p "$new_root"
    chmod 0700 "$new_root"
    if [[ -n "$(ls -A "$old_root" 2>/dev/null)" ]]; then
      info "迁移已有备份：$old_root → $new_root"
      mv "$old_root"/* "$new_root"/ 2>/dev/null || {
        warn "迁移失败，回滚配置"
        return 1
      }
    fi
    rmdir "$old_root" 2>/dev/null
  fi
  backup_conf_set ROOT "$new_root"
  BACKUP_ROOT=$new_root
}
# $1..$N = scope keys
backup_estimate_size() {
  local total=0 sk
  for sk in "$@"; do
    case "$sk" in
      ai-pg)
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$'; then
          local s
          s=$(docker exec ai-db sh -c "du -sb /var/lib/postgresql/data 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
          [[ -n "$s" ]] && total=$((total + s / 4))   # dump 一般是数据目录的 1/4 ~ 1/2
        fi ;;
      ai-data)
        local _d _s
        for _d in sub2api new-api litellm openwebui; do
          if [[ -d "$BACKUP_AI_BASE/$_d" ]]; then
            _s=$(du -sb "$BACKUP_AI_BASE/$_d" 2>/dev/null | awk '{print $1}')
            [[ -n "$_s" ]] && total=$((total + _s))
          fi
        done ;;
      ai-config)
        [[ -f "$BACKUP_AI_BASE/docker-compose.yml" ]] && total=$((total + $(stat -c%s "$BACKUP_AI_BASE/docker-compose.yml" 2>/dev/null || echo 0)))
        [[ -f "$BACKUP_AI_BASE/.env" ]]               && total=$((total + $(stat -c%s "$BACKUP_AI_BASE/.env" 2>/dev/null || echo 0))) ;;
      clash)     [[ -d "$BACKUP_AI_BASE/clash" ]] && total=$((total + $(du -sb "$BACKUP_AI_BASE/clash" 2>/dev/null | awk '{print $1}'))) ;;
      singbox)   [[ -d /etc/sing-box ]] && total=$((total + $(du -sb /etc/sing-box 2>/dev/null | awk '{print $1}'))) ;;
      caddy)     [[ -d /etc/caddy ]]    && total=$((total + $(du -sb /etc/caddy 2>/dev/null | awk '{print $1}'))) ;;
      ai-cli)
        local d
        for d in ~/.claude ~/.codex ~/.opencode ~/.openclaw; do
          [[ -d "$d" ]] && total=$((total + $(du -sb "$d" 2>/dev/null | awk '{print $1}')))
        done ;;
    esac
  done
  echo "$total"
}

