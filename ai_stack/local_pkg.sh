#!/usr/bin/env bash
# 生成本地机器（Linux / Windows）安装包
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 生成本地机器安装包
# ═══════════════════════════════════════════════════════════════════
generate_local_package() {
  [[ "$DEPLOY_MODE" != "distributed" ]] && return 0
  step "生成本地机器安装包"

  local _out="$LOCAL_PKG_DIR"
  rm -rf "$_out" && mkdir -p "$_out/data" "$_out/config" "$_out/sub2api"

  # OpenWebUI → New-API 连接地址
  local _na_url
  [[ -n "$DOMAIN" ]] && _na_url="https://${PREFIX_NEWAPI}.${DOMAIN}/v1" \
                     || _na_url="http://${VPS_IP}:13000/v1"

  # ── docker-compose.yml ──────────────────────────────────────────
  cat > "$_out/docker-compose.yml" <<DHEAD
# AI Stack 本地 docker-compose（分布式模式）
# 生成时间：$(date -u '+%Y-%m-%d %H:%M UTC')
# 启动：docker compose up -d
services:
DHEAD

  if $INST_WEBUI && [[ "$LOC_WEBUI" == "local" ]]; then
    cat >> "$_out/docker-compose.yml" <<SVC

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    restart: unless-stopped
    volumes:
      - ./data/openwebui:/app/backend/data
    environment:
      OPENAI_API_BASE_URLS: "${_na_url}"
      OPENAI_API_KEY: "${NEWAPI_TOKEN}"
      WEBUI_SECRET_KEY: "${NEWAPI_TOKEN}"
    ports:
      - "127.0.0.1:13010:8080"
SVC
  fi

  if $INST_LITELLM && [[ "$LOC_LITELLM" == "local" ]]; then
    cat >> "$_out/docker-compose.yml" <<SVC

  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    volumes:
      - ./config/litellm.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "4"]
    environment:
      LITELLM_MASTER_KEY: "${LITELLM_KEY}"
      # OPENAI_API_KEY: "sk-..."
      # ANTHROPIC_API_KEY: "sk-ant-..."
    ports:
      - "127.0.0.1:14000:4000"
SVC
  fi

  if $INST_SUB2API && [[ "$LOC_SUB2API" == "local" ]]; then
    local _s2a_pg_pass; _s2a_pg_pass=$(openssl rand -hex 12)
    local _s2a_jwt; _s2a_jwt=$(openssl rand -hex 32)
    # Sub2API config.yaml
    cat > "$_out/sub2api/config.yaml" <<S2ACFG
server:
  host: "0.0.0.0"
  port: 8080
  mode: "release"

database:
  host: "ai-db"
  port: 5432
  user: "ai"
  password: "${_s2a_pg_pass}"
  dbname: "sub2api"
  sslmode: "disable"

jwt:
  secret: "${_s2a_jwt}"
  expire_hour: 24

redis:
  addr: "ai-redis:6379"
  password: ""
  db: 0
S2ACFG
    cat >> "$_out/docker-compose.yml" <<SVC

  ai-db:
    image: postgres:16-alpine
    container_name: ai-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ai
      POSTGRES_PASSWORD: ${_s2a_pg_pass}
      POSTGRES_DB: sub2api
    volumes:
      - ./data/ai-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ai"]
      interval: 10s
      retries: 5

  ai-redis:
    image: redis:7-alpine
    container_name: ai-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./data/ai-redis:/data

  sub2api:
    image: xidahuang/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    depends_on:
      ai-db:
        condition: service_healthy
      ai-redis:
        condition: service_started
    environment:
      TZ: Asia/Shanghai
    volumes:
      - ./data/sub2api:/app/data
      - ./sub2api/config.yaml:/app/config.yaml:ro
    ports:
      - "127.0.0.1:13001:8080"
