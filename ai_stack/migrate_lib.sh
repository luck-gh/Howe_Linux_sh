#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — VPS 迁移 低层函数库
#
# 迁移包 = 一个 backup point 目录 → tar → 可选加密 → 单文件
# 复用 backup_lib.sh 的 scope 打包 / 校验 / 恢复能力，只加：
#   1) 单文件 bundle 封装 + migration manifest
#   2) 加密流层（age / openssl / none）
#   3) 传输层（本地 / rsync-pull / rsync-push）
#
# bundle 文件结构（tar 内容）：
#   migration.json      迁移元信息（版本 / 源主机 / cipher / 时间戳）
#   manifest.json       原备份点 manifest（scope 列表）
#   <scope>.tar.gz      各 scope 归档
#   <scope>.sha256      各 scope 校验和
#
# 加密后扩展名：.tar (none) / .tar.age (age) / .tar.enc (openssl)
# bundle 同目录会再落一个 <bundle>.sha256 供外层校验
# ═══════════════════════════════════════════════════════════════════

MIGRATE_BUNDLE_VERSION=1
MIGRATE_ROOT_DEFAULT=/var/backups/howe-migrate

# 迁移落地根目录（与 backup 分开，避免 backup_apply_retention 误删）
migrate_root() {
  local r
  r=$(backup_conf_get MIGRATE_ROOT "$MIGRATE_ROOT_DEFAULT")
  echo "$r"
}

# ── 运行时检测 ────────────────────────────────────────────────────

mig_has_age()     { command -v age >/dev/null 2>&1; }
mig_has_openssl() { command -v openssl >/dev/null 2>&1; }
mig_has_rsync()   { command -v rsync >/dev/null 2>&1; }
mig_has_ssh()     { command -v ssh >/dev/null 2>&1; }

# 引导安装缺失依赖（apt 系）
mig_ensure_dep() {
  local pkg=$1
  command -v "$pkg" >/dev/null 2>&1 && return 0
  warn "缺少 $pkg"
  local yn
  askyn yn "自动 apt install $pkg?" y
  if $yn; then
    apt-get install -y -qq "$pkg" >/dev/null 2>&1 \
      && { log "$pkg 已安装"; return 0; } \
      || { err "$pkg 安装失败"; return 1; }
  fi
  return 1
}

# 支持的 cipher 列表（按运行时能力过滤）
mig_available_ciphers() {
  echo "none"
  mig_has_age     && echo "age"
  mig_has_openssl && echo "openssl"
}

# ── 口令交互（不落盘、不出现在 argv、read -s 无回显）─────────────────

# 双次输入并校验；结果写入 stdout 的 fd 由调用方通过管道消费
# 用法：passphrase=$(mig_prompt_passphrase_new) || return 1
mig_prompt_passphrase_new() {
  # 测试钩子（CI/fixture 用）
  if [[ -n "${MIG_TEST_PASSPHRASE:-}" ]]; then
    printf '%s' "$MIG_TEST_PASSPHRASE"; return 0
  fi
  # 预设口令钩子（migrate_action_pack 提前收集后设置）
  if [[ -n "${MIG_PASSPHRASE:-}" ]]; then
    printf '%s' "$MIG_PASSPHRASE"; return 0
  fi
  local p1="" p2=""
  read -rsp "  设置加密口令（至少 8 位）: " p1 </dev/tty >&2
  echo >&2
  if (( ${#p1} < 8 )); then
    err "口令过短" >&2; return 1
  fi
  read -rsp "  再次输入以确认: " p2 </dev/tty >&2
  echo >&2
  if [[ "$p1" != "$p2" ]]; then
    err "两次口令不一致" >&2; return 1
  fi
  printf '%s' "$p1"
}

mig_prompt_passphrase_open() {
  if [[ -n "${MIG_TEST_PASSPHRASE:-}" ]]; then
    printf '%s' "$MIG_TEST_PASSPHRASE"
    return 0
  fi
  local p=""
  read -rsp "  输入解密口令: " p </dev/tty >&2
  echo >&2
  [[ -z "$p" ]] && { err "口令为空" >&2; return 1; }
  printf '%s' "$p"
}

# ── 加密 / 解密（流式；口令通过 fd 传递，不出现在 argv）───────────────

# 用法：cat plain | _mig_encrypt <cipher> <pass_fd> > cipher
_mig_encrypt() {
  local cipher=$1 pass_fd=$2
  case "$cipher" in
    none)
      cat
      ;;
    age)
      # age -p 从 tty 读，不适合非交互；改用 --passphrase 从 stdin?
      # age 官方无 --pass-fd，实践：用 age-plugin 或改走 openssl。
      # 折中：age 场景走对称口令时借助 expect 麻烦，这里改用 age 的
      # scrypt recipient（-R -）不适用；因此 age 场景要求用户装 age 且
      # 使用 -p（交互）——由调用侧 detach tty；此处为一致 API，把口令
      # 写入 stdin 的做法在 age 上不通用。
      # 简化：age 模式必须走密钥文件（-r / -i），口令模式回退 openssl。
      err "age 口令模式请改用 openssl 或密钥文件（见 _mig_encrypt_age_keyfile）" >&2
      return 1
      ;;
    openssl)
      openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
        -pass "fd:${pass_fd}"
      ;;
    *)
      err "未知 cipher: $cipher" >&2; return 1
      ;;
  esac
}

_mig_decrypt() {
  local cipher=$1 pass_fd=$2
  case "$cipher" in
    none)
      cat
      ;;
    openssl)
      openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -pass "fd:${pass_fd}"
      ;;
    *)
      err "未知 cipher: $cipher" >&2; return 1
      ;;
  esac
}

# age 密钥文件模式（-r <recipient> 加密 / -i <identity> 解密）
_mig_encrypt_age_recipient() {
  local recipient_file=$1
  age -R "$recipient_file"
}
_mig_decrypt_age_identity() {
  local identity_file=$1
  age -d -i "$identity_file"
}

