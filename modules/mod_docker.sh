#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# Howe_Linux_sh — Docker 管理模块
#
# 功能：容器管理 / 镜像管理 / 网络管理 / IPv6 开关
# 来源：kejilion.sh（已去除遥测和安全隐患）
# ═══════════════════════════════════════════════════════════════════

# ── Docker 安装检查 ──────────────────────────────────────────────

_DOCKER_SCRIPTS="${BASH_SOURCE[0]%/*}/../lib/scripts"

ensure_docker() {
  if command -v docker &>/dev/null; then
    return 0
  fi

  warn "Docker 未安装"
  local install_yn
  askyn install_yn "是否安装 Docker？" "y"
  $install_yn || return 1

  if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    # 使用本地 linuxmirrors 镜像加速脚本
    bash "${_DOCKER_SCRIPTS}/docker-mirror.sh" \
      --source download.docker.com \
      --source-registry registry.hub.docker.com \
      --protocol https \
      --use-intranet-source false \
      --install-latest true \
      --close-firewall false \
      --ignore-backup-tips || {
      # 回退到本地官方脚本
      bash "${_DOCKER_SCRIPTS}/docker-official.sh"
    }
  else
    bash "${_DOCKER_SCRIPTS}/docker-official.sh"
  fi

  systemctl enable docker
  systemctl start docker
  log "Docker 安装完成"
}

# ── 容器管理 ─────────────────────────────────────────────────────

docker_container_menu() {
  ensure_docker || return 1

  while true; do
    clear
    echo -e "${W}Docker 容器管理${N}"
    echo "  ─────────────────────────────────────────────"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
    echo "  ─────────────────────────────────────────────"
    echo ""
    echo "  1. 启动容器              5. 启动所有容器"
    echo "  2. 停止容器              6. 停止所有容器"
    echo "  3. 重启容器              7. 删除所有容器"
    echo "  4. 删除容器              8. 重启所有容器"
    echo "  ─────────────────"
    echo "  11. 进入容器             12. 查看容器日志"
    echo "  13. 查看容器网络         14. 查看资源占用"
    echo "  ─────────────────"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) local n; read -erp "容器名：" n; docker start $n ;;
      2) local n; read -erp "容器名：" n; docker stop $n ;;
      3) local n; read -erp "容器名：" n; docker restart $n ;;
      4) local n; read -erp "容器名：" n; docker rm -f $n ;;
      5) docker start $(docker ps -a -q) ;;
      6) docker stop $(docker ps -q) ;;
      7)
        local yn; askyn yn "确定删除所有容器？" "n"
        $yn && docker rm -f $(docker ps -a -q)
        ;;
      8) docker restart $(docker ps -q) ;;
      11)
        local n; read -erp "容器名：" n
        docker exec -it "$n" /bin/sh
        break_end
        ;;
      12)
        local n; read -erp "容器名：" n
        docker logs "$n"
        break_end
        ;;
      13) _show_container_networks; break_end ;;
      14) docker stats --no-stream; break_end ;;
      0|*) break ;;
    esac
  done
}

_show_container_networks() {
  local container_ids
  container_ids=$(docker ps -q)
  [[ -z "$container_ids" ]] && { info "没有运行中的容器"; return; }

  echo ""
  printf "  ${W}%-25s %-20s %-18s${N}\n" "容器名称" "网络名称" "IP 地址"
  echo "  ─────────────────────────────────────────────────────────────"
  for cid in $container_ids; do
    local info
    info=$(docker inspect --format '{{ .Name }}{{ range $net, $cfg := .NetworkSettings.Networks }} {{ $net }} {{ $cfg.IPAddress }}{{ end }}' "$cid")
    local name=$(echo "$info" | awk '{print $1}')
    local net_info=$(echo "$info" | cut -d' ' -f2-)
    while IFS= read -r line; do
      local net_name=$(echo "$line" | awk '{print $1}')
      local ip=$(echo "$line" | awk '{print $2}')
      printf "  %-25s %-20s %-18s\n" "$name" "$net_name" "$ip"
    done <<< "$net_info"
  done
}

# ── 镜像管理 ─────────────────────────────────────────────────────

docker_image_menu() {
  ensure_docker || return 1

  while true; do
    clear
    echo -e "${W}Docker 镜像管理${N}"
    echo "  ─────────────────────────────────────────────"
    docker image ls 2>/dev/null
    echo "  ─────────────────────────────────────────────"
    echo ""
    echo "  1. 拉取镜像"
    echo "  2. 删除指定镜像"
    echo "  3. 删除所有未使用镜像"
    echo "  ─────────────────"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) local n; read -erp "镜像名：" n; docker pull "$n" ;;
      2) local n; read -erp "镜像名：" n; docker rmi -f "$n" ;;
      3)
        local yn; askyn yn "删除所有未使用的镜像？" "n"
        $yn && docker image prune -a -f
        ;;
      0|*) break ;;
    esac
    break_end
  done
}

