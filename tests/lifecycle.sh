#!/usr/bin/env bash
# 升级 / 回滚 / 迁移隔离回归. 服务命令默认拒绝, 仅操作合成临时数据.
set -uo pipefail
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d /tmp/howe-lifecycle.XXXXXX) || exit 1
trap 'rm -rf -- "$TEST_TMP"' EXIT
BACKUP_CONF_FILE="$TEST_TMP/backup.conf"
source "$TEST_REPO/ai_stack/ai-stack-setup.sh"
W= N= R= G= Y= C= DIM= B=
log() { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
step() { :; }; section() { :; }; clear() { :; }; sleep() { :; }
docker() { printf 'UNEXPECTED_DOCKER %s\n' "$*" >&2; return 97; }
systemctl() { return 97; }; curl() { return 97; }; wget() { return 97; }
apt-get() { return 97; }; rsync() { return 97; }
askyn() { printf -v "$1" '%s' true; }
backup_root() { printf '%s/backups\n' "$CASE_DIR"; }
_upgrade_pre_backup_hook() { return "${BACKUP_RC:-0}"; }
_dump_db_if_needed() { LAST_DB_BACKUP=; return "${DUMP_RC:-0}"; }
_prune_unreferenced_dangling_images() { :; }
_svc_image_ref() { echo example.invalid/service:latest; }
_svc_image_id() { echo sha256:current; }
_mig_preflight_docker() { :; }
_mig_reconcile_all() { :; }
_mig_reconcile_binaries_only() { :; }
_mig_show_inventory() { :; }
input_multi() { INPUT_RESULTS=(0 1); }

make_point() {
  local ts=$1 point="$(backup_root)/$1"
  mkdir -p "$point" "$CASE_DIR/payload"
  printf 'synthetic data\n' > "$CASE_DIR/payload/value"
  tar czf "$point/ai-config.tar.gz" -C "$CASE_DIR/payload" value || return
  _bk_seal "$point/ai-config.tar.gz"
  printf '{"scopes_ok":["ai-config"],"scopes_fail":[]}\n' > "$point/manifest.json"
  mig_write_manifest_v2 "$point" none ai-config
}

bundle_roundtrip() {
  local cipher=$1 packed restored
  make_point sample || return
  MIG_TEST_PASSPHRASE='synthetic-test-passphrase'
  packed=$(mig_pack_bundle sample "$cipher" "$CASE_DIR/bundles") || return
  mv "$(backup_root)/sample" "$CASE_DIR/original"
  restored=$(mig_unpack_bundle "$packed" "$cipher") || return
  [[ "$restored" == sample ]] || return 1
  cmp "$CASE_DIR/original/ai-config.tar.gz" "$(backup_root)/sample/ai-config.tar.gz" || return
  # 相同备份点不能被后一次解包静默替换.
  mig_unpack_bundle "$packed" "$cipher" >/dev/null 2>&1 && return 1
  if [[ "$cipher" == openssl ]]; then
    MIG_TEST_PASSPHRASE=wrong-passphrase
    mig_unpack_bundle "$packed" openssl >/dev/null 2>&1 && return 1
  fi
  printf corruption >> "$packed"
  ! mig_unpack_bundle "$packed" "$cipher" >/dev/null 2>&1
}

upgrade_model() {
  _record_image_history() { :; }
  docker() {
    case "$*" in
      'compose config --services') echo new-api ;;
      'compose config --format json') printf '{"services":{"new-api":{"image":"%s"}}}\n' "${DESIRED_IMAGE:-example.invalid/service:latest}" ;;
      'compose pull new-api'|'inspect new-api'|'logs --tail 30 new-api') return 0 ;;
      'image inspect '* ) [[ "$3" == "${DESIRED_IMAGE:-example.invalid/service:latest}" ]] || return 98; echo sha256:new ;;
      'compose up '*) [[ "$*" == *'--wait --wait-timeout 60'* ]] || return 98; return "${WAIT_RC:-0}" ;;
      *) return 97 ;;
    esac
  }
  _BATCH_UPGRADE_YES=1
}
upgrade_healthy() { upgrade_model; upgrade_single_service demo new-api; }
upgrade_unhealthy_fails() { upgrade_model; WAIT_RC=1; ! upgrade_single_service demo new-api; }
upgrade_backup_failure_stops() { upgrade_model; BACKUP_RC=1; ! upgrade_single_service demo new-api; }
upgrade_dump_failure_stops() { upgrade_model; DUMP_RC=1; ! upgrade_single_service demo new-api; }
upgrade_uses_configured_image() { upgrade_model; DESIRED_IMAGE=example.invalid/renamed:v2; upgrade_single_service demo new-api; }