# age 交互口令模式（tty passphrase，直接 -p / -d，让 age 自行提示）
_mig_encrypt_age_passphrase() { age -p; }
_mig_decrypt_age_passphrase() { age -d; }

# ── 打包：把一个 backup point 封成 bundle 单文件 ───────────────────

# 写 migration manifest 到指定目录
_mig_write_manifest() {
  local dir=$1 cipher=$2 backup_ts=$3
  local host kernel created bundle_ts
  host=$(hostname)
  kernel=$(uname -r)
  created=$(date -Iseconds)
  bundle_ts=$(date +%Y%m%d-%H%M%S)
  cat > "$dir/migration.json" <<JSON
{
  "bundle_version": ${MIGRATE_BUNDLE_VERSION},
  "created_at": "${created}",
  "bundle_ts": "${bundle_ts}",
  "source_host": "${host}",
  "source_kernel": "${kernel}",
  "cipher": "${cipher}",
  "backup_ts": "${backup_ts}"
}
JSON
}

# 主打包函数
# $1 = backup point timestamp（已通过 backup_create 生成）
# $2 = cipher (none|openssl|age-pass|age-keyfile)
# $3 = 输出目录（默认 migrate_root）
# $4 = age recipient 文件（仅 age-keyfile 用）
# 成功：echo <bundle 完整路径>；失败：返回非 0
mig_pack_bundle() {
  local backup_ts=$1 cipher=$2 out_dir=${3:-} recipient=${4:-}
  local bkroot; bkroot=$(backup_root)
  local src_dir="$bkroot/$backup_ts"
  [[ -d "$src_dir" ]] || { err "备份点不存在：$backup_ts" >&2; return 1; }

  out_dir=${out_dir:-$(migrate_root)}
  mkdir -p "$out_dir" && chmod 0700 "$out_dir" 2>/dev/null

  local bundle_ts host ext
  bundle_ts=$(date +%Y%m%d-%H%M%S)
  host=$(hostname)
  case "$cipher" in
    none)          ext="tar" ;;
    openssl)       ext="tar.enc" ;;
    age-pass)      ext="tar.age" ;;
    age-keyfile)   ext="tar.age" ;;
    *) err "未知 cipher: $cipher" >&2; return 1 ;;
  esac

  local out="$out_dir/migrate-${host}-${bundle_ts}.${ext}"

  # 临时目录：拷贝 backup point 内容 + 写 migration.json
  local tmp; tmp=$(mktemp -d /tmp/howe-mig-pack.XXXXXX) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  cp -a "$src_dir"/. "$tmp/"
  _mig_write_manifest "$tmp" "$cipher" "$backup_ts"

  # 打包 + 加密（流式，避免落中间明文）
  case "$cipher" in
    none)
      ( cd "$tmp" && tar cf - . ) > "$out" || return 1
      ;;
    openssl)
      local pass; pass=$(mig_prompt_passphrase_new) || return 1
      # 通过 fd 3 传口令；不写临时文件
      if ( cd "$tmp" && tar cf - . ) \
          | _mig_encrypt openssl 3 3< <(printf '%s' "$pass") > "$out"; then
        :
      else
        rm -f "$out"
        err "加密失败" >&2
        return 1
      fi
      unset pass
      ;;
    age-pass)
      mig_has_age || { err "age 未安装" >&2; return 1; }
      # age 直接读 tty 提示口令
      ( cd "$tmp" && tar cf - . ) | _mig_encrypt_age_passphrase > "$out" || {
        rm -f "$out"; err "age 加密失败" >&2; return 1
      }
      ;;
    age-keyfile)
      mig_has_age || { err "age 未安装" >&2; return 1; }
      [[ -f "$recipient" ]] || { err "recipient 文件不存在：$recipient" >&2; return 1; }
      ( cd "$tmp" && tar cf - . ) | _mig_encrypt_age_recipient "$recipient" > "$out" || {
        rm -f "$out"; err "age 加密失败" >&2; return 1
      }
      ;;
  esac

  chmod 0600 "$out"
  # 外层 sha256（供传输后校验）
  ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
  echo "$out"
}

# ── 解包：把 bundle 还原为 backup point ────────────────────────────

