#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 本地网络测试函数
#
# 所有功能用 bash + curl 原生实现，零外部脚本依赖
# ═══════════════════════════════════════════════════════════════════

# ── 工具函数 ─────────────────────────────────────────────────────

# 格式化字节速度
_fmt_speed() {
  local bytes=$1 seconds=$2
  local speed=$((bytes / seconds / 1024 / 1024))
  if [[ $speed -ge 1024 ]]; then
    echo "$((speed / 1024)).$((speed % 1024 / 10)) GB/s"
  else
    echo "${speed} MB/s"
  fi
}

# 带超时的 curl HTTP 状态码
_http_code() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -L "$1" 2>/dev/null
}

# ── ChatGPT 解锁检测 ─────────────────────────────────────────────

check_chatgpt() {
  section "ChatGPT 解锁状态检测"

  # 获取当前 IP 信息
  local ip_info
  ip_info=$(curl -s --max-time 5 "${URL_IPINFO}" 2>/dev/null)
  local ip=$(echo "$ip_info" | grep '"ip"' | head -1 | grep -oP '[\d.]+')
  local country=$(echo "$ip_info" | grep '"country"' | grep -oP '"[A-Z]{2}"' | tr -d '"')
  local org=$(echo "$ip_info" | grep '"org"' | cut -d'"' -f4)

  echo -e "  ${DIM}IP：${N}${ip:-未知}  ${DIM}地区：${N}${country:-未知}"
  echo -e "  ${DIM}ISP：${N}${org:-未知}"
  echo ""

  # 测试 api.openai.com
  echo -ne "  ${DIM}测试 api.openai.com ...${N} "
  local api_code
  api_code=$(_http_code "${URL_OPENAI_API}")
  if [[ "$api_code" == "200" ]] || [[ "$api_code" == "401" ]]; then
    echo -e "${G}可用${N} (HTTP $api_code)"
  elif [[ "$api_code" == "403" ]]; then
    echo -e "${R}被封锁${N} (HTTP 403)"
  elif [[ "$api_code" == "000" ]]; then
    echo -e "${R}连接超时${N}"
  else
    echo -e "${Y}异常${N} (HTTP $api_code)"
  fi

  # 测试 chat.openai.com
  echo -ne "  ${DIM}测试 chat.openai.com ...${N} "
  local chat_code
  chat_code=$(_http_code "${URL_OPENAI_CHAT}")
  if [[ "$chat_code" == "200" ]]; then
    echo -e "${G}可用${N}"
  elif [[ "$chat_code" == "403" ]]; then
    echo -e "${R}被封锁${N}"
  elif [[ "$chat_code" == "000" ]]; then
    echo -e "${R}连接超时${N}"
  else
    echo -e "${Y}HTTP $chat_code${N}"
  fi

  # 测试 oai 到期检测
  echo -ne "  ${DIM}测试 oai 到期状态 ...${N} "
  local oai_status
  oai_status=$(curl -s --max-time 10 "${URL_OPENAI_STATUS}" 2>/dev/null)
  if echo "$oai_status" | grep -q '"status":"normal"'; then
    echo -e "${G}正常${N}"
  elif [[ -z "$oai_status" ]]; then
    echo -e "${Y}无法获取${N}"
  else
    echo -e "${Y}${oai_status}${N}"
  fi

  echo ""

  # 综合判断
  if [[ "$api_code" == "200" ]] || [[ "$api_code" == "401" ]]; then
    log "当前 IP 可正常使用 ChatGPT API"
  else
    warn "当前 IP 可能无法使用 ChatGPT API（HTTP $api_code）"
  fi
}

# ── 流媒体解锁检测 ───────────────────────────────────────────────

