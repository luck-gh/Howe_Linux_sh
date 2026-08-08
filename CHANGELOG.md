# Changelog

本项目所有重大变更记录于此文件。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- **恢复前置检查 `_mig_preflight_tools`**：把恢复顺序纠正为「先有运行环境，
  再落数据」。原先直接解压数据，新机没装 Docker 时 `ai-pg` 必然失败，用户
  还得自己从「ai-db 容器未运行」倒推根因。
  - ① Docker：bundle 含容器化 scope 且本机缺 Docker 时，说明后果并询问是否
    安装（官方脚本，装最新版）；已装且版本不同时给出选择：切到 bundle 版本
    （apt 锁版本，会重启 daemon）或保持本机版本。刚装完 Docker 还没起容器时
    也会问是否改装成 bundle 版本——此刻无容器重启风险，是最适合对齐的时机。
  - ② 原生二进制对账：读 `host-inventory.json` 的 `native_versions`，逐项
    判定已一致 / 版本不同 / 未安装，三种处置模式（按旧机版本安装切换 /
    仅补缺失项 / 全部跳过）
  - ③ 才执行数据恢复
- **Docker 锁版本 `mig_install_docker_pinned`**：Docker CE 由官方 apt 源
  分发，可精确锁版本（之前判断「官方脚本无版本参数所以锁不了」只对
  get.docker.com 那条路成立，走 apt 是可以的）。新增四个相关函数：
  `mig_docker_apt_managed`（判断是否 apt 管理）、`mig_docker_apt_pkgver`
  （查询 apt 源中的完整包版本串）、`mig_docker_apt_versions`（列出可用版本）、
  `mig_install_docker_pinned`（按指定版本安装/切换，会重启 daemon）。
  版本串匹配用 `:版本-` 锚定以防误中（`grep -F 29.5.0` 会匹配 129.5.0 /
  29.5.01）。
- **锁版本安装器 `mig_install_singbox_pinned` / `mig_install_frps_pinned`**：
  现有 `install_singbox` 与 `install_frp_server` 都是「查 GitHub latest 后
  装」，且失败时调 `err()`（内部 `exit 1`）——在恢复流程里调用会直接杀掉整个
  脚本。新写的这套版本由调用方指定，失败只 `warn` + `return 1`。
  - `armv7l` 的架构串两个项目不一致（frp 用 `arm`，sing-box 用 `armv7`），
    已分别复刻，写错会导致 x86 正常而 ARM 下载 404
  - Caddy 走 apt 无法干净锁版本，只报差异并提示到「AI 服务栈 → 安装」处理；
    不在恢复流程里调 `install_caddy`，同样因为它内部会 `exit`

### Fixed
- **误敲回车穿透多层菜单**：长任务（打包 / 备份 / 传输）执行期间用户敲的回车
  滞留 tty 输入队列，随后被菜单里连续的 `read` 逐个消费——「按回车继续」暂停
  失效、`print_header` 的 `clear` 冲掉执行结果、菜单自行退回上层。表现为打包
  成功后一闪回到顶层主菜单，看不到 bundle 路径。
  - 新增 `flush_stdin`（`lib/utils.sh`）丢弃缓冲按键，长任务返回后调用
  - `migrate_menu` 的 `0|*) break` 拆分：仅显式 `0` 退出，空输入与无效输入
    留在菜单（原写法让任何无效输入都等于退出，是穿透的最后一环）
- **SSH 推送/拉取卡死无提示**：`ssh` 未设 `ConnectTimeout`，地址或端口填错要
  等 `tcp_syn_retries` 耗尽（默认约 127 秒）才失败，期间零输出，看起来像
  「卡住后莫名退出」。
  - 新增 `mig_ssh_opts`：统一 `ConnectTimeout=10` + `ServerAliveInterval=15`
    / `ServerAliveCountMax=2`（后者管传输中途断链，30s 内失败而非无限挂着）
  - 新增 `mig_ssh_check`：传输前预检，按 ssh stderr 分类诊断 host key 校验
    失败（附 `ssh-keygen -R` 命令，按端口给出 known_hosts 的正确格式）/
    网络不可达 / 端口拒绝 / 认证失败
  - 首连新机时 host key 确认提示会被 stdin 残留回车自动答掉，预检前先 flush
- **恢复策略逐项弹窗**：选中 N 个 scope 后要连点 N 次单选框。根因是每个
  scope 的候选策略都含 `skip`，让「只剩一个策略就免问」的判断永远不成立——
  而选中 scope 本身已表达「不跳过」，`skip` 是冗余项。
  - 剔除 `skip` 候选后，多数 scope 只剩单一策略，直接采用不再打扰
  - 改为一屏展示完整恢复计划，只有存在真实分支的项（`docker-images` save 模式
    的 load/pull、`custom` 的原路径/前缀目录）可输编号切换