# $1 = bundle 文件路径
# $2 = cipher（none|openssl|age-pass|age-keyfile）
# $3 = age identity 文件（仅 age-keyfile 用）
# 成功：echo <还原后的 backup point 目录>；失败非 0
mig_unpack_bundle() {
  local bundle=$1 cipher=$2 identity=${3:-}
  [[ -f "$bundle" ]] || { err "bundle 不存在：$bundle" >&2; return 1; }

  # 外层 sha256 校验（若存在）
  if [[ -f "$bundle.sha256" ]]; then
    ( cd "$(dirname "$bundle")" && sha256sum -c "$(basename "$bundle").sha256" >/dev/null 2>&1 ) \
      || { err "bundle sha256 校验失败" >&2; return 1; }
    info "bundle 完整性校验通过" >&2
  else
    warn "未找到 $(basename "$bundle").sha256，跳过外层校验" >&2
  fi

  local tmp; tmp=$(mktemp -d /tmp/howe-mig-unpack.XXXXXX) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  case "$cipher" in
    none)
      tar xf "$bundle" -C "$tmp" || { err "解包失败" >&2; return 1; }
      ;;
    openssl)
      local pass; pass=$(mig_prompt_passphrase_open) || return 1
      if _mig_decrypt openssl 3 3< <(printf '%s' "$pass") < "$bundle" \
          | tar xf - -C "$tmp"; then
        :
      else
        err "解密/解包失败（口令错误或包已损坏）" >&2
        return 1
      fi
      unset pass
      ;;
    age-pass)
      mig_has_age || { err "age 未安装" >&2; return 1; }
      _mig_decrypt_age_passphrase < "$bundle" | tar xf - -C "$tmp" || {
        err "age 解密/解包失败" >&2; return 1
      }
      ;;
    age-keyfile)
      mig_has_age || { err "age 未安装" >&2; return 1; }
      [[ -f "$identity" ]] || { err "identity 文件不存在：$identity" >&2; return 1; }
      _mig_decrypt_age_identity "$identity" < "$bundle" | tar xf - -C "$tmp" || {
        err "age 解密/解包失败" >&2; return 1
      }
      ;;
    *)
      err "未知 cipher: $cipher" >&2; return 1
      ;;
  esac

  # 校验 migration.json 存在
  [[ -f "$tmp/migration.json" ]] || { err "包内缺少 migration.json" >&2; return 1; }
  [[ -f "$tmp/manifest.json"  ]] || { err "包内缺少 manifest.json" >&2; return 1; }

  # 解出 backup_ts 并放到本机 backup_root/<ts>/
  local backup_ts
  backup_ts=$(grep -oE '"backup_ts":\s*"[^"]+"' "$tmp/migration.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  [[ -n "$backup_ts" ]] || { err "无法解析 backup_ts" >&2; return 1; }

  local bkroot; bkroot=$(backup_root)
  mkdir -p "$bkroot" && chmod 0700 "$bkroot" 2>/dev/null

  # 冲突处理：目标点已存在则改名保存原状
  local dst="$bkroot/$backup_ts"
  if [[ -e "$dst" ]]; then
    local sfx; sfx=$(date +%s)
    mv "$dst" "${dst}.pre-migrate.${sfx}"
    warn "已存在同名备份点，原目录已改名保存" >&2
  fi
  mv "$tmp" "$dst" || { err "落地失败" >&2; return 1; }
  chmod 0700 "$dst"
  # 从 trap 中释放（已改名到目标位置）
  trap - RETURN

  # 用 backup_lib 的 verify 校验每个 scope 完整
  local bad
  bad=$(backup_verify "$backup_ts") || true
  if [[ -n "$bad" ]]; then
    warn "以下 scope 校验失败：$bad" >&2
    return 2
  fi

  echo "$backup_ts"
}

# ── 传输层 ────────────────────────────────────────────────────────
# 均通过 rsync -e ssh；不在参数里嵌任何口令；SSH 认证走用户既有的
# ~/.ssh/config / 密钥 / ssh-agent。若目标机需口令登录，交由 ssh 自身
# 交互提示。

# 统一 SSH 选项：
#   ConnectTimeout   —— 不设时地址填错要等 tcp_syn_retries 耗尽（默认约 127s）
#                       才失败，期间无任何输出，表现为「卡住然后莫名退出」
#   ServerAlive*     —— 传输中途链路断掉时 30s 内失败，而不是无限挂着
# 不加 BatchMode：目标机可能需要口令登录，要留给 ssh 交互提示
MIG_SSH_CONNECT_TIMEOUT=10
mig_ssh_opts() {
  echo "-o ConnectTimeout=${MIG_SSH_CONNECT_TIMEOUT}" \
       "-o ServerAliveInterval=15" \
       "-o ServerAliveCountMax=2"
}

# SSH 连通性预检
# $1 = user@host  $2 = 端口
# 成功返回 0；失败打印分类诊断并返回 1
# 交互提示（口令 / 首次连接确认 host key）直通 tty，不做捕获
mig_ssh_check() {
  local remote=$1 port=${2:-22}
  local -a opts; read -ra opts <<< "$(mig_ssh_opts)"

  # 首次连接新机时 ssh 会交互确认 host key。若 stdin 残留按键（如打包/传输
  # 期间误敲的回车），确认提示会被空行自动答掉并判定验证失败。
  declare -F flush_stdin >/dev/null 2>&1 && flush_stdin

  info "检测 SSH 连通性：${remote}:${port}（最长 ${MIG_SSH_CONNECT_TIMEOUT}s）..." >&2
  local errf; errf=$(mktemp /tmp/howe-sshchk.XXXXXX)
  local rc=0
  # stderr 收进文件用于分类诊断；口令与 host key 确认提示由 ssh 直接写 /dev/tty，
  # 不受此重定向影响，用户照常能看到并作答
  ssh -p "$port" "${opts[@]}" "$remote" 'exit 0' 2>"$errf" || rc=$?

  local emsg; emsg=$(cat "$errf" 2>/dev/null); rm -f "$errf"

  if (( rc == 0 )); then
    log "SSH 连通" >&2
    return 0
  fi

  # 失败才回显 ssh 原始错误，避免成功路径打印无关警告
  [[ -n "$emsg" ]] && sed 's/^/  /' <<< "$emsg" >&2
  err "SSH 无法连通 ${remote}:${port}" >&2
  case "$emsg" in
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      # known_hosts 里 22 端口存裸主机名，非标端口存 [host]:port
      local _h="${remote##*@}" _kh
      [[ "$port" == "22" ]] && _kh="$_h" || _kh="[${_h}]:${port}"
      echo -e "  ${Y}host key 校验失败${N}（新机首连或对端重装过系统）" >&2
      echo -e "  ${DIM}先手工连一次并输入 yes 确认指纹：${N}" >&2
      echo -e "  ${DIM}  ssh -p ${port} ${remote}${N}" >&2
      echo -e "  ${DIM}若对端重装过，需先删旧记录：ssh-keygen -R '${_kh}'${N}" >&2
      ;;
    *"Connection timed out"*|*"No route to host"*|*"Network is unreachable"*)
      echo -e "  ${DIM}网络不可达：地址写错、防火墙拦截、或对端未放行该端口${N}" >&2
      ;;
    *"Connection refused"*)
      echo -e "  ${DIM}端口拒绝连接：对端 sshd 未运行，或 SSH 端口不是 ${port}${N}" >&2
      ;;
    *"Permission denied"*)
      echo -e "  ${DIM}认证失败：密钥未授权到对端，或用户名不对${N}" >&2
      ;;
    *)
      echo -e "  ${DIM}ssh 退出码 $rc${N}" >&2
      ;;
  esac
  echo -e "  ${DIM}可先在命令行自行验证：ssh -p ${port} ${remote}${N}" >&2
  return 1
}

