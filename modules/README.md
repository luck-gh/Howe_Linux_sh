# modules/ — 顶层菜单功能模块

`howe.sh` 主菜单的 7 个子菜单各对应这里一个 `mod_*.sh`。每个文件聚焦一个领域，
通过 `source` 加载到主入口的命名空间，互不依赖（除了共享 `lib/` 下的工具函数）。

## 模块列表

| 文件 | 行数级别 | 主菜单项 | 主要负责的事 |
|------|---------|---------|-------------|
| `mod_system.sh` | ~280 | 1. 系统管理 | `show_system_info` / `system_update` / `system_clean`（apt clean + autoremove + journal vacuum）/ `fix_dpkg` / `create_backup` / `restore_backup` / `list_backups` / `delete_backup`。`manage_swap` 函数体保留但已从子菜单摘除（迁去 `mod_memmgr`）。 |
| `mod_memmgr.sh` | ~915 | 2. 内存管理 | 完整内存运维工具集，专为 1GB 等小内存 VPS 设计。`mem_status`（只读诊断：free / swapon / sysctl 参数 / 可回收缓存估算 / Top RSS / Top Swap / Docker stats）/ `mem_triage`（内存救援：诊断报告 + kill 候选列表 + 逐项确认；自动标记当前 SSH 会话祖先链避免误杀，过滤系统派生进程）/ `mem_clean`（drop_caches + apt clean + journal vacuum 7d，每项独立确认）/ `sysctl_tune`（写 `/etc/sysctl.d/99-howe-mem.conf`，幂等）/ `swap_resize`（自动检测 `/swap` 或 `/swapfile`，dd 重建 + fstab 持久化）/ `zram_setup`（zram-tools 安装 + 配置 ALGO/SIZE/PRIORITY）/ `earlyoom_setup`（可选预防：内存+swap 双低于阈值时主动 kill 最大进程）。 |
| `mod_docker.sh` | ~270 | 3. Docker 管理 | 容器管理（启停 / 重启 / 查看日志）/ 镜像管理（拉取 / 删除 / 清理）/ 网络管理 / IPv6 开关。源自 `kejilion.sh`，已去除遥测。 |
| `mod_security.sh` | ~550 | 4. 安全加固 | SSH 加固（端口 / 密钥 / 禁 root）/ fail2ban / iptables 防火墙 / DDoS 防御 / 国家 IP 封锁。源自 `kejilion.sh`，已去除遥测和 `gh_proxy`。 |
| `mod_network.sh` | ~360 | 5. 网络优化 | DNS 管理 / BBR 拥塞控制 / 内核参数调优 / IPv4 优先。源自 `kejilion.sh`。**注意**：sysctl 写入与 `mod_memmgr` 的 swappiness / vfs_cache_pressure 不重叠，分别落在 `99-howe-bbr.conf` 和 `99-howe-mem.conf`。 |
| `mod_ai_stack.sh` | ~100 | 6. AI 服务栈 | 入口胶水层。`mod_ai_stack_main` 通过 `bash <path>` 调用 `ai_stack/ai-stack-setup.sh`，让 ai_stack 在独立子进程中运行（避免 ai_stack 内部的 `set -u` 与主入口的环境变量冲突）。具体功能见 `ai_stack/README.md`。 |
| `mod_test.sh` | ~210 | 7. 网络测试 | IP 解锁检测 / 回程路由（NextTrace / besttrace）/ 三网测速 / VPS 综合性能。简便工具走 `lib/nettest.sh` 的本地 bash 实现；复杂工具首次下载到 `lib/scripts/` 后本地执行（详见 `mod_complex_tools.sh`）。 |
| `mod_complex_tools.sh` | ~150 | （`mod_test` 内部调用） | 复杂脚本本地化：查找 / 下载 / 更新 / 删除 / 状态查看。所有复杂工具都缓存到 `lib/scripts/`，避免每次执行都从网络拉取。 |

## 加载方式

`howe.sh` 在启动时 `source` 全部 `mod_*.sh`，各模块向全局命名空间注册自己的
`mod_<name>_main` 函数。模块之间没有依赖顺序约束（不像 `ai_stack/` 内部那样
严格按 source 顺序），但都依赖 `lib/colors.sh` `lib/utils.sh` 等基础库已经
预先 source。

## 新增一个模块的步骤

1. 新建 `modules/mod_<name>.sh`，第一行 `#!/usr/bin/env bash`，参照现有文件
   写文件头注释。提供一个入口函数 `mod_<name>_main`（建议带 `while true` 循环
   的子菜单），其余函数随意命名。
2. 复用 `lib/colors.sh` 提供的 `log` / `warn` / `info` / `err` / `section`
   和 `lib/utils.sh` 提供的 `ask` / `askyn` / `break_end`，菜单风格保持一致。
3. 在 `howe.sh` 改三处：
   - 顶部 `source` 列表加一行
   - 主菜单 `echo` 列表加一项 + `case "$choice"` 加一个分支（注意更新原编号）
   - 非交互入口 `case "$1"` 加一个别名
4. 在本 README 表格里加一行。

## 与 lib/ 的分工

| 在哪里 | 放什么 |
|--------|--------|
| `lib/` | 跨模块通用工具：颜色 / 日志 / 询问输入 / 系统检测 / 网络测试原语 / 子菜单分页等。**任何 mod 都可能引用。** |
| `modules/mod_*.sh` | 主菜单某一项的具体业务逻辑。**不应被其他 mod 引用，只被 `howe.sh` 引用。** |
| `ai_stack/` | AI 服务栈这个特定子系统的所有内部实现（多文件拆分）。`mod_ai_stack.sh` 是它的薄入口。 |

## 调用约定

- 模块入口函数命名固定：`mod_<name>_main`，便于 `howe.sh` 主菜单和非交互入口
  统一调用。
- 模块内部辅助函数建议加 `_` 前缀避免污染（参照 `ai_stack/clash.sh` 里
  `_clash_dir` `_static_menu_*` 的做法）。
- 不要在模块加载（`source`）阶段执行有副作用的代码——只定义函数。所有动作
  都从 `mod_<name>_main` 开始触发。