SVC
  fi

  printf '\nnetworks:\n  default:\n    driver: bridge\n' >> "$_out/docker-compose.yml"

  # LiteLLM 本地配置
  if $INST_LITELLM && [[ "$LOC_LITELLM" == "local" ]]; then
    cat > "$_out/config/litellm.yaml" <<'EOF'
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
router_settings:
  routing_strategy: least-busy
  num_retries: 3
  timeout: 120
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
litellm_settings:
  drop_params: true
EOF
  fi

  # ── frpc.toml ────────────────────────────────────────────────────
  cat > "$_out/frpc.toml" <<EOF
# frp 客户端配置 — 连接 VPS frps，将本地服务透传到 VPS
serverAddr = "${VPS_IP}"
serverPort = ${FRP_PORT}
[auth]
method = "token"
token = "${FRP_TOKEN}"
[log]
to = "frpc.log"
level = "info"
EOF

  local _has_proxy=false
  _add_proxy() {
    local _n=$1 _lp=$2 _rp=$3; _has_proxy=true
    printf '\n[[proxies]]\nname = "%s"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' \
           "$_n" "$_lp" "$_rp" >> "$_out/frpc.toml"
  }
  $INST_WEBUI   && [[ "$LOC_WEBUI"   == "local" ]] && _add_proxy "openwebui" 13010 13010
  $INST_LITELLM && [[ "$LOC_LITELLM" == "local" ]] && _add_proxy "litellm"   14000 14000
  $INST_SUB2API && [[ "$LOC_SUB2API" == "local" ]] && _add_proxy "sub2api"   13001 13001
  $INST_DIFY    && [[ "$LOC_DIFY"    == "local" ]] && _add_proxy "dify"      13080 13080
  ! $_has_proxy && warn "没有本地服务，frpc.toml 无穿透条目"

  # ── Linux 安装脚本 ────────────────────────────────────────────────
  local _frp_ver="0.61.0"
  cat > "$_out/install-local.sh" <<LSCRIPT
#!/usr/bin/env bash
# AI Stack 本地安装（Linux）— 由 VPS 自动生成
set -euo pipefail
G='\033[0;32m' Y='\033[1;33m' N='\033[0m'
log()  { echo -e "\${G}[✓]\${N} \$*"; }
warn() { echo -e "\${Y}[!]\${N} \$*"; }
DIR=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)

# Docker
if ! command -v docker &>/dev/null; then
  log "安装 Docker..."
  curl -fsSL https://get.docker.com | bash
fi
if ! docker compose version &>/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin 2>/dev/null || \
  yum install -y docker-compose-plugin 2>/dev/null || true
fi
systemctl enable --now docker 2>/dev/null || true
log "Docker 就绪"

# frpc
FRP_VER="${_frp_ver}"
ARCH=\$(uname -m)
[[ "\${ARCH}" == "x86_64"  ]] && ARCH="amd64"
[[ "\${ARCH}" == "aarch64" ]] && ARCH="arm64"
TB="frp_\${FRP_VER}_linux_\${ARCH}.tar.gz"
log "下载 frpc v\${FRP_VER}..."
wget -qO /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v\${FRP_VER}/\${TB}"
tar -xzf /tmp/frp.tar.gz -C /tmp/
install -m 755 "/tmp/frp_\${FRP_VER}_linux_\${ARCH}/frpc" /usr/local/bin/frpc
rm -rf /tmp/frp.tar.gz "/tmp/frp_\${FRP_VER}_linux_\${ARCH}"
log "frpc 已安装"

cat > /etc/systemd/system/frpc-aistack.service <<UNIT
[Unit]
Description=frp 客户端（AI Stack 穿透）
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=\${DIR}
ExecStart=/usr/local/bin/frpc -c \${DIR}/frpc.toml
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now frpc-aistack
log "frpc 已启动，隧道建立至 ${VPS_IP}:${FRP_PORT}"

cd "\${DIR}"
log "拉取并启动本地 Docker 服务..."
docker compose pull -q
docker compose up -d
docker compose ps
log "完成！本地服务已通过 frp 隧道接入 VPS"
LSCRIPT
  chmod +x "$_out/install-local.sh"

  # ── Windows 脚本 ─────────────────────────────────────────────────
  if [[ "$LOCAL_OS" == "windows" ]]; then
    cat > "$_out/start.bat" <<'BAT'