# rsync 推送本机 bundle 到远端
# $1 = 本地 bundle 完整路径
# $2 = ssh 目标（user@host）
# $3 = 远端目录
# $4 = 远端 ssh 端口（默认 22）
mig_rsync_push() {
  local local_path=$1 remote=$2 remote_dir=$3 port=${4:-22}
  mig_ensure_dep rsync || return 1
  local sshopts; sshopts=$(mig_ssh_opts)
  local -a opts; read -ra opts <<< "$sshopts"
  # 建远端目录 + 同步 bundle 与 sha256
  ssh -p "$port" "${opts[@]}" "$remote" \
      "mkdir -p '$remote_dir' && chmod 0700 '$remote_dir'" || {
    err "无法在 $remote:$remote_dir 创建目录（检查路径权限）" >&2; return 1
  }
  rsync -e "ssh -p $port $sshopts" -av --partial --progress \
        "$local_path" "$local_path.sha256" \
        "$remote:$remote_dir/" || {
    err "rsync 推送失败" >&2; return 1
  }
  log "已推送到 $remote:$remote_dir/$(basename "$local_path")"
}

# rsync 从远端拉取 bundle 到本机
# $1 = ssh 源（user@host）
# $2 = 远端 bundle 完整路径
# $3 = 本地目录（默认 migrate_root）
# $4 = 远端 ssh 端口（默认 22）
mig_rsync_pull() {
  local remote=$1 remote_path=$2 local_dir=${3:-} port=${4:-22}
  mig_ensure_dep rsync || return 1
  local_dir=${local_dir:-$(migrate_root)}
  mkdir -p "$local_dir" && chmod 0700 "$local_dir"
  local sshopts; sshopts=$(mig_ssh_opts)
  rsync -e "ssh -p $port $sshopts" -av --partial --progress \
        "$remote:$remote_path" "$remote:$remote_path.sha256" \
        "$local_dir/" >&2 || {
    err "rsync 拉取失败" >&2; return 1
  }
  local base; base=$(basename "$remote_path")
  echo "$local_dir/$base"
}

# ── 列表 / 删除 ───────────────────────────────────────────────────

# 列出本机 bundles（每行：filename|size_bytes|cipher_ext|mtime）
mig_list_bundles() {
  local dir; dir=$(migrate_root)
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/migrate-*.tar "$dir"/migrate-*.tar.enc "$dir"/migrate-*.tar.age; do
    [[ -f "$f" ]] || continue
    local size mtime ext base
    size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    base=$(basename "$f")
    ext="${base##*.}"
    echo "$base|$size|$ext|$mtime"
  done | sort -t'|' -k4 -rn
}

# 删除 bundle（同时删 .sha256）
mig_delete_bundle() {
  local name=$1
  local dir; dir=$(migrate_root)
  local p="$dir/$name"
  [[ -f "$p" ]] || { err "bundle 不存在：$name" >&2; return 1; }
  rm -f "$p" "$p.sha256"
  log "已删除：$name"
}

# ── migrate-manifest.json v2 ──────────────────────────────────────
# 打包时写入备份点根目录，解包后随 bundle 传递到新机。
# 记录每个 scope 的文件名、描述、可选解包策略，驱动新机的选择式恢复。

_mig_scope_strategies() {
  # 返回 scope 可用策略列表（JSON 数组片段），仅 python3 调用
  local scope=$1 pack_strategy=${2:-}
  case "$scope" in
    ai-pg)
      echo '[{"id":"restore","label":"从dump恢复（覆盖现有数据）"},{"id":"skip","label":"跳过"}]'
      ;;
    ai-data|ai-config|clash|singbox|caddy|ai-cli|kiro|nrouter)
      echo '[{"id":"restore","label":"从备份恢复"},{"id":"skip","label":"跳过"}]'
      ;;
    system-sec)
      echo '[{"id":"staging","label":"落到 staging 不 apply（安全）"},{"id":"skip","label":"跳过"}]'
      ;;
    system-tune)
      echo '[{"id":"restore","label":"恢复并立即 sysctl --system"},{"id":"skip","label":"跳过"}]'
      ;;
    docker-images)
      if [[ "$pack_strategy" == "save" ]]; then
        echo '[{"id":"load","label":"docker load 从包恢复"},{"id":"pull","label":"docker pull 重新拉取"},{"id":"skip","label":"跳过"}]'
      else
        echo '[{"id":"pull","label":"docker pull 重新拉取（推荐，包内仅有镜像名单）"},{"id":"skip","label":"跳过"}]'
      fi
      ;;
    custom)
      echo '[{"id":"restore_original","label":"恢复到原路径"},{"id":"restore_prefix","label":"恢复到指定前缀目录"},{"id":"skip","label":"跳过"}]'
      ;;
    *)
      echo '[{"id":"restore","label":"恢复"},{"id":"skip","label":"跳过"}]'
      ;;
  esac
}

