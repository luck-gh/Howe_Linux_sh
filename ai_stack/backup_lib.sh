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
#   kiro      /opt/ai-stack/kiro-rs/config（config.json + credentials.json）
#
# 备份点目录结构：/var/backups/howe/<timestamp>/
#   <scope>.tar.gz
#   <scope>.sha256
#   manifest.json
# ═══════════════════════════════════════════════════════════════════

BACKUP_ROOT_DEFAULT=/var/backups/howe
BACKUP_KEEP_DEFAULT=7
BACKUP_DEFAULT_SCOPES_DEFAULT="ai-pg,ai-data,ai-config,clash,singbox,caddy,kiro,system-sec,system-tune"
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
  "caddy|Caddy 配置与证书（/etc/caddy + /var/lib/caddy）|_bk_has_caddy"
  "ai-cli|AI CLI 配置（claude / codex / opencode / openclaw）|_bk_has_ai_cli"
  "kiro|kiro-rs 配置（config.json / credentials.json）|_bk_has_kiro"
  "nrouter|9router 数据目录（/opt/ai-stack/9router/data）|_bk_has_nrouter"
  "system-sec|主机安全（fail2ban / iptables / ipset）|_bk_has_system_sec"
  "system-tune|主机调优（sysctl / zram / earlyoom / crontab）|_bk_has_system_tune"
  "docker-images|Docker 镜像（记录名单或 docker save 打包）|_bk_has_docker_images"
  "custom|自定义路径（由 MIG_CUSTOM_PATHS 指定）|_bk_has_custom"
)

