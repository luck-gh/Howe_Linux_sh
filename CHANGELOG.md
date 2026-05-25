# Changelog

本项目所有重大变更记录于此文件。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [V1.4] - 2026-05-25

### Security
- **sub2api 镜像源切换到上游官方**：原 `xidahuang/sub2api:latest` 是第三方
  打包，版本号自编（伪装 1.8.0）与上游 GitHub release 完全脱钩，且为闭源
  二进制存在凭据回传风险。改用 `weishaw/sub2api:0.1.130` 并钉版本。
- **openclaw 镜像源修正**：`docker pull openclaw/openclaw:latest` 改为
  `ghcr.io/openclaw/openclaw:latest`（Docker Hub 上无该命名空间，原命令必然
  404 失败）。
- **备份目录权限收紧**：`/var/backups/howe` 及备份点目录权限设为 `0700`，
  避免 PG dump、JWT secret、订阅 token 等敏感数据被普通用户读取。

### Added
- **「备份 / 恢复（数据 / 配置文件）」模块**（主菜单第 3 项）
  - 7 类备份范围（scope）：`ai-pg` / `ai-data` / `ai-config` / `clash` /
    `singbox` / `caddy` / `ai-cli`，按服务粒度独立备份与恢复
  - 备份点结构：`tar.gz` + `sha256` 校验 + `manifest.json`
  - 自动检测可用 scope（缺哪个服务就不显示）
  - 配置文件 `/etc/howe-backup.conf`（mode 0600）：保留份数 / 存储路径 /
    默认范围 / 升级前自动备份开关 / systemd timer 定时任务
  - 默认备份范围统一控制 3 处：立即备份预选、升级前自动备份、定时备份
  - 路径迁移：修改存储路径时自动 `mv` 已有备份点
  - 中文备注与列对齐：使用 `unicodedata.east_asian_width` 计算显示宽度
- **升级菜单加批量检查更新**（升级菜单底部 `[c]` 入口）
  - 并发查询所有已安装服务的当前版本与上游最新版本
  - docker 服务用 `docker buildx imagetools inspect` 拿 registry digest 与
    本地 `RepoDigests` 比对
  - sing-box / caddy 走 GitHub releases API
  - 表格输出 + 状态标记（✓ 已最新 / ↑ 可升级 / ? 检查失败）

### Changed
- **菜单文案区分易混项**
  - `安装 / 更新` → `安装 / 重新生成配置`（强调它实际重写
    `.env` / `docker-compose.yml` / `Caddyfile` 等配置）
  - `升级 / 回滚单服务` → 加副标题"程序版本：镜像 / 二进制"
  - 新增的备份模块命名为`备份 / 恢复（数据 / 配置文件）`，与升级回滚区隔
- **服务栈主菜单重排**：「卸载」从第 3 项移到第 6 项（按操作风险递增排序）
- **`input_choose` 交互统一**：所有菜单加同一行提示文案——
  `输入编号（1-N），输入 0 / Enter 返回，输入 q / quit 退出`
- 顶部标题 `v3` → `V1.4`

### Fixed
- **sing-box 版本解析**：`_singbox_cur_ver` 等 3 处把 `sing-box version`
  输出第 2 列（字面量 `version`）当作版本号的老 bug，改为取末列 `$NF`
- **manifest.json JSON 转义**：`note` 字段含特殊字符（双引号 / 反斜杠 /
  换行 / 中文）时改用 `python3 json.dumps(ensure_ascii=False)` 安全编码；
  空数组从 `[""]` 改为 `[]`
- **`ai-data` 大小估算**：原本算了整个 `/opt/ai-stack`（含 ai-db 数据卷
  几百 MB），改为只算实际备份的 `sub2api/new-api/litellm/openwebui` 子目录
- **`ai-pg` 备份失败**：`psql -U ai` 默认连同名库 `ai`（不存在）导致
  `pg_dump` 拿不到库列表，改为 `psql -U ai -d postgres`

## [V1.0] - 2026-05-24

### Added
- 初始版本：VPS 管理工具箱 + AI 服务栈 + Clash 多订阅代理

[Unreleased]: https://github.com/luck-gh/Howe_Linux_sh/compare/V1.4...HEAD
[V1.4]: https://github.com/luck-gh/Howe_Linux_sh/compare/V1.0...V1.4
[V1.0]: https://github.com/luck-gh/Howe_Linux_sh/releases/tag/V1.0