restore_failure_propagates() {
  make_point sample || return
  _bk_rs_ai_config() { return 42; }
  ! backup_restore sample ai-config
}

oldest_rollback_survives() {
  mkdir -p "$BASE_DIR/upgrade/history" "$CASE_DIR/images"
  printf 't1 example.invalid/service:latest sha256:oldest\nt2 example.invalid/service:latest sha256:middle\n' > "$BASE_DIR/upgrade/history/new-api.log"
  touch "$CASE_DIR/images/sha256:oldest" "$CASE_DIR/images/sha256:middle" "$CASE_DIR/images/sha256:current"
  docker() {
    case "$*" in
      'compose config --services') echo new-api ;;
      'compose config --format json') echo '{"services":{"new-api":{"image":"example.invalid/service:latest"}}}' ;;
      'image inspect '*) [[ -f "$CASE_DIR/images/$3" ]] ;;
      'image rm '*) rm "$CASE_DIR/images/$3" ;;
      'tag '*) [[ -f "$CASE_DIR/images/$2" ]] ;;
      'compose up '*) [[ "$*" == *'--pull never'* && "$*" == *'--wait --wait-timeout 60'* ]] ;;
      'logs --tail 30 new-api') return 0 ;;
      *) return 97 ;;
    esac
  }
  rollback_single_service demo new-api <<< $'1\n0\n' || return
  [[ -f "$CASE_DIR/images/sha256:oldest" ]]
}

fresh_restore() {
  local pg_rc=${1:-0} startup_rc=${2:-0} bp="$CASE_DIR/point"
  mkdir -p "$bp" "$CASE_DIR/config"
  touch "$bp/ai-pg.tar.gz"
  printf 'services: {}\n' > "$CASE_DIR/config/docker-compose.yml"
  tar czf "$bp/ai-config.tar.gz" -C "$CASE_DIR/config" docker-compose.yml
  cat > "$bp/migrate-manifest.json" <<'JSON'
{"format_version":2,"source_host":"synthetic","source_os":"synthetic","scopes":[{"scope":"ai-pg","file":"ai-pg.tar.gz","size":1,"unpack_strategies":[{"id":"restore","label":"restore"}]},{"scope":"ai-config","file":"ai-config.tar.gz","size":1,"unpack_strategies":[{"id":"restore","label":"restore"}]}]}
JSON
  _mig_verify_restore() { return 0; }
  if (( startup_rc != 0 )); then
    _mig_offer_compose_up() { return "$startup_rc"; }
  fi
  _bk_rs_ai_pg() {
    [[ -f "$CASE_DIR/database-started" ]] || return 98
    (( pg_rc == 0 )) || return "$pg_rc"
    touch "$CASE_DIR/database-restored"
  }
  docker() {
    case "$*" in
      'compose up -d --pull never --wait --wait-timeout 60 ai-db') touch "$CASE_DIR/database-started" ;;
      'compose up -d --pull never --wait --wait-timeout 60')
        [[ -f "$CASE_DIR/database-restored" ]] || return 98
        touch "$CASE_DIR/apps-started" ;;
      *) return 97 ;;
    esac
  }
  _mig_restore_v2 "$bp" "$bp/migrate-manifest.json"
  local rc=$?
  if (( pg_rc != 0 )); then [[ $rc != 0 && ! -f "$CASE_DIR/apps-started" ]]
  elif (( startup_rc != 0 )); then [[ $rc == "$startup_rc" && ! -f "$CASE_DIR/apps-started" ]]
  else [[ $rc == 0 && -f "$CASE_DIR/apps-started" ]]; fi
}

compose_health_failure() {
  printf 'services: {}\n' > "$BASE_DIR/docker-compose.yml"
  docker() { [[ "$*" == *'--wait --wait-timeout 60'* ]] || return 98; return 1; }
  ! _mig_offer_compose_up
}

