#!/usr/bin/env bash
# 公网地址边界及安装入口的隔离回归, 不访问网络或修改业务配置.
set -uo pipefail
TEST_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TEST_REPO/lib/urls.sh"
source "$TEST_REPO/lib/public_ip.sh"
source "$TEST_REPO/ai_stack/services.sh"
source "$TEST_REPO/ai_stack/lifecycle.sh"

curl() {
  [[ " $* " == *' --noproxy * '* ]] || return 98
  case "$1" in
    -4) printf '%s' "$MOCK_IPV4"; return "$MOCK_IPV4_RC" ;;
    -6) printf '%s' "$MOCK_IPV6"; return "$MOCK_IPV6_RC" ;;
    *) return 99 ;;
  esac
}

dual_stack() {
  detect_public_ips || return
  [[ "$PUBLIC_IP" == 1.1.1.1 && "$IPV6_ADDRESS" == 2606:4700:4700::1111 ]]
}

ipv6_unavailable() {
  MOCK_IPV6_RC=7
  detect_public_ips 2>/dev/null || return
  [[ "$PUBLIC_IP" == 1.1.1.1 && -z "$IPV6_ADDRESS" ]] || return 1
  [[ "$(show_public_ips)" == *'公网 IPv6: 未获取'* ]]
}

ipv4_unavailable() {
  MOCK_IPV4_RC=7
  PUBLIC_IP=8.8.8.8
  detect_public_ips 2>/dev/null || return
  [[ -z "$PUBLIC_IP" && "$IPV6_ADDRESS" == 2606:4700:4700::1111 ]]
}

ipv4_rejects_ipv6() {
  MOCK_IPV4="$MOCK_IPV6"
  ! _query_public_ip 4 >/dev/null 2>&1
}

ipv6_rejects_ipv4() {
  MOCK_IPV6="$MOCK_IPV4"
  ! _query_public_ip 6 >/dev/null 2>&1
}

rejects_html() {
  MOCK_IPV4='<html>upstream error</html>'
  ! _query_public_ip 4 >/dev/null 2>&1
}

rejects_private_address() {
  MOCK_IPV4=192.168.1.2
  ! _query_public_ip 4 >/dev/null 2>&1
}

trims_response() {
  MOCK_IPV4=$' 1.1.1.1\r\n'
  [[ "$(_query_public_ip 4)" == 1.1.1.1 ]]
}

replaces_saved_ipv4() {
  VPS_IP=8.8.8.8
  PUBLIC_IP=1.1.1.1
  MOCK_IPV4_RC=7
  use_current_ipv4 || return
  [[ "$VPS_IP" == 1.1.1.1 ]]
}

refreshes_saved_ipv4() {
  VPS_IP=8.8.8.8
  PUBLIC_IP=8.8.8.8
  refresh_current_ipv4 || return
  [[ "$VPS_IP" == 1.1.1.1 && "$PUBLIC_IP" == 1.1.1.1 ]]
}

failed_refresh_clears_old_ipv4() {
  VPS_IP=8.8.8.8
  PUBLIC_IP=8.8.8.8
  MOCK_IPV4_RC=7
  refresh_current_ipv4 >/dev/null 2>&1 && return 1
  [[ -z "$VPS_IP" && -z "$PUBLIC_IP" ]]
}

singbox_stops_before_writing() {
  INST_SINGBOX=true
  VPS_IP=8.8.8.8
  MOCK_IPV4_RC=7
  touch() { printf 'unexpected write\n'; return 99; }
  local output rc
  output=$(write_singbox_config 2>/dev/null); rc=$?
  [[ "$rc" == 1 && -z "$output" ]]
}

installation_stops_after_failed_preflight() {
  preflight() { return 1; }
  collect_config() { printf 'unexpected configuration\n'; return 99; }
  local output rc
  output=$(install_or_update); rc=$?
  [[ "$rc" == 1 && -z "$output" ]]
}

failures=0
for test_case in dual_stack ipv6_unavailable ipv4_unavailable ipv4_rejects_ipv6 \
  ipv6_rejects_ipv4 rejects_html rejects_private_address trims_response \
  replaces_saved_ipv4 refreshes_saved_ipv4 failed_refresh_clears_old_ipv4 \
  singbox_stops_before_writing installation_stops_after_failed_preflight; do
  if (
    MOCK_IPV4=1.1.1.1; MOCK_IPV6=2606:4700:4700::1111
    MOCK_IPV4_RC=0; MOCK_IPV6_RC=0; PUBLIC_IP=; IPV6_ADDRESS=
    "$test_case"
  ); then
    printf 'PASS %s\n' "$test_case"
  else
    printf 'FAIL %s\n' "$test_case" >&2
    failures=$((failures + 1))
  fi
done
(( failures == 0 ))
