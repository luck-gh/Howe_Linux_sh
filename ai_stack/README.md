# ai_stack/ — AI 服务栈安装脚本（拆分模块）

> 原 `lib/ai-stack-setup.sh`（3956 行）按职责拆分到此目录，单个文件聚焦一个领域，便于针对性修改和维护。
> 入口仍是单一 shell 脚本：`ai_stack/ai-stack-setup.sh`，它按依赖顺序 source 各模块；外部调用方（`modules/mod_ai_stack.sh` 通过 `bash <path>` 调用）无需感知拆分。

## 目录结构与每个文件的职责

| 文件 | 行数级别 | 主要负责的事 |
|------|---------|-------------|
| `ai-stack-setup.sh` | ~60 | **入口 / loader**。`set -uo pipefail`，stty trap，按顺序 `source` 下列模块，最后 `if BASH_SOURCE==$0; main "$@"`. |
| `core.sh` | ~200 | 颜色 / `log` `warn` `err` `info` / `step` / `ask` `askyn` / `print_header` / `dc_cmd` / `multi_select_input` / 全局常量（`PREFIX_*` `BASE_DIR` `SINGBOX_DIR` 等）/ 加载 `lib/utils.sh`。**最先 source，所有模块都依赖。** |
| `detect.sh` | ~290 | `detect_resources` / `assess_svc` / `preflight` / `choose_deploy_mode` / 服务安装状态探测（`SVC_REGISTRY_*` / `svc_check` / `svc_running` / `detect_installed_services` / `detect_ai_agents` / `has_*_service`）。 |
| `select.sh` | ~470 | `select_services`（输入式服务多选）/ `assign_service_locations`（分布式 VPS 或本地）/ `collect_config`（域名 / frp / Clash 端口段 等）/ `check_dns`。 |
| `base.sh` | ~80 | `install_deps` / `setup_dirs` / `sync_brand_assets` / `refresh_brand_assets`。**轻量公用步骤。** |
| `clash.sh` | ~360 | Clash 多订阅子系统：路径辅助 (`_clash_dir/_clash_py/_clash_stats_py`)，端口段 (`_clash_port_range/_sync_clash_ufw`)，`setup_clash_subscription / setup_clash_stats_timer / render_clash_subscription`，订阅菜单 `_clash_menu_*` (`pick_one/show/add/edit/remove/defaults/refresh`)，`refresh_clash_subscription`。 |
| `compose.sh` | ~390 | `write_env`（生成 `/opt/ai-stack/.env`）/ `write_compose`（生成 `docker-compose.yml`，按服务和分布式模式裁剪）/ `write_litellm_config`。 |
| `caddy.sh` | ~300 | `install_caddy` / `write_caddyfile`（按已选服务渲染站点 + 注入 Clash caddy-blocks）/ `reconfigure_domain`（独立流程，复用 `write_caddyfile`/`check_dns`）。 |
| `services.sh` | ~325 | `install_singbox`（含 anytls 多 inbound 渲染 + nft 表 + reload 钩子 `reload_clash_subscription` / `setup_clash_nft` / `write_singbox_config`）/ `install_frp_server` / `configure_firewall` / `start_services` / `health_check` / `setup_dify` / `sync_newapi_logo`。 |
| `local_pkg.sh` | ~340 | `generate_local_package` — 生成分布式架构里跑在本地机器上的安装包（Linux `install-local.sh` / Windows `start.bat` / docker-compose / frpc.toml），含大段 HEREDOC。 |
| `lifecycle.sh` | ~395 | `print_clash_link` / `print_summary` / `confirm_installation` / `install_or_update`（主安装流水线）/ `uninstall_stack`（多选卸载）。 |
| `view.sh` | ~325 | `show_secrets` / `show_db_connection` / `show_config`（已安装栈的运行状态 + 可改项）/ 服务管理（启动/停止/重启）。 |
| `main.sh` | ~505 | `service_stack_menu`（AI 服务栈子菜单：安装 / 配置 / 卸载 / 刷新 / 查看密钥 / 服务管理 / 订阅 ...）/ `ai_agent_menu`（智能体 CLI 工具：Claude Code / Codex / OpenCode / OpenClaw 安装管理）/ `main`（顶级两选一）。 |