empty_database_archive_fails() {
  mkdir "$CASE_DIR/empty"
  tar czf "$CASE_DIR/empty.tar.gz" -C "$CASE_DIR/empty" .
  docker() { [[ "$*" == 'ps --format {{.Names}}' ]] || return 98; echo ai-db; }
  ! _bk_rs_ai_pg "$CASE_DIR/empty.tar.gz"
}

metadata_rejects_escape() {
  make_point sample || return
  printf '{"backup_ts":"../escaped"}\n' > "$(backup_root)/sample/migration.json"
  tar cf "$CASE_DIR/unsafe.tar" -C "$(backup_root)/sample" .
  _bk_seal "$CASE_DIR/unsafe.tar"
  mig_unpack_bundle "$CASE_DIR/unsafe.tar" none >/dev/null 2>&1 && return 1
  [[ ! -e "$CASE_DIR/escaped" ]]
}

ssh_failure_is_returned() {
  ssh() { printf 'Permission denied\n' >&2; return 255; }
  local status=0
  mig_ssh_check nobody@example.invalid 22 >/dev/null 2>&1 || status=$?
  [[ "$status" == 1 ]]
}

postgres_init_script_is_backed_up() {
  mkdir -p "$BASE_DIR/ai-db" "$CASE_DIR/point"
  printf 'services: {}\n' > "$BASE_DIR/docker-compose.yml"
  printf '#!/bin/sh\nexit 0\n' > "$BASE_DIR/ai-db/init-multi-db.sh"
  _bk_do_ai_config "$CASE_DIR/point" || return
  _bk_extract "$CASE_DIR/point/ai-config.tar.gz" "$CASE_DIR/restored" || return
  cmp "$BASE_DIR/ai-db/init-multi-db.sh" "$CASE_DIR/restored/ai-db/init-multi-db.sh"
}

native_ip_and_startup() {
  mkdir -p "$BASE_DIR/clash"
  printf 'VPS_IP=8.8.8.8\n' > "$BASE_DIR/.env"
  cat > "$BASE_DIR/clash/nodes.yaml" <<'YAML'
nodes:
  - {server: 8.8.8.8, sni: 8.8.8.8}
  - {server: external.example, sni: external.example}
YAML
  PUBLIC_IP=1.1.1.1
  setup_clash_subscription() { :; }; write_singbox_config() { :; }
  render_clash_subscription() { :; }; setup_clash_nft() { :; }
  systemctl() { printf '%s\n' "$*" >> "$CASE_DIR/events"; }
  _mig_activate_native_services singbox clash || return
  grep -q '^VPS_IP=1.1.1.1$' "$BASE_DIR/.env" || return
  python3 - "$BASE_DIR/clash/nodes.yaml" <<'PY'
import sys, yaml
nodes = yaml.safe_load(open(sys.argv[1]))['nodes']
assert nodes[0] == {'server':'1.1.1.1','sni':'1.1.1.1'}
assert nodes[1] == {'server':'external.example','sni':'external.example'}
PY
  [[ $? == 0 ]] && grep -q '^restart sing-box$' "$CASE_DIR/events"
}

native_domain_endpoint_survives() {
  mkdir -p "$BASE_DIR/clash"
  printf 'VPS_IP=8.8.8.8\n' > "$BASE_DIR/.env"
  cat > "$BASE_DIR/clash/nodes.yaml" <<'YAML'
nodes:
  - {name: vps-anytls, type: anytls, server: node.example, sni: 8.8.8.8, skip_cert_verify: true, port: 0, password: PER_SUB}
  - {name: external, server: external.example, sni: external.example}
YAML
  cp "$BASE_DIR/clash/nodes.yaml" "$CASE_DIR/original-nodes.yaml"
  PUBLIC_IP=1.1.1.1
  setup_clash_subscription() { :; }; write_singbox_config() { :; }
  render_clash_subscription() {
    # 确认真实迁移路径在渲染前保留完整域名节点, 包括独立的 SNI 契约.
    python3 - "$CASE_DIR/original-nodes.yaml" "$BASE_DIR/clash/nodes.yaml" <<'PY'
from pathlib import Path
import sys, yaml
original, restored = (yaml.safe_load(Path(path).read_text()) for path in sys.argv[1:])
assert restored == original
PY
    [[ $? == 0 ]] || return
    touch "$CASE_DIR/domain-rendered"
  }
  setup_clash_nft() { :; }
  systemctl() { printf '%s\n' "$*" >> "$CASE_DIR/events"; }
  _mig_activate_native_services singbox clash || return
  grep -q '^VPS_IP=1.1.1.1$' "$BASE_DIR/.env" || return
  [[ -f "$CASE_DIR/domain-rendered" ]] || return
  grep -q '^restart sing-box$' "$CASE_DIR/events"
}

