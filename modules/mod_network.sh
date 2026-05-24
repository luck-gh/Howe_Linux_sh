#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 网络优化模块
#
# 功能：DNS 管理 / BBR 拥塞控制 / 内核参数调优 / IPv4 优先
# 来源：kejilion.sh（已去除遥测和安全隐患）
# ═══════════════════════════════════════════════════════════════════

# ── DNS 管理（chattr 锁定防覆盖）────────────────────────────────

apply_dns() {
  chattr -i /etc/resolv.conf 2>/dev/null
  > /etc/resolv.conf

  local dns1_ipv4="${1:-1.1.1.1}"
  local dns2_ipv4="${2:-8.8.8.8}"
  local dns1_ipv6="${3:-}"
  local dns2_ipv6="${4:-}"

  echo "nameserver $dns1_ipv4" >> /etc/resolv.conf
  echo "nameserver $dns2_ipv4" >> /etc/resolv.conf
  [[ -n "$dns1_ipv6" ]] && echo "nameserver $dns1_ipv6" >> /etc/resolv.conf
  [[ -n "$dns2_ipv6" ]] && echo "nameserver $dns2_ipv6" >> /etc/resolv.conf

  if [[ ! -s /etc/resolv.conf ]]; then
    echo "nameserver 223.5.5.5" >> /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi

  chattr +i /etc/resolv.conf 2>/dev/null
  log "DNS 已更新"
}

dns_menu() {
  while true; do
    clear
    echo -e "${W}DNS 管理${N}"
    echo "  当前 DNS："
    cat /etc/resolv.conf | sed 's/^/    /'
    echo ""
    echo "  1. 国际 DNS（1.1.1.1 + 8.8.8.8）"
    echo "  2. 国内 DNS（223.5.5.5 + 183.60.83.19）"
    echo "  3. Cloudflare IPv6 + Google IPv6"
    echo "  4. 手动编辑（nano）"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) apply_dns "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" ;;
      2) apply_dns "223.5.5.5" "183.60.83.19" "2400:3200::1" "2400:da00::6666" ;;
      3) apply_dns "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" ;;
      4)
        command -v nano &>/dev/null || apt install -y nano 2>/dev/null
        chattr -i /etc/resolv.conf 2>/dev/null
        nano /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
        ;;
      *) break ;;
    esac
    [[ "$c" != "4" ]] && break_end
  done
}

# ── BBR 拥塞控制 ────────────────────────────────────────────────

enable_bbr() {
  section "BBR 拥塞控制"

  # 检查内核版本
  local kver
  kver=$(uname -r | grep -oP '^\d+\.\d+')
  if ! printf '%s\n%s' "4.9" "$kver" | sort -V -C 2>/dev/null; then
    warn "内核版本 $kver 不支持 BBR（需要 4.9+）"
    return 1
  fi

  # 加载模块
  if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
    modprobe tcp_bbr 2>/dev/null
  fi

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    warn "BBR 不可用"
    return 1
  fi

  # 写入配置
  local CONF="/etc/sysctl.d/99-howe-bbr.conf"
  mkdir -p /etc/sysctl.d
  cat > "$CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

  # 清理旧配置冲突
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null

  sysctl -p "$CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1

  # 持久化模块加载
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null

  local cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  local qdisc=$(sysctl -n net.core.default_qdisc)
  log "BBR 已启用（拥塞算法: $cc, 队列: $qdisc）"
}

# ── IPv4 优先 ────────────────────────────────────────────────────

prefer_ipv4() {
  if ! grep -q 'ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
    echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
    log "已设置 IPv4 优先"
  else
    info "IPv4 优先已设置"
  fi
}

# ── 内核参数调优 ────────────────────────────────────────────────