check_streaming() {
  section "流媒体解锁检测"

  # Netflix
  echo -ne "  ${DIM}Netflix          ...${N} "
  local nf_code
  nf_code=$(_http_code "${URL_NETFLIX}")
  if [[ "$nf_code" == "200" ]]; then
    echo -e "${G}解锁${N}"
  elif [[ "$nf_code" == "404" ]]; then
    echo -e "${Y}未解锁（地区限制）${N}"
  elif [[ "$nf_code" == "403" ]]; then
    echo -e "${R}被封锁${N}"
  else
    echo -e "${Y}HTTP $nf_code${N}"
  fi

  # YouTube Premium
  echo -ne "  ${DIM}YouTube Premium  ...${N} "
  local yt_body
  yt_body=$(curl -s --max-time 10 -L "${URL_YOUTUBE_PREMIUM}" 2>/dev/null)
  if echo "$yt_body" | grep -q "Premium is not available in your country"; then
    echo -e "${R}未解锁${N}"
  elif echo "$yt_body" | grep -qo '"GL":"[A-Z]*"' ; then
    local yt_region
    yt_region=$(echo "$yt_body" | grep -oP '"GL":"[A-Z]*"' | head -1 | grep -oP '[A-Z]{2}')
    echo -e "${G}解锁${N} (地区: $yt_region)"
  elif [[ -n "$yt_body" ]]; then
    echo -e "${G}可能解锁${N}"
  else
    echo -e "${Y}无法检测${N}"
  fi

  # Disney+
  echo -ne "  ${DIM}Disney+          ...${N} "
  local dis_code
  dis_code=$(_http_code "${URL_DISNEYPLUS}")
  if [[ "$dis_code" == "200" ]]; then
    local dis_body
    dis_body=$(curl -s --max-time 10 -L "${URL_DISNEYPLUS}" 2>/dev/null)
    local dis_region
    dis_region=$(echo "$dis_body" | grep -oP '"countryCode":"[A-Z]*"' | head -1 | grep -oP '[A-Z]{2}')
    if [[ -n "$dis_region" ]]; then
      echo -e "${G}解锁${N} (地区: $dis_region)"
    else
      echo -e "${G}可访问${N}"
    fi
  elif [[ "$dis_code" == "403" ]]; then
    echo -e "${R}被封锁${N}"
  else
    echo -e "${Y}HTTP $dis_code${N}"
  fi

  # TikTok
  echo -ne "  ${DIM}TikTok           ...${N} "
  local tiktok_code
  tiktok_code=$(_http_code "${URL_TIKTOK}")
  if [[ "$tiktok_code" == "200" ]]; then
    echo -e "${G}可访问${N}"
  elif [[ "$tiktok_code" == "000" ]]; then
    echo -e "${R}连接超时${N}"
  else
    echo -e "${Y}HTTP $tiktok_code${N}"
  fi

  # Spotify
  echo -ne "  ${DIM}Spotify          ...${N} "
  local spotify_body
  spotify_body=$(curl -s --max-time 10 "${URL_SPOTIFY}" -H "Accept: application/json" 2>/dev/null)
  local spotify_country
  spotify_country=$(echo "$spotify_body" | grep -oP '"country":"[A-Z]*"' | head -1 | grep -oP '[A-Z]{2}')
  if [[ -n "$spotify_country" ]]; then
    echo -e "${G}解锁${N} (地区: $spotify_country)"
  elif [[ -n "$spotify_body" ]]; then
    echo -e "${Y}可访问${N}"
  else
    echo -e "${Y}无法检测${N}"
  fi

  echo ""
}

# ── IP 质量检测 ──────────────────────────────────────────────────

check_ip_quality() {
  section "IP 质量检测"

  local ip_info
  ip_info=$(curl -s --max-time 5 "${URL_IPINFO}" 2>/dev/null)

  local ip=$(echo "$ip_info" | grep '"ip"' | head -1 | grep -oP '[\d.]+')
  local country=$(echo "$ip_info" | grep '"country"' | grep -oP '"[A-Z]{2}"' | tr -d '"')
  local city=$(echo "$ip_info" | grep '"city"' | cut -d'"' -f4)
  local org=$(echo "$ip_info" | grep '"org"' | cut -d'"' -f4)
  local asn=$(echo "$org" | grep -oP 'AS\d+')

  echo -e "  ${W}基本信息${N}"
  echo "  IP:      ${ip:-未知}"
  echo "  位置:    ${city:-未知}, ${country:-未知}"
  echo "  ISP:     ${org:-未知}"
  echo ""

  # 反向 DNS
  echo -e "  ${W}反向 DNS${N}"
  local rdns
  rdns=$(host "$ip" 2>/dev/null | grep "domain name pointer" | awk '{print $NF}')
  if [[ -n "$rdns" ]]; then
    echo "  rDNS:    $rdns"
  else
    echo "  rDNS:    无"
  fi
  echo ""

  # 黑名单检测
  echo -e "  ${W}安全检测${N}"
  echo -ne "  ${DIM}Spamhaus ...${N} "
  if command -v host &>/dev/null && [[ -n "$asn" ]]; then
    local reverse_ip
    reverse_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
    if host "${reverse_ip}.zen.spamhaus.org" &>/dev/null; then
      echo -e "${R}在黑名单${N}"
    else
      echo -e "${G}正常${N}"
    fi
  else
    echo -e "${Y}跳过${N}"
  fi

  # WebRTC 泄漏检测
  echo -ne "  ${DIM}WebRTC 泄漏 ...${N} "
  local stun_result
  stun_result=$(curl -s --max-time 5 "${URL_WEBRTC_CHECK}" 2>/dev/null)
  if [[ -n "$stun_result" ]]; then
    echo -e "${G}正常${N}"
  else
    echo -e "${Y}无法检测${N}"
  fi

  echo ""
}

