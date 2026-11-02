#!/usr/bin/env bash
# 真实 PostgreSQL 集成. 只创建带测试前缀的隔离容器, 不挂载生产目录或开放端口.
set -euo pipefail
TEST_DOCKER_CLI=$(command -v docker)
: "${POSTGRES_TEST_IMAGE:?请指定本机已有的 PostgreSQL 16 镜像, 测试不自动拉取镜像}"
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/howe-postgres-test.XXXXXX)
container="howe-test-pg-$$-$RANDOM"
project="howe-test-compose-$$-$RANDOM"
created=false
cleanup() {
  local rc=0
  if [[ -f "$fixture/compose/docker-compose.yml" ]]; then
    "$TEST_DOCKER_CLI" compose -p "$project" -f "$fixture/compose/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || rc=1
  fi
  if $created; then "$TEST_DOCKER_CLI" rm -fv "$container" >/dev/null || rc=1; fi
  rm -rf -- "$fixture" || rc=1
  return "$rc"
}
trap 'status=$?; cleanup || status=1; exit "$status"' EXIT
BACKUP_CONF_FILE="$fixture/backup.conf"
source "$TEST_REPO/ai_stack/ai-stack-setup.sh"
BASE_DIR="$fixture/base"; BACKUP_AI_BASE="$BASE_DIR"; mkdir -p "$BASE_DIR"
"$TEST_DOCKER_CLI" create --pull never --network none --memory 192m --cpus .5 \
  --name "$container" --label howe-test=postgres \
  -e POSTGRES_USER=ai -e POSTGRES_PASSWORD=synthetic-test-only -e POSTGRES_DB=postgres \
  "$POSTGRES_TEST_IMAGE" -c shared_buffers=16MB -c max_connections=10 >/dev/null
created=true
"$TEST_DOCKER_CLI" start "$container" >/dev/null
ready=false
for (( attempt=0; attempt<60; attempt++ )); do
  if "$TEST_DOCKER_CLI" exec "$container" pg_isready -h 127.0.0.1 -U ai -d postgres >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
$ready || { echo '临时 PostgreSQL 未就绪' >&2; exit 1; }

# 仅把生产函数中的 ai-db 映射到本次创建的容器; 其他容器命令拒绝执行.
docker() {
  local -a mapped=()
  local argument
  case "$1" in
    ps) printf 'ai-db\n'; return 0 ;;
    exec|cp)
      for argument in "$@"; do
        case "$argument" in ai-db) argument="$container";; ai-db:*) argument="$container:${argument#*:}";; esac
        mapped+=("$argument")
      done
      "$TEST_DOCKER_CLI" "${mapped[@]}" ;;
    *) printf '拒绝未声明的测试 Docker 命令: %s\n' "$*" >&2; return 97 ;;
  esac
}
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE howe_fixture OWNER ai;' >/dev/null
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d howe_fixture -v ON_ERROR_STOP=1 -c "CREATE TABLE marker(value text); INSERT INTO marker VALUES ('before');" >/dev/null
mkdir "$fixture/point"
_bk_do_ai_pg "$fixture/point"
_bk_verify "$fixture/point/ai-pg.tar.gz"
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d howe_fixture -v ON_ERROR_STOP=1 -c "UPDATE marker SET value='after'; CREATE TABLE extra(value integer);" >/dev/null
_bk_rs_ai_pg "$fixture/point/ai-pg.tar.gz"
value=$("$TEST_DOCKER_CLI" exec "$container" psql -U ai -d howe_fixture -Atc 'SELECT value FROM marker;')
[[ "$value" == before ]]
value=$("$TEST_DOCKER_CLI" exec "$container" psql -U ai -d howe_fixture -Atc "SELECT to_regclass('public.extra');")
[[ -z "$value" ]]
echo PASS_REAL_POSTGRES_DUMP_RESTORE

# 真实执行回滚中的 SQL drop/create/import, 镜像与应用容器操作全部模拟.
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE newapi OWNER ai;' >/dev/null
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d newapi -v ON_ERROR_STOP=1 -c "CREATE TABLE marker(value text); INSERT INTO marker VALUES ('rollback-before');" >/dev/null
mkdir -p "$BASE_DIR/upgrade/history" "$BASE_DIR/upgrade/db_backups"
printf 't1 example.invalid/test:latest sha256:old\n' > "$BASE_DIR/upgrade/history/new-api.log"
"$TEST_DOCKER_CLI" exec "$container" pg_dump -U ai newapi | gzip > "$BASE_DIR/upgrade/db_backups/new-api-test.sql.gz"
"$TEST_DOCKER_CLI" exec "$container" psql -U ai -d newapi -v ON_ERROR_STOP=1 -c "UPDATE marker SET value='rollback-after';" >/dev/null
_svc_image_ref() { echo example.invalid/test:latest; }
_svc_image_id() { echo sha256:current; }
askyn() { printf -v "$1" '%s' true; }
eval "$(declare -f docker | sed '1s/docker /fixture_docker /')"
docker() {
  case "$*" in
    'exec '*|'cp '*) fixture_docker "$@" ;;
    'compose config --services') echo new-api ;;
    'compose config --format json') echo '{"services":{"new-api":{"image":"example.invalid/test:latest"}}}' ;;
    'image inspect '*|'tag '*|'compose stop '*|'compose up '*|'logs --tail '*) return 0 ;;
    *) return 97 ;;
  esac
}
rollback_single_service fixture new-api <<< $'1\n1\n'
value=$("$TEST_DOCKER_CLI" exec "$container" psql -U ai -d newapi -Atc 'SELECT value FROM marker;')
[[ "$value" == rollback-before ]]
echo PASS_REAL_SQL_ROLLBACK

# 非法 SQL 必须让真实回滚失败, 不能静默宣称成功.
printf 'INVALID SQL;\n' | gzip > "$BASE_DIR/upgrade/db_backups/new-api-test.sql.gz"
if rollback_single_service fixture new-api <<< $'1\n1\n'; then
  echo '非法 SQL 未使回滚失败' >&2; exit 1
fi
echo PASS_REAL_SQL_FAILURE_PROPAGATES

# 用独立 Compose project 验证官方 --wait 的真实健康等待和失败行为.
BASE_DIR="$fixture/compose"; BACKUP_AI_BASE="$BASE_DIR"; mkdir -p "$BASE_DIR"
cat > "$BASE_DIR/docker-compose.yml" <<YAML
services:
  database:
    image: ${POSTGRES_TEST_IMAGE}
    network_mode: none
    mem_limit: 192m
    cpus: 0.5
    environment:
      POSTGRES_USER: ai
      POSTGRES_PASSWORD: synthetic-test-only
    command: ["postgres", "-c", "shared_buffers=16MB", "-c", "max_connections=10"]
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "ai", "-d", "postgres"]
      interval: 1s
      timeout: 2s
      retries: 10
YAML
docker() {
  [[ "$1" == compose ]] || return 97
  shift
  "$TEST_DOCKER_CLI" compose -p "$project" -f "$BASE_DIR/docker-compose.yml" "$@"
}
_mig_offer_compose_up
echo PASS_REAL_COMPOSE_HEALTHY
sed -i 's/"pg_isready", "-h", "127.0.0.1", "-U", "ai", "-d", "postgres"/"false"/' "$BASE_DIR/docker-compose.yml"
if _mig_offer_compose_up; then
  echo '不健康的测试服务未被拒绝' >&2; exit 1
fi
echo PASS_REAL_COMPOSE_UNHEALTHY_REJECTED
