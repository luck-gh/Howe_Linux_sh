#!/usr/bin/env bash
# write_env + write_compose + write_litellm_config
# 由 ai_stack/ai-stack-setup.sh 统一 source；不可独立运行。

# ═══════════════════════════════════════════════════════════════════
# 写入配置文件（含所有变量，chmod 600）
# ═══════════════════════════════════════════════════════════════════
write_env() {
  step "写入配置"
  [[ -f "$BASE_DIR/.env" ]] && warn "已有 .env，覆盖更新"
  cat > "$BASE_DIR/.env" <<EOF
# ═══════════════════════════════════════════════════════════════════
# AI Stack 配置文件 — $(date -u '+%Y-%m-%d %H:%M UTC')
# 由 ai-stack-setup.sh 自动生成，请谨慎手动修改
# ═══════════════════════════════════════════════════════════════════

# ── 部署模式 ────────────────────────────────────────────────────
# 部署架构：allinone=所有服务在 VPS | distributed=分布式（重服务放本地）
DEPLOY_MODE=${DEPLOY_MODE}
# 本地机器系统（仅 distributed 模式）：linux | windows
LOCAL_OS=${LOCAL_OS}
# VPS 公网 IP（自动探测，用于本地连接 / Clash 节点）
VPS_IP=${VPS_IP}

# ── 域名与 HTTPS ────────────────────────────────────────────────
# 主域名（如 example.com），留空则用 IP+HTTP 测试模式
DOMAIN=${DOMAIN}
# Let's Encrypt 邮箱（Caddy 申请证书时通知使用）
EMAIL=${EMAIL}

# ── 服务安装开关 ────────────────────────────────────────────────
# New-API：API Key 管理 + 多渠道路由（OpenWebUI 依赖）
INST_NEWAPI=${INST_NEWAPI}
# OpenWebUI：自托管 AI 对话界面（依赖 New-API）
INST_WEBUI=${INST_WEBUI}
# LiteLLM：多 Provider 负载均衡网关
INST_LITELLM=${INST_LITELLM}
# Sub2API：将订阅包装成 OpenAI 兼容 API
INST_SUB2API=${INST_SUB2API}
# Dify：LLM 工作流 / Agent / RAG 平台
INST_DIFY=${INST_DIFY}
# sing-box：AnyTLS 代理服务（供 Clash / Mihomo 使用）
INST_SINGBOX=${INST_SINGBOX}
# Caddy：HTTPS 反向代理 + 自动 Let's Encrypt 证书
INST_CADDY=${INST_CADDY}
# PostgreSQL：数据库（Sub2API / New-API 自动依赖）
INST_PGSQL=${INST_PGSQL}
# Redis：缓存（Sub2API 自动依赖）
INST_REDIS=${INST_REDIS}

# ── 服务密钥 / Token ────────────────────────────────────────────
# New-API 会话密钥（SESSION_SECRET），保护 Web 登录会话
NEWAPI_TOKEN=${NEWAPI_TOKEN}
# LiteLLM 主密钥（API 调用鉴权，sk- 前缀）
LITELLM_KEY=${LITELLM_KEY}
# Dify 后端密钥（用于加密敏感数据）
DIFY_SECRET=${DIFY_SECRET}

# ── sing-box AnyTLS 代理（多订阅，每订阅独立端口）────────────────
# 端口分配段（每条订阅占用其中一个，由 clash_subs.py 自动分配）
CLASH_PORT_MIN=${CLASH_PORT_MIN:-13443}
CLASH_PORT_MAX=${CLASH_PORT_MAX:-13458}

# ── frp 内网穿透（仅 distributed 模式）─────────────────────────
# frps 服务端监听端口（VPS 端，frpc 客户端连此端口）
FRP_PORT=${FRP_PORT}
# frp 认证 Token（VPS / 本地共用，泄露需重置）
FRP_TOKEN=${FRP_TOKEN}

# ── 服务运行位置（仅 distributed 模式）─────────────────────────
# OpenWebUI 部署位置：vps | local
LOC_WEBUI=${LOC_WEBUI}
# LiteLLM 部署位置：vps | local
LOC_LITELLM=${LOC_LITELLM}
# Sub2API 部署位置：vps | local
LOC_SUB2API=${LOC_SUB2API}
# Dify 部署位置：vps | local
LOC_DIFY=${LOC_DIFY}
EOF
  chmod 600 "$BASE_DIR/.env"
  log "密钥文件 → $BASE_DIR/.env"
}

