#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — 系统检测（发行版 / IP / 资源）
# ═══════════════════════════════════════════════════════════════════

# ── 资源检测 ──────────────────────────────────────────────────────
SYS_CPU=1
SYS_MEM_MB=1024
SYS_MEM_GB="1.0"
SYS_DISK_GB=20

detect_resources() {
  SYS_CPU=$(nproc 2>/dev/null || echo 1)
  SYS_MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
  SYS_MEM_GB=$(awk 'BEGIN{printf "%.1f", '"$SYS_MEM_MB"'/1024}')
  SYS_DISK_GB=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo 20)
}

# ── 发行版检测 ────────────────────────────────────────────────────
DISTRO_ID=""        # ubuntu, debian, centos, alpine, arch, fedora ...
DISTRO_FAMILY=""    # debian, rhel, alpine, arch, suse
DISTRO_PRETTY=""    # Ubuntu 22.04.3 LTS
PKG_MGR=""          # apt, dnf, yum, apk, pacman, zypper

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    DISTRO_ID=$(. /etc/os-release && echo "${ID:-unknown}")
    DISTRO_PRETTY=$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")
  elif [[ -f /etc/issue ]]; then
    DISTRO_PRETTY=$(head -1 /etc/issue | sed 's/\\.*//')
    DISTRO_ID="unknown"
  else
    DISTRO_ID="unknown"
    DISTRO_PRETTY="未知系统"
  fi

  # 发行版家族
  case "$DISTRO_ID" in
    ubuntu|debian|linuxmint|pop|raspbian) DISTRO_FAMILY="debian" ;;
    centos|rhel|fedora|rocky|alma|ol)     DISTRO_FAMILY="rhel" ;;
    alpine)                                DISTRO_FAMILY="alpine" ;;
    arch|manjaro|endeavouros)              DISTRO_FAMILY="arch" ;;
    opensuse*|sles)                        DISTRO_FAMILY="suse" ;;
    *)                                     DISTRO_FAMILY="unknown" ;;
  esac

  # 包管理器
  if command -v apt &>/dev/null; then PKG_MGR="apt"
  elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
  elif command -v yum &>/dev/null; then PKG_MGR="yum"
  elif command -v apk &>/dev/null; then PKG_MGR="apk"
  elif command -v pacman &>/dev/null; then PKG_MGR="pacman"
  elif command -v zypper &>/dev/null; then PKG_MGR="zypper"
  else PKG_MGR=""
  fi
}

# ── IP 地址检测 ───────────────────────────────────────────────────
PUBLIC_IP=""
LOCAL_IP=""
IPV6_ADDRESS=""
ISP_INFO=""

detect_ip() {
  PUBLIC_IP=$(curl -s --max-time 5 "${URL_IPINFO}/ip" 2>/dev/null || echo "")
  LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || \
             hostname -I 2>/dev/null | awk '{print $1}' || echo "")
  IPV6_ADDRESS=$(curl -s --max-time 3 "${URL_IPINFO_V6}/ip" 2>/dev/null || echo "")
  ISP_INFO=$(curl -s --max-time 3 "${URL_IPINFO}/org" 2>/dev/null || echo "")
}

# ── 网络连通性检测 ────────────────────────────────────────────────
VPS_IP=""

check_network() {
  if ! curl -s --max-time 5 -o /dev/null "${URL_GITHUB_CONNECTIVITY}"; then
    warn "网络连通性检测失败，可能无法访问 GitHub"
    return 1
  fi
  VPS_IP=$(curl -s --max-time 5 "${URL_IPINFO}/ip" 2>/dev/null || echo "未知")
  return 0
}

# ── 获取网络流量 ──────────────────────────────────────────────────
NET_RX=""
NET_TX=""

get_network_traffic() {
  local output
  output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
    $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
      rx_total += $2
      tx_total += $10
    }
    END {
      rx_units = "Bytes"; tx_units = "Bytes";
      if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
      if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
      if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }
      if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
      if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
      if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }
      printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
    }' /proc/net/dev)
  NET_RX=$(echo "$output" | awk '{print $1}')
  NET_TX=$(echo "$output" | awk '{print $2}')
}

# ── 完整预检 ─────────────────────────────────────────────────────
preflight() {
  # Root 检查
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此脚本"
  fi

  detect_distro
  detect_resources
  detect_ip
  check_network || true

  log "系统：${DISTRO_PRETTY}"
  log "硬件：${SYS_CPU}核 CPU | ${SYS_MEM_MB}MB RAM | ${SYS_DISK_GB}GB 磁盘"
  [[ -n "$VPS_IP" ]] && log "公网 IP：${VPS_IP}"
}