native_startup_failure() {
  systemctl() { [[ "$*" != 'restart frps' ]]; }
  ! _mig_activate_native_services frps
}

clash_install_model() {
  DOMAIN= DEPLOY_MODE=single VPS_IP=1.1.1.1
  INST_SINGBOX=true INST_CADDY=false INST_DIFY=false
  CLASH_PORT_MIN=15443 CLASH_PORT_MAX=15458
  preflight() { :; }; collect_config() { :; }; confirm_installation() { :; }
  install_deps() { :; }; setup_dirs() { :; }; write_env() { :; }
  write_compose() { :; }; write_litellm_config() { :; }; install_singbox() { :; }
  setup_clash_stats_timer() { :; }; setup_clash_serve_service() { :; }
  # 保留真实订阅初始化和入站生成, 仅隔离主机安装及系统配置写入.
  write_singbox_config() {
    touch "$CASE_DIR/config-requested"
    python3 "$(_clash_py)" --base "$(_clash_dir)" sing-box-inbounds \
      --tls-cert "$CASE_DIR/cert.pem" --tls-key "$CASE_DIR/key.pem" \
      --server-name "$VPS_IP" > "$CASE_DIR/inbounds.json"
  }
  render_clash_subscription() { touch "$CASE_DIR/rendered"; }
  install_frp_server() { :; }; configure_firewall() { :; }
  start_services() { touch "$CASE_DIR/services-started"; }
  health_check() { :; }; print_summary() { :; }
}

first_clash_install_has_subscription_inbound() {
  clash_install_model
  install_or_update <<< $'node.example\n\n' || return
  python3 - "$BASE_DIR/clash" "$CASE_DIR/inbounds.json" <<'PY'
from pathlib import Path
import json, sys, yaml
base = Path(sys.argv[1])
subs = yaml.safe_load((base / 'subs.yaml').read_text())['subscriptions']
nodes = yaml.safe_load((base / 'nodes.yaml').read_text())['nodes']
inbounds = json.loads(Path(sys.argv[2]).read_text())
assert len(subs) == len(inbounds) == 1
assert subs[0]['name'] == 'default'
assert inbounds[0]['type'] == 'anytls'
assert inbounds[0]['listen_port'] == subs[0]['port'] == 15443
assert inbounds[0]['users'] == [{'name': 'default', 'password': subs[0]['password']}]
assert nodes[0]['server'] == nodes[0]['sni'] == 'node.example'
PY
  [[ $? == 0 ]] || return
  [[ -f "$CASE_DIR/rendered" && -f "$CASE_DIR/services-started" ]]
}

clash_setup_failure_stops_install() {
  clash_install_model
  install_or_update </dev/null && return 1
  [[ ! -f "$BASE_DIR/clash/subs.yaml" && ! -f "$CASE_DIR/config-requested" \
     && ! -f "$CASE_DIR/rendered" && ! -f "$CASE_DIR/services-started" ]]
}

restore_verification() {
  local health=$1 expected=$2
  printf 'services: {}\n' > "$BASE_DIR/docker-compose.yml"
  docker() {
    [[ "$*" == 'compose ps --format json' ]] || return 97
    printf '%s\n' "$health"
  }
  local rc=0
  _mig_verify_restore ai-config || rc=$?
  [[ "$rc" == "$expected" ]]
}

special_scope_manifest() {
  make_point sample || return
  mkdir -p "$CASE_DIR/custom payload"
  printf 'content\n' > "$CASE_DIR/custom payload/value with spaces"
  MIG_CUSTOM_PATHS="$CASE_DIR/custom payload"
  _bk_do_custom "$(backup_root)/sample" || return
  _mig_resync_manifest "$(backup_root)/sample" || return
  backup_verify sample
}