- **手动 scp 漏传校验和**：原提示只给 bundle 本身，遗漏同名 `.sha256`，
  导致新机解包时跳过完整性校验。现给出通配两文件的完整命令。

### Added
- **镜像版本锁 `docker-images.lock.json`**：每次 `backup_create` 都写，与是否
  勾选 `docker-images` scope 无关。
  - 动机：compose 里大量使用 `:latest` / `:main` 等可变 tag（本项目的
    new-api / 9router / open-webui / litellm 均是），新机 `docker compose up -d`
    拉到的是「此刻的 latest」而非旧机当时实际运行的版本，迁移后版本漂移。
    仅靠 tag 字面量无法还原。
  - 记录每个运行容器镜像的 compose service、镜像引用、`RepoDigest`（不可变）、
    image ID、构建时间，并标记 tag 是否可变
- **恢复时镜像版本对账 `mig_reconcile_images`**：恢复 `ai-config` 后自动触发，
  逐镜像对比新机现状并让用户决定版本取向。
  - 状态判定：已一致 / 版本不同 / 未安装 / 缺 tag（本地有该 digest 但未打 tag）
    / 无 digest（本地构建镜像，无法锁定）
  - 可选动作覆盖新装、回退、更新、保持四种诉求；支持 `a` 全部对齐 bundle 版本、
    `t` 全部拉 tag 最新版、输编号单项切换
  - 落地手法：按 digest 拉取后 `docker tag` 回 compose 里写的 tag。retag 是
    零成本别名（同一 image ID），且 compose 默认 `pull_policy=missing`，本地
    已有该 tag 就不会再拉 latest —— 因此无需改写用户的 docker-compose.yml
  - 本地已有目标 digest 时跳过 `docker pull` 直接 retag（pull 即便命中本地也会
    联网校验，离网环境会无谓失败）
  - 镜像就位后询问是否 `docker compose up -d`
- **打包前补齐清单与镜像锁**：仅选 `docker-images`/`custom`（不走 `backup_create`）、
  复用本功能上线前创建的旧备份点、`backup_create` 当时 docker 不可用——这三种
  路径原本都不会生成 `host-inventory.json` 与镜像锁，现于打包前检测补写。
- **传递阶段明示落地路径**：传递菜单顶部直接标出新机必须放置 bundle 的目录，
  「无 bundle」提示也改为可操作（给出目录、命名规则与现成 scp 命令），
  不必等点进恢复才发现路径不对。

### Changed
- **备份进度显示**：`backup_create` 逐 scope 显示 `[i/N]` + spinner（tty）
  或阶段行（非 tty / 定时任务），完成后汇总"X 成功 / Y 失败 / 总耗时 / 合计大小"。
  单个 scope 失败会缩进打印其 stderr。可用 `BACKUP_PROGRESS=off` 关掉动画。
- **Clash 静态 IP 子组架构精简**：原 `静态IP_ALL` + `静态IP_Partial` 双子组
  合并为单一 `静态IP` 组，节点前缀从 `[静态_A]` / `[静态_P]` 统一为 `[静态]`，
  每条静态资源由 2 个 sing-box user（A/P）减为 1 个，`route.rules` 注入目标
  从 `静态IP_Partial` 改为 `静态IP`。
  - 静态IP 组内成员顺序：信息节点（服务包 / 关键词，永远渲染，无内容显示
    "(无)"）→ "VPS 节点" 引用 → "外购" 引用（仅在外购存在时）→ 真静态节点
    → DIRECT
  - 字段 `static_passwords_p` 废弃；下次 render 自动迁移并清掉
  - 远端 outbound 协议固定为 socks5（先前注释里出现的 anytls 是误述）
- **静态 IP 服务包新增 `ip` 包**：`ippure` / `ipapi` / `ipinfo` / `myip` /
  `ip.sb` / `ipify` / `icanhazip` / `ifconfig.me` / `ipchaxun` / `whatismyip`，
  方便切静态后直接访问 IP 检测站验证出口是否生效。服务包菜单同步加详细
  中文说明，解释每条预设关键词为什么需要静态 IP。

### Added
- **VPS 迁移子系统 v2**：`ai_stack/migrate_lib.sh` + `ai_stack/migrate.sh`，
  从 AI 服务栈子菜单进入。迁移流程拆为三个独立步骤，每步单独进入菜单：
  - **① 打包**（旧机）：多选 scope + 加密方式，输出 bundle 到本机；
    支持 scope：全部现有备份 scope + `docker-images`（记录名单 / docker save 打包两种策略）
    + `custom`（打包时交互录入任意路径，如 /root/.vimrc）
  - **② 传递**：三种方式独立选择——推送到新机（rsync over SSH）/
    新机从旧机拉取（rsync over SSH）/ 手动 scp 提示；上次打包的 bundle 自动预填
  - **③ 解包恢复**（新机）：读取 `migrate-manifest.json v2`，
    多选要恢复的 scope，每个 scope 单独选恢复策略（如 ai-pg：从dump恢复/跳过；
    docker-images：docker pull 重拉/docker load/跳过；custom：原路径/指定前缀/跳过）
  - `migrate-manifest.json v2`：python3 序列化，记录源主机信息、每个 scope 的
    文件名/大小/描述/打包策略/可选解包策略列表；随 bundle 传递给新机驱动恢复流程
  - 策略执行器 `mig_execute_strategy`（migrate_lib.sh）统一分派所有 scope×策略组合
  - v1 bundle 兼容模式（无 migrate-manifest.json v2 时自动降级）
  - 加密：none / openssl AES-256-CBC PBKDF2 / age 口令+密钥对；口令走 fd 不进 argv
  - bundle 内外两层 sha256 校验 + 同名备份点改名保护
