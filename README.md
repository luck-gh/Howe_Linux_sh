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
- 静态 IP 出口：每订阅可挂载远端 socks5 资源池，按服务关键词
  分流（AI / 流媒体 / 银行 / 社交 / IP 检测），客户端只看到 sing-box 不暴露原始凭据
- 订阅 URL 格式：`https://<domain>/sub/<token>/<name>.yaml`
- 节点入口支持稳定域名或 IP, 可在订阅菜单 `[e] 节点入口` 修改; 域名入口在刷新和迁移后保留.
- 域名节点支持受信任 TLS: Caddy 签发并续期, sing-box 热加载证书, 自建与静态入口统一校验证书.
- 客户端模板将节点解析、国内直连解析和经代理的海外解析分开, 首装自动填入订阅域名.
- 自动生成节点显示名（IP 地理位置 → `[自建] 🇺🇸 美国 · 洛杉矶`）

节点域名须直达 VPS, 与可经 CDN 的 HTTPS 订阅网址分开处理. 配置、迁移和现有安装更新方法见
[Clash 节点入口与 DNS](ai_stack/doc/README.md#节点入口与-dns).

**系统工具**
- 启动页分别探测并显示当前公网 IPv4 / IPv6, IPv6 不可用时明确显示未获取
- 网络测速 / 流媒体解锁检测 / VPS 综合测评
- Docker 安装 / 防火墙管理 / SSH 安全加固
- AI 智能体 CLI 工具安装（Claude Code / OpenCode 等）

## 快速开始

```bash
git clone https://github.com/luck-gh/Howe_Linux_sh.git
cd Howe_Linux_sh
bash howe.sh
```

入口依赖仓库中的模块, 请使用完整克隆, 不单独下载或通过进程替换运行 howe.sh.

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
  doc/               # 分发资源
    clash_subs.py    # 订阅管理 + 渲染脚本
    clash_subs_serve.py# 订阅按需刷新 HTTP 服务
    clash_subs_stats.py# 流量统计 + 限流执法
    vps.yaml         # Clash 配置模板
lib/                 # 基础工具库
modules/             # 功能模块入口
```

## 依赖

- Ubuntu 22.04 / Debian 12（推荐）
- Docker + Docker Compose
- Python 3.10.12+ 与 PyYAML（公网 IP 校验, 归档安全过滤和订阅管理）
- 支持 `up/start --wait` 的 Docker Compose v2（升级与恢复等待健康检查）
- sing-box 1.11+（代理服务，静态 IP 多用户路由依赖此版本）

## 开发验证

```bash
bash tests/public_ip.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/lifecycle.sh
```

以上测试使用合成数据与模拟服务命令, 不修改业务配置. 覆盖公网地址, 归档路径与摘要,
备份失败中止升级, 镜像回滚, 首次恢复顺序, 迁移健康检查与交互取消.
安装 age 后会运行密钥模式回归; 在内存充足的 Linux 测试机上设置
`HOWE_TEST_AGE_PASSPHRASE=1` 可额外运行真实口令交互测试.

真实数据库与 Compose 集成测试需要本机已有 PostgreSQL 16 镜像:

```bash
POSTGRES_TEST_IMAGE=postgres:16-alpine bash tests/integration_postgres.sh
```

集成测试仅创建自动清理的独立容器与卷, 不拉取镜像, 不开放主机端口,
不挂载生产目录. 测试真实 dump/restore, SQL 回滚及健康/不健康状态.
这些检查不等同于实际业务迁移验收, 正式迁移仍需确认范围, 停机和回退条件.

## 备份与迁移约束

迁移只接受当前 manifest v2; 旧格式请用当前脚本重新打包. 打包与解包均核对 scope,
归档摘要和路径, 同名备份点不自动覆盖. 恢复按配置、文件数据、数据库、服务启动顺序执行;
任何失败都会中止. 用户选择暂不启动时返回未完成状态, 不报告迁移验收成功.

新增 frps 配置/启动单元备份, AI 配置备份包含数据库初始化脚本.
主机安全配置仅解压到 `/root/howe-migrate-restore/system-sec`, 需对比目标机配置后处理.
自定义备份路径逐行输入, 支持路径包含空格. 备份有失败项时返回非零, 不用于自动升级.

9router 与 kiro-rs 的健康探针已修正. 已存在容器仍使用创建时的探针,
需要在计划维护时重新生成 Compose 并重建相应服务才会应用.

## 致谢

本项目的系统工具部分（网络测速、流媒体检测、Docker 安装等）参考并借鉴了 [kejilion/sh](https://github.com/kejilion/sh)，该项目同样采用 Apache-2.0 协议。

ECS 启动器来自 [oneclickvirt/ecs](https://github.com/oneclickvirt/ecs), 随仓库版本取自
`01a8003f840292396d1364a1dfef82a9a8f8b597` 的 `goecs.sh`. 更新工具时先下载到临时文件,
语法检查通过后再替换; 综合测评本身涉及外部下载与资源消耗, 未纳入自动回归.
该独立脚本遵循上游 GPL-3.0, 许可证见 [ecs.LICENSE](lib/scripts/ecs.LICENSE).

## License

[Apache-2.0](LICENSE)

第三方脚本保留各自许可证; ECS 例外见上方说明.

本项目基于 Apache-2.0 协议开源，在 [kejilion/sh](https://github.com/kejilion/sh)（Apache-2.0）基础上进行了扩展开发。