partial_backup_is_failure() {
  printf 'services: {}\n' > "$BASE_DIR/docker-compose.yml"
  _bk_do_custom() { printf incomplete > "$1/custom.tar.gz"; return 1; }
  _bk_write_inventory() { :; }; _bk_write_image_lock() { :; }
  local point rc=0
  point=$(backup_create synthetic ai-config custom) || rc=$?
  [[ "$rc" == 2 && -d "$point" ]] || return 1
  python3 "$BACKUP_LIB_DIR/backup_archive.py" verify "$point" || return
  ! python3 "$BACKUP_LIB_DIR/backup_archive.py" verify "$point" --complete
}

bundle_selected_scopes() {
  make_point sample || return
  mkdir -p "$CASE_DIR/custom payload"
  printf 'content\n' > "$CASE_DIR/custom payload/value with spaces"
  MIG_CUSTOM_PATHS="$CASE_DIR/custom payload"
  _bk_do_custom "$(backup_root)/sample" || return
  _mig_resync_manifest "$(backup_root)/sample" || return
  mig_write_manifest_v2 "$(backup_root)/sample" none ai-config custom || return
  local bundle unpacked
  bundle=$(mig_pack_bundle sample none "$CASE_DIR/bundles" '' ai-config) || return
  mv "$(backup_root)/sample" "$CASE_DIR/original"
  unpacked=$(mig_unpack_bundle "$bundle" none) || return
  [[ -f "$(backup_root)/$unpacked/ai-config.tar.gz" && ! -e "$(backup_root)/$unpacked/custom.tar.gz" ]] || return 1
  [[ -f "$CASE_DIR/original/custom.tar.gz" ]]
}

eof_does_not_confirm() {
  source "$TEST_REPO/lib/utils.sh"
  local answer=true
  askyn answer synthetic y </dev/null && return 1
  [[ "$answer" == false ]] || return 1
  INPUT_RESULT=3
  input_choose synthetic '*default action' </dev/null || return
  [[ "$INPUT_RESULT" == -1 ]]
}

age_keyfile_roundtrip() {
  make_point sample || return
  age-keygen -o "$CASE_DIR/identity" 2>/dev/null || return
  age-keygen -y "$CASE_DIR/identity" > "$CASE_DIR/recipients" || return
  local bundle restored
  bundle=$(mig_pack_bundle sample age-keyfile "$CASE_DIR/bundles" "$CASE_DIR/recipients") || return
  mv "$(backup_root)/sample" "$CASE_DIR/original"
  restored=$(mig_unpack_bundle "$bundle" age-keyfile "$CASE_DIR/identity") || return
  cmp "$CASE_DIR/original/ai-config.tar.gz" "$(backup_root)/$restored/ai-config.tar.gz"
}

eof_arrow_menu_cancels() {
  source "$TEST_REPO/lib/menu.sh"
  howe_menu_single synthetic action </dev/null && return 1
  [[ "$HOWE_MENU_BACK" == true && "$HOWE_MENU_RESULT" == -1 ]]
}

incomplete_entry_fails_clearly() {
  bash <(cat "$TEST_REPO/howe.sh") info > "$CASE_DIR/entry.log" 2>&1 && return 1
  grep -q '缺少脚本模块' "$CASE_DIR/entry.log"
}

tool_update_is_atomic() {
  source "$TEST_REPO/modules/mod_complex_tools.sh"
  SCRIPTS_DIR="$CASE_DIR/scripts"; mkdir -p "$SCRIPTS_DIR"
  _COMPLEX_TOOLS[synthetic]='test.sh|synthetic'
  _COMPLEX_UPDATE_URLS[synthetic]='https://example.invalid/test'
  printf '#!/bin/sh\nexit 0\n' > "$SCRIPTS_DIR/test.sh"
  curl() { touch "$CASE_DIR/download-attempted"; printf 'if true; then\n' > "${@: -1}"; }
  _update_complex_tool synthetic && return 1
  [[ -f "$CASE_DIR/download-attempted" ]] || return 1
  grep -q '^exit 0$' "$SCRIPTS_DIR/test.sh" || return
  [[ -z "$(find "$SCRIPTS_DIR" -name '*.download.*' -print)" ]]
}

stopped_database_blocks_upgrade_backup() {
  source "$TEST_REPO/ai_stack/view.sh"
  docker() { return 0; }
  ! _dump_db_if_needed new-api
}