- **docker-images scope**（`backup_lib.sh`）：`MIG_DOCKER_STRATEGY=record` 仅保存
  镜像名单（默认），`save` 则 docker save 打包；恢复策略：pull / load / skip
- **custom scope**（`backup_lib.sh`）：`MIG_CUSTOM_PATHS` 驱动，打包时
  保留原始目录结构；恢复到原路径或指定前缀目录
- **system-sec scope**（`backup_lib.sh`）：打包 `/etc/fail2ban/jail.d`
  / `iptables rules.v4/.v6` / `ipset save`；恢复时落到 staging 不自动 apply
- **system-tune scope**（`backup_lib.sh`）：打包 `/etc/sysctl.d/99-howe-*.conf`
  / `/etc/default/zramswap` / `/etc/default/earlyoom` / root crontab
- **host-inventory.json**：每次 backup_create 自动写入，记录 Docker 镜像清单 /
  原生二进制版本 / systemd units / 未打包项计数 / 新机待办清单；解包后展示摘要
- **SSH 遗留会话清理**：`mod_security.sh` → SSH 安全管理子菜单新增 3 项
  （预览 / 交互清理 / 强制清理），关闭 `sshd: root@pts/*` 与 `sshd: root@notty`
  残留而保留当前会话。当前会话通过父进程链定位 sshd 会话 PID（tty 号作辅助
  匹配），双重保护避免自杀；listener（`sshd -D [listener]`）永远排除；
  SIGTERM 失败则 SIGKILL 兜底。
- **静态 IP 子菜单 `[q] 退出菜单` 快捷键**：策略 / 添加 / 删除 / 整体替换
  / 清空 五个子菜单全部支持 `q` 一路退出到 Clash 主菜单（用 `_STATIC_QUIT`
  标志协调），中途误进可一键撤离。
- **取消语义统一**：所有静态 IP 子菜单的 `0` / `y` / `Y` / `n` / `N` /
  回车都视为取消，避免按惯性回 `y` 把空值写进去。
- **资源去重保护**：`apply_fields` 与 `cmd_defaults` 追加静态 IP 时按
  `(server, port, username, password)` 去重，重复条目自动跳过并提示数量。

### Fixed
- **defaults / apply_fields 无变更也写盘**：相同值赋值前先比较，避免触发
  下游 reload 与文件 mtime 抖动。

## [V1.5] - 2026-06-04

### Added
- **Clash 订阅静态 IP 出口**：每订阅可配置远端 socks5/anytls 静态 IP 资源池，
  按策略路由（`off` / `on`），流量仍通过本机 sing-box 中转，nft 计额逻辑零变化。
  - 资源录入格式：`host:port:user:password`（无认证时 `host:port:password`）
  - 资源池两层结构：默认池（`defaults.yaml`）+ 订阅独立池（覆盖默认）
  - 同一份资源被多个订阅引用会自动去重为同一个 sing-box outbound
  - `on` 模式渲染 `静态IP_ALL` + `静态IP_Partial` 两个子组；预设服务包
    （ai / streaming / banking / social）+ 自定义 DOMAIN-KEYWORD 列表，
    render 时注入 Clash `rules` 头部，命中关键词的服务走「静态IP_Partial」
    子组（用户在该子组里手动选静态节点 / 信息节点决定走静态还是 VPS）
  - 主菜单新增第 7 项「静态 IP 资源管理」：列表 / 添加（单条或多行粘贴）/
    删除（按编号，多个用逗号或空格分隔）/ 整体替换 / 清空回继承
  - 新 CLI：`clash_subs.py {add,edit,defaults} --static-strategy/--static-service-packs/
    --static-custom-keywords/--static-proxies/--static-proxy-add/--static-proxy-remove`，
    新子命令 `static-list`、`sing-box-outbounds`、`sing-box-route-rules`
  - sing-box `inbounds[].users[]` 多挂静态 user，`route.rules` 用 `user→outbound`
    把流量路由到对应远端，client 永远看不到原始静态 IP 凭据

### Changed
- **菜单字段编辑体验**：新增 / 编辑订阅 / 修改默认值的字段循环现在显示
  「将继承的默认值」与「[修改] 高亮」，留空字段可预知最终生效值。

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