# ── 三网回程路由测试 ─────────────────────────────────────────────

# 中国三网测试 IP
declare -a _ROUTE_TARGETS=(
  "219.141.136.12|北京电信"
  "202.106.50.1|北京联通"
  "221.179.155.161|北京移动"
  "202.96.209.133|上海电信"
  "210.22.97.1|上海联通"
  "211.136.112.200|上海移动"
  "58.60.188.222|广州电信"
  "210.21.196.6|广州联通"
  "120.196.165.24|广州移动"
)

_test_route() {
  local target="$1"
  local ip="${target%%|*}"
  local name="${target##*|}"

  echo -e "  ${W}${name}${N} ($ip)"
  if command -v mtr &>/dev/null; then
    mtr -r -c 3 -n --no-dns "$ip" 2>/dev/null | tail -n +2 | sed 's/^/    /'
  elif command -v traceroute &>/dev/null; then
    traceroute -n -m 15 -w 2 "$ip" 2>/dev/null | tail -n +2 | sed 's/^/    /'
  else
    echo -e "    ${Y}需要安装 mtr 或 traceroute${N}"
    return 1
  fi
  echo ""
}

check_route() {
  section "三网回程路由测试"

  if ! command -v mtr &>/dev/null && ! command -v traceroute &>/dev/null; then
    warn "需要安装 mtr 或 traceroute"
    local yn
    askyn yn "是否安装 mtr？" "y"
    if $yn; then
      if command -v apt &>/dev/null; then
        apt install -y mtr >/dev/null 2>&1
      elif command -v dnf &>/dev/null; then
        dnf install -y mtr >/dev/null 2>&1
      elif command -v yum &>/dev/null; then
        yum install -y mtr >/dev/null 2>&1
      elif command -v apk &>/dev/null; then
        apk add mtr >/dev/null 2>&1
      fi
    else
      return 1
    fi
  fi

  echo ""
  for target in "${_ROUTE_TARGETS[@]}"; do
    _test_route "$target"
  done
}

# 指定 IP 回程测试
check_route_custom() {
  echo -e "${W}可参考的国内 IP 列表${N}"
  echo -e "${DIM}────────────────────────────────────${N}"
  for target in "${_ROUTE_TARGETS[@]}"; do
    local ip="${target%%|*}"
    local name="${target##*|}"
    printf "  %-10s %s\n" "$name" "$ip"
  done
  echo -e "${DIM}────────────────────────────────────${N}"
  echo ""

  local testip
  read -erp "  输入目标 IP：" testip
  [[ -z "$testip" ]] && return

  section "回程路由 → $testip"
  if command -v mtr &>/dev/null; then
    mtr -r -c 10 -n "$testip"
  elif command -v traceroute &>/dev/null; then
    traceroute -n -m 30 -w 3 "$testip"
  else
    warn "需要安装 mtr 或 traceroute"
    return 1
  fi
}

# ── 三网测速 ─────────────────────────────────────────────────────

# 测速文件列表（已知稳定的测试端点）
declare -a _SPEED_TARGETS=(
  "${URL_SPEED_CACHEFLY}|Cachefly CDN"
  "${URL_SPEED_TELE2}|Tele2 瑞典"
  "${URL_SPEED_OVH}|OVH 法国"
  "${URL_SPEED_BOUYGUES}|Bouygues 法国"
  "${URL_SPEED_OTE}|OTE 希腊"
)

