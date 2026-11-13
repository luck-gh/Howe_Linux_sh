#!/usr/bin/env bash
# 使用合成镜像状态验证版本检查, 不访问 Docker 或网络.
set -uo pipefail
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d) || exit 1
trap 'rm -rf -- "$fixture"' EXIT
source "$TEST_REPO/ai_stack/ai-stack-setup.sh"
print_header() { :; }
_svc_image_ref() { echo example.invalid/app:latest; }
_svc_image_id() { echo sha256:running-old; }
timeout() { shift; "$@"; }
backup_conf_get() { printf 'ai-config,kiro,nrouter\n'; }
for service in kiro-rs 9router; do
  scopes=$(_upgrade_backup_scopes_for_services "$service")
  grep -Fxq ai-config <<< "$scopes" || exit 1
  echo "PASS_CONFIG_BACKUP_$service"
done
mapfile -t unmatched < <(_upgrade_backup_scopes_for_services unregistered)
(( ${#unmatched[@]} == 0 )) || exit 1
echo PASS_EMPTY_BACKUP_SCOPE_IS_EMPTY
docker() {
  case "$*" in
    'image inspect sha256:running-old '*) echo example.invalid/app@sha256:old ;;
    'buildx imagetools inspect '*) echo sha256:new ;;
    *) echo '未声明的 Docker 调用' >&2; return 97 ;;
  esac
}
_check_one_update TEST synthetic docker app "$fixture/version" || exit 1
grep -q '|↑$' "$fixture/version" || exit 1
echo PASS_RUNNING_IMAGE_INSTEAD_OF_PULLED_TAG

docker() {
  case "$1" in
    image) echo example.invalid/app@sha256:old ;;
    buildx) echo sha256:new; return 23 ;;
    *) return 97 ;;
  esac
}
_check_one_update TEST synthetic docker app "$fixture/version" || exit 1
grep -q '|?$' "$fixture/version" || exit 1
echo PASS_REGISTRY_FAILURE_WITH_PARTIAL_OUTPUT

docker() { return 1; }
_check_one_update TEST synthetic docker app "$fixture/version" && exit 1
echo PASS_IMAGE_INSPECTION_FAILURE

BASE_DIR="$fixture/base"; mkdir -p "$BASE_DIR"; touch "$BASE_DIR/.env"
_UPDATE_CACHE_DIR="$fixture/cache"; mkdir -p "$_UPDATE_CACHE_DIR"
SVC_REGISTRY_STACK=('TEST|synthetic|docker|app')
detect_installed_services() { SVC_TEST_INSTALLED=true; }
_update_cache_refresh() { :; }
for state in '?' missing '✓'; do
  rm -f "$_UPDATE_CACHE_DIR/TEST"
  [[ "$state" == missing ]] || printf 'TEST|synthetic|old|new|%s\n' "$state" > "$_UPDATE_CACHE_DIR/TEST"
  check_all_updates 1 <<< '' > "$fixture/report" || exit 1
  if [[ "$state" == '✓' ]]; then
    grep -q '全部已是最新' "$fixture/report" || exit 1
  else
    grep -q '未能确认版本' "$fixture/report" || exit 1
    if grep '全部已是最新' "$fixture/report" | grep -v '不能判定' >/dev/null; then exit 1; fi
  fi
  echo "PASS_REPORT_$state"
done