native_install_failure_is_returned() {
  source "$TEST_REPO/ai_stack/migrate.sh"
  printf '{"native_versions":{"sing_box":"1.12.0"}}\n' > "$CASE_DIR/host-inventory.json"
  mig_local_tool_version() { :; }
  input_choose() { INPUT_RESULT=0; }
  _mig_install_native() { return 42; }
  ! _mig_reconcile_binaries_only "$CASE_DIR"
}

image_pull_failure_is_returned() {
  printf '{"images":[{"service":"synthetic","ref":"example.invalid/service:latest"}]}\n' > "$CASE_DIR/docker-images.lock.json"
  docker() { [[ "$1" == info ]]; }
  _mig_img_local_digest() { :; }
  ! mig_reconcile_images "$CASE_DIR" <<< ''
}

missing_native_service_is_failure() {
  ! _mig_verify_restore frps
}

missing_compose_is_failure() {
  ! _mig_offer_compose_up || return 1
  ! _mig_verify_restore ai-config
}

tests=0; failures=0
run_case() {
  local name=$1; shift
  tests=$((tests+1))
  if (
    CASE_DIR="$TEST_TMP/$name"; mkdir -p "$CASE_DIR"
    BASE_DIR="$CASE_DIR/base"; BACKUP_AI_BASE="$BASE_DIR"; mkdir -p "$BASE_DIR"
    "$@"
  ) > "$TEST_TMP/$name.log" 2>&1; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    tail -12 "$TEST_TMP/$name.log" >&2
    failures=$((failures+1))
  fi
}
run_case bundle_none bundle_roundtrip none
run_case bundle_openssl bundle_roundtrip openssl
run_case upgrade_healthy upgrade_healthy
run_case upgrade_unhealthy upgrade_unhealthy_fails
run_case upgrade_backup_failure upgrade_backup_failure_stops
run_case upgrade_dump_failure upgrade_dump_failure_stops
run_case upgrade_configured_image upgrade_uses_configured_image
run_case restore_failure restore_failure_propagates
run_case rollback_oldest oldest_rollback_survives
run_case fresh_restore fresh_restore 0
run_case fresh_restore_database_failure fresh_restore 42
run_case restore_startup_declined fresh_restore 0 2
run_case compose_health_failure compose_health_failure
run_case empty_database_archive empty_database_archive_fails
run_case metadata_escape metadata_rejects_escape
run_case ssh_failure ssh_failure_is_returned
run_case postgres_init_script postgres_init_script_is_backed_up
run_case native_ip_and_startup native_ip_and_startup
run_case native_domain_endpoint_survives native_domain_endpoint_survives
run_case native_startup_failure native_startup_failure
run_case first_clash_install first_clash_install_has_subscription_inbound
run_case clash_setup_failure clash_setup_failure_stops_install
run_case health_json_lines restore_verification '{"State":"running","Health":"healthy"}' 0
run_case health_json_array restore_verification $'[\n {"State":"running","Health":"healthy"}\n]' 0
run_case health_starting_fails restore_verification '{"State":"running","Health":"starting"}' 1
run_case health_empty_fails restore_verification '' 1
run_case health_bad_json_fails restore_verification 'invalid json' 1
run_case special_scope_manifest special_scope_manifest
run_case partial_backup_is_failure partial_backup_is_failure
run_case bundle_selected_scopes bundle_selected_scopes
run_case eof_does_not_confirm eof_does_not_confirm
run_case eof_arrow_menu_cancels eof_arrow_menu_cancels
run_case incomplete_entry incomplete_entry_fails_clearly
run_case tool_update_atomic tool_update_is_atomic
run_case stopped_database_backup stopped_database_blocks_upgrade_backup
run_case native_install_failure native_install_failure_is_returned
run_case image_pull_failure image_pull_failure_is_returned
run_case missing_native_service missing_native_service_is_failure
run_case missing_compose missing_compose_is_failure
if command -v age >/dev/null; then
  run_case bundle_age_keyfile age_keyfile_roundtrip
else
  printf 'SKIP bundle_age_keyfile (age 未安装)\n'
fi
printf 'LIFECYCLE_TESTS=%d FAILURES=%d\n' "$tests" "$failures"
(( failures == 0 ))