@echo off
chcp 65001 >nul
echo [AI Stack] 启动 Docker 服务...
docker compose up -d
if not exist frpc.exe (
  echo [错误] 未找到 frpc.exe
  echo 请从 https://github.com/fatedier/frp/releases 下载 windows_amd64 版本，解压 frpc.exe 至本目录
  pause & exit /b 1
)
echo [AI Stack] 启动 frp 客户端...
start "" /B frpc.exe -c frpc.toml
echo [AI Stack] 完成！
pause
BAT
    cat > "$_out/stop.bat" <<'BAT'
@echo off
chcp 65001 >nul
docker compose down
taskkill /IM frpc.exe /F 2>nul
echo [AI Stack] 已停止
pause
BAT
  fi

  # ── README.md ─────────────────────────────────────────────────────
  local _svc_list=""
  $INST_WEBUI   && [[ "$LOC_WEBUI"   == "local" ]] && _svc_list+="- OpenWebUI  本地 :13010 → VPS :13010\n"
  $INST_LITELLM && [[ "$LOC_LITELLM" == "local" ]] && _svc_list+="- LiteLLM   本地 :14000 → VPS :14000\n"
  $INST_SUB2API && [[ "$LOC_SUB2API" == "local" ]] && _svc_list+="- Sub2API   本地 :13001 → VPS :13001\n"
  $INST_DIFY    && [[ "$LOC_DIFY"    == "local" ]] && _svc_list+="- Dify      本地 :13080 → VPS :13080（需单独 git clone）\n"

  cat > "$_out/README.md" <<EOF
# AI Stack 本地安装包（分布式模式）

## 架构
\`\`\`
用户浏览器 → VPS:443 Caddy (HTTPS)
                  ↑ frp TCP 隧道
              本地台式机 Docker 服务
\`\`\`

## 本地服务列表
$(printf '%b' "${_svc_list:-无}")

## 关键参数
| 参数           | 值                        |
|----------------|---------------------------|
| VPS IP         | ${VPS_IP}                |
| frp 端口       | ${FRP_PORT}              |
| frp Token      | ${FRP_TOKEN}             |
| New-API 地址   | ${_na_url}               |

## Linux 一键安装
\`\`\`bash
# 在 VPS 上将安装包传到本地机器
scp -r root@${VPS_IP}:${LOCAL_PKG_DIR} ~/ai-stack-local/
# 在本地机器执行
cd ~/ai-stack-local/ && sudo bash install-local.sh
\`\`\`

## Windows 安装
1. 安装 [Docker Desktop](https://www.docker.com/products/docker-desktop/)
2. 从 [frp Releases](https://github.com/fatedier/frp/releases) 下载 \`frp_*_windows_amd64.zip\`，解压 frpc.exe 到本目录
3. 双击 start.bat

## Dify 本地安装（如已选择）
\`\`\`bash
git clone --depth=1 https://github.com/langgenius/dify ~/dify
cd ~/dify/docker && cp .env.example .env
sed -i 's/^EXPOSE_NGINX_PORT=.*/EXPOSE_NGINX_PORT=13080/' .env
docker compose up -d
\`\`\`

## 排障
\`\`\`bash
# VPS
journalctl -u frps -f
# 本地 Linux
journalctl -u frpc-aistack -f
tail -f frpc.log
# 本地 Docker
docker compose ps
docker compose logs -f
\`\`\`
EOF

  log "本地安装包 → ${_out}/"
  ls -1 "$_out/" | sed 's/^/    /'
  echo ""
  echo -e "  ${W}本地机器执行以下命令完成安装：${N}"
  echo -e "    ${C}scp -r root@${VPS_IP}:${_out} ~/ai-stack-local/${N}"
  echo -e "    ${C}cd ~/ai-stack-local/ && sudo bash install-local.sh${N}"
}

