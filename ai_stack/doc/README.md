# Clash 订阅子系统 — 节点命名规范

本目录(`ai_stack/doc/`)是 Clash 多订阅子系统的核心代码,部署到 `/opt/ai-stack/clash/`。

## 节点命名统一规范(物理节点)

```
[自建/静态/外购](宅/机-%d)[anno] 国旗 国家·城市 (IP)
└─ 类别 ──┘└── 风险后缀 ─┘└备注┘└── geo 标签 ──┘ └ IP ┘
```

**段位含义**:

| 段位 | 取值 | 关闭后 |
|---|---|---|
| 类别 | `[自建]` / `[静态]` / `[外购]` | 不可关 |
| 风险后缀 `(宅/机-%d)` | `宅`/`机` + 风险分 0-100 (越小越好) | 显示为空,该段消失 |
| 备注 `[anno]` | 静态 IP 资源可选(中英文/数字/空格/-_, ≤12 字符) | 资源未填则不显示 |
| geo 标签 | `🇺🇸 美国·洛杉矶` | 查询失败时退化为 server 字符串 |
| IP `(xxx)` | 实测出口 IP | 显示为空,该段消失 |

**示例**(全开 / 关风险 / 关 IP / 都关 / 带 annotation):

```
[自建](机-66) 🇺🇸 美国 · 洛杉矶 (199.193.124.234)
[自建] 🇺🇸 美国 · 洛杉矶 (199.193.124.234)
[自建](机-66) 🇺🇸 美国 · 洛杉矶
[自建] 🇺🇸 美国 · 洛杉矶
[静态](宅-0)[好用1] 🇺🇸 美国 · 洛杉矶 (172.56.121.124)
```

**静态 IP 资源录入格式**:

```
[annotation:]host:port:user:password   # 4 或 5 段
[annotation:]host:port:password        # 3 或 4 段(无认证用户名)
```

冒号段数自动判别:第 2 段是不是合法端口数字。`annotation` 仅出现在节点名前置标签,**不进去重键**(同一个 socks5 资源不同 annotation 仍算重复)。

## 三类节点的处理差异

| 类别 | server 含义 | 真实出口 IP 来源 | 评分 | 命名生成 |
|---|---|---|---|---|
| `[自建]` | VPS 域名/IP | VPS 本机 `curl ipify`(直发) | ✓ | 自动 |
| `[静态]` | socks5 入口(IP 或 LB 域名) | `curl --socks5-hostname` 走该节点测 ipify | ✓ | 自动 |
| `[外购]` | 机场 anytls/vless/... 入口 | 协议私有,无法实测 | **✗ 不评分** | 沿用机场原 name,仅加 `[外购] ` 前缀 |

**外购例外说明**: 外购协议是 anytls/vless/vmess 等私有协议,Python 无法直接连。若强行按 server 字段查 quality,得到的是入口 LB 而不是真实落地,误差大。因此**外购组始终不参与评分**,节点名沿用机场原始 name。

## 信息节点(不参与排序/评分)

`[自建]`/`[静态]` 的信息节点由我们生成(显示在组首):

- `[自建] 剩余流量:xx GB`
- `[自建] 距离下次重置:xx 天`
- `[自建] 套餐到期:YYYY-MM-DD`
- `[静态] 服务包: ai,ip`
- `[静态] 关键词: (无)`

`[外购]` 的信息节点由机场塞在 yaml 里(name 含关键词 `剩余/流量/重置/到期/倍率/套餐/公告/续费/官网/距离/工单/客服/群组/网址/域名/节点信息`),识别后置顶,不评分不排序。

## 排序规则

每组组内顺序:

```
信息节点(原序) → 真实节点(按风险升序,失败排末尾)
```

组之间顺序:`自建 → 静态 → 外购`。

## 缓存机制

| 文件 | 用途 | TTL |
|---|---|---|
| `.ip_geo_cache.yaml` | 地理位置(国旗/国家/城市) | 7 天,失败 1h |
| `.ip_quality_cache.yaml` | 风险分 + 类型(宅/机) | 24 小时,失败 1h |

