#!/usr/bin/env bash
# 用本地 Git 仓库验证快进更新和保护用户改动, 不连接外网.
set -euo pipefail
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
source "$TEST_REPO/modules/mod_system.sh"
log() { echo "$*"; }; warn() { echo "$*"; }
commit_fixture() { git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qam "$2"; }
git init --bare -q "$fixture/remote"
git init -q -b main "$fixture/source"
printf first > "$fixture/source/value"
git -C "$fixture/source" add value
commit_fixture "$fixture/source" first
git -C "$fixture/source" remote add origin "$fixture/remote"
git -C "$fixture/source" push -q origin main
git clone -q -b main "$fixture/remote" "$fixture/target"
printf second > "$fixture/source/value"
commit_fixture "$fixture/source" second
git -C "$fixture/source" push -q origin main
howe_update_self "$fixture/target"
cmp "$fixture/source/value" "$fixture/target/value"
echo PASS_SELF_UPDATE_FAST_FORWARD
printf local > "$fixture/target/value"
if howe_update_self "$fixture/target"; then exit 1; fi
[[ "$(cat "$fixture/target/value")" == local ]]
echo PASS_SELF_UPDATE_PRESERVES_DIRTY_TREE
commit_fixture "$fixture/target" local
local_head=$(git -C "$fixture/target" rev-parse HEAD)
printf third > "$fixture/source/value"
commit_fixture "$fixture/source" third
git -C "$fixture/source" push -q origin main
if howe_update_self "$fixture/target"; then exit 1; fi
[[ "$(git -C "$fixture/target" rev-parse HEAD)" == "$local_head" ]]
echo PASS_SELF_UPDATE_REFUSES_DIVERGENCE