# ═══════════════════════════════════════════════════════════════════
# 生成 VPS docker-compose.yml（跳过本地服务）
# ═══════════════════════════════════════════════════════════════════
write_compose() {
  step "生成 VPS docker-compose"
  if ! has_vps_compose_service; then
    # 安全闸：当前若有非空 compose（说明已有正在跑的服务），不要覆盖。
    # 防止用户在"安装 / 更新"里误把所有服务取消勾选导致 compose 被清空。
    if [[ -s "$BASE_DIR/docker-compose.yml" ]] && \
       grep -q '^  [a-z][a-zA-Z0-9_-]*:[[:space:]]*$' "$BASE_DIR/docker-compose.yml"; then
      local _bak="$BASE_DIR/docker-compose.yml.bak.$(date +%s)"
      cp "$BASE_DIR/docker-compose.yml" "$_bak"
      warn "未选择任何 VPS 服务，但已有 compose 文件，保留并备份至 ${_bak}"
      info "如确实要清空，请先卸载相关服务，或手动删除 docker-compose.yml"
      return 0
    fi
    cat > "$BASE_DIR/docker-compose.yml" <<'EOF'
# AI Stack VPS docker-compose.yml
# 本次未选择需要在 VPS 侧运行的 Docker 服务。
services: {}
EOF
    log "未选择 VPS Docker 服务，生成空 compose"
    return 0
  fi

  # 有 Caddy 反代时绑定 127.0.0.1，否则绑定 0.0.0.0 让服务可直连
  local _BIND="127.0.0.1"
  $INST_CADDY || _BIND="0.0.0.0"

  cat > "$BASE_DIR/docker-compose.yml" <<'HEADER'
# AI Stack VPS docker-compose.yml
# 端口均绑定 127.0.0.1；分布式下 frp 隧道为 Caddy 提供远程端口
services:

HEADER

  # ── 共享 PostgreSQL（Sub2API + New-API 共用）──────────────────
  local _pg_pass=""
  local _need_pg=false
  $INST_SUB2API && [[ "$LOC_SUB2API" == "vps" ]] && _need_pg=true
  $INST_NEWAPI  && _need_pg=true

  if $_need_pg; then
    _pg_pass=$(openssl rand -hex 12)
    mkdir -p "$BASE_DIR/ai-db"
    cat > "$BASE_DIR/ai-db/init-multi-db.sh" <<'INITDB'
#!/bin/bash
set -e
for db in $EXTRA_DBS; do
  echo "  Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "SELECT 1 FROM pg_database WHERE datname = '$db'" -t | grep -q 1 || \
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "CREATE DATABASE \"$db\";"
done
INITDB
    chmod +x "$BASE_DIR/ai-db/init-multi-db.sh"
    cat >> "$BASE_DIR/docker-compose.yml" <<SVC

  ai-db:
    image: postgres:16-alpine
    container_name: ai-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ai
      POSTGRES_PASSWORD: ${_pg_pass}
      POSTGRES_DB: sub2api
      EXTRA_DBS: "newapi"
    volumes:
      - ./ai-db/data:/var/lib/postgresql/data
      - ./ai-db/init-multi-db.sh:/docker-entrypoint-initdb.d/init-multi-db.sh:ro
    networks: [ai-stack]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ai"]
      interval: 10s
      retries: 5
SVC
    echo "AI_DB_PASS=${_pg_pass}" >> "$BASE_DIR/.env"
  fi

  # ── Redis（Sub2API 依赖）────────────────────────────────────
  local _need_redis=false
  $INST_SUB2API && [[ "${LOC_SUB2API:-vps}" == "vps" ]] && _need_redis=true

  if $_need_redis; then
    cat >> "$BASE_DIR/docker-compose.yml" <<'SVC'

  ai-redis:
    image: redis:7-alpine
    container_name: ai-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./ai-redis/data:/data
    networks: [ai-stack]
SVC
  fi

  # ── New-API ─────────────────────────────────────────────────
  if $INST_NEWAPI; then
    cat >> "$BASE_DIR/docker-compose.yml" <<SVC

  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: unless-stopped
    depends_on:
      ai-db:
        condition: service_healthy
    volumes:
      - ./new-api/data:/data
    environment:
      SESSION_SECRET: "\${NEWAPI_TOKEN}"
      TZ: Asia/Shanghai
      SQL_DSN: "postgres://ai:${_pg_pass}@ai-db:5432/newapi"
    ports:
      - "\${_BIND_PLACEHOLDER}:13000:3000"
    networks: [ai-stack]
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/status"]
      interval: 30s
      retries: 3
SVC
  fi

  if $INST_WEBUI && [[ "$LOC_WEBUI" == "vps" ]]; then
    cat >> "$BASE_DIR/docker-compose.yml" <<'SVC'

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    restart: unless-stopped
    volumes:
      - ./openwebui/data:/app/backend/data
    environment:
      OPENAI_API_BASE_URLS: "http://new-api:3000/v1"
      OPENAI_API_KEY: "${NEWAPI_TOKEN}"
      WEBUI_SECRET_KEY: "${NEWAPI_TOKEN}"
    ports:
      - "${_BIND_PLACEHOLDER}:13010:8080"
    networks: [ai-stack]
    depends_on: [new-api]
SVC
  fi

  if $INST_LITELLM && [[ "$LOC_LITELLM" == "vps" ]]; then
    cat >> "$BASE_DIR/docker-compose.yml" <<'SVC'

  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    volumes:
      - ./litellm/config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "2"]
    environment:
      LITELLM_MASTER_KEY: "${LITELLM_KEY}"
      # OPENAI_API_KEY: "sk-..."
      # ANTHROPIC_API_KEY: "sk-ant-..."
    ports:
      - "127.0.0.1:14000:4000"
    networks: [ai-stack]