## source 顺序约束（务必保持这个顺序）

```
core → detect → select → base → clash → compose → caddy → services → local_pkg → lifecycle → view → main
```

约束来源：
- `core.sh` 定义颜色、日志、`ask*`、`_AI_STACK_DIR`、全局常量 — 其它所有模块都用。
- `detect.sh` 定义 `INST_*` / `SVC_*_INSTALLED` 等运行时变量 — `select / view / lifecycle` 依赖。
- `clash.sh` 用到的 `BASE_DIR` 在 `core.sh` 定义；`reload_clash_subscription`（在 `services.sh`）反向引用 `_sync_clash_ufw`（`clash.sh`）。bash 是动态作用域，只要调用前 source 完即可，所以 `clash → services` 这个顺序必须保持。
- `lifecycle.sh` 调度上面所有写文件的函数，必须在它们之后 source。
- `main.sh` 是顶层菜单，所有功能都从这里分发，最后 source。

## 共享变量（跨模块使用，避免重复定义）

| 变量 | 在哪里定义 | 含义 |
|-----|-----------|------|
| `BASE_DIR` | core.sh | 部署根目录，固定 `/opt/ai-stack` |
| `PREFIX_VPS` 等 | core.sh | 子域名前缀（`vps.<DOMAIN>` 给 Clash 订阅） |
| `SINGBOX_DIR` / `SINGBOX_BIN` | core.sh | sing-box 配置和二进制路径 |
| `_AI_STACK_DIR` | core.sh | `${BASH_SOURCE[0]%/*}`，指向 `ai_stack/` 自身（用来定位 `../doc`） |
| `INST_<SVC>` | select.sh / detect.sh | 用户选了 / 已安装的服务布尔变量 |
| `LOC_<SVC>` | select.sh | 分布式模式下服务跑在 VPS 还是本地（`vps`/`local`） |
| `DOMAIN` / `VPS_IP` / `FRP_TOKEN` 等 | select.sh / detect.sh / `.env` | 用户配置；持久化到 `/opt/ai-stack/.env`，下次启动 source 进来 |
| `DEPLOY_MODE` | select.sh | `aio` 或 `distributed` |

## 修改建议

- **改一个具体模块**：直接编辑对应 `.sh`，跑 `bash -n ai_stack/<file>.sh`，再跑入口 `bash ai_stack/ai-stack-setup.sh`（被 `modules/mod_ai_stack.sh` 间接调用）。
- **加新功能**：尽量加到职责最相近的现有文件；新建文件需在 `ai-stack-setup.sh` 里按依赖顺序 `source`，并在本 README 表格里加一行。
- **改路径常量**：只在 `core.sh` 改一次。
- **doc 资源（vps.yaml / clash_subs.py / 品牌图标）路径**：模块内统一用 `${_AI_STACK_DIR%/}/../doc`（注意 `_AI_STACK_DIR` 现在指向 `ai_stack/` 而非旧的 `lib/`，但 `..` 仍能定位到仓库根的 `doc/`）。

## 调用入口

外部只通过两条路径调用：

1. `modules/mod_ai_stack.sh` 里执行 `bash ai_stack/ai-stack-setup.sh` — 走 `if BASH_SOURCE==$0; main`，进入顶级菜单。
2. 单独命令行 `source ai_stack/ai-stack-setup.sh` — 守卫保证不会自动跑菜单，方便外部 CI/调试时直接调子函数（如 `write_caddyfile`、`reload_clash_subscription`）。

## 与原 `lib/ai-stack-setup.sh` 的关系

- 拆分后 `lib/ai-stack-setup.sh` 已废弃，调用方（`modules/mod_ai_stack.sh`）改指向 `ai_stack/ai-stack-setup.sh`。
- 历史代码已逐行迁入；行号和函数名完全保持一致，git diff 友好。
