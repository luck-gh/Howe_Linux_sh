# Howe_Linux_sh

Linux VPS 管理工具箱，集成 AI 服务栈一键部署与 sing-box + Clash 多订阅代理管理。

## 功能概览

**AI 服务栈**
- New-API / OpenWebUI / LiteLLM / Sub2API / Dify 一键安装
- Caddy 自动 HTTPS 反代
- 支持 All-in-One 与分布式（VPS + 本地）两种部署模式

**代理订阅**
- sing-box AnyTLS 多订阅，每订阅独立端口 + 密码
- nftables 流量统计 + 超额自动限流（无需重启）
- Clash / Mihomo 订阅渲染，支持外购节点合并
- 订阅 URL 格式：`https://<domain>/sub/<token>/<name>.yaml`
- 自动生成节点显示名（IP 地理位置 → `[自建] 🇺🇸 美国 · 洛杉矶`）

**系统工具**
- 网络测速 / 流媒体解锁检测 / VPS 综合测评
- Docker 安装 / 防火墙管理 / SSH 安全加固
- AI 智能体 CLI 工具安装（Claude Code / OpenCode 等）

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luck-gh/Howe_Linux_sh/main/howe.sh)
```

或克隆后本地运行：

```bash
git clone https://github.com/luck-gh/Howe_Linux_sh.git
cd Howe_Linux_sh
bash howe.sh
```

## 目录结构

```
howe.sh              # 主入口
ai_stack/            # AI 服务栈 + 代理订阅（核心模块）
  ai-stack-setup.sh  # 模块加载入口
  clash.sh           # Clash 多订阅管理
  services.sh        # sing-box / frp / 防火墙
  caddy.sh           # Caddy HTTPS 反代
  compose.sh         # Docker Compose 生成
  lifecycle.sh       # 安装 / 卸载流程
  ...
doc/                 # 分发资源
  clash_subs.py      # 订阅管理 + 渲染脚本
  clash_subs_serve.py# 订阅按需刷新 HTTP 服务
  clash_subs_stats.py# 流量统计 + 限流执法
  vps.yaml           # Clash 配置模板
lib/                 # 基础工具库
modules/             # 功能模块入口
```

## 依赖

- Ubuntu 22.04 / Debian 12（推荐）
- Docker + Docker Compose
- Python 3.10+（订阅管理脚本）
- sing-box 1.10+（代理服务）

## 致谢

本项目的系统工具部分（网络测速、流媒体检测、Docker 安装等）参考并借鉴了 [kejilion/sh](https://github.com/kejilion/sh)，该项目同样采用 Apache-2.0 协议。

## License

[Apache-2.0](LICENSE)

本项目基于 Apache-2.0 协议开源，在 [kejilion/sh](https://github.com/kejilion/sh)（Apache-2.0）基础上进行了扩展开发。