# 写 migrate-manifest.json v2 到备份点目录
# $1 = 备份点目录  $2 = cipher  $3... = 已成功打包的 scope 列表
mig_write_manifest_v2() {
  local dir=$1 cipher=$2; shift 2
  local -a scopes=("$@")
  command -v python3 >/dev/null 2>&1 || { warn "无 python3，跳过 manifest v2 生成" >&2; return 0; }

  # 收集每个 scope 的元数据
  local scope_data=""
  local sep=""
  for sk in "${scopes[@]}"; do
    local f="$dir/${sk}.tar.gz"
    [[ -f "$f" ]] || continue
    local size; size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    local desc; desc=$(backup_scope_desc "$sk")
    local pack_strat=""
    [[ "$sk" == "docker-images" && -f "$dir/pack-strategy" ]] && \
      pack_strat=$(cat "$dir/pack-strategy" 2>/dev/null || echo "record")
    # 解包 pack-strategy 从 docker-images.tar.gz 内部读取
    if [[ "$sk" == "docker-images" ]]; then
      pack_strat=$(tar xzf "$f" -O ./pack-strategy 2>/dev/null | head -1 || echo "record")
    fi
    local custom_paths=""
    if [[ "$sk" == "custom" ]]; then
      custom_paths=$(tar xzf "$f" -O ./.custom-paths 2>/dev/null | head -50 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().splitlines()))" 2>/dev/null || echo "[]")
    fi
    local strategies; strategies=$(_mig_scope_strategies "$sk" "$pack_strat")
    scope_data+="${sep}{\"scope\":\"${sk}\",\"file\":\"${sk}.tar.gz\",\"size\":${size},\"description\":\"${desc}\",\"pack_strategy\":\"${pack_strat}\",\"custom_paths\":${custom_paths:-[]},\"unpack_strategies\":${strategies}}"
    sep=","
  done

  python3 - "$dir" "$cipher" "[${scope_data}]" <<'PY'
import json, sys, os, subprocess
from datetime import datetime, timezone

out_dir, cipher, scopes_json = sys.argv[1], sys.argv[2], sys.argv[3]
host = subprocess.check_output("hostname", text=True).strip()
os_name = ""
try:
    with open("/etc/os-release") as f:
        for line in f:
            if line.startswith("PRETTY_NAME="):
                os_name = line.split("=",1)[1].strip().strip('"')
                break
except:
    pass

d = {
    "format_version": 2,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "source_host": host,
    "source_os": os_name,
    "cipher": cipher,
    "scopes": json.loads(scopes_json)
}
with open(os.path.join(out_dir, "migrate-manifest.json"), "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

# 读取 migrate-manifest.json v2，返回 scope 信息供 migrate.sh 使用
# 输出：每行 scope|file|size|description|pack_strategy|strategies_json
mig_read_manifest_scopes() {
  local mfile=$1
  [[ -f "$mfile" ]] || return 1
  python3 - "$mfile" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("format_version",1) < 2:
    print("__v1__")
    sys.exit(0)
for s in d.get("scopes",[]):
    strats = json.dumps(s.get("unpack_strategies",[]), ensure_ascii=False)
    cp = json.dumps(s.get("custom_paths",[]), ensure_ascii=False)
    print(f"{s['scope']}|{s['file']}|{s.get('size',0)}|{s.get('description','')}|{s.get('pack_strategy','')}|{strats}|{cp}")
PY
}

# ── 原生二进制锁版本安装 ──────────────────────────────────────────
# 现有 install_singbox / install_frp_server 都是「查 GitHub latest 后装」，
# 且失败时调 err()（内部 exit 1）——在恢复流程里调用会直接杀掉整个脚本。
# 这里另写一套：版本由调用方指定，失败只 warn + return 1。
#
# 注意 armv7l 的架构字符串两个项目不一致：
#   frp      → arm
#   sing-box → armv7
# 写错会导致 x86 正常、ARM 下载 404。

# $1 = 项目（singbox|frps）
# 输出该项目对应的架构串；不支持的架构返回 1
_mig_arch_for() {
  local proj=$1 m; m=$(uname -m)
  case "$proj:$m" in
    singbox:x86_64)  echo amd64 ;;
    singbox:aarch64) echo arm64 ;;
    singbox:armv7l)  echo armv7 ;;
    frps:x86_64)     echo amd64 ;;
    frps:aarch64)    echo arm64 ;;
    frps:armv7l)     echo arm   ;;
    *) warn "不支持的架构：$m" >&2; return 1 ;;
  esac
}

