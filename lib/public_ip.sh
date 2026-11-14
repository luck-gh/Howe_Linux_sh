#!/usr/bin/env bash
# 当前进程探测到的公网地址, 不从持久化的 VPS_IP 推断主机身份.
PUBLIC_IP=""
IPV6_ADDRESS=""

_query_public_ip() {
  local family=$1 address
  address=$(curl "-${family}" --noproxy '*' -fsS --connect-timeout 3 --max-time 5 "$URL_PUBLIC_IP") || return $?
  python3 - "$family" "$address" <<'PY'
import ipaddress
import sys

family, value = int(sys.argv[1]), sys.argv[2].strip()
try:
    address = ipaddress.ip_address(value)
except ValueError:
    sys.exit(f"公网 IPv{family} 探测返回了无效地址")
if address.version != family or not address.is_global:
    sys.exit(f"公网 IPv{family} 探测未返回对应协议的公网地址")
print(address)
PY
}

detect_public_ips() {
  local status
  printf '  公网 IPv4: 查询中...\n' >&2
  if PUBLIC_IP=$(_query_public_ip 4); then
    printf '  公网 IPv4: 查询成功\n' >&2
  else
    status=$?
    PUBLIC_IP=""
    if (( status == 28 )); then
      printf '  公网 IPv4: 查询超时, 地址未知.\n' >&2
    else
      printf '  公网 IPv4: 查询失败, 地址未知 (退出码 %s).\n' "$status" >&2
    fi
  fi
  printf '  公网 IPv6: 查询中...\n' >&2
  if IPV6_ADDRESS=$(_query_public_ip 6); then
    printf '  公网 IPv6: 查询成功\n' >&2
  else
    status=$?
    IPV6_ADDRESS=""
    if (( status == 28 )); then
      printf '  公网 IPv6: 查询超时, 地址未知.\n' >&2
    else
      printf '  公网 IPv6: 查询失败或未配置, 地址未知 (退出码 %s).\n' "$status" >&2
    fi
  fi
}

refresh_current_ipv4() {
  if ! PUBLIC_IP=$(_query_public_ip 4); then
    PUBLIC_IP=""
    VPS_IP=""
    printf '无法获取当前公网 IPv4, 已停止生成依赖该地址的配置.\n' >&2
    return 1
  fi
  VPS_IP="$PUBLIC_IP"
}

use_current_ipv4() {
  if [[ -z "$PUBLIC_IP" ]]; then
    refresh_current_ipv4 || return 1
  fi
  VPS_IP="$PUBLIC_IP"
}

show_public_ips() {
  printf '  公网 IPv4: %s\n' "${PUBLIC_IP:-未获取（探测失败）}"
  printf '  公网 IPv6: %s\n' "${IPV6_ADDRESS:-未获取（未配置或探测失败）}"
}