- 缓存键统一是 IP(域名先 DNS 解析后用解析结果)
- 进程内 `_ip_*_memo` 同一次 render 同一 IP 只查一次
- 出口 IP 探测内存级缓存(`_exit_ip_memo`),render 进程结束即丢

## 配置开关(defaults)

```yaml
quality_check_enabled: off      # 风险检测总开关
quality_check_for_self: on      # 检测 [自建]
quality_check_for_static: on    # 检测 [静态]
# 外购不评分,无独立开关
quality_source: free            # free=proxycheck 匿名 / scamalytics
scamalytics_url: ""             # scamalytics 完整 URL(优先于 proxycheck)
proxycheck_api_key: ""          # 空走匿名 100/天,有 key 1000/天
exit_ip_show_enabled: on        # (IP) 显示总开关
exit_ip_show_for_self: on       # [自建] 末尾 (IP)
exit_ip_show_for_static: on     # [静态] 末尾 (IP)
```

通过 `howe.sh → Clash 订阅管理 → IP 检测` 子菜单可视化配置。

## 关键文件

| 文件 | 职责 |
|---|---|
| `clash_subs.py` | 订阅 CRUD + 渲染 + nft 差分入账 + enforce 限流 |
| `clash_subs_stats.py` | systemd timer 驱动的轮询执法流水线 |
| `clash_subs_serve.py` | HTTP 服务(127.0.0.1:13888),客户端拉取时触发防抖 stats |

## 菜单风格约定

`ai_stack/clash.sh` 里的所有菜单按以下三种风格之一实现,新增菜单优先复用现有助手 (`_clash_field_loop` / `_clash_field_originals_from` / `_quality_get` / `_quality_set` 等),不重写。

### 风格 A — 动作型主菜单

每行 = 一个独立动作(列出 / 添加 / 删除 / 替换 / 清空)。选号进入子流程,完成后回主菜单。

适用: 一组互相独立、各自有完整流程的操作。范例: `_clash_menu_static` (静态 IP 资源管理)、订阅管理顶层。

### 风格 B — 批量字段编辑器

每行 = 一个**字段**,显示当前值或 `[修改] 暂存值`。选号编辑 → 暂存到 `_values[]` → `[0/回车]` 才批量提交,`[N]` 放弃。

适用: 多个字段一起改、需要预览所有改动后再保存的场景。范例: `_clash_menu_defaults` / `_clash_menu_add` / `_static_menu_strategy`。**助手**: `_clash_field_loop`。

### 风格 D — 立即生效字段表

每行 = 一个字段(状态展示),选号立即写盘,主菜单重绘新值,无暂存。

适用: 多个独立开关或配置项,改一项立即看到效果,误改可立刻反向操作。范例: `_clash_menu_quality` (IP 检测)。

**字段三种类型对应不同操作语义**:

| 类型 | 选号后 | 例子 |
|---|---|---|
| 布尔 | 立即 toggle (on↔off),不弹子界面 | 评分总开关 / 自建评分 |
| 枚举 | 弹子选择器([1] 选项A [2] 选项B),选完即写 | 数据源 (free / scamalytics / lookup_scrape) |
| 文本 | 弹单行输入提示;空回车=不变,`-`=清空,文本=保存 | scamalytics URL / proxycheck key |

**字段值的展示**:

- 布尔: `${G}on${N}` / `${DIM}off${N}` 颜色区分
- 枚举: 当前值原样显示
- 文本(可能较长): 统一用 `(已配置)` / `(未配置)` 简化,不暴露原文

### 通用约定

- 进入菜单先调 `_xxx_print_overview` 或表头,显示当前关键状态
- 退出键: `[0 / 回车]` 返回上层 + `[q]` 退出整个订阅管理菜单 (复用 `_STATIC_QUIT` 模式,变量名按菜单命名)
- 操作动作(非字段): 用字母编号区分字段编号 (例: `[c] 清空缓存`)
- 字段编辑器或子选择器**不允许**用户输入字符串确认布尔值;布尔即 toggle