# 按指定版本安装 sing-box
# $1 = 版本号（不带 v 前缀，如 1.13.16）
mig_install_singbox_pinned() {
  local ver=$1
  [[ -n "$ver" ]] || { warn "未指定 sing-box 版本"; return 1; }
  local arch; arch=$(_mig_arch_for singbox) || return 1

  local tmp; tmp=$(mktemp -d /tmp/howe-mig-sb.XXXXXX) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  info "下载 sing-box v${ver}（${arch}）..."
  wget -qO "$tmp/sb.tar.gz" "$url" || { warn "下载失败：$url"; return 1; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { warn "解压失败"; return 1; }

  local bin="$tmp/sing-box-${ver}-linux-${arch}/sing-box"
  [[ -f "$bin" ]] || { warn "包内未找到 sing-box 二进制"; return 1; }
  install -m 755 "$bin" "${SINGBOX_BIN:-/usr/local/bin/sing-box}" \
    || { warn "安装失败（权限或路径问题）"; return 1; }
  log "sing-box 已装到 v${ver}"
}

# 按指定版本安装 frps
# $1 = 版本号（不带 v 前缀，如 0.68.1）
mig_install_frps_pinned() {
  local ver=$1
  [[ -n "$ver" ]] || { warn "未指定 frps 版本"; return 1; }
  local arch; arch=$(_mig_arch_for frps) || return 1

  local tmp; tmp=$(mktemp -d /tmp/howe-mig-frp.XXXXXX) || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local dir="frp_${ver}_linux_${arch}"
  local url="https://github.com/fatedier/frp/releases/download/v${ver}/${dir}.tar.gz"
  info "下载 frp v${ver}（${arch}）..."
  wget -qO "$tmp/frp.tar.gz" "$url" || { warn "下载失败：$url"; return 1; }
  tar -xzf "$tmp/frp.tar.gz" -C "$tmp" || { warn "解压失败"; return 1; }

  local bin="$tmp/${dir}/frps"
  [[ -f "$bin" ]] || { warn "包内未找到 frps 二进制"; return 1; }
  install -m 755 "$bin" /usr/local/bin/frps \
    || { warn "安装失败（权限或路径问题）"; return 1; }
  log "frps 已装到 v${ver}"
}

# ── Docker 锁版本 ─────────────────────────────────────────────────
# Docker CE 由官方 apt 源分发，可以精确锁版本 —— 之前判断「官方脚本无版本
# 参数所以锁不了」只对 get.docker.com 那条路成立，走 apt 是可以的。
#
# 版本串格式差异：inventory 里记的是 `29.5.0`（docker --version 的裸版本），
# apt 里是 `5:29.5.0-1~ubuntu.24.04~noble`（epoch + 发行版后缀）。
# 匹配必须用 `:版本-` 锚定，否则 `grep -F 29.5.0` 会误中 129.5.0 / 29.5.01。

# 判断 docker 是否由 apt 管理（脚本装的没有 apt 记录，无法锁版本）
mig_docker_apt_managed() {
  dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'ok installed'
}

# 查询 apt 源中是否有指定裸版本，命中则输出完整包版本串
# $1 = 裸版本（如 29.5.0）
mig_docker_apt_pkgver() {
  local want=$1
  [[ -n "$want" ]] || return 1
  apt-cache madison docker-ce 2>/dev/null \
    | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
    | grep -F ":${want}-" | head -1
}

# 列出 apt 源中可用的 docker 裸版本（供用户参考）
mig_docker_apt_versions() {
  apt-cache madison docker-ce 2>/dev/null \
    | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
    | sed -E 's/^[0-9]+://; s/-[0-9].*$//' | head -12
}

# 按指定版本安装/切换 Docker
# $1 = 裸版本（如 29.5.0）
# 注意：会重启 docker daemon，运行中的容器随之重启。调用方须先确认。
mig_install_docker_pinned() {
  local want=$1
  [[ -n "$want" ]] || { warn "未指定 Docker 版本"; return 1; }

  mig_docker_apt_managed || {
    warn "本机 Docker 不是 apt 安装的（可能来自 get.docker.com 脚本）"
    echo -e "  ${DIM}锁版本需先卸载再用官方 apt 源重装，此处不代为执行${N}" >&2
    return 1
  }

  local pkgver; pkgver=$(mig_docker_apt_pkgver "$want")
  if [[ -z "$pkgver" ]]; then
    warn "apt 源中没有 docker-ce ${want}"
    local -a avail=(); mapfile -t avail < <(mig_docker_apt_versions)
    (( ${#avail[@]} > 0 )) && \
      echo -e "  ${DIM}源中可用：${avail[*]}${N}" >&2
    return 1
  fi

  info "切换 Docker 到 ${want}（包版本 ${pkgver}）..."
  # docker-ce 与 docker-ce-cli 必须同版本，否则 apt 会解不开依赖。
  # --allow-downgrades：降级时 apt 默认拒绝。
  # 实测 dry-run 只有 Inst/Conf 没有 Remv，容器不会被删除。
  local -a pkgs=("docker-ce=$pkgver" "docker-ce-cli=$pkgver")
  # rootless-extras 若已装也要跟着走，否则版本不一致
  dpkg-query -W -f='${Status}' docker-ce-rootless-extras 2>/dev/null \
    | grep -q 'ok installed' && pkgs+=("docker-ce-rootless-extras=$pkgver")

  if apt-get install -y -qq --allow-downgrades "${pkgs[@]}" >/dev/null 2>&1; then
    systemctl restart docker >/dev/null 2>&1 || true
    local now; now=$(mig_local_tool_version docker)
    if [[ "$now" == "$want" ]]; then
      log "Docker 已切到 ${now}"
    else
      warn "安装完成但版本显示为 ${now}（预期 ${want}）"
    fi
  else
    warn "apt 安装失败，Docker 版本未变"
    return 1
  fi
}

# 读取本机某工具的当前版本（未安装则输出空）
# $1 = caddy|sing-box|frps|docker
mig_local_tool_version() {
  case "$1" in
    caddy)
      command -v caddy >/dev/null 2>&1 || return 0
      caddy version 2>/dev/null | awk 'NR==1{print $1}' | tr -d 'v'
      ;;
    sing-box)
      command -v sing-box >/dev/null 2>&1 || return 0
      sing-box version 2>/dev/null | awk '/version/{print $NF; exit}'
      ;;
    frps)
      command -v frps >/dev/null 2>&1 || return 0
      frps --version 2>/dev/null | awk '{print $NF; exit}'
      ;;
    docker)
      command -v docker >/dev/null 2>&1 || return 0
      docker --version 2>/dev/null | awk '{print $3}' | tr -d ','
      ;;
  esac
}

# ── 版本比较工具 ──────────────────────────────────────────────────
# 比较两个语义化版本号
# $1 = 版本 A，$2 = 版本 B
# 返回：0 表示相等，<0 表示 A < B，>0 表示 A > B
# 通过退出码传递：0=相等，1=A<B，2=A>B
mig_version_compare() {
  local a=$1 b=$2
  [[ "$a" == "$b" ]] && return 0

  # 去除 'v' 前缀
  a=${a#v}; b=${b#v}

  # 用 Python 做语义化版本比较
  python3 -c "
import sys
from packaging import version
try:
    va = version.parse('$a')
    vb = version.parse('$b')
    if va < vb:
        sys.exit(1)
    elif va > vb:
        sys.exit(2)
    else:
        sys.exit(0)
except:
    # 降级到字符串比较
    if '$a' < '$b':
        sys.exit(1)
    elif '$a' > '$b':
        sys.exit(2)
    else:
        sys.exit(0)
" 2>/dev/null
  local ret=$?
  case $ret in
    1) return 1 ;;  # A < B
    2) return 2 ;;  # A > B
    *) return 0 ;;  # A == B
  esac
}