_speed_test_single() {
  local url="$1"
  local name="$2"

  echo -ne "  ${DIM}${name}${N} "
  local result
  result=$(curl -s -o /dev/null -w "%{speed_download} %{time_total}" --max-time 30 "$url" 2>/dev/null)
  local speed=$(echo "$result" | awk '{printf "%.2f", $1/1024/1024}')
  local time=$(echo "$result" | awk '{printf "%.1f", $2}')

  if [[ "$(echo "$speed > 0.01" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
    echo -e "${G}${speed} MB/s${N} (${time}s)"
  else
    echo -e "${R}失败${N}"
  fi
}

check_speed() {
  section "三网测速"

  # 检查是否安装了 speedtest-cli
  if command -v speedtest-cli &>/dev/null; then
    echo -e "  ${W}使用 speedtest-cli 测试${N}"
    echo ""
    speedtest-cli --simple 2>/dev/null | sed 's/^/  /'
    echo ""
  elif command -v speedtest &>/dev/null; then
    echo -e "  ${W}使用 speedtest 测试${N}"
    echo ""
    speedtest --simple 2>/dev/null | sed 's/^/  /'
    echo ""
  fi

  echo -e "  ${W}下载速度测试（10MB 文件）${N}"
  echo ""

  for target in "${_SPEED_TARGETS[@]}"; do
    local url="${target%%|*}"
    local name="${target##*|}"
    _speed_test_single "$url" "$name"
  done
  echo ""
}

# ── 基准测试 ─────────────────────────────────────────────────────

check_bench() {
  section "服务器基准测试"

  # CPU 测试
  echo -e "  ${W}CPU 性能${N}"
  echo -ne "  ${DIM}单核 md5sum (1GB)  ...${N} "
  local cpu_time
  cpu_time=$( { time dd if=/dev/zero bs=1M count=1024 2>/dev/null | md5sum >/dev/null; } 2>&1 | grep real | grep -oP '[\d.]+')
  echo -e "${G}${cpu_time}s${N}"

  # 磁盘写入测试
  echo -e ""
  echo -e "  ${W}磁盘 I/O${N}"
  echo -ne "  ${DIM}顺序写入 (1GB)     ...${N} "
  local write_result
  write_result=$(dd if=/dev/zero of=/tmp/howe_bench_test bs=1M count=1024 conv=fdatasync 2>&1 | tail -1)
  local write_speed=$(echo "$write_result" | grep -oP '[\d.]+ [A-Za-z/]+/s')
  echo -e "${G}${write_speed}${N}"

  echo -ne "  ${DIM}顺序读取 (1GB)     ...${N} "
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
  local read_result
  read_result=$(dd if=/tmp/howe_bench_test of=/dev/null bs=1M 2>&1 | tail -1)
  local read_speed=$(echo "$read_result" | grep -oP '[\d.]+ [A-Za-z/]+/s')
  echo -e "${G}${read_speed}${N}"
  rm -f /tmp/howe_bench_test

  # 4K 随机读写 (需要 fio)
  if command -v fio &>/dev/null; then
    echo ""
    echo -e "  ${W}4K 随机 I/O (fio)${N}"
    echo -ne "  ${DIM}随机读 ...${N} "
    local fio_read
    fio_read=$(fio --name=randread --ioengine=libaio --direct=1 --bs=4k --size=64m --numjobs=1 --runtime=5 --rw=randread --group_reporting 2>/dev/null | grep "read:" | grep -oP 'IOPS=[\d.k]+' | head -1)
    echo -e "${G}${fio_read:-N/A}${N}"

    echo -ne "  ${DIM}随机写 ...${N} "
    local fio_write
    fio_write=$(fio --name=randwrite --ioengine=libaio --direct=1 --bs=4k --size=64m --numjobs=1 --runtime=5 --rw=randwrite --group_reporting 2>/dev/null | grep "write:" | grep -oP 'IOPS=[\d.k]+' | head -1)
    echo -e "${G}${fio_write:-N/A}${N}"
    rm -f /tmp/randread.* /tmp/randwrite.* 2>/dev/null
  fi

  # 下载速度
  echo ""
  echo -e "  ${W}网络下载${N}"
  echo -ne "  ${DIM}Cachefly 10MB     ...${N} "
  local dl_result
  dl_result=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 30 "${URL_SPEED_CACHEFLY}" 2>/dev/null)
  local dl_speed=$(echo "$dl_result" | awk '{printf "%.2f", $1/1024/1024}')
  echo -e "${G}${dl_speed} MB/s${N}"

  echo ""
}