SVC
  fi

  if $INST_SUB2API && [[ "$LOC_SUB2API" == "vps" ]]; then
    # Sub2API：端口由脚本完全掌控
    # 注意：sub2api 启动时会把"运行时配置"持久化到 /app/data/config.yaml，并以
    # 该文件为准（优先级高于挂载的 /app/config.yaml）。一旦该文件存在，sub2api
    # 不会再用内置默认值（port=443）覆盖。我们因此采取三道闸门：
    #   1. 预置 data/config.yaml，避免 first-run 写出 port=443
    #   2. 若已存在（重装/升级），仅回写 server.host/port，保留 jwt/库连接
    #   3. 通过 SERVER_PORT 环境变量兜底（健康检查也读它）
    mkdir -p "$BASE_DIR/sub2api/data"
    local _s2a_port=8080
    local _s2a_data_cfg="$BASE_DIR/sub2api/data/config.yaml"
    local _s2a_jwt _s2a_totp
    if [[ -f "$_s2a_data_cfg" ]]; then
      # 复用既有 secret，避免使旧会话失效
      _s2a_jwt=$(awk '/^jwt:/{f=1;next} f && /secret:/{gsub(/[ \t"'"'"']/,"",$2);print $2;exit}' "$_s2a_data_cfg")
      [[ -z "$_s2a_jwt" ]] && _s2a_jwt=$(openssl rand -hex 32)
    else
      _s2a_jwt=$(openssl rand -hex 32)
    fi
    _s2a_totp=$(openssl rand -hex 32)

    # 写入持久化运行时配置（first-run 不会再用 port=443 覆盖）
    cat > "$_s2a_data_cfg" <<S2ADATA