# ── 镜像版本对账 ──────────────────────────────────────────────────
# 读 docker-images.lock.json，逐镜像对比新机现状，让用户决定版本取向。
#
# 之所以必须做这一步：compose 里 :latest / :main 这类可变 tag 直接
# `docker compose up -d` 拉到的是「此刻的 latest」，不是旧机当时在跑的版本。
# 锁文件记了 RepoDigest（不可变），据此可精确还原。
#
# 落地手法：按 digest 拉取 → retag 回原 tag。retag 是零成本别名（同一
# image ID），且 compose 默认 pull_policy=missing，本地已有该 tag 就不会
# 再去拉 latest，因此无需改写用户的 docker-compose.yml。

# 判断本地是否已有该 digest 对应的镜像
# $1 = digest 引用（repo@sha256:...）
_mig_img_has_digest() {
  local dref=$1
  [[ -n "$dref" ]] || return 1
  local want="${dref##*@}"
  [[ -n "$want" ]] || return 1
  # 用 --digests 直接列出所有镜像的 digest，避免把镜像 ID 全部展开成 argv
  docker images --digests --format '{{.Digest}}' 2>/dev/null | grep -qF "$want"
}

# 取本地某 tag 当前指向的 digest（无则空）
_mig_img_local_digest() {
  local ref=$1
  docker image inspect "$ref" --format \
    '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | head -1
}