_get_mem_mb() {
  awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

# 内核调优核心函数
# 参数：$1 = 模式名称, $2 = 场景 (high/balanced/web)
kernel_optimize() {
  local mode_name="${1:-高性能优化}"
  local scene="${2:-high}"
  local CONF="/etc/sysctl.d/99-howe-optimize.conf"
  local MEM_MB
  MEM_MB=$(_get_mem_mb)

  section "$mode_name（${MEM_MB}MB 内存）"

  # 根据场景设定参数
  local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
  local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
  local SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE FIN_TIMEOUT
  local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES

  case "$scene" in
    high|stream|game)
      SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
      RMEM_MAX=67108864; WMEM_MAX=67108864
      TCP_RMEM="4096 262144 67108864"; TCP_WMEM="4096 262144 67108864"
      SOMAXCONN=8192; BACKLOG=250000; SYN_BACKLOG=8192
      PORT_RANGE="1024 65535"; FIN_TIMEOUT=10
      KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
      ;;
    web)
      SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
      RMEM_MAX=33554432; WMEM_MAX=33554432
      TCP_RMEM="4096 131072 33554432"; TCP_WMEM="4096 131072 33554432"
      SOMAXCONN=16384; BACKLOG=10000; SYN_BACKLOG=16384
      PORT_RANGE="1024 65535"; FIN_TIMEOUT=15
      KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
      ;;
    balanced)
      SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
      RMEM_MAX=16777216; WMEM_MAX=16777216
      TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
      SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096
      PORT_RANGE="1024 49151"; FIN_TIMEOUT=30
      KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
      ;;
  esac

  # 内存自适应调整
  if [[ $MEM_MB -ge 16384 ]]; then
    MIN_FREE_KB=131072
    [[ "$scene" != "balanced" ]] && SWAPPINESS=5
  elif [[ $MEM_MB -ge 4096 ]]; then
    MIN_FREE_KB=65536
  elif [[ $MEM_MB -ge 1024 ]]; then
    MIN_FREE_KB=32768
    if [[ "$scene" != "balanced" ]]; then
      RMEM_MAX=16777216; WMEM_MAX=16777216
      TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
    fi
  else
    MIN_FREE_KB=16384; SWAPPINESS=30; OVERCOMMIT=0
    RMEM_MAX=4194304; WMEM_MAX=4194304
    TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
    SOMAXCONN=1024; BACKLOG=1000
  fi

  # BBR 检测
  local CC="bbr" QDISC="fq"
  local KVER
  KVER=$(uname -r | grep -oP '^\d+\.\d+')
  if printf '%s\n%s' "4.9" "$KVER" | sort -V -C 2>/dev/null; then
    modprobe tcp_bbr 2>/dev/null
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr || { CC="cubic"; QDISC="fq_codel"; }
  else
    CC="cubic"; QDISC="fq_codel"
  fi

  # 备份已有配置
  [[ -f "$CONF" ]] && cp "$CONF" "${CONF}.bak.$(date +%s)"

  # 写入配置
  cat > "$CONF" << SYSCTL
# Howe_Linux_sh 内核调优
# 模式: $mode_name | 场景: $scene | 内存: ${MEM_MB}MB

# TCP 拥塞控制
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC

# TCP 缓冲区
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

# 连接队列
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# TCP 连接优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1

# 端口与内存
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $((MEM_MB * 1024 / 8)) $((MEM_MB * 1024 / 4)) $((MEM_MB * 1024 / 2))

# 虚拟内存
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

# 安全防护
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 文件描述符
fs.file-max = 1048576
fs.nr_open = 1048576

# 连接跟踪
$(if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))"
echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
else
echo "# conntrack 未启用"
fi)
SYSCTL

  # 应用配置（逐行，跳过不支持的参数）
  local applied=0 skipped=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if sysctl -w "$line" >/dev/null 2>&1; then
      ((applied++))
    else
      ((skipped++))
    fi
  done < "$CONF"

  # 透明大页面
  [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]] && echo "never" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null

  # 文件描述符限制
  if ! grep -q "# howe-optimize" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf << 'LIMITS'

# howe-optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
  fi

  # BBR 持久化
  if [[ "$CC" == "bbr" ]]; then
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
  fi

  log "已应用 ${applied} 项参数${skipped:+，跳过 ${skipped} 项}"
  log "内存: ${MEM_MB}MB | 拥塞: ${CC} | 队列: ${QDISC}"
}

restore_kernel_defaults() {
  section "还原默认内核设置"
  rm -f /etc/sysctl.d/99-howe-optimize.conf
  rm -f /etc/sysctl.d/99-howe-bbr.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
  sysctl --system >/dev/null 2>&1
  log "已还原默认内核参数"
}

# ── 网络优化主菜单 ───────────────────────────────────────────────
mod_network_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           网络优化                   ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""
    echo "  1. DNS 管理"
    echo "  2. BBR 拥塞控制"
    echo "  3. 内核参数调优"
    echo "  4. IPv4 优先"
    echo "  5. 还原默认内核设置"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) dns_menu; break_end ;;
      2) enable_bbr; break_end ;;
      3) _optimize_menu ;;
      4) prefer_ipv4; break_end ;;
      5) restore_kernel_defaults; break_end ;;
      0|*) break ;;
    esac
  done
}

_optimize_menu() {
  while true; do
    clear
    echo -e "${W}内核参数调优${N}"
    echo "  1. 高性能模式"
    echo "  2. 均衡模式"
    echo "  3. 网站服务器模式"
    echo "  ─────────────────"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) kernel_optimize "高性能模式" "high"; break_end ;;
      2) kernel_optimize "均衡模式" "balanced"; break_end ;;
      3) kernel_optimize "网站服务器模式" "web"; break_end ;;
      0|*) break ;;
    esac
  done
}