server:
    host: 0.0.0.0
    port: ${_s2a_port}
    mode: release
database:
    host: ai-db
    port: 5432
    user: ai
    password: ${_pg_pass}
    dbname: sub2api
    sslmode: disable
redis:
    host: ai-redis
    port: 6379
    password: ""
    db: 0
    enable_tls: false
jwt:
    secret: ${_s2a_jwt}
    expire_hour: 24
default:
    user_concurrency: 5
    user_balance: 0
    api_key_prefix: sk-
    rate_multiplier: 1
rate_limit:
    requests_per_minute: 60
    burst_size: 10
timezone: Asia/Shanghai
S2ADATA
    chmod 0644 "$_s2a_data_cfg"

    # 同时保留挂载到 /app/config.yaml 的旧版配置（兼容场景使用）
    cat > "$BASE_DIR/sub2api/config.yaml" <<S2ACFG
server:
  host: "0.0.0.0"
  port: ${_s2a_port}
  mode: "release"

database:
  host: "ai-db"
  port: 5432
  user: "ai"
  password: "${_pg_pass}"
  dbname: "sub2api"
  sslmode: "disable"

jwt:
  secret: "${_s2a_jwt}"
  expire_hour: 24

default:
  user_concurrency: 5
  user_balance: 0
  api_key_prefix: "sk-"
  rate_multiplier: 1.0

redis:
  addr: "ai-redis:6379"
  password: ""
  db: 0
S2ACFG
    cat >> "$BASE_DIR/docker-compose.yml" <<SVC

  sub2api:
    image: weishaw/sub2api:0.1.130
    container_name: sub2api
    restart: unless-stopped
    depends_on:
      ai-db:
        condition: service_healthy
      ai-redis:
        condition: service_started
    environment:
      TZ: Asia/Shanghai
      SERVER_PORT: "${_s2a_port}"
    ports:
      - "\${_BIND_PLACEHOLDER}:13001:${_s2a_port}"
    volumes:
      - ./sub2api/data:/app/data
      - ./sub2api/config.yaml:/app/config.yaml:ro
    networks: [ai-stack]
SVC
    echo "S2A_PORT=${_s2a_port}" >> "$BASE_DIR/.env"
    echo "S2A_JWT_SECRET=${_s2a_jwt}" >> "$BASE_DIR/.env"
    echo "S2A_TOTP_KEY=${_s2a_totp}" >> "$BASE_DIR/.env"
  fi

  cat >> "$BASE_DIR/docker-compose.yml" <<'FOOTER'

networks:
  ai-stack:
    name: ai-stack
    driver: bridge
FOOTER

  # 替换端口绑定占位符
  sed -i "s|\${_BIND_PLACEHOLDER}|${_BIND}|g" "$BASE_DIR/docker-compose.yml"

  log "docker-compose.yml 已生成"
  info "VPS Docker 服务：$(docker compose -f "$BASE_DIR/docker-compose.yml" config --services 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo '（解析失败）')"
}

# LiteLLM 路由配置（仅 VPS 侧）
write_litellm_config() {
  $INST_LITELLM && [[ "${LOC_LITELLM:-vps}" == "vps" ]] || return 0
  cat > "$BASE_DIR/litellm/config.yaml" <<'EOF'
# LiteLLM 路由 — 重启生效：docker compose restart litellm
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
  # - model_name: claude-sonnet
  #   litellm_params:
  #     model: anthropic/claude-sonnet-4-5
  #     api_key: os.environ/ANTHROPIC_API_KEY
  # 多 Key 轮转：同 model_name 写多条，自动 round-robin
router_settings:
  routing_strategy: least-busy
  num_retries: 3
  timeout: 120
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
litellm_settings:
  drop_params: true
  set_verbose: false
EOF
  log "LiteLLM 配置 → $BASE_DIR/litellm/config.yaml"
}