# ── 网络管理 ─────────────────────────────────────────────────────

docker_network_menu() {
  while true; do
    clear
    echo -e "${W}Docker 网络管理${N}"
    echo "  ─────────────────────────────────────────────"
    docker network ls 2>/dev/null
    echo "  ─────────────────────────────────────────────"
    echo ""
    echo "  1. 查看网络详情"
    echo "  2. 删除指定网络"
    echo "  3. 清理未使用网络"
    echo "  ─────────────────"
    echo "  0. 返回"
    echo ""
    local c; read -erp "  选择：" c
    case "$c" in
      1) local n; read -erp "网络名：" n; docker network inspect "$n" | jq '.' 2>/dev/null || docker network inspect "$n"; break_end ;;
      2) local n; read -erp "网络名：" n; docker network rm "$n" ;;
      3) docker network prune -f ;;
      0|*) break ;;
    esac
    break_end
  done
}

# ── IPv6 开关 ────────────────────────────────────────────────────

docker_ipv6_toggle() {
  local daemon_json="/etc/docker/daemon.json"
  local current="disabled"

  if [[ -f "$daemon_json" ]] && grep -q '"ipv6"' "$daemon_json" 2>/dev/null; then
    if grep -q '"ipv6": true' "$daemon_json" 2>/dev/null || grep -q '"ipv6":true' "$daemon_json" 2>/dev/null; then
      current="enabled"
    fi
  fi

  echo -e "  Docker IPv6：${W}${current}${N}"
  local yn
  if [[ "$current" == "enabled" ]]; then
    askyn yn "是否关闭 IPv6？" "y"
  else
    askyn yn "是否开启 IPv6？" "y"
  fi

  if $yn; then
    if [[ "$current" == "enabled" ]]; then
      # 关闭
      if command -v jq &>/dev/null && [[ -f "$daemon_json" ]]; then
        jq '.ipv6 = false' "$daemon_json" > "${daemon_json}.tmp" && mv "${daemon_json}.tmp" "$daemon_json"
      else
        # 简单 sed
        sed -i 's/"ipv6": true/"ipv6": false/g' "$daemon_json" 2>/dev/null
      fi
      log "IPv6 已关闭"
    else
      # 开启
      if [[ ! -f "$daemon_json" ]]; then
        echo '{"ipv6": true, "fixed-cidr-v6": "fd00::/80"}' > "$daemon_json"
      elif command -v jq &>/dev/null; then
        jq '.ipv6 = true | .["fixed-cidr-v6"] //= "fd00::/80"' "$daemon_json" > "${daemon_json}.tmp" && mv "${daemon_json}.tmp" "$daemon_json"
      else
        # 如果文件存在但没有 ipv6 字段
        if ! grep -q '"ipv6"' "$daemon_json"; then
          sed -i 's/^{/{\n  "ipv6": true,\n  "fixed-cidr-v6": "fd00::\/80",/' "$daemon_json" 2>/dev/null
        else
          sed -i 's/"ipv6": false/"ipv6": true/g' "$daemon_json" 2>/dev/null
        fi
      fi
      log "IPv6 已开启"
    fi

    local yn2; askyn yn2 "需要重启 Docker 生效，是否现在重启？" "y"
    $yn2 && systemctl restart docker
  fi
}

# ── Docker 管理主菜单 ────────────────────────────────────────────
mod_docker_main() {
  while true; do
    clear
    echo -e "${W}${C}╔══════════════════════════════════════╗${N}"
    echo -e "${W}${C}║           Docker 管理                ║${N}"
    echo -e "${W}${C}╚══════════════════════════════════════╝${N}"
    echo ""

    # 显示 Docker 状态
    if command -v docker &>/dev/null; then
      local ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
      local running=$(docker ps -q 2>/dev/null | wc -l)
      local total=$(docker ps -a -q 2>/dev/null | wc -l)
      echo -e "  Docker ${G}v${ver}${N}  运行中: ${G}${running}${N}  总计: ${total}"
    else
      echo -e "  Docker ${R}未安装${N}"
    fi

    echo ""
    echo "  1. 容器管理"
    echo "  2. 镜像管理"
    echo "  3. 网络管理"
    echo "  4. IPv6 开关"
    echo "  ─────────────────"
    echo "  0. 返回主菜单"
    echo ""
    local choice
    read -erp "  请输入选择：" choice

    case "$choice" in
      1) docker_container_menu ;;
      2) docker_image_menu ;;
      3) docker_network_menu ;;
      4) docker_ipv6_toggle; break_end ;;
      0|*) break ;;
    esac
  done
}