# 主对账入口
# $1 = 备份点目录（含 docker-images.lock.json）
# 返回 0 表示流程正常结束（含用户取消）
mig_reconcile_images() {
  local bp_dir=$1
  local lock="$bp_dir/docker-images.lock.json"

  [[ -f "$lock" ]] || { info "备份点无镜像版本锁，跳过镜像对账"; return 0; }
  command -v docker >/dev/null 2>&1 || { warn "本机无 docker，跳过镜像对账"; return 0; }
  docker info >/dev/null 2>&1 || { warn "docker 未运行，跳过镜像对账"; return 0; }
  command -v python3 >/dev/null 2>&1 || { warn "无 python3，无法解析镜像锁"; return 0; }

  # 读锁文件：每行 service|ref|digest|tag|mutable|created
  local -a rows=()
  mapfile -t rows < <(python3 - "$lock" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for i in d.get("images", []):
    print("|".join([
        i.get("service", "") or i.get("container", ""),
        i.get("ref", ""),
        i.get("digest", ""),
        i.get("tag", ""),
        "1" if i.get("mutable_tag") else "0",
        (i.get("created", "") or "")[:10],
    ]))
PY
  )
  (( ${#rows[@]} == 0 )) && { info "镜像锁内无记录，跳过"; return 0; }

  section "镜像版本对账"
  echo -e "  ${DIM}锁文件记录了旧机运行时的精确镜像版本（digest）${N}"
  echo ""

  # 逐条判定状态，生成候选策略
  local -a m_svc=() m_ref=() m_dg=() m_state=() m_ids=() m_labels=() m_cur=()
  local row
  for row in "${rows[@]}"; do
    local svc ref dg tag mut created
    IFS='|' read -r svc ref dg tag mut created <<< "$row"
    [[ -n "$ref" ]] || continue

    local local_dg; local_dg=$(_mig_img_local_digest "$ref")
    local state ids labels

    if [[ -z "$dg" ]]; then
      # 旧机侧没有 digest（本地构建镜像等），只能按 tag 拉
      state="无digest"
      ids="pull_tag skip"
      labels="按 tag 拉取（无法锁版本）"$'\x1f'"跳过"
    elif [[ -n "$local_dg" && "${local_dg##*@}" == "${dg##*@}" ]]; then
      state="已一致"
      ids="keep pull_tag"
      labels="保持现状（版本已匹配）"$'\x1f'"改拉 tag 最新版"
    elif [[ -n "$local_dg" ]]; then
      # 本机已有同 tag 但 digest 不同 —— 版本不一致，需用户决定
      state="版本不同"
      ids="pin pull_tag keep"
      labels="用 bundle 版本（回退/对齐）"$'\x1f'"拉 tag 最新版（更新）"$'\x1f'"保持本机现状"
    elif _mig_img_has_digest "$dg"; then
      state="缺tag"
      ids="pin pull_tag"
      labels="用 bundle 版本并打 tag"$'\x1f'"按 tag 重新拉取"
    else
      state="未安装"
      ids="pin pull_tag skip"
      labels="拉 bundle 版本（推荐）"$'\x1f'"拉 tag 最新版"$'\x1f'"跳过"
    fi

    m_svc+=("$svc"); m_ref+=("$ref"); m_dg+=("$dg")
    m_state+=("$state"); m_ids+=("$ids"); m_labels+=("$labels"); m_cur+=(0)
  done

  (( ${#m_svc[@]} == 0 )) && return 0

  # 交互：一屏切换
  local _msg=""
  while true; do
    echo ""
    printf "  %-4s %-14s %-30s %-10s %s\n" "" "SERVICE" "IMAGE" "状态" "将执行"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────────${N}"
    local n=0 z
    for z in "${!m_svc[@]}"; do
      n=$((n + 1))
      local -a _ids=() _labs=()
      read -ra _ids <<< "${m_ids[$z]}"
      IFS=$'\x1f' read -ra _labs <<< "${m_labels[$z]}"
      local cur=${m_cur[$z]}
      local sc="${m_state[$z]}" scol="$N"
      case "$sc" in
        已一致)   scol="$G" ;;
        版本不同) scol="$Y" ;;
        未安装)   scol="$C" ;;
        无digest) scol="$Y" ;;
        缺tag)    scol="$C" ;;
      esac
      # 中文占 2 个显示宽度但 printf 按字符数计，故状态列手工补空格对齐
      local pad=$(( 10 - ${#sc} * 2 )); (( pad < 1 )) && pad=1
      printf "  %2d.  %-14s %-30s ${scol}%s${N}%*s %s\n" \
        "$n" "${m_svc[$z]:0:14}" "${m_ref[$z]:0:30}" "$sc" "$pad" "" "${_labs[$cur]}"
    done
    echo ""
    echo -e "  ${DIM}输入编号切换该项 | a=全部用 bundle 版本 | t=全部拉最新 | 回车执行 | q 跳过${N}"
    [[ -n "$_msg" ]] && { echo -e "  ${Y}$_msg${N}"; _msg=""; }

    local _in; read -erp "  选择: " _in
    [[ -z "$_in" ]] && break
    case "${_in,,}" in
      q|quit) info "已跳过镜像对账"; return 0 ;;
      a)
        # 对齐到 bundle 版本：已一致的项本就是 bundle 版本，keep 即达成目标，
        # 不存在 pin 候选也属正常，如实统计避免「按了没反应」的错觉
        local changed=0 already=0
        for z in "${!m_svc[@]}"; do
          local -a _ids=(); read -ra _ids <<< "${m_ids[$z]}"
          local k hit=-1
          for k in "${!_ids[@]}"; do
            [[ "${_ids[$k]}" == "pin" ]] && { hit=$k; break; }
          done
          if (( hit >= 0 )); then
            (( m_cur[z] != hit )) && changed=$((changed + 1))
            m_cur[$z]=$hit
          else
            # 无 pin 候选：已一致（keep 就是 bundle 版本）或无 digest 可锁
            [[ "${m_state[$z]}" == "已一致" ]] && already=$((already + 1))
          fi
        done
        _msg="已对齐 bundle 版本：${changed} 项调整"
        (( already > 0 )) && _msg+="，${already} 项本就一致"
        ;;
      t)
        for z in "${!m_svc[@]}"; do
          local -a _ids=(); read -ra _ids <<< "${m_ids[$z]}"
          local k
          for k in "${!_ids[@]}"; do
            [[ "${_ids[$k]}" == "pull_tag" ]] && { m_cur[$z]=$k; break; }
          done
        done
        _msg="已全部切为拉取 tag 最新版"
        ;;
      *)
        if [[ "$_in" =~ ^[0-9]+$ ]] && (( _in >= 1 && _in <= ${#m_svc[@]} )); then
          z=$((_in - 1))
          local -a _ids=(); read -ra _ids <<< "${m_ids[$z]}"
          m_cur[$z]=$(( (m_cur[z] + 1) % ${#_ids[@]} ))
        else
          _msg="无效输入：$_in"
        fi
        ;;
    esac
  done

  # 执行
  echo ""
  local ok=0 fail=0 skipped=0 z
  for z in "${!m_svc[@]}"; do
    local -a _ids=(); read -ra _ids <<< "${m_ids[$z]}"
    local act="${_ids[${m_cur[$z]}]}"
    local ref="${m_ref[$z]}" dg="${m_dg[$z]}" svc="${m_svc[$z]}"

    case "$act" in
      keep|skip)
        skipped=$((skipped + 1))
        ;;
      pin)
        # 本地已有该 digest 时直接 retag：docker pull 即便命中本地也会联网
        # 校验，离网环境会无谓失败
        if _mig_img_has_digest "$dg"; then
          info "[$svc] 本地已有该版本，直接打 tag"
        else
          info "[$svc] 拉取 bundle 版本 ${dg##*@}"
          if ! docker pull "$dg" >/dev/null 2>&1; then
            warn "  ✗ $dg 拉取失败（镜像可能已从仓库删除）"
            fail=$((fail + 1))
            continue
          fi
        fi
        # retag 回 compose 里写的 tag，使 compose 无需改写即命中该版本
        if docker tag "$dg" "$ref" 2>/dev/null; then
          log "  ✓ $ref → ${dg##*@}"
          ok=$((ok + 1))
        else
          warn "  ✗ $ref retag 失败"
          fail=$((fail + 1))
        fi
        ;;
      pull_tag)
        info "[$svc] 拉取 $ref 最新版"
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
  echo -e "  ${W}镜像对账完成${N}：${G}${ok} 成功${N} / ${R}${fail} 失败${N} / ${DIM}${skipped} 保持不变${N}"
  return 0
}

# ── 策略执行器 ────────────────────────────────────────────────────
# $1 = scope  $2 = strategy  $3 = 备份点目录
mig_execute_strategy() {
  local scope=$1 strategy=$2 bp_dir=$3
  local arc="$bp_dir/${scope}.tar.gz"
  [[ -f "$arc" ]] || { err "scope 文件不存在：$arc" >&2; return 1; }

  case "$scope:$strategy" in
    # ── 标准 backup_lib 恢复 ──
    ai-pg:restore)     _bk_rs_ai_pg "$arc" ;;
    ai-data:restore)   _bk_rs_ai_data "$arc" ;;
    ai-config:restore) _bk_rs_ai_config "$arc" ;;
    clash:restore)     _bk_rs_clash "$arc" ;;
    singbox:restore)   _bk_rs_singbox "$arc" ;;
    caddy:restore)     _bk_rs_caddy "$arc" ;;
    ai-cli:restore)    _bk_rs_ai_cli "$arc" ;;
    kiro:restore)      _bk_rs_kiro "$arc" ;;
    nrouter:restore)   _bk_rs_nrouter "$arc" ;;
    # ── 特殊策略 ──
    system-sec:staging)    _bk_rs_system_sec "$arc" ;;
    system-tune:restore)   _bk_rs_system_tune "$arc" ;;
    docker-images:pull)    _bk_rs_docker_images "$arc" pull ;;
    docker-images:load)    _bk_rs_docker_images "$arc" load ;;
    custom:restore_original) _bk_rs_custom "$arc" / ;;
    custom:restore_prefix)
      local prefix; ask prefix "恢复目标根目录（如 /tmp/restore）" "/tmp/migrate-restore"
      [[ -n "$prefix" ]] && _bk_rs_custom "$arc" "$prefix"
      ;;
    # ── 跳过 ──
    *:skip)
      info "跳过 $scope" ;;
    *)
      warn "未知策略 $scope:$strategy，尝试默认恢复" >&2
      local fn="_bk_rs_${scope//-/_}"
      declare -F "$fn" >/dev/null 2>&1 && "$fn" "$arc" || return 1
      ;;
  esac
}