# ── 检测函数（决定 scope 是否对当前主机可用）────────────────────────
_bk_has_ai_pg()     { docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ai-db$'; }
_bk_has_ai_data()   { [[ -d "$BACKUP_AI_BASE" ]] && find "$BACKUP_AI_BASE" -maxdepth 2 -name 'data' -type d 2>/dev/null | grep -q .; }
_bk_has_ai_config() { [[ -f "$BACKUP_AI_BASE/docker-compose.yml" ]] || [[ -f "$BACKUP_AI_BASE/.env" ]]; }
_bk_has_clash()     { [[ -f "$BACKUP_AI_BASE/clash/subs.yaml" ]]; }
_bk_has_singbox()   { [[ -d /etc/sing-box ]]; }
_bk_has_caddy()     { [[ -f /etc/caddy/Caddyfile ]] || [[ -d /etc/caddy ]]; }
_bk_has_ai_cli()    { local d; for d in ~/.claude ~/.codex ~/.opencode ~/.openclaw; do [[ -d "$d" ]] && return 0; done; return 1; }
_bk_has_kiro()      { [[ -d "$BACKUP_AI_BASE/kiro-rs/config" ]]; }
_bk_has_nrouter()   { [[ -d "$BACKUP_AI_BASE/9router/data" ]]; }
_bk_has_system_sec() {
  # 有实际内容才算可用（避免只装了命令但没配任何规则时误判）
  [[ -f /etc/fail2ban/jail.local ]] && return 0
  compgen -G "/etc/fail2ban/jail.d/*.local" >/dev/null 2>&1 && return 0
  compgen -G "/etc/fail2ban/jail.d/*.conf"  >/dev/null 2>&1 && return 0
  [[ -f /etc/iptables/rules.v4 ]] && return 0
  [[ -f /etc/iptables/rules.v6 ]] && return 0
  command -v ipset >/dev/null 2>&1 && ipset list -n 2>/dev/null | grep -q . && return 0
  return 1
}
_bk_has_system_tune() {
  compgen -G "/etc/sysctl.d/99-howe-*.conf" >/dev/null 2>&1 \
    || [[ -f /etc/default/zramswap ]] || [[ -f /etc/default/earlyoom ]] \
    || crontab -l -u root 2>/dev/null | grep -q .
}
_bk_has_docker_images() {
  command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | grep -q .
}
_bk_has_custom() {
  [[ -n "${MIG_CUSTOM_PATHS:-}" ]]
}

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

# ── 备份进度显示 ─────────────────────────────────────────────────
_BK_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# 是否显示动画进度（stderr 是 tty 且未被显式关闭）
_bk_progress_tty() {
  [[ "${BACKUP_PROGRESS:-auto}" != "off" ]] && [[ -t 2 ]]
}

# 起止时间戳（ns）转 "N.Ns"
_bk_dur_s() {
  local diff=$(( $2 - $1 ))
  (( diff < 0 )) && diff=0
  local s=$(( diff / 1000000000 ))
  local ms=$(( (diff / 100000000) % 10 ))
  printf "%d.%ds" "$s" "$ms"
}

# 运行单个 scope 备份并渲染进度
# $1=idx $2=total $3=scope $4=desc $5=fn $6=dir
_bk_run_scope_with_progress() {
  local idx=$1 total=$2 sk=$3 desc=$4 fn=$5 dir=$6
  local prefix; prefix=$(printf "[%d/%d]" "$idx" "$total")
  local start end rc dur sz
  local log; log=$(mktemp /tmp/howe-bk-scope.XXXXXX)
  start=$(date +%s%N)

  if _bk_progress_tty; then
    ( "$fn" "$dir" ) >"$log" 2>&1 &
    local pid=$! i=0 frame
    while kill -0 "$pid" 2>/dev/null; do
      frame=${_BK_SPIN_FRAMES[$(( i % ${#_BK_SPIN_FRAMES[@]} ))]}
      printf "\r\033[K  %s %s %-14s ${DIM}%s${N}" "$prefix" "$frame" "$sk" "$desc" >&2
      i=$((i+1))
      sleep 0.1
    done
    wait "$pid"; rc=$?
    end=$(date +%s%N); dur=$(_bk_dur_s "$start" "$end")
    if (( rc == 0 )); then
      sz=$(stat -c%s "$dir/$sk.tar.gz" 2>/dev/null || echo 0)
      printf "\r\033[K  %s ${G}✓${N} %-14s %s   %s\n" \
        "$prefix" "$sk" "$(_bk_human "$sz")" "$dur" >&2
    else
      printf "\r\033[K  %s ${R}✗${N} %-14s ${R}失败${N}   %s\n" \
        "$prefix" "$sk" "$dur" >&2
      [[ -s "$log" ]] && sed 's/^/      /' "$log" >&2
    fi
  else
    "$fn" "$dir" >"$log" 2>&1; rc=$?
    end=$(date +%s%N); dur=$(_bk_dur_s "$start" "$end")
    if (( rc == 0 )); then
      sz=$(stat -c%s "$dir/$sk.tar.gz" 2>/dev/null || echo 0)
      printf "  %s ✓ %-14s %s   %s\n" \
        "$prefix" "$sk" "$(_bk_human "$sz")" "$dur" >&2
    else
      printf "  %s ✗ %-14s 失败   %s\n" "$prefix" "$sk" "$dur" >&2
      [[ -s "$log" ]] && sed 's/^/      /' "$log" >&2
    fi
  fi
  rm -f "$log"
  return "$rc"
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
  local -a inc=()
  [[ -d /etc/caddy ]]     && inc+=("etc/caddy")
  [[ -d /var/lib/caddy ]] && inc+=("var/lib/caddy")
  (( ${#inc[@]} == 0 )) && return 1
  ( cd / && tar czf "$out" "${inc[@]}" ) || return 1
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
_bk_rs_caddy() {
  tar xzf "$1" -C /
  # 归还 caddy 用户所有权（跨机 uid/gid 可能不同）
  if id caddy >/dev/null 2>&1 && [[ -d /var/lib/caddy ]]; then
    chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true
  fi
}
_bk_rs_ai_cli()  { tar xzf "$1" -C "$HOME"; }

_bk_do_kiro() {
  local out=$1/kiro.tar.gz
  [[ -d "$BACKUP_AI_BASE/kiro-rs/config" ]] || return 1
  ( cd "$BACKUP_AI_BASE" && tar czf "$out" kiro-rs/config ) || return 1
  _bk_seal "$out"
}

_bk_rs_kiro() {
  [[ -d "$BACKUP_AI_BASE/kiro-rs" ]] || mkdir -p "$BACKUP_AI_BASE/kiro-rs"
  tar xzf "$1" -C "$BACKUP_AI_BASE"
}

_bk_do_nrouter() {
  local out=$1/nrouter.tar.gz
  [[ -d "$BACKUP_AI_BASE/9router/data" ]] || return 1
  ( cd "$BACKUP_AI_BASE" && tar czf "$out" 9router/data ) || return 1
  _bk_seal "$out"
}

_bk_rs_nrouter() {
  [[ -d "$BACKUP_AI_BASE/9router" ]] || mkdir -p "$BACKUP_AI_BASE/9router"
  tar xzf "$1" -C "$BACKUP_AI_BASE"
}

# ── system-sec：主机层安全配置 ────────────────────────────────────
# 打包：fail2ban 配置 + iptables 规则文件 + ipset 名单导出
# 不打包运行时 iptables/ipset 内存状态（新机上要 restore 后 iptables-restore）
_bk_do_system_sec() {
  local out=$1/system-sec.tar.gz
  local tmp; tmp=$(mktemp -d /tmp/howe-bk-sec.XXXXXX)
  trap "rm -rf '$tmp'" RETURN

  local -a inc=()
  if [[ -d /etc/fail2ban ]]; then
    ( cd /etc && tar cf - \
        --exclude='fail2ban/*.sock' \
        --exclude='fail2ban/*.pid' \
        fail2ban 2>/dev/null ) | ( cd "$tmp" && tar xf - ) 2>/dev/null \
      && inc+=("fail2ban") || true
  fi
  if [[ -d /etc/iptables ]]; then
    cp -a /etc/iptables "$tmp/" 2>/dev/null && inc+=("iptables") || true
  fi
  # 导出当前 iptables/ip6tables 规则（新机可直接 iptables-restore）
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > "$tmp/iptables.rules.v4" 2>/dev/null && inc+=("iptables-runtime") || true
  fi
  if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > "$tmp/iptables.rules.v6" 2>/dev/null || true
  fi
  # 导出 ipset 名单
  if command -v ipset >/dev/null 2>&1 && ipset list -n 2>/dev/null | grep -q .; then
    ipset save > "$tmp/ipset.save" 2>/dev/null && inc+=("ipset") || true
  fi
  [[ ${#inc[@]} -eq 0 ]] && { warn "system-sec 无可打包内容"; return 1; }

  ( cd "$tmp" && tar czf "$out" . ) || return 1
  _bk_seal "$out"
}

# 恢复：写文件到位；iptables/ipset 需要用户确认后手动 apply（避免锁住 SSH）
_bk_rs_system_sec() {
  local arc=$1
  local tmp; tmp=$(mktemp -d /tmp/howe-rs-sec.XXXXXX)
  trap "rm -rf '$tmp'" RETURN
  tar xzf "$arc" -C "$tmp" || return 1

  # fail2ban：直接落到 /etc
  if [[ -d "$tmp/fail2ban" ]]; then
    mkdir -p /etc/fail2ban
    ( cd "$tmp" && tar cf - fail2ban ) | ( cd /etc && tar xf - )
    log "已恢复 /etc/fail2ban（需要 systemctl restart fail2ban 生效）"
  fi
  # iptables 规则文件：落回 /etc/iptables
  if [[ -d "$tmp/iptables" ]]; then
    mkdir -p /etc/iptables
    cp -a "$tmp/iptables/." /etc/iptables/
    log "已恢复 /etc/iptables 规则文件"
  fi
  # 运行时规则和 ipset：只放到目录里，不 apply（避免锁 SSH）
  local staging=/root/howe-migrate-restore
  mkdir -p "$staging"
  local staged=0
  for f in iptables.rules.v4 iptables.rules.v6 ipset.save; do
    [[ -f "$tmp/$f" ]] && cp "$tmp/$f" "$staging/" && staged=1
  done
  if (( staged )); then
    warn "以下规则已放入 $staging，未自动 apply（防止误封 SSH）："
    ls -1 "$staging" | sed 's/^/    /'
    echo "    请在确认好后手动执行："
    echo "      iptables-restore < $staging/iptables.rules.v4"
    echo "      ip6tables-restore < $staging/iptables.rules.v6"
    echo "      ipset restore < $staging/ipset.save"
  fi
}

# ── system-tune：主机层内核/调度配置 ───────────────────────────────
_bk_do_system_tune() {
  local out=$1/system-tune.tar.gz
  local tmp; tmp=$(mktemp -d /tmp/howe-bk-tune.XXXXXX)
  trap "rm -rf '$tmp'" RETURN

  local -a inc=()
  # 项目专属 sysctl 配置（99-howe-*.conf）
  if compgen -G "/etc/sysctl.d/99-howe-*.conf" >/dev/null; then
    mkdir -p "$tmp/sysctl.d"
    cp /etc/sysctl.d/99-howe-*.conf "$tmp/sysctl.d/" 2>/dev/null && inc+=("sysctl.d") || true
  fi
  # zram / earlyoom 配置
  [[ -f /etc/default/zramswap ]] && { mkdir -p "$tmp/default"; cp /etc/default/zramswap "$tmp/default/" && inc+=("zramswap"); }
  [[ -f /etc/default/earlyoom ]] && { mkdir -p "$tmp/default"; cp /etc/default/earlyoom "$tmp/default/" && inc+=("earlyoom"); }
  # root crontab
  if command -v crontab >/dev/null 2>&1; then
    crontab -l -u root > "$tmp/root.crontab" 2>/dev/null && [[ -s "$tmp/root.crontab" ]] && inc+=("crontab") || rm -f "$tmp/root.crontab"
  fi
  [[ ${#inc[@]} -eq 0 ]] && { warn "system-tune 无可打包内容"; return 1; }

  ( cd "$tmp" && tar czf "$out" . ) || return 1
  _bk_seal "$out"
}

_bk_rs_system_tune() {
  local arc=$1
  local tmp; tmp=$(mktemp -d /tmp/howe-rs-tune.XXXXXX)
  trap "rm -rf '$tmp'" RETURN
  tar xzf "$arc" -C "$tmp" || return 1

  if [[ -d "$tmp/sysctl.d" ]]; then
    cp "$tmp/sysctl.d/"*.conf /etc/sysctl.d/ 2>/dev/null || true
    log "已恢复 /etc/sysctl.d/99-howe-*.conf（sysctl --system 生效）"
    sysctl --system >/dev/null 2>&1 || true
  fi
  if [[ -d "$tmp/default" ]]; then
    [[ -f "$tmp/default/zramswap" ]] && cp "$tmp/default/zramswap" /etc/default/ && log "已恢复 /etc/default/zramswap"
    [[ -f "$tmp/default/earlyoom" ]] && cp "$tmp/default/earlyoom" /etc/default/ && log "已恢复 /etc/default/earlyoom"
  fi
  if [[ -f "$tmp/root.crontab" ]]; then
    # 不覆盖：写入待应用文件，让用户对比
    cp "$tmp/root.crontab" /root/howe-migrate-restore/root.crontab 2>/dev/null || {
      mkdir -p /root/howe-migrate-restore
      cp "$tmp/root.crontab" /root/howe-migrate-restore/
    }
    warn "旧机 root crontab 已放入 /root/howe-migrate-restore/root.crontab（未自动 apply）"
    echo "    对比后可执行： crontab /root/howe-migrate-restore/root.crontab"
  fi
}

# ── docker-images scope ───────────────────────────────────────────
# MIG_DOCKER_STRATEGY = "record"（默认，仅记录镜像名）或 "save"（docker save 打包）
_bk_do_docker_images() {
  local out=$1/docker-images.tar.gz
  local strategy="${MIG_DOCKER_STRATEGY:-record}"
  local tmp; tmp=$(mktemp -d /tmp/howe-bk-docker.XXXXXX)
  trap "rm -rf '$tmp'" RETURN

  # 始终记录运行中镜像名单（解包时 pull 用）
  docker ps --format '{{.Image}}' 2>/dev/null | sort -u > "$tmp/running-images.list"
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u > "$tmp/all-images.list"
  echo "$strategy" > "$tmp/pack-strategy"

  if [[ "$strategy" == "save" ]]; then
    local -a imgs=()
    mapfile -t imgs < "$tmp/running-images.list"
    if (( ${#imgs[@]} > 0 )); then
      info "docker save ${#imgs[@]} 个镜像，可能需要较长时间..." >&2
      docker save "${imgs[@]}" 2>/dev/null | gzip > "$tmp/docker-images.tar.gz" \
        || { warn "docker save 失败，降级为 record 模式" >&2; echo "record" > "$tmp/pack-strategy"; }
    fi
  fi

  ( cd "$tmp" && tar czf "$out" . ) || return 1
  _bk_seal "$out"
}

# $1 = tar.gz $2 = strategy (pull|load|skip)
_bk_rs_docker_images() {
  local arc=$1 strategy="${2:-pull}"
  [[ "$strategy" == "skip" ]] && { info "跳过 docker 镜像"; return 0; }
  local tmp; tmp=$(mktemp -d /tmp/howe-rs-docker.XXXXXX)
  trap "rm -rf '$tmp'" RETURN
  tar xzf "$arc" -C "$tmp" || return 1

  case "$strategy" in
    pull)
      [[ -f "$tmp/running-images.list" ]] || { warn "包内无镜像名单"; return 1; }
      local failed=0 ok=0
      while IFS= read -r img; do
        [[ -n "$img" ]] || continue
        if docker pull "$img" >/dev/null 2>&1; then
          log "  ✓ $img" >&2; ok=$((ok+1))
        else
          warn "  ✗ $img（失败）" >&2; failed=$((failed+1))
        fi
      done < "$tmp/running-images.list"
      log "docker pull 完成：成功 $ok，失败 $failed"
      ;;
    load)
      [[ -f "$tmp/docker-images.tar.gz" ]] || {
        warn "包内无 docker save tar（打包时用的是 record 模式，请改用 pull 策略）" >&2
        return 1
      }
      docker load < "$tmp/docker-images.tar.gz" && log "docker load 完成" || return 1
      ;;
  esac
}

# ── custom scope ──────────────────────────────────────────────────
# MIG_CUSTOM_PATHS = 换行或空格分隔的路径列表
_bk_do_custom() {
  local out=$1/custom.tar.gz
  local -a paths=()
  # 支持换行与空格分隔
  while IFS= read -r p; do
    [[ -n "$p" ]] && paths+=("$p")
  done <<< "$(tr ' ' '\n' <<< "${MIG_CUSTOM_PATHS:-}")"
  [[ ${#paths[@]} -eq 0 ]] && { warn "无自定义路径"; return 1; }

  local tmp; tmp=$(mktemp -d /tmp/howe-bk-custom.XXXXXX)
  trap "rm -rf '$tmp'" RETURN
  printf '%s\n' "${paths[@]}" > "$tmp/.custom-paths"

  local found=0
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] || { warn "路径不存在，跳过：$p" >&2; continue; }
    local rel="${p#/}"
    mkdir -p "$tmp/$(dirname "$rel")"
    cp -a "$p" "$tmp/$rel" 2>/dev/null && found=$((found+1)) || warn "复制失败：$p" >&2
  done
  (( found == 0 )) && { warn "自定义路径均不存在"; return 1; }

  ( cd "$tmp" && tar czf "$out" . ) || return 1
  _bk_seal "$out"
}

# $1 = tar.gz  $2 = 恢复目标根目录（默认 /）
_bk_rs_custom() {
  local arc=$1 target="${2:-/}"
  local tmp; tmp=$(mktemp -d /tmp/howe-rs-custom.XXXXXX)
  trap "rm -rf '$tmp'" RETURN
  tar xzf "$arc" -C "$tmp" || return 1
  # 按原目录结构恢复，排除元数据文件
  ( cd "$tmp" && find . -mindepth 1 -not -name '.custom-paths' | \
    tar cf - --files-from=- ) | tar xf - -C "$target" 2>/dev/null
  log "自定义路径已恢复到 $target"
  [[ -f "$tmp/.custom-paths" ]] && {
    echo "  包含路径："; sed 's/^/    /' "$tmp/.custom-paths"
  }
}
# 记录本次备份产生环境的关键状态，供新机迁移解包时对齐：
#   - 已安装但未打包的组件（Docker 镜像 / 二进制 / systemd unit）
#   - 已打包但需要重启才生效的服务
#   - 建议在新机上手动重跑的加固/调优步骤
_bk_write_inventory() {
  local dir=$1
  local out=$dir/host-inventory.json

  # 收集 shell 侧变量，统一交给 python3 做 JSON 序列化（避免手拼 JSON 转义问题）
  local host kernel os_pretty arch cpu mem_kb docker_ver
  host=$(hostname)
  kernel=$(uname -r)
  arch=$(uname -m)
  os_pretty=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
  cpu=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "")

  local -a images=()
  command -v docker >/dev/null 2>&1 && mapfile -t images < <(docker ps --format '{{.Image}}' 2>/dev/null | sort -u)

  local caddy_ver singbox_ver frps_ver
  caddy_ver=$(caddy version 2>/dev/null | awk 'NR==1{print $1}' | tr -d 'v' || echo "")
  singbox_ver=$(sing-box version 2>/dev/null | awk '/version/{print $NF; exit}' || echo "")
  frps_ver=$(frps --version 2>/dev/null | awk '{print $NF; exit}' || echo "")

  local -a units=()
  local u
  for u in caddy sing-box frps clash-subs-serve clash-subs-stats; do
    systemctl list-unit-files 2>/dev/null | grep -qE "^${u}\.(service|timer)" && units+=("$u")
  done

  local ssh_keys=0 cron_lines=0 f2b_jails=0 ipt_rules=0
  if [[ -f /root/.ssh/authorized_keys ]]; then
    ssh_keys=$(grep -cE '^(ssh|ecdsa|sk-)' /root/.ssh/authorized_keys 2>/dev/null) || ssh_keys=0
  fi
  cron_lines=$(crontab -l -u root 2>/dev/null | grep -cvE '^\s*(#|$)' 2>/dev/null) || cron_lines=0
  if command -v fail2ban-client >/dev/null 2>&1; then
    f2b_jails=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{print $2}' | tr ',' '\n' | grep -c .) || f2b_jails=0
  fi
  if command -v iptables >/dev/null 2>&1; then
    ipt_rules=$(iptables -S 2>/dev/null | grep -cvE '^(-P|-N)') || ipt_rules=0
  fi

  # 待办清单（收集到数组再传给 python）
  local -a todos=(
    "在新机重新拉取 Docker 镜像：docker compose up -d"
    "在新机重跑 ai-stack-setup.sh 安装原生服务（Caddy / sing-box / frps）"
    "检查 DNS 是否指向新机 IP，验证 Caddy 证书签发"
    "验证订阅链接 / 业务端点"
  )
  (( ssh_keys > 0 ))   && todos+=("导入 SSH authorized_keys（旧机 ${ssh_keys} 条，未打包）")
  (( cron_lines > 0 )) && todos+=("重建 root crontab（旧机 ${cron_lines} 条，system-tune scope 已打包）")
  (( f2b_jails > 0 ))  && todos+=("重启 fail2ban（system-sec 已恢复配置）")
  (( ipt_rules > 0 ))  && todos+=("重启 iptables 或 iptables-restore（system-sec 已恢复规则）")

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$out" \
      "$host" "$os_pretty" "$kernel" "$arch" \
      "$cpu" "$mem_kb" "$docker_ver" \
      "$caddy_ver" "$singbox_ver" "$frps_ver" \
      "$ssh_keys" "$cron_lines" "$f2b_jails" "$ipt_rules" \
      "${#images[@]}" "${images[@]+"${images[@]}"}" \
      "${#units[@]}" "${units[@]+"${units[@]}"}" \
      "${#todos[@]}" "${todos[@]+"${todos[@]}"}" \
      <<'PY'
import json, sys
args = sys.argv[1:]
out = args.pop(0)
host, os_pretty, kernel, arch = args.pop(0), args.pop(0), args.pop(0), args.pop(0)
cpu, mem_kb, docker_ver = int(args.pop(0)), int(args.pop(0)), args.pop(0)
caddy_ver, singbox_ver, frps_ver = args.pop(0), args.pop(0), args.pop(0)
ssh_keys, cron_lines, f2b_jails, ipt_rules = int(args.pop(0)), int(args.pop(0)), int(args.pop(0)), int(args.pop(0))
n = int(args.pop(0)); images = [args.pop(0) for _ in range(n)]
n = int(args.pop(0)); units  = [args.pop(0) for _ in range(n)]
n = int(args.pop(0)); todos  = [args.pop(0) for _ in range(n)]
d = {
  "host": host, "os": os_pretty, "kernel": kernel, "arch": arch,
  "cpu_count": cpu, "mem_kb": mem_kb,
  "docker_version": docker_ver,
  "docker_images": images,
  "native_versions": {"caddy": caddy_ver, "sing_box": singbox_ver, "frps": frps_ver},
  "systemd_units": units,
  "unpacked_counters": {
    "ssh_authorized_keys": ssh_keys,
    "root_crontab_lines": cron_lines,
    "fail2ban_jails": f2b_jails,
    "iptables_rules": ipt_rules,
  },
  "new_host_todos": todos,
}
with open(out, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
  else
    # 无 python3 时写简化版（纯 ASCII，足够新机读取）
    {
      echo '{'
      echo "  \"host\": \"$host\","
      echo "  \"os\": \"$os_pretty\","
      echo "  \"kernel\": \"$kernel\","
      echo "  \"arch\": \"$arch\","
      echo "  \"cpu_count\": $cpu,"
      echo "  \"mem_kb\": $mem_kb,"
      echo "  \"note\": \"python3 unavailable, simplified inventory\""
      echo '}'
    } > "$out"
  fi
}

# ── 镜像版本锁 docker-images.lock.json ────────────────────────────
# 每次 backup_create 都写，与是否勾选 docker-images scope 无关。
#
# 为什么需要：compose 里大量用 :latest / :main 这类可变 tag（本项目的
# new-api / 9router / open-webui / litellm 都是），新机 `docker compose
# up -d` 拉到的是「此刻的 latest」，而不是旧机当时实际在跑的那个版本。
# 光靠 docker_images 里的 tag 字面量无法还原版本。
#
# 解法：记录每个运行容器镜像的 RepoDigest（不可变）。新机按 digest 拉取，
# 再 retag 回原 tag —— retag 是零成本别名（同一 image ID），且 compose
# 默认 pull_policy=missing，本地已有该 tag 就不会再去拉 latest，从而在
# 不改写用户 docker-compose.yml 的前提下锁死版本。
_bk_write_image_lock() {
  local dir=$1
  local out=$dir/docker-images.lock.json
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0

  local tsv; tsv=$(mktemp /tmp/howe-imglock.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tsv'" RETURN

  local cid
  while read -r cid; do
    [[ -n "$cid" ]] || continue
    # 容器侧字段：名字 / compose service / compose project / compose 里写的镜像引用 / image id
    local cline
    cline=$(docker inspect "$cid" --format \
      '{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Config.Image}}|{{.Image}}' \
      2>/dev/null) || continue
    [[ -n "$cline" ]] || continue

    local imgid="${cline##*|}"
    # 镜像侧字段：RepoDigest（取第一个）/ 创建时间
    local iline
    iline=$(docker image inspect "$imgid" --format \
      '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}|{{.Created}}' \
      2>/dev/null) || iline="|"
    printf '%s|%s\n' "$cline" "$iline" >> "$tsv"
  done < <(docker ps -q 2>/dev/null)

  [[ -s "$tsv" ]] || return 0

  if command -v python3 >/dev/null 2>&1; then
    # 数据文件走 argv 传入而非 stdin：`python3 -` 的脚本本身就占用 stdin
    # （heredoc），再用 < 重定向喂数据会被 heredoc 覆盖，读到 0 行
    python3 - "$out" "$(hostname)" "$tsv" <<'PY'
import json, sys
from datetime import datetime, timezone

out, host, tsv = sys.argv[1], sys.argv[2], sys.argv[3]
# 可变 tag 白名单：这些 tag 指向的内容会随时间变化，迁移时必须靠 digest 锁定
MUTABLE = {"latest", "main", "master", "stable", "edge", "dev", "nightly", "beta"}

images = []
project = ""
with open(tsv, encoding="utf-8") as fh:
    rows = fh.readlines()
for raw in rows:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    parts = raw.split("|")
    if len(parts) < 7:
        continue
    name, svc, proj, ref, image_id, digest, created = parts[:7]
    name = name.lstrip("/")
    project = project or proj
    # 解析 tag：注意 registry 可能带端口（ghcr.io:443/x），需从最后一个 / 之后找 :
    tail = ref.rsplit("/", 1)[-1]
    tag = tail.split(":", 1)[1] if ":" in tail else ""
    images.append({
        "container": name,
        "service": svc,
        "ref": ref,
        "digest": digest,
        "image_id": image_id,
        "created": created,
        "tag": tag or "latest",
        "mutable_tag": (tag or "latest") in MUTABLE,
        "pinnable": bool(digest),
    })

d = {
    "format_version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "source_host": host,
    "compose_project": project,
    "images": images,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)

mut = sum(1 for i in images if i["mutable_tag"])
unp = sum(1 for i in images if not i["pinnable"])
print(f"  镜像版本锁：{len(images)} 个镜像"
      + (f"，{mut} 个用可变 tag（已按 digest 锁定）" if mut else "")
      + (f"，{unp} 个无 digest 无法锁定" if unp else ""))
PY
  fi
}

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
  local sk fn desc total idx=0 t_start t_end
  total=${#scopes[@]}
  echo "" >&2
  echo -e "  ${W}开始备份 ${total} 个 scope ...${N}" >&2
  echo "" >&2
  t_start=$(date +%s%N)
  for sk in "${scopes[@]}"; do
    idx=$((idx+1))
    fn=_bk_do_${sk//-/_}
    desc=$(backup_scope_desc "$sk")
    if ! declare -F "$fn" >/dev/null 2>&1; then
      fail+=("$sk")
      printf "  [%d/%d] ${R}✗${N} %-14s ${R}未知 scope${N}\n" "$idx" "$total" "$sk" >&2
      continue
    fi
    if _bk_run_scope_with_progress "$idx" "$total" "$sk" "$desc" "$fn" "$dir"; then
      ok+=("$sk")
    else
      fail+=("$sk")
    fi
  done
  t_end=$(date +%s%N)

  local total_sz=0 f fsz
  for f in "$dir"/*.tar.gz; do
    [[ -f "$f" ]] || continue
    fsz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    total_sz=$((total_sz + fsz))
  done
  echo "" >&2
  echo -e "  ${W}完成${N}：${G}${#ok[@]} 成功${N} / ${R}${#fail[@]} 失败${N}   总耗时 $(_bk_dur_s "$t_start" "$t_end")   合计 $(_bk_human "$total_sz")" >&2
  echo "" >&2

  # 写主机清单（新机迁移时对照用）
  _bk_write_inventory "$dir" >&2 || true
  # 写镜像版本锁：与是否勾选 docker-images scope 无关，恢复 ai-config 后
  # 需要它把 :latest 之类可变 tag 还原到旧机当时的实际版本
  _bk_write_image_lock "$dir" >&2 || true

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
      caddy)
        [[ -d /etc/caddy ]]     && total=$((total + $(du -sb /etc/caddy 2>/dev/null | awk '{print $1}')))
        [[ -d /var/lib/caddy ]] && total=$((total + $(du -sb /var/lib/caddy 2>/dev/null | awk '{print $1}'))) ;;
      ai-cli)
        local d
        for d in ~/.claude ~/.codex ~/.opencode ~/.openclaw; do
          [[ -d "$d" ]] && total=$((total + $(du -sb "$d" 2>/dev/null | awk '{print $1}')))
        done ;;
      kiro)      [[ -d "$BACKUP_AI_BASE/kiro-rs/config" ]] && total=$((total + $(du -sb "$BACKUP_AI_BASE/kiro-rs/config" 2>/dev/null | awk '{print $1}'))) ;;
      nrouter)   [[ -d "$BACKUP_AI_BASE/9router/data" ]]  && total=$((total + $(du -sb "$BACKUP_AI_BASE/9router/data" 2>/dev/null | awk '{print $1}'))) ;;
    esac
  done
  echo "$total"
}

