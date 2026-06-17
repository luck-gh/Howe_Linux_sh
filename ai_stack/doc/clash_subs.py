#!/usr/bin/env python3
"""
Clash 订阅管理 + 渲染工具
管理 $BASE_DIR/clash/ 下的多订阅配置,渲染 Clash YAML,生成 Caddy 块。

文件布局
  $BASE_DIR/clash/
    nodes.yaml        节点池(纯节点,无订阅元数据)
    template.yaml     Clash 模板
    subs.yaml         订阅列表
    defaults.yaml     新订阅默认值
    output/<token>/clash.yaml   渲染产物

子命令
  init [--base DIR]                            初始化缺失的 subs/defaults 文件
  list [--brief|--names] [--base DIR]          列出所有订阅
  show NAME [--base DIR]                       显示一条订阅明细
  add NAME [--traffic-gb N] [--reset-day N]
          [--expire YYYY-MM-DD] [--interval H]
          [--token HEX] [--password PWD]
          [--port N] [--external-url URL]
          [--base DIR]                         新增订阅(端口未指定则自动分配)
  edit NAME [--rename NEW] [--traffic-gb N]
          [--reset-day N] [--expire YYYY-MM-DD]
          [--interval H] [--password PWD]
          [--port N] [--external-url URL|-]
          [--base DIR]                         修改订阅
  remove NAME [--base DIR]                     删除订阅
  defaults [--show] [--traffic-gb N]
          [--reset-day N] [--expire-days N]
          [--interval H] [--stats-refresh-minutes M]
          [--port-min N] [--port-max N]
          [--external-url URL]
          [--external-name-prefix STR]
          [--base DIR]                         查看 / 修改默认值
  render [--name NAME | --all] [--base DIR]    渲染订阅
  caddy-blocks --host HOST [--base DIR]        输出 Caddy handle_path 块
  sing-box-inbounds --tls-cert F --tls-key F
          --server-name S [--base DIR]         输出 sing-box inbounds[] (多 anytls)
  nft-config [--base DIR]                      输出 nftables clash_subs table 配置
  usage-from-nft --json (FILE|-) [--verbose]
          [--base DIR]                         消费 nft -j 输出做差分入账
  record-usage --name NAME [--up N] [--down N]
          [--base DIR]                         手动累加用量(字节)
  reset-period [--base DIR]                    跨入新计费期则清零 period_bytes
  enforce [--base DIR]                         按用量/到期重算 disabled 标志
  set-disabled NAME --value (true|false)       手动启停订阅
  get-setting KEY [--base DIR]                 读取一个 default 字段值
  clear-external-cache [--base DIR]            清空外购订阅缓存（强制下次重拉）
"""
import argparse
import hashlib
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone

import yaml


# ─── 默认值 ────────────────────────────────────────────────────────
BUILTIN_DEFAULTS = {
    "traffic_gb": 100,
    "reset_day": 1,
    "expire_days": 365,
    "update_interval_hours": 24,
    # serve.py 按需刷新已是主路径；timer 仅做兜底，默认 10 分钟
    "stats_refresh_minutes": 10,
    # 自动刷新策略: interval(间隔) / daily(日刷新) / off(关闭)
    # - interval: 每 stats_refresh_minutes 分钟刷新一次（传统模式）
    # - daily:    每天 daily_refresh_time 刷新一次（systemd OnCalendar）
    # - off:      关闭定时器，纯手动刷新
    "refresh_mode": "interval",
    # 日刷新模式：每天 HH:MM 执行（仅 refresh_mode=daily 时生效）
    "daily_refresh_time": "03:00",
    # 定时刷新时是否强制重新检测 IP 质量（带 --refresh-quality）
    # - true:  定时刷新时忽略缓存，全量探测出口 IP + 重新拉取评分
    # - false: 定时刷新走 prefer_cache 路径（复用现有缓存）
    "refresh_force_recheck": "false",
    # IP 质量缓存有效期（小时）；超过此时长的缓存条目视为过期需重新拉取
    "ip_quality_cache_hours": 24,
    # 每订阅独立端口段（≤ 16 个用户）
    "port_min": 13443,
    "port_max": 13458,
    # 外购 Clash 订阅：默认 URL（空 = 不启用），节点显示前缀
    "external_url": "",
    "external_name_prefix": "[外购] ",
    # 静态 IP 出口：远端 socks5 资源池 + 路由策略
    # static_proxies 元素：{name, type, server, port, password, sni, skip_cert_verify, udp}
    "static_proxies": [],
    # off : 不渲染 静态IP 子组、不挂静态 user
    # on  : 渲染单一 静态IP 子组（节点信息(服务包) + 节点信息(关键词) + VPS引用 + 外购引用
    #       + 静态节点 + DIRECT）；rules 头部注入 DOMAIN-KEYWORD,xxx,静态IP
    #       关键词命中后由用户在该组里手选目标节点决定走 VPS / 外购 / 静态
    "static_strategy": "off",
    # on 模式下走静态 IP 的预设服务包（包名见 STATIC_SERVICE_PACKS）
    "static_service_packs": [],
    # on 模式下额外的 DOMAIN-KEYWORD 白名单
    "static_custom_keywords": [],
    # 静态 IP 子组节点显示前缀
    "static_name_prefix": "[静态] ",
    # IP 质量检测：总开关 + 自建/静态 分项开关
    # 外购始终不评分(协议私有,server 是入口 LB 而非真实落地,评分无意义)
    "quality_check_enabled": "off",
    "quality_check_for_self": "on",
    "quality_check_for_static": "on",
    # 出口 IP 显示(节点名末尾 (IP))总开关 + 自建/静态分项
    # off = 显示 server 字段(可能是域名);on = 实测出口 IP 显示
    "exit_ip_show_enabled": "on",
    "exit_ip_show_for_self": "on",
    "exit_ip_show_for_static": "on",
    # 数据源：free = proxycheck 免费匿名(100/天，区分度低，所有 datacenter 一律 risk=66)
    #         scamalytics = 用 scamalytics_url(免费 5K/月，区分度高)
    "quality_source": "free",
    # IP 质量打分数据源（按优先级回落）：
    # - scamalytics_url 非空 → 用 scamalytics(区分度高,免费 5000/月)
    #   填 dashboard 给的完整 URL,如 "https://api12.scamalytics.com/v3/?key=XXX&user=YYY"
    #   代码会自动追加 &ip={ip}
    # - 否则用 proxycheck(免费匿名 100/天,区分度低,所有 datacenter 都 risk=66)
    #   填 API key 升级到 1000/天,空 = 走匿名额度
    "scamalytics_url": "",
    "proxycheck_api_key": "",
}

QUALITY_SOURCES = ("free", "scamalytics", "lookup_scrape")
QUALITY_BOOL_KEYS = (
    "quality_check_enabled", "quality_check_for_self",
    "quality_check_for_static",
    "exit_ip_show_enabled", "exit_ip_show_for_self", "exit_ip_show_for_static",
)
REFRESH_MODES = ("interval", "daily", "off")

# 默认值字段类型（影响 cmd_defaults 转换）
INT_DEFAULT_KEYS = {
    "traffic_gb", "reset_day", "expire_days", "update_interval_hours",
    "stats_refresh_minutes", "port_min", "port_max", "ip_quality_cache_hours",
}

# 静态 IP 字段（list[str|dict] 型，CLI 用逗号或 YAML 文本传入）
LIST_DEFAULT_KEYS = {
    "static_proxies", "static_service_packs", "static_custom_keywords",
}

# on 模式下的预设服务包：包名 → DOMAIN-KEYWORD 列表
STATIC_SERVICE_PACKS = {
    "ai":        ["openai", "anthropic", "claude", "chatgpt", "perplexity", "googleapis"],
    "streaming": ["netflix", "disneyplus", "hulu", "primevideo", "spotify"],
    "banking":   ["paypal", "wise", "stripe"],
    "social":    ["twitter", "facebook", "instagram"],
    "ip":        ["ippure", "ipapi", "ipinfo", "myip", "ip.sb", "ipify",
                  "icanhazip", "ifconfig.me", "ipchaxun", "whatismyip"],
}

STATIC_STRATEGIES = ("off", "on")


# 让 proxies 列表里的每个节点以 flow style（一行一个）输出，其它结构保持 block。
class _FlowMap(dict):
    pass


def _represent_flow_map(dumper, data):
    return dumper.represent_mapping("tag:yaml.org,2002:map", data, flow_style=True)


yaml.SafeDumper.add_representer(_FlowMap, _represent_flow_map)


def gen_password():
    return secrets.token_urlsafe(16)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_date(s):
    return datetime.strptime(s, "%Y-%m-%d").date()


def alloc_port(subs, defs):
    """在 [port_min, port_max] 内找最小未被占用的端口。"""
    used = {int(s["port"]) for s in subs if s.get("port")}
    lo, hi = int(defs["port_min"]), int(defs["port_max"])
    for p in range(lo, hi + 1):
        if p not in used:
            return p
    raise SystemExit(f"端口段 {lo}-{hi} 已用满（共 {hi-lo+1} 个），请扩大或删订阅")


def expected_period_start(today, reset_day):
    """给定今天和重置日，返回当前计费期的起点日期。"""
    rd = max(1, min(28, int(reset_day)))
    if today.day >= rd:
        return date(today.year, today.month, rd)
    m = today.month - 1
    y = today.year
    if m == 0:
        m, y = 12, y - 1
    return date(y, m, rd)


def fmt_bytes(n):
    n = int(n or 0)
    if n < 1024:
        return f"{n} B"
    units = ("KB", "MB", "GB", "TB")
    v = n / 1024.0
    for u in units:
        if v < 1024.0 or u == units[-1]:
            return f"{v:.2f} {u}"
        v /= 1024.0
    return f"{v:.2f} TB"


def _empty_usage():
    return {
        "period_bytes": 0,
        "total_bytes": 0,
        "last_at": "",
        "period_started": "",
    }


# ─── 外购订阅拉取 + 缓存 ───────────────────────────────────────────
EXTERNAL_CACHE_DIR = ".external_cache"
EXTERNAL_FETCH_TIMEOUT = 10
# 同一次进程内（如 render --all）共享拉取结果，避免重复 IO
_external_fetch_memo = {}


def _external_cache_paths(base, url):
    key = hashlib.sha1(url.encode("utf-8")).hexdigest()
    d = os.path.join(base, EXTERNAL_CACHE_DIR)
    return d, os.path.join(d, f"{key}.yaml"), os.path.join(d, f"{key}.meta.yaml")


def _read_cached_external(yaml_path):
    try:
        with open(yaml_path, "rb") as f:
            return yaml.safe_load(f.read()) or {}
    except (OSError, yaml.YAMLError):
        return None


def fetch_external_yaml(url, base, ttl_seconds, force=False, prefer_cache=False):
    """拉取外购 Clash yaml，失败兜底用旧缓存。返回 dict 或 None。

    缓存命中（force=False 且未过期）→ 直接读缓存
    prefer_cache=True 且本地有缓存 → 直接读缓存（不论 TTL，无网络请求）
    否则发请求（带 ETag / If-Modified-Since）：
      200  → 写新缓存 + meta
      304  → 只更新 fetched_at
      其它 → 用旧缓存（如有），否则 None
    """
    if not url:
        return None
    if url in _external_fetch_memo:
        return _external_fetch_memo[url]

    cache_dir, yaml_path, meta_path = _external_cache_paths(base, url)
    meta = load_yaml(meta_path) if os.path.exists(meta_path) else {}
    now = int(time.time())
    fetched_at = int(meta.get("fetched_at") or 0)

    # prefer_cache: 自动刷新关闭 → 有本地缓存就直接用,不发 HTTP 请求
    if prefer_cache and not force and os.path.exists(yaml_path):
        data = _read_cached_external(yaml_path)
        _external_fetch_memo[url] = data
        return data

    if (not force) and fetched_at and (now - fetched_at < max(60, int(ttl_seconds))):
        data = _read_cached_external(yaml_path)
        _external_fetch_memo[url] = data
        return data

    req = urllib.request.Request(url, headers={"User-Agent": "clash.meta"})
    if meta.get("etag"):
        req.add_header("If-None-Match", str(meta["etag"]))
    if meta.get("last_modified"):
        req.add_header("If-Modified-Since", str(meta["last_modified"]))

    try:
        with urllib.request.urlopen(req, timeout=EXTERNAL_FETCH_TIMEOUT) as resp:
            body = resp.read()
            os.makedirs(cache_dir, exist_ok=True)
            tmp = yaml_path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(body)
            os.replace(tmp, yaml_path)
            new_meta = {
                "url": url,
                "etag": resp.headers.get("ETag", ""),
                "last_modified": resp.headers.get("Last-Modified", ""),
                "fetched_at": now,
                "status": resp.status,
            }
            dump_yaml(meta_path, new_meta)
            data = _read_cached_external(yaml_path)
            _external_fetch_memo[url] = data
            return data
    except urllib.error.HTTPError as e:
        if e.code == 304 and os.path.exists(yaml_path):
            meta["fetched_at"] = now
            meta["status"] = 304
            dump_yaml(meta_path, meta)
            data = _read_cached_external(yaml_path)
            _external_fetch_memo[url] = data
            return data
        sys.stderr.write(f"[external] {url} HTTP {e.code}，使用旧缓存（如有）\n")
    except (urllib.error.URLError, OSError, ValueError) as e:
        sys.stderr.write(f"[external] {url} 拉取失败：{e}，使用旧缓存（如有）\n")

    data = _read_cached_external(yaml_path) if os.path.exists(yaml_path) else None
    _external_fetch_memo[url] = data
    return data


def resolve_external_url(sub, defs):
    """订阅级 external_url：
      - key 不存在 → 继承全局
      - 空字符串   → 显式禁用
      - 非空       → 该订阅专属
    """
    if "external_url" in sub:
        return sub["external_url"] or ""
    return defs.get("external_url", "") or ""


# ─── 静态 IP 出口（远端 socks5 outbound 资源池 + 路由策略）──────────
def _coerce_static_proxy(p):
    """把单条静态 IP 资源标准化成 dict；非 dict / 缺关键字段时返回 None。
    必填：server, port, password；type 默认 socks5；username 可选；
    annotation 可选(中英文/数字/空格/-_, 最多 12 字符,显示在节点名 risk 后 geo 前)；
    name 缺省自动生成"""
    if not isinstance(p, dict):
        return None
    server = (p.get("server") or "").strip()
    try:
        port = int(p.get("port") or 0)
    except (TypeError, ValueError):
        port = 0
    password = p.get("password")
    if not server or not (1 <= port <= 65535) or not password:
        return None
    username = (p.get("username") or "").strip() or None
    annotation = (p.get("annotation") or "").strip() or None
    if annotation:
        # 校验:不允许 : , ; 和过长(12 字符上限)
        if any(c in annotation for c in (":", ",", ";")) or len(annotation) > 12:
            annotation = None
    out = {
        "name": (p.get("name") or "").strip(),
        "type": (p.get("type") or "socks5").strip().lower(),
        "server": server,
        "port": port,
        "password": str(password),
    }
    if username:
        out["username"] = username
    if annotation:
        out["annotation"] = annotation
    return out


def parse_static_proxy_line(line):
    """解析单行字符串 → 静态 IP 资源 dict。支持：
      [annotation:]host:port:user:password   (annotation 可选)
      [annotation:]host:port:password        (无认证用户名)
    冒号段数:3 = host:port:pwd / 4 = host:port:user:pwd 或 anno:host:port:pwd /
            5 = anno:host:port:user:pwd
    其它格式返回 None。
    """
    if line is None:
        return None
    s = str(line).strip()
    if not s or s.startswith("#"):
        return None
    parts = s.split(":")
    annotation = None
    if len(parts) == 5:
        annotation, host, port, user, pwd = parts
    elif len(parts) == 4:
        # 区分 anno:host:port:pwd vs host:port:user:pwd:看第 2 段是不是端口数字
        if parts[1].isdigit() and 1 <= int(parts[1]) <= 65535:
            host, port, user, pwd = parts
        else:
            annotation, host, port, pwd = parts
            user = ""
    elif len(parts) == 3:
        host, port, pwd = parts
        user = ""
    else:
        return None
    try:
        port_n = int(port)
    except ValueError:
        return None
    return _coerce_static_proxy({
        "server": host.strip(),
        "port": port_n,
        "username": user.strip() or None,
        "password": pwd,
        "annotation": (annotation or "").strip() or None,
    })


def _static_proxy_key(p):
    """静态 IP 资源去重键:(server, port, username, password)"""
    return (p.get("server"), int(p.get("port", 0)),
            p.get("username") or "", p.get("password") or "")


def parse_static_proxies_blob(blob):
    """解析多行 / 逗号分隔的静态 IP 字符串列表 → list[dict]。
    分隔符兼容换行、逗号、分号。空行/'#' 起始行忽略。
    自动按 (server,port,user,password) 去重,保留首次出现。"""
    if blob is None:
        return []
    s = str(blob)
    for sep in (",", ";"):
        s = s.replace(sep, "\n")
    out = []
    seen = set()
    for line in s.splitlines():
        rec = parse_static_proxy_line(line)
        if not rec:
            continue
        k = _static_proxy_key(rec)
        if k in seen:
            continue
        seen.add(k)
        out.append(rec)
    return out


def _norm_static_list(raw):
    """list/None → 标准化后的 list[dict]，过滤无效项,
    按 (server,port,user,password) 去重(读取路径兜底)。"""
    if not isinstance(raw, list):
        return []
    out = []
    seen = set()
    for p in raw:
        c = _coerce_static_proxy(p)
        if c is None:
            continue
        k = _static_proxy_key(c)
        if k in seen:
            continue
        seen.add(k)
        out.append(c)
    return out


def resolve_static_proxies(sub, defs):
    """订阅级 static_proxies：与 external_url 同语义。
    返回标准化后的 list[dict]。"""
    if "static_proxies" in sub:
        return _norm_static_list(sub.get("static_proxies"))
    return _norm_static_list(defs.get("static_proxies"))


def resolve_static_strategy(sub, defs):
    v = sub.get("static_strategy") if "static_strategy" in sub else defs.get("static_strategy")
    v = (v or "off").strip().lower()
    if v in ("all", "partial", "on"):
        return "on"
    return "off"


def resolve_static_keywords(sub, defs):
    """合并预设服务包关键词 + 自定义关键词，去重保序。"""
    packs = sub.get("static_service_packs") if "static_service_packs" in sub else defs.get("static_service_packs")
    custom = sub.get("static_custom_keywords") if "static_custom_keywords" in sub else defs.get("static_custom_keywords")
    out = []
    seen = set()
    for pack in (packs or []):
        for kw in STATIC_SERVICE_PACKS.get(str(pack).strip().lower(), []):
            if kw not in seen:
                seen.add(kw)
                out.append(kw)
    for kw in (custom or []):
        kw = str(kw).strip()
        if kw and kw not in seen:
            seen.add(kw)
            out.append(kw)
    return out


def resolve_static_name_prefix(defs):
    return defs.get("static_name_prefix") or ""


def _static_user_name(sub_name, idx):
    """sing-box inbound user 名 / clash 节点 name 的稳定生成规则。
    每条静态资源对应一个 user，密码取 sub["static_passwords"][idx]。
    sing-box 据此把流量路由到同一份资源对应的远端 socks5 outbound。"""
    return f"{sub_name}--static-{idx}"


def _ensure_static_passwords(sub, defs=None):
    """根据生效的静态 IP 资源数量补齐 sub["static_passwords"]。
    静态 IP 节点共用一组 inbound user 密码（A/P 拆分已合并为单一 静态IP 组）。
    生效池：sub 自己的 static_proxies；缺失则用 defs.static_proxies（继承）。
    长度不足 → 追加 gen_password()；长度过多 → 截断尾部。
    遗留的 static_passwords_p 字段会被清掉。
    返回是否发生变更。"""
    if "static_proxies" in sub:
        proxies = _norm_static_list(sub.get("static_proxies"))
    elif defs is not None:
        proxies = _norm_static_list(defs.get("static_proxies"))
    else:
        proxies = []
    target = len(proxies)
    changed = False
    pwds = sub.get("static_passwords")
    if not isinstance(pwds, list):
        pwds = []
    while len(pwds) < target:
        pwds.append(gen_password())
        changed = True
    if len(pwds) > target:
        pwds = pwds[:target]
        changed = True
    sub["static_passwords"] = pwds
    if "static_passwords_p" in sub:
        sub.pop("static_passwords_p", None)
        changed = True
    return changed


def load_external_proxies(base, sub, defs, ttl_seconds, prefer_cache=False):
    """拉外购 yaml，提取 proxies 列表，加前缀 + 命名去重。"""
    url = resolve_external_url(sub, defs)
    if not url:
        return []
    data = fetch_external_yaml(url, base, ttl_seconds, prefer_cache=prefer_cache)
    if not isinstance(data, dict):
        return []
    raw = data.get("proxies")
    if not isinstance(raw, list):
        sys.stderr.write(f"[external] {url}：未找到 proxies 列表，跳过\n")
        return []
    prefix = defs.get("external_name_prefix") or ""
    out = []
    seen = set()
    info_nodes = []
    real_nodes = []
    for p in raw:
        if not isinstance(p, dict) or not p.get("name"):
            continue
        q = _FlowMap(p)
        new_name = f"{prefix}{p['name']}"
        base_name = new_name
        i = 1
        while new_name in seen:
            i += 1
            new_name = f"{base_name} #{i}"
        q["name"] = new_name
        seen.add(new_name)
        if _is_external_info_node(p["name"]):
            info_nodes.append(q)
        else:
            real_nodes.append(q)
    # 信息节点保持原序置顶，真节点保持机场原序
    out = info_nodes + real_nodes
    return out


# ─── IP 地理位置 → 节点名自动生成 ────────────────────────────────────
IP_GEO_CACHE_FILE = ".ip_geo_cache.yaml"
IP_GEO_FETCH_TIMEOUT = 8
IP_GEO_CACHE_TTL = 7 * 24 * 3600      # 7 天，IP 归属地不常变
IP_GEO_NEG_TTL = 3600                  # 失败负缓存 1 小时，避免频繁重试
# 进程内去重：同一次 render --all 里多个订阅共享同一 IP 只查一次
_ip_geo_memo: dict = {}


def _country_flag(code):
    """ISO 3166-1 alpha-2 → 国旗 emoji（'US' → '🇺🇸'）。"""
    if not code or len(code) != 2:
        return ""
    return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in code.upper())


def lookup_ip_geo(ip, base):
    """查询 IP 地理位置，返回 (flag, country, city)。
    结果缓存在 $BASE/.ip_geo_cache.yaml，TTL 7 天；失败负缓存 1 小时；
    同一进程内同一 IP 只查一次。失败返回 ('', '', '')。
    """
    import json as _json
    if ip in _ip_geo_memo:
        return _ip_geo_memo[ip]

    cache_path = os.path.join(base, IP_GEO_CACHE_FILE)
    cache = load_yaml(cache_path) if os.path.exists(cache_path) else {}
    now = int(time.time())

    entry = cache.get(ip)
    if isinstance(entry, dict):
        fetched_at = int(entry.get("fetched_at", 0))
        ttl = IP_GEO_NEG_TTL if entry.get("error") else IP_GEO_CACHE_TTL
        if now - fetched_at < ttl:
            result = (entry.get("flag", ""), entry.get("country", ""), entry.get("city", ""))
            _ip_geo_memo[ip] = result
            return result

    try:
        # ip-api.com: 45 req/min free, no key needed
        req = urllib.request.Request(
            f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city&lang=zh-CN",
            headers={"User-Agent": "curl/7.88.1"},
        )
        with urllib.request.urlopen(req, timeout=IP_GEO_FETCH_TIMEOUT) as resp:
            data = _json.loads(resp.read().decode("utf-8"))
        if data.get("status") != "success":
            raise ValueError(f"ip-api.com status={data.get('status')}")
        country_code = data.get("countryCode") or ""
        country = data.get("country") or ""
        city = data.get("city") or ""
        flag = _country_flag(country_code)
        entry = {"flag": flag, "country": country, "city": city, "fetched_at": now}
        cache[ip] = entry
        dump_yaml(cache_path, cache)
        result = (flag, country, city)
        _ip_geo_memo[ip] = result
        return result
    except Exception as e:
        sys.stderr.write(f"[geo] {ip} 查询失败：{e}\n")
        # 写负缓存，避免下次立即重试
        cache[ip] = {"flag": "", "country": "", "city": "", "fetched_at": now, "error": True}
        try:
            dump_yaml(cache_path, cache)
        except Exception:
            pass
        result = ("", "", "")
        _ip_geo_memo[ip] = result
        return result


def format_geo_label(server, base, display=None):
    """根据 server 地址查 IP 地理位置，返回纯文本标签：
        "🇺🇸 United States · Los Angeles (1.2.3.4)"
    server: 用于查 geo 的 IP/域名
    display: 节点名末尾 (xxx) 中显示什么；None 则用 server；""(空) 则不附 (xxx)
    server 为空时返回空串；查询失败时退化为 server 本身。"""
    if not server:
        return ""
    flag, country, city = lookup_ip_geo(server, base)
    parts = []
    if flag:
        parts.append(flag)
    if country:
        parts.append(country)
    if city and city != country:
        parts.append(f"· {city}")
    show = server if display is None else display
    if show:
        parts.append(f"({show})")
    return " ".join(parts) if parts else server


# ─── 实测节点真实出口 IP ───────────────────────────────────────────
# 节点的 server 字段往往是 LB / CDN 入口,不是真实落地 IP。
# 走真实的代理协议跑一次 ipify 才能拿到对外感知的出口 IP。
EXIT_IP_PROBE_URL = "https://api.ipify.org"
EXIT_IP_PROBE_TIMEOUT = 8
_exit_ip_memo: dict = {}   # key: ("self",) / ("static", server, port, user) → ip 或 ""


def _evict_quality_cache(base, old_ip):
    """从质量缓存中删除旧出口 IP 的记录，避免废弃 IP 占用配额。"""
    if not old_ip:
        return
    cache = _load_quality_cache(base)
    if old_ip in cache:
        del cache[old_ip]
        _save_quality_cache(base, cache)
        sys.stderr.write(f"[exit-ip] 出口 IP 变更，已删除旧质量缓存: {old_ip}\n")


def _check_exit_ip_change(track_key, new_ip, base):
    """对比持久化的上次出口 IP；若变更则清除旧 IP 质量缓存并更新记录。"""
    if not new_ip or not base:
        return
    track_path = os.path.join(base, EXIT_IP_TRACK_FILE)
    track = load_yaml(track_path) if os.path.exists(track_path) else {}
    old_ip = track.get(track_key, "")
    if old_ip and old_ip != new_ip:
        _evict_quality_cache(base, old_ip)
    if old_ip != new_ip:
        track[track_key] = new_ip
        dump_yaml(track_path, track)


def _read_cached_exit_ip(base, node_key):
    """从 .ip_quality_cache.yaml 读取 node_key 已缓存的 exit_ip;无则返回 ''."""
    if not base or not node_key:
        return ""
    cache = _load_quality_cache(base)
    entry = cache.get(node_key)
    if isinstance(entry, dict):
        return entry.get("exit_ip", "") or ""
    return ""


def _probe_self_exit_ip(base=None, prefer_cache=False):
    """VPS 本机直发 ipify,拿自建出口 IP，返回 (ip, node_key)。
    prefer_cache=True 时先读缓存里上次探测结果,未命中再 curl(避免每次 render 都跑一次)。"""
    node_key = "self"
    key = ("self",)
    if key in _exit_ip_memo:
        return _exit_ip_memo[key], node_key
    if prefer_cache:
        cached = _read_cached_exit_ip(base, node_key)
        if cached:
            _exit_ip_memo[key] = cached
            return cached, node_key
    try:
        out = subprocess.check_output(
            ["curl", "-s", "--max-time", str(EXIT_IP_PROBE_TIMEOUT), EXIT_IP_PROBE_URL],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        ip = out if out and all(c.isdigit() or c in ".:" for c in out) else ""
    except Exception:
        ip = ""
    _exit_ip_memo[key] = ip
    return ip, node_key


def _probe_static_exit_ip(server, port, username, password, base=None, prefer_cache=False):
    """通过 socks5 节点跑 ipify,拿真实落地 IP，返回 (ip, node_key)。
    prefer_cache=True 时先读缓存里上次探测结果,未命中再 curl(避免每次 render 都跑一次)。"""
    node_key = f"static:{server}:{port}:{username or ''}"
    key = ("static", server, int(port), username or "")
    if key in _exit_ip_memo:
        return _exit_ip_memo[key], node_key
    if prefer_cache:
        cached = _read_cached_exit_ip(base, node_key)
        if cached:
            _exit_ip_memo[key] = cached
            return cached, node_key
    try:
        cmd = ["curl", "-s", "--max-time", str(EXIT_IP_PROBE_TIMEOUT),
               "--socks5-hostname", f"{server}:{port}"]
        if username:
            cmd += ["-U", f"{username}:{password or ''}"]
        cmd.append(EXIT_IP_PROBE_URL)
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
        ip = out if out and all(c.isdigit() or c in ".:" for c in out) else ""
    except Exception as e:
        sys.stderr.write(f"[exit-ip] {server}:{port} 探测失败:{e}\n")
        ip = ""
    _exit_ip_memo[key] = ip
    return ip, node_key


# ─── 外购信息节点识别(机场订阅常见的"剩余流量/到期"等无效占位)─────
_EXTERNAL_INFO_KEYWORDS = (
    "剩余", "流量", "重置", "到期", "倍率", "套餐",
    "公告", "续费", "官网", "距离", "工单", "客服",
    "群组", "网址", "域名", "节点信息",
)


def _is_external_info_node(name):
    s = str(name or "")
    return any(k in s for k in _EXTERNAL_INFO_KEYWORDS)


# ─── IP 质量打分(proxycheck.io)→ 节点名后缀 ──────────────────
IP_QUALITY_CACHE_FILE = ".ip_quality_cache.yaml"
EXIT_IP_TRACK_FILE   = ".exit_ip_track.yaml"   # 持久化上次出口 IP，用于变更检测
IP_QUALITY_FETCH_TIMEOUT = 8
# IP_QUALITY_CACHE_TTL 改由 ip_quality_cache_hours 配置项动态计算
IP_QUALITY_NEG_TTL = 6 * 3600          # 失败负缓存 6 小时（避免限流时频繁重试耗配额）
_ip_quality_memo: dict = {}
_scrape_quota_exhausted = False  # 配额耗尽后本进程内跳过网页爬取
# render 路径"是否强制重新探测/评分"开关:
# - False(默认): 由 render_one 按 stats_refresh_minutes 判断 prefer_cache
# - True (cmd_render 收到 --refresh-quality 时设置): 全部走实时探测/拉取
_REFRESH_QUALITY_FLAG = False
# .ip_quality_cache.yaml 解析后的进程级内存副本(69KB YAML 反复 load 是热点)
# 第一次访问读盘,后续直接命中;同进程内写入后通过 _save_quality_cache 同步落盘
_quality_cache_memo: dict | None = None
_quality_cache_path_memo: str = ""


def _quality_cache_path(base):
    return os.path.join(base, IP_QUALITY_CACHE_FILE)


def _load_quality_cache(base):
    """读取并缓存 .ip_quality_cache.yaml 解析结果(进程级)。"""
    global _quality_cache_memo, _quality_cache_path_memo
    cp = _quality_cache_path(base)
    if _quality_cache_memo is not None and _quality_cache_path_memo == cp:
        return _quality_cache_memo
    if not os.path.exists(cp):
        _quality_cache_memo = {}
        _quality_cache_path_memo = cp
        return _quality_cache_memo
    try:
        _quality_cache_memo = load_yaml(cp) or {}
    except Exception:
        _quality_cache_memo = {}
    _quality_cache_path_memo = cp
    return _quality_cache_memo


def _save_quality_cache(base, cache):
    """落盘并更新内存副本。"""
    global _quality_cache_memo, _quality_cache_path_memo
    cp = _quality_cache_path(base)
    dump_yaml(cp, cache)
    _quality_cache_memo = cache
    _quality_cache_path_memo = cp


# proxycheck 把 ISP 大网商常误归为 Business (例: Spectrum / Comcast / 中国移动)；
# 这些关键词命中 provider/organisation 时强制视为家宽 → "宅"
_RESIDENTIAL_ISP_KEYWORDS = (
    # 美国
    "spectrum", "charter", "comcast", "xfinity", "verizon", "at&t", "att inc",
    "cox communications", "centurylink", "frontier", "windstream", "mediacom",
    # 英 / 欧 / 加 / 澳
    "british telecom", "bt group", "virgin media", "sky broadband", "talktalk",
    "deutsche telekom", "telekom", "vodafone", "orange", "telefonica",
    "kpn", "swisscom", "rogers", "telstra", "optus",
    # 日 / 韩 / 港 / 台
    "ntt", "kddi", "softbank", "nuro", "kt corp", "korea telecom", "skt",
    "pccw", "hkt", "hutchison", "smartone",
    "chunghwa", "hinet", "taiwan mobile", "fareastone",
    # 中国大陆
    "china telecom", "china unicom", "china mobile", "cnc",
    "中国电信", "中国联通", "中国移动",
    # 通用关键词（兜底）—— 不放 "communications"/"telecom" 避免机房 ISP 误判
    "broadband", "cable", "fiber", "fibre", "dsl", "fttx", "ftth",
    "wireless", "mobile",
)


def _looks_like_residential(provider, organisation):
    blob = f"{provider or ''} {organisation or ''}".lower()
    return any(k in blob for k in _RESIDENTIAL_ISP_KEYWORDS)


def _sort_by_risk(nodes, base, defs, kind_label, prefer_cache=False):
    """组内按风险升序排序：风险小(干净)排前，风险大排后，失败(score="")排末尾。
    若该 kind 检测开关关，保持原顺序。返回新 list。
    "self" 类用 VPS 本机出口 IP 作为排序依据(节点 server 可能是 LB 域名)。"""
    if not nodes or not _is_quality_enabled(defs, kind_label):
        return list(nodes)
    self_exit_ip, _self_nk = _probe_self_exit_ip(base=base, prefer_cache=prefer_cache) if kind_label == "self" else ("", "self")
    def _key(n):
        if kind_label == "self":
            target, nk = self_exit_ip, _self_nk
        else:
            target, nk = n.get("server", ""), None
        if not target:
            return (1, 0, 0)
        _, score = lookup_ip_quality(target, base, defs, node_key=nk, prefer_cache=prefer_cache)
        if score == "" or score is None:
            return (1, 0, 0)
        return (0, int(score), 0)
    return sorted(nodes, key=_key)
    """返回 (kind, score, type_raw) 或抛异常。
    scamalytics V3 返回 score 0-100(越小越干净),risk文字,connection.type。
    score 直接用作风险分(0=干净=好,100=高危=差)。"""
    import json as _json
    sep = "&" if "?" in base_url else "?"
    url = f"{base_url}{sep}ip={ip}"
    req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = _json.loads(resp.read().decode("utf-8"))
    if (data.get("status") or "ok") not in ("ok", "OK", "success", "", None):
        raise ValueError(f"scamalytics status={data.get('status')} err={data.get('error')}")
    fraud = data.get("score")
    if fraud is None and isinstance(data.get("scamalytics"), dict):
        fraud = data["scamalytics"].get("scamalytics_score")
    if fraud is None:
        raise ValueError(f"scamalytics 响应无 score 字段: {list(data.keys())}")
    score = max(0, min(100, int(fraud)))
    type_raw = ""
    conn = data.get("connection") or {}
    if isinstance(conn, dict):
        type_raw = conn.get("type") or conn.get("connection_type") or ""
    if not type_raw:
        type_raw = data.get("connection_type") or ""
    t = (type_raw or "").lower()
    kind = "宅" if any(x in t for x in ("residential", "isp", "broadband", "cable", "dsl", "mobile")) else "机"
    return kind, score, type_raw or "Unknown"


def _quality_via_lookup_scrape(ip, timeout):
    """爬 https://proxycheck.io/lookup/IP 网页,解析综合风险分。
    网页比 API 多一个综合评分(基于 type+history+ASN 干净度),
    例如 hosting datacenter 网页给 33,API 给 0/66。
    返回 (kind, score, type_raw) 或抛异常。"""
    import re as _re
    url = f"https://proxycheck.io/lookup/{ip}"
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        html = resp.read().decode("utf-8", errors="replace")
    # 优先匹配长描述句里的 "risk score of N%"
    m = _re.search(r'risk score of (\d+)%', html)
    if not m:
        # 备选：data-copy="N%" （独立百分比字段）
        m = _re.search(r'data-copy="(\d+)%"', html)
    if not m:
        if "queries exhausted" in html:
            raise RuntimeError("proxycheck_quota_exhausted")
        raise ValueError("lookup 页未找到 risk score")
    score = max(0, min(100, int(m.group(1))))
    # type 字段:页面里有 data-copy="Hosting." / "Residential." / "Business." 等
    # (一个简短词 + 句号),要避开第一个长描述句
    type_raw = ""
    tm = _re.search(
        r'data-copy="(Hosting|Residential|Business|VPN|Mobile|Wireless|Compromised[^.]*?|Public[^.]*?|Datacenter|ISP)\.?"',
        html)
    if tm:
        type_raw = tm.group(1).strip()
    t = type_raw.lower()
    # provider/org 用 "operated by XXX" 句式提取做 ISP 兜底
    pm = _re.search(r'operated by ([^.<]{2,80})', html)
    provider = pm.group(1).strip() if pm else ""
    if t == "residential" or "mobile" in t or "wireless" in t \
            or _looks_like_residential(provider, ""):
        kind = "宅"
    else:
        kind = "机"
    return kind, score, type_raw or "Unknown"


def _quality_via_proxycheck(ip, api_key, timeout):
    """返回 (kind, score, type_raw) 或抛异常。
    使用 risk=1 但不启用 vpn=1 严格模式;vpn=1 会强制 datacenter range 一律打 66 分,
    与 proxycheck 网页 /lookup 显示不一致。不带 vpn 时 type 字段更细
    (Residential/Business/Hosting/...),risk 体现真实历史滥用。
    """
    import json as _json
    qs = "risk=1&asn=1&node=0"
    if api_key:
        qs += f"&key={api_key}"
    url = f"https://proxycheck.io/v2/{ip}?{qs}"
    req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88.1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = _json.loads(resp.read().decode("utf-8"))
    if data.get("status") != "ok":
        raise ValueError(f"proxycheck status={data.get('status')} msg={data.get('message')}")
    info = data.get(ip) or {}
    t = (info.get("type") or "").strip().lower()
    provider = info.get("provider") or ""
    organisation = info.get("organisation") or ""
    if t == "residential" or _looks_like_residential(provider, organisation):
        kind = "宅"
    else:
        kind = "机"
    risk = int(info.get("risk", 0))
    score = max(0, min(100, risk))  # 风险分:0=干净,100=高危
    return kind, score, info.get("type", "")


def lookup_ip_quality(host, base, defs=None, node_key=None, prefer_cache=False):
    """查询 host 的类型 + 风险分，返回 (kind, score)。
    node_key: 节点唯一标识（"self" / "static:server:port:user"），用于出口 IP 变更检测。
    缓存以 node_key 为主键（无 node_key 时退化为 IP 键，向后兼容）。
    出口 IP 变更 → 复位评分；评分未过期 → 跳过查询。
    prefer_cache=True 时只要缓存里有非空评分就直接复用,忽略 24h TTL;
    缓存未命中(新静态 IP) 仍 fetch 一次写入缓存。
    """
    import socket as _socket
    memo_key = node_key or host
    if memo_key in _ip_quality_memo:
        return _ip_quality_memo[memo_key]

    try:
        ip = _socket.gethostbyname(host)
    except Exception as e:
        sys.stderr.write(f"[quality] {host} DNS 解析失败：{e}\n")
        result = ("", "")
        _ip_quality_memo[memo_key] = result
        return result

    cache_path = _quality_cache_path(base)
    cache = _load_quality_cache(base)
    now = int(time.time())
    cache_key = node_key or ip

    entry = cache.get(cache_key)
    if isinstance(entry, dict):
        # 出口 IP 变更时复位评分
        if node_key and entry.get("exit_ip") and entry["exit_ip"] != ip:
            sys.stderr.write(f"[quality] {node_key} 出口 IP 变更 {entry['exit_ip']} → {ip}，复位评分\n")
            entry = None
        else:
            fetched_at = int(entry.get("fetched_at", 0))
            cache_hours = int((defs or {}).get("ip_quality_cache_hours", 24))
            ttl = IP_QUALITY_NEG_TTL if entry.get("error") else (cache_hours * 3600)
            # prefer_cache: 自动刷新关闭 → 有非空评分就用,不看 TTL
            if prefer_cache and not entry.get("error") and entry.get("kind") != "":
                result = (entry.get("kind", ""), entry.get("score", ""))
                _ip_quality_memo[memo_key] = result
                return result
            if now - fetched_at < ttl:
                result = (entry.get("kind", ""), entry.get("score", ""))
                _ip_quality_memo[memo_key] = result
                return result

    scama = ((defs or {}).get("scamalytics_url") or "").strip()
    proxy_key = ((defs or {}).get("proxycheck_api_key") or "").strip()
    src_pref = str((defs or {}).get("quality_source", "free")).strip().lower()
    use_scama = src_pref == "scamalytics" and bool(scama)
    use_scrape = src_pref == "lookup_scrape"
    source = "none"
    try:
        if use_scama:
            kind, score, type_raw = _quality_via_scamalytics(ip, scama, IP_QUALITY_FETCH_TIMEOUT)
            source = "scamalytics"
        elif use_scrape:
            global _scrape_quota_exhausted
            if _scrape_quota_exhausted:
                kind, score, type_raw = _quality_via_proxycheck(ip, proxy_key, IP_QUALITY_FETCH_TIMEOUT)
                source = "proxycheck_fallback"
            else:
                try:
                    kind, score, type_raw = _quality_via_lookup_scrape(ip, IP_QUALITY_FETCH_TIMEOUT)
                    source = "lookup_scrape"
                except RuntimeError as _quota_err:
                    if "quota_exhausted" in str(_quota_err):
                        _scrape_quota_exhausted = True
                        sys.stderr.write("[quality] proxycheck 网页配额已耗尽，本次渲染回退 API\n")
                        kind, score, type_raw = _quality_via_proxycheck(ip, proxy_key, IP_QUALITY_FETCH_TIMEOUT)
                        source = "proxycheck_fallback"
                    else:
                        raise
                except Exception as _scrape_err:
                    sys.stderr.write(f"[quality] {ip} lookup_scrape 失败({_scrape_err})，回退 proxycheck\n")
                    kind, score, type_raw = _quality_via_proxycheck(ip, proxy_key, IP_QUALITY_FETCH_TIMEOUT)
                    source = "proxycheck_fallback"
        else:
            kind, score, type_raw = _quality_via_proxycheck(ip, proxy_key, IP_QUALITY_FETCH_TIMEOUT)
            source = "proxycheck"
        new_entry = {"exit_ip": ip, "kind": kind, "score": score,
                     "type_raw": type_raw, "source": source, "fetched_at": now}
        cache[cache_key] = new_entry
        _save_quality_cache(base, cache)
        result = (kind, score)
        _ip_quality_memo[memo_key] = result
        return result
    except Exception as e:
        sys.stderr.write(f"[quality] {host} ({ip}) {source or 'lookup'} 失败：{e}\n")
        cache[cache_key] = {"exit_ip": ip, "kind": "", "score": "", "source": source,
                            "fetched_at": now, "error": True}
        try:
            _save_quality_cache(base, cache)
        except Exception:
            pass
        result = ("", "")
        _ip_quality_memo[memo_key] = result
        return result


def _is_exit_ip_show_enabled(defs, kind_label):
    """检查出口 IP 显示开关。kind_label: self / static。
    总关 → False；总开 + 单类关 → False。"""
    if not defs:
        return False
    if str(defs.get("exit_ip_show_enabled", "on")).strip().lower() != "on":
        return False
    per_key = {
        "self":   "exit_ip_show_for_self",
        "static": "exit_ip_show_for_static",
    }.get(kind_label)
    if per_key is None:
        return True
    return str(defs.get(per_key, "on")).strip().lower() == "on"


def _is_quality_enabled(defs, kind_label):
    """检查 IP 检测开关。kind_label: self / external / static。
    总关 = 都跳过；总开 + 单类关 = 该类跳过。"""
    if not defs:
        return False
    if str(defs.get("quality_check_enabled", "off")).strip().lower() != "on":
        return False
    per_key = {
        "self":     "quality_check_for_self",
        "external": "quality_check_for_external",
        "static":   "quality_check_for_static",
    }.get(kind_label)
    if per_key is None:
        return True
    return str(defs.get(per_key, "on")).strip().lower() == "on"


def format_quality_suffix(server, base, defs=None, kind_label=None, node_key=None, prefer_cache=False):
    """节点名后缀，格式：(宅-85) / (机-12) / (?-?)（查询失败）。
    kind_label 指定该节点类别 self/external/static 用于检查分项开关；
    传 None 则只看总开关；server 为空或开关关闭返回空串。"""
    if not server:
        return ""
    if kind_label is not None and not _is_quality_enabled(defs, kind_label):
        return ""
    if kind_label is None and defs is not None and \
            str(defs.get("quality_check_enabled", "off")).strip().lower() != "on":
        return ""
    kind, score = lookup_ip_quality(server, base, defs, node_key=node_key, prefer_cache=prefer_cache)
    if kind == "" or score == "":
        return "(?-?)"
    return f"({kind}-{score})"


def auto_node_name(node, base, defs=None, prefer_cache=False):
    """节点 name 为空时，根据 server 地址自动生成显示名。
    格式：[自建](机-23) 🇺🇸 United States · Los Angeles (199.193.124.234)
    server 字段可能是域名(LB)，所以 geo / quality 都基于 VPS 真实出口 IP。
    出口 IP 显示开关关时，末尾 (IP) 隐藏。
    """
    name = (node.get("name") or "").strip()
    if name:
        return name
    raw_server = node.get("server", "")
    # 自建出口 = VPS 本机出口（无论 server 写的是 IP 还是域名）
    exit_ip, _self_nk = _probe_self_exit_ip(base=base, prefer_cache=prefer_cache) if (_is_quality_enabled(defs, "self") or _is_exit_ip_show_enabled(defs, "self")) else ("", "self")
    target = exit_ip or raw_server
    show_ip = _is_exit_ip_show_enabled(defs, "self")
    display = (exit_ip or raw_server) if show_ip else ""
    label = format_geo_label(target, base, display=display)
    quality = format_quality_suffix(target, base, defs, kind_label="self", node_key=_self_nk, prefer_cache=prefer_cache)
    if not label:
        return f"[自建]{quality}" if quality else "[自建]"
    return f"[自建]{quality} {label}" if quality else f"[自建] {label}"


def _normalize_sub(sub, defs, subs_for_port_alloc=None):
    """补齐缺失字段（老 subs.yaml 兼容），不覆盖已有值。
    subs_for_port_alloc: 在批量 normalize 时传入已处理列表，避免端口分配冲突。"""
    sub.setdefault("password", gen_password())
    sub.setdefault("traffic_gb", defs["traffic_gb"])
    sub.setdefault("reset_day", defs["reset_day"])
    sub.setdefault("expire", default_expire(defs["expire_days"]))
    sub.setdefault("update_interval_hours", defs["update_interval_hours"])
    sub.setdefault("nodes", [])
    sub.setdefault("disabled", False)
    if not sub.get("port"):
        sub["port"] = alloc_port(subs_for_port_alloc or [], defs)
    u = sub.get("usage")
    if not isinstance(u, dict):
        u = _empty_usage()
    for k, v in _empty_usage().items():
        u.setdefault(k, v)
    if not u["period_started"]:
        u["period_started"] = expected_period_start(date.today(), sub["reset_day"]).isoformat()
    sub["usage"] = u
    # 静态 IP：standardize 后回写 sub（去掉脏数据），并按数量补齐 inbound user 密码
    if "static_proxies" in sub:
        sub["static_proxies"] = _norm_static_list(sub.get("static_proxies"))
    _ensure_static_passwords(sub, defs)
    return sub


# ─── 路径辅助 ──────────────────────────────────────────────────────
def paths(base):
    return {
        "subs": os.path.join(base, "subs.yaml"),
        "defaults": os.path.join(base, "defaults.yaml"),
        "nodes": os.path.join(base, "nodes.yaml"),
        "template": os.path.join(base, "template.yaml"),
        "output": os.path.join(base, "output"),
    }


def load_yaml(path, default=None):
    if not os.path.exists(path):
        return default if default is not None else {}
    with open(path) as f:
        return yaml.safe_load(f) or (default if default is not None else {})


def dump_yaml(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False, width=4096)
    os.replace(tmp, path)


# ─── 订阅 / 默认值读写 ─────────────────────────────────────────────
def read_defaults(base):
    d = load_yaml(paths(base)["defaults"]).get("defaults", {})
    out = dict(BUILTIN_DEFAULTS)
    # list/dict 型字段拷副本，避免 BUILTIN_DEFAULTS 被外部 mutation
    for k, v in BUILTIN_DEFAULTS.items():
        if isinstance(v, (list, dict)):
            out[k] = list(v) if isinstance(v, list) else dict(v)
    out.update({k: d[k] for k in BUILTIN_DEFAULTS if k in d})

    # 向后兼容：旧配置无 refresh_mode 时根据 stats_refresh_minutes 推断
    if "refresh_mode" not in d:
        mins = int(out.get("stats_refresh_minutes", 10))
        out["refresh_mode"] = "off" if mins == 0 else "interval"

    return out


def write_defaults(base, d):
    dump_yaml(paths(base)["defaults"], {"defaults": d})


def read_subs(base):
    return load_yaml(paths(base)["subs"]).get("subscriptions", [])


def read_subs_normalized(base):
    """补齐字段后的视图。批量处理，避免端口分配冲突。"""
    defs = read_defaults(base)
    subs = read_subs(base)
    processed = []
    for s in subs:
        _normalize_sub(s, defs, subs_for_port_alloc=processed)
        processed.append(s)
    return subs


def write_subs(base, subs):
    dump_yaml(paths(base)["subs"], {"subscriptions": subs})


def find_sub(subs, name):
    for s in subs:
        if s.get("name") == name:
            return s
    return None


def gen_token():
    return secrets.token_hex(16)


def default_expire(days):
    return (date.today() + timedelta(days=int(days))).strftime("%Y-%m-%d")


# ─── init ──────────────────────────────────────────────────────────
def cmd_init(args):
    base = args.base
    os.makedirs(paths(base)["output"], exist_ok=True)
    if not os.path.exists(paths(base)["defaults"]):
        write_defaults(base, BUILTIN_DEFAULTS)
        print(f"created {paths(base)['defaults']}")
    if not os.path.exists(paths(base)["subs"]):
        write_subs(base, [])
        print(f"created {paths(base)['subs']}")
    return 0


# ─── list / show ───────────────────────────────────────────────────
def fmt_sub(s, defs=None):
    u = s.get("usage") or _empty_usage()
    total_gb = int(s.get("traffic_gb", 0))
    total_bytes = total_gb * 1024 * 1024 * 1024
    period = int(u.get("period_bytes") or 0)
    cum = int(u.get("total_bytes") or 0)
    pct = (period / total_bytes * 100) if total_bytes else 0.0
    state = "停用" if s.get("disabled") else "启用"
    last = u.get("last_at") or "-"
    period_started = u.get("period_started") or "-"
    # 外购源显示
    if "external_url" in s:
        ext_line = s["external_url"] or "(显式禁用)"
    else:
        gdef = (defs or {}).get("external_url", "")
        ext_line = f"(继承默认: {gdef})" if gdef else "(未启用)"
    # 静态 IP 出口显示
    strategy = resolve_static_strategy(s, defs or {})
    own_static = "static_proxies" in s
    static_list = resolve_static_proxies(s, defs or {})
    if own_static and not static_list:
        static_src = "(显式禁用)"
    elif own_static:
        static_src = "(订阅独立)"
    elif static_list:
        static_src = "(继承默认)"
    else:
        static_src = "(未配置)"
    static_lines = []
    static_lines.append(f"      静态 IP 策略: {strategy}  {static_src}")
    if static_list:
        for i, p in enumerate(static_list, 1):
            user = p.get("username") or "-"
            static_lines.append(f"        [{i}] {p['server']}:{p['port']} user={user}")
    else:
        static_lines.append("        (无资源)")
    # 服务包 / 关键词（仅 on 模式生效，但都展示）
    packs = s.get("static_service_packs") if "static_service_packs" in s else (defs or {}).get("static_service_packs") or []
    kws = s.get("static_custom_keywords") if "static_custom_keywords" in s else (defs or {}).get("static_custom_keywords") or []
    static_lines.append(f"      静态 IP 服务包: {','.join(packs) if packs else '(无)'}")
    static_lines.append(f"      静态 IP 关键词: {','.join(kws) if kws else '(无)'}")
    return (
        f"  - {s['name']}\n"
        f"      token       : {s['token']}\n"
        f"      端口        : {s.get('port', '?')}\n"
        f"      password    : {s.get('password', '?')}\n"
        f"      状态        : {state}\n"
        f"      流量上限    : {total_gb} GB\n"
        f"      本期已用    : {fmt_bytes(period)} ({pct:.2f}%)\n"
        f"      累计已用    : {fmt_bytes(cum)}\n"
        f"      流量重置日  : 每月 {s.get('reset_day', '?')} 号\n"
        f"      本期起算    : {period_started}\n"
        f"      统计更新于  : {last}\n"
        f"      到期        : {s.get('expire', '?')}\n"
        f"      客户端拉取  : 每 {s.get('update_interval_hours', '?')} 小时\n"
        f"      节点过滤    : {s.get('nodes') or '(全部)'}\n"
        f"      外购源      : {ext_line}\n"
        + "\n".join(static_lines)
    )


def fmt_sub_brief(s):
    u = s.get("usage") or _empty_usage()
    total_gb = int(s.get("traffic_gb", 0))
    total_bytes = total_gb * 1024 * 1024 * 1024
    period = int(u.get("period_bytes") or 0)
    pct = (period / total_bytes * 100) if total_bytes else 0.0
    state = "停用" if s.get("disabled") else "启用"
    return f"  - {s['name']:<16}  :{s.get('port', '?')}  {fmt_bytes(period)} / {total_gb} GB ({pct:.1f}%)  到期 {s.get('expire', '-')}  [{state}]"


def cmd_list(args):
    subs = read_subs_normalized(args.base)
    if not subs:
        print("(尚无订阅)")
        return 0
    if getattr(args, "brief", False):
        print(f"共 {len(subs)} 条订阅:")
        for s in subs:
            print(fmt_sub_brief(s))
    elif getattr(args, "names", False):
        for s in subs:
            print(s["name"])
    else:
        print(f"共 {len(subs)} 条订阅:")
        defs = read_defaults(args.base)
        for s in subs:
            print(fmt_sub(s, defs))
    return 0


def cmd_show(args):
    s = find_sub(read_subs_normalized(args.base), args.name)
    if not s:
        print(f"未找到订阅: {args.name}", file=sys.stderr)
        return 1
    print(fmt_sub(s, read_defaults(args.base)))
    return 0


# ─── add / edit / remove ───────────────────────────────────────────
def apply_fields(sub, args, defs, creating, all_subs):
    """all_subs: 当前订阅列表（不含正在添加的 sub），用于端口冲突检查。"""
    if creating:
        sub.setdefault("password", gen_password())
        sub.setdefault("traffic_gb", defs["traffic_gb"])
        sub.setdefault("reset_day", defs["reset_day"])
        sub.setdefault("expire", default_expire(defs["expire_days"]))
        sub.setdefault("update_interval_hours", defs["update_interval_hours"])
        sub.setdefault("nodes", [])
        sub.setdefault("disabled", False)
        sub.setdefault("usage", _empty_usage())
        sub["usage"]["period_started"] = expected_period_start(
            date.today(), sub["reset_day"]
        ).isoformat()
    if args.traffic_gb is not None:
        sub["traffic_gb"] = int(args.traffic_gb)
    if args.reset_day is not None:
        rd = int(args.reset_day)
        if not 1 <= rd <= 31:
            raise SystemExit("reset_day 必须 1-31")
        sub["reset_day"] = rd
        sub.setdefault("usage", _empty_usage())
        sub["usage"]["period_started"] = expected_period_start(
            date.today(), rd
        ).isoformat()
    if args.expire is not None:
        datetime.strptime(args.expire, "%Y-%m-%d")
        sub["expire"] = args.expire
    if args.interval is not None:
        sub["update_interval_hours"] = int(args.interval)
    if getattr(args, "password", None) is not None:
        if not args.password:
            raise SystemExit("password 不能为空")
        sub["password"] = args.password
    if getattr(args, "port", None) is not None:
        p = int(args.port)
        if not 1 <= p <= 65535:
            raise SystemExit("port 必须 1-65535")
        for other in all_subs:
            if other is sub:
                continue
            if int(other.get("port", 0)) == p:
                raise SystemExit(f"端口 {p} 已被订阅 {other['name']} 占用")
        sub["port"] = p
    elif creating and "port" not in sub:
        sub["port"] = alloc_port(all_subs, defs)
    if getattr(args, "external_url", None) is not None:
        # "-" 表示清空，让该订阅回到继承全局；空串表示显式禁用；其它字符串覆盖
        if args.external_url == "-":
            sub.pop("external_url", None)
        else:
            # 与当前生效值完全相同则跳过，避免触发不必要的重渲染 / reload
            if sub.get("external_url") != args.external_url:
                sub["external_url"] = args.external_url
    # ── 静态 IP 出口 ────────────────────────────────────────────────
    if getattr(args, "static_strategy", None) is not None:
        v = args.static_strategy
        if v == "-":
            sub.pop("static_strategy", None)
        else:
            v = v.strip().lower()
            if v not in STATIC_STRATEGIES:
                raise SystemExit(f"static_strategy 必须是 {'/'.join(STATIC_STRATEGIES)}")
            sub["static_strategy"] = v
    if getattr(args, "static_service_packs", None) is not None:
        v = args.static_service_packs
        if v == "-":
            sub.pop("static_service_packs", None)
        else:
            packs = [p.strip().lower() for p in v.split(",") if p.strip()]
            unknown = [p for p in packs if p not in STATIC_SERVICE_PACKS]
            if unknown:
                raise SystemExit(f"未知服务包: {', '.join(unknown)}（可选: {', '.join(sorted(STATIC_SERVICE_PACKS))}）")
            sub["static_service_packs"] = packs
    if getattr(args, "static_custom_keywords", None) is not None:
        v = args.static_custom_keywords
        if v == "-":
            sub.pop("static_custom_keywords", None)
        else:
            kws = [k.strip() for k in v.split(",") if k.strip()]
            sub["static_custom_keywords"] = kws
    if getattr(args, "static_proxies", None) is not None:
        v = args.static_proxies
        if v == "-":
            # 清空 → 回继承全局 + 重置每订阅密码
            sub.pop("static_proxies", None)
            sub.pop("static_passwords", None)
            sub.pop("static_passwords_p", None)
        else:
            parsed = parse_static_proxies_blob(v)
            sub["static_proxies"] = parsed
            # 资源数量变了，密码列表跟着重算
            sub.pop("static_passwords", None)
            sub.pop("static_passwords_p", None)
            _ensure_static_passwords(sub, defs)
    # 增量追加：--static-proxy-add 可多次出现
    adds = getattr(args, "static_proxy_add", None) or []
    rems = getattr(args, "static_proxy_remove", None) or []
    if adds or rems:
        # 在现有基础上增删；若 sub 还没显式 static_proxies，则从默认值拷一份当起点
        cur = list(_norm_static_list(sub.get("static_proxies"))) if "static_proxies" in sub \
              else list(_norm_static_list(defs.get("static_proxies")))
        # 删除:支持索引(1 起算)或 server:port 匹配。
        # 索引类先全部收集再降序删,避免每删一项后续索引漂移
        idx_tokens = []
        host_tokens = []
        for token in rems:
            t = str(token).strip()
            if not t:
                continue
            if t.isdigit():
                idx_tokens.append((t, int(t) - 1))
            else:
                host_tokens.append(t)
        for raw, idx in sorted(idx_tokens, key=lambda x: -x[1]):
            if 0 <= idx < len(cur):
                cur.pop(idx)
            else:
                raise SystemExit(f"未找到要删除的静态 IP: {raw}（索引越界,共 {len(cur) + len([t for t in idx_tokens if 0 <= t[1] < len(cur)])} 条）")
        for t in host_tokens:
            removed = False
            if ":" in t:
                host, _, port = t.partition(":")
                try:
                    port_n = int(port)
                except ValueError:
                    port_n = -1
                for i, p in enumerate(cur):
                    if p.get("server") == host and int(p.get("port", 0)) == port_n:
                        cur.pop(i)
                        removed = True
                        break
            if not removed:
                raise SystemExit(f"未找到要删除的静态 IP: {t}（用 1 起算的索引或 host:port）")
        # 追加：每个 token 可能含多行/多条
        # 完全相同的 (server, port, username, password) 跳过，避免重复
        def _sp_key(p):
            return (p.get("server"), int(p.get("port", 0)),
                    p.get("username") or "", p.get("password") or "")
        seen_keys = {_sp_key(p) for p in cur}
        skipped = 0
        for blob in adds:
            for rec in parse_static_proxies_blob(blob):
                k = _sp_key(rec)
                if k in seen_keys:
                    skipped += 1
                    continue
                seen_keys.add(k)
                cur.append(rec)
        if skipped:
            print(f"[static_proxies] 跳过 {skipped} 条重复资源（同 host:port:user:pwd）")
        sub["static_proxies"] = cur
        # 数量变了 → 让 _ensure_static_passwords 按新长度补齐 / 截断
        _ensure_static_passwords(sub, defs)


def cmd_add(args):
    subs = read_subs(args.base)
    if find_sub(subs, args.name):
        print(f"订阅已存在: {args.name}", file=sys.stderr)
        return 1
    defs = read_defaults(args.base)
    sub = {"name": args.name, "token": args.token or gen_token()}
    apply_fields(sub, args, defs, creating=True, all_subs=subs)
    subs.append(sub)
    write_subs(args.base, subs)
    print(f"已新增订阅: {args.name} (token={sub['token']}, port={sub['port']})")
    return 0


def cmd_edit(args):
    subs = read_subs(args.base)
    s = find_sub(subs, args.name)
    if not s:
        print(f"未找到订阅: {args.name}", file=sys.stderr)
        return 1
    defs = read_defaults(args.base)
    apply_fields(s, args, defs, creating=False, all_subs=subs)
    if args.rename:
        if args.rename != args.name and find_sub(subs, args.rename):
            print(f"目标名已存在: {args.rename}", file=sys.stderr)
            return 1
        s["name"] = args.rename
    write_subs(args.base, subs)
    print(f"已更新订阅: {s['name']}")
    return 0


def cmd_remove(args):
    subs = read_subs(args.base)
    s = find_sub(subs, args.name)
    if not s:
        print(f"未找到订阅: {args.name}", file=sys.stderr)
        return 1
    subs.remove(s)
    write_subs(args.base, subs)
    out_dir = os.path.join(paths(args.base)["output"], s["token"])
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir, ignore_errors=True)
    print(f"已删除订阅: {args.name}")
    return 0


# ─── defaults ──────────────────────────────────────────────────────
def cmd_defaults(args):
    defs = read_defaults(args.base)
    changed = False
    for key, attr in (
        ("traffic_gb", "traffic_gb"),
        ("reset_day", "reset_day"),
        ("expire_days", "expire_days"),
        ("update_interval_hours", "interval"),
        ("stats_refresh_minutes", "stats_refresh_minutes"),
        ("port_min", "port_min"),
        ("port_max", "port_max"),
        ("external_url", "external_url"),
        ("external_name_prefix", "external_name_prefix"),
        ("static_strategy", "static_strategy"),
        ("static_name_prefix", "static_name_prefix"),
        ("quality_check_enabled", "quality_check_enabled"),
        ("quality_check_for_self", "quality_check_for_self"),
        ("quality_check_for_static", "quality_check_for_static"),
        ("quality_source", "quality_source"),
        ("exit_ip_show_enabled", "exit_ip_show_enabled"),
        ("exit_ip_show_for_self", "exit_ip_show_for_self"),
        ("exit_ip_show_for_static", "exit_ip_show_for_static"),
        ("scamalytics_url", "scamalytics_url"),
        ("proxycheck_api_key", "proxycheck_api_key"),
        ("refresh_mode", "refresh_mode"),
        ("daily_refresh_time", "daily_refresh_time"),
        ("refresh_force_recheck", "refresh_force_recheck"),
        ("ip_quality_cache_hours", "ip_quality_cache_hours"),
    ):
        v = getattr(args, attr, None)
        if v is None:
            continue
        new_v = int(v) if key in INT_DEFAULT_KEYS else str(v)
        if defs.get(key) == new_v:
            continue
        defs[key] = new_v
        changed = True
    # 静态 IP 策略校验
    if "static_strategy" in defs:
        if str(defs["static_strategy"]).strip().lower() not in STATIC_STRATEGIES:
            raise SystemExit(f"static_strategy 必须是 {'/'.join(STATIC_STRATEGIES)}")
    # IP 质量检测 on/off 字段标准化
    for k in QUALITY_BOOL_KEYS:
        if k in defs:
            v = str(defs[k]).strip().lower()
            if v not in ("on", "off"):
                raise SystemExit(f"{k} 必须是 on/off")
            defs[k] = v
    if "quality_source" in defs:
        v = str(defs["quality_source"]).strip().lower()
        if v not in QUALITY_SOURCES:
            raise SystemExit(f"quality_source 必须是 {'/'.join(QUALITY_SOURCES)}")
        defs["quality_source"] = v
    # refresh_mode 校验
    if "refresh_mode" in defs:
        v = str(defs["refresh_mode"]).strip().lower()
        if v not in REFRESH_MODES:
            raise SystemExit(f"refresh_mode 必须是 {'/'.join(REFRESH_MODES)}")
        defs["refresh_mode"] = v
    # 列表型字段：逗号分隔 → list
    for key, attr in (
        ("static_service_packs", "static_service_packs"),
        ("static_custom_keywords", "static_custom_keywords"),
    ):
        v = getattr(args, attr, None)
        if v is None:
            continue
        items = [x.strip() for x in str(v).split(",") if x.strip()]
        if key == "static_service_packs":
            unknown = [p for p in items if p.lower() not in STATIC_SERVICE_PACKS]
            if unknown:
                raise SystemExit(f"未知服务包: {', '.join(unknown)}（可选: {', '.join(sorted(STATIC_SERVICE_PACKS))}）")
            items = [p.lower() for p in items]
        defs[key] = items
        changed = True
    # 静态 IP 资源池（默认值）：blob 解析或增量
    if getattr(args, "static_proxies", None) is not None:
        defs["static_proxies"] = parse_static_proxies_blob(args.static_proxies)
        changed = True
    adds = getattr(args, "static_proxy_add", None) or []
    rems = getattr(args, "static_proxy_remove", None) or []
    if adds or rems:
        cur = list(_norm_static_list(defs.get("static_proxies")))
        # 索引类先全部收集再降序删,避免每删一项后续索引漂移
        idx_tokens = []
        host_tokens = []
        for token in rems:
            t = str(token).strip()
            if not t:
                continue
            if t.isdigit():
                idx_tokens.append((t, int(t) - 1))
            else:
                host_tokens.append(t)
        for raw, idx in sorted(idx_tokens, key=lambda x: -x[1]):
            if 0 <= idx < len(cur):
                cur.pop(idx)
            else:
                raise SystemExit(f"未找到要删除的静态 IP: {raw}（索引越界）")
        for t in host_tokens:
            removed = False
            if ":" in t:
                host, _, port = t.partition(":")
                try:
                    port_n = int(port)
                except ValueError:
                    port_n = -1
                for i, p in enumerate(cur):
                    if p.get("server") == host and int(p.get("port", 0)) == port_n:
                        cur.pop(i); removed = True; break
            if not removed:
                raise SystemExit(f"未找到要删除的静态 IP: {t}（用 1 起算的索引或 host:port）")
        def _sp_key(p):
            return (p.get("server"), int(p.get("port", 0)),
                    p.get("username") or "", p.get("password") or "")
        seen_keys = {_sp_key(p) for p in cur}
        skipped = 0
        for blob in adds:
            for rec in parse_static_proxies_blob(blob):
                k = _sp_key(rec)
                if k in seen_keys:
                    skipped += 1
                    continue
                seen_keys.add(k)
                cur.append(rec)
        if skipped:
            print(f"[static_proxies] 跳过 {skipped} 条重复资源（同 host:port:user:pwd）")
        defs["static_proxies"] = cur
        changed = True
    if changed:
        write_defaults(args.base, defs)
        print("默认值已更新")
    print("当前默认值:")
    for k, v in defs.items():
        print(f"  {k}: {v}")
    return 0


# ─── render ────────────────────────────────────────────────────────
def days_until_reset(reset_day):
    today = date.today()
    if reset_day < today.day:
        m = today.month + 1
        y = today.year + (1 if m > 12 else 0)
        m = ((m - 1) % 12) + 1
    else:
        m, y = today.month, today.year
    return (date(y, m, min(reset_day, 28)) - today).days


def make_proxy(name, n, password=None, port=None):
    return _FlowMap({
        "name": name,
        "type": n.get("type", "anytls"),
        "server": n["server"],
        "port": port if port is not None else n["port"],
        "password": password if password is not None else n["password"],
        "udp": True,
        "sni": n.get("sni", "baidu.com"),
        "skip-cert-verify": bool(n.get("skip_cert_verify", True)),
    })


def make_static_proxy(name, sub_password, sub_port, vps_server, sni):
    """静态 IP 节点：客户端看到的还是连本机 anytls，server/port 都是本机；
    password 用 sub["static_passwords"][i]，让 sing-box 据此把流量路由去对应的远端 outbound。"""
    return _FlowMap({
        "name": name,
        "type": "anytls",
        "server": vps_server,
        "port": sub_port,
        "password": sub_password,
        "udp": True,
        "sni": sni or vps_server,
        "skip-cert-verify": True,
    })


def render_one(base, sub):
    p = paths(base)
    nodes = load_yaml(p["nodes"]).get("nodes", [])
    if sub.get("nodes"):
        wanted = set(sub["nodes"])
        nodes = [n for n in nodes if n.get("name") in wanted]
    if not nodes:
        raise SystemExit(f"订阅 {sub['name']}: 没有可用节点")
    tpl = load_yaml(p["template"])
    if not tpl:
        raise SystemExit("template.yaml 缺失或为空")

    defs = read_defaults(base)
    # 自动刷新关 (stats_refresh_minutes==0) 且未传 --refresh-quality:
    # 出口 IP 探测 / 评分都优先走缓存,新静态 IP(缓存未命中) 仍会即时探测一次
    try:
        _auto_off = int(defs.get("stats_refresh_minutes", 10)) == 0
    except (TypeError, ValueError):
        _auto_off = False
    prefer_cache = _auto_off and not _REFRESH_QUALITY_FLAG
    pwd = sub.get("password")
    sub_port = sub.get("port")
    u = sub.get("usage") or _empty_usage()
    total_gb = int(sub.get("traffic_gb", 0))
    total_bytes = total_gb * 1024 * 1024 * 1024
    used = int(u.get("period_bytes") or 0)
    remain = max(0, total_bytes - used)

    # 判断套餐状态（基于实时计算，不读 sub['disabled']）
    over_quota = total_bytes > 0 and used >= total_bytes
    expired = False
    if sub.get("expire"):
        try:
            expired = parse_date(sub["expire"]) < date.today()
        except ValueError:
            pass

    head = nodes[0]
    info = []
    if expired:
        # 套餐到期：仅显示到期日，隐藏流量/重置信息
        info.append(make_proxy(f"[自建] ⚠ 套餐已到期(已断网)到期时间为:{sub['expire']}", head, pwd, sub_port))
    else:
        # 流量用完时显示"流量用完"，否则显示剩余字节数
        remain_label = "流量用完" if over_quota else fmt_bytes(remain)
        info.append(make_proxy(f"[自建] 剩余流量:{remain_label}", head, pwd, sub_port))
        info.append(make_proxy(f"[自建] 距离下次重置:{days_until_reset(int(sub['reset_day']))} 天", head, pwd, sub_port))
        if sub.get("expire"):
            info.append(make_proxy(f"[自建] 套餐到期:{sub['expire']}", head, pwd, sub_port))

    # 套餐到期时不显示自建节点；流量用完时仍显示（nft 负责限流）
    real = [] if expired else [make_proxy(auto_node_name(n, base, defs, prefer_cache=prefer_cache), n, pwd, sub_port) for n in nodes]
    real = _sort_by_risk(real, base, defs, "self", prefer_cache=prefer_cache)

    # 外购订阅节点（不计流量、不受 nft 限流约束）;
    # load_external_proxies 内部已按"信息置顶 + 真节点风险升序"排好
    ttl = int(defs.get("stats_refresh_minutes", 10)) * 60
    external = load_external_proxies(base, sub, defs, ttl, prefer_cache=prefer_cache)

    # ── 静态 IP 出口节点 ─────────────────────────────────────────────
    # 客户端看到的还是连本机的 anytls 节点（server=VPS_IP, port=订阅端口）；
    # password 取自 sub["static_passwords"][i]，sing-box inbound 多挂的 user 在
    # route.rules 里被映射到对应的远端 socks5 outbound。
    static_strategy = "off" if expired else resolve_static_strategy(sub, defs)
    static_proxies = resolve_static_proxies(sub, defs)
    static_pwds = sub.get("static_passwords") or []
    static_nodes = []  # 真实静态节点（前缀 [静态]）
    if static_strategy == "on" and static_proxies and static_pwds:
        # 真实 vps server / sni 取自首个自建节点（同 head）
        vps_server = head.get("server")
        sni = head.get("sni")
        seen_names = set(pp.get("name") for pp in info + real + external)
        def _uniq(name):
            if name not in seen_names:
                seen_names.add(name)
                return name
            j = 1
            while True:
                j += 1
                cand = f"{name} #{j}"
                if cand not in seen_names:
                    seen_names.add(cand)
                    return cand
        for i, sp in enumerate(static_proxies):
            if i >= len(static_pwds):
                break
            entry_server = sp.get("server", "")
            entry_port = sp.get("port", 0)
            entry_user = sp.get("username") or ""
            entry_pwd = sp.get("password") or ""
            target = ""
            # 实测出口 IP:质量检测 OR 出口IP显示 任一开就要探测
            if _is_quality_enabled(defs, "static") or _is_exit_ip_show_enabled(defs, "static"):
                target, _static_nk = _probe_static_exit_ip(entry_server, entry_port, entry_user, entry_pwd, base=base, prefer_cache=prefer_cache)
            else:
                target, _static_nk = "", f"static:{entry_server}:{entry_port}:{entry_user}"
            target = target or entry_server
            show_ip = _is_exit_ip_show_enabled(defs, "static")
            display = target if show_ip else ""
            label = format_geo_label(target, base, display=display) or target or ""
            quality = format_quality_suffix(target, base, defs, kind_label="static", node_key=_static_nk, prefer_cache=prefer_cache)
            anno = sp.get("annotation") or ""
            anno_seg = f"[{anno}]" if anno else ""
            display_name = f"[静态]{quality}{anno_seg} {label}" if (quality or anno_seg) else f"[静态] {label}"
            name = _uniq(display_name)
            node = make_static_proxy(
                name=name, sub_password=static_pwds[i],
                sub_port=sub_port, vps_server=vps_server, sni=sni,
            )
            if _is_quality_enabled(defs, "static") and target:
                _, sc = lookup_ip_quality(target, base, defs, node_key=_static_nk, prefer_cache=prefer_cache)
                node["__sort_risk"] = (1, 0) if sc == "" or sc is None else (0, int(sc))
            else:
                node["__sort_risk"] = (1, 0)
            static_nodes.append(node)
        static_nodes.sort(key=lambda n: n.get("__sort_risk", (1, 0)))
        for n in static_nodes:
            n.pop("__sort_risk", None)

    # 静态IP 组顶部的"信息说明节点"：用主 password（不是静态密码），所以 sing-box
    # 把它识别为主 user，流量沿 final=direct 出去 = VPS 出口。两条永远渲染：
    # 服务包列表 / 关键词列表，无内容时显示 (无)。
    static_info_nodes = []
    if static_nodes:
        packs_for_info = sub.get("static_service_packs") if "static_service_packs" in sub \
                         else (defs or {}).get("static_service_packs") or []
        custom_for_info = sub.get("static_custom_keywords") if "static_custom_keywords" in sub \
                          else (defs or {}).get("static_custom_keywords") or []
        info_lines = [
            f"[静态] 服务包: {','.join(packs_for_info) if packs_for_info else '(无)'}",
            f"[静态] 关键词: {','.join(custom_for_info) if custom_for_info else '(无)'}",
        ]
        for ln in info_lines:
            static_info_nodes.append(make_static_proxy(
                name=ln,
                sub_password=sub["password"],  # 主 user → final: direct → VPS
                sub_port=sub_port,
                vps_server=head.get("server"),
                sni=head.get("sni"),
            ))

    # 组顺序: 自建(info+real) → 静态(static_info+static_nodes) → 外购(external)
    # 组内: info 节点在前, 真实节点按风险升序(已在各类生成时排好)
    proxies = info + real + static_info_nodes + static_nodes + external
    tpl["proxies"] = proxies

    # proxy-groups：始终拆 "VPS 节点" 子组（含信息节点+自建），有外购时再加 "外购" 子组；
    # 主组只放子组入口 + REJECT/DIRECT
    groups = tpl.get("proxy-groups") or []
    if not groups:
        groups = [_FlowMap({"name": "代理", "type": "select"})]
        tpl["proxy-groups"] = groups
    first = groups[0]
    # REJECT 保留在前（拦截用），DIRECT 移到末尾（避免 Shadowrocket 默认选直连）
    keep_front = [x for x in (first.get("proxies") or []) if x == "REJECT"]
    keep_back  = [x for x in (first.get("proxies") or []) if x == "DIRECT"]

    vps_names = [pp["name"] for pp in (info + real)]
    external_names = [pp["name"] for pp in external]
    static_node_names = [pp["name"] for pp in static_nodes]
    static_info_names = [pp["name"] for pp in static_info_nodes]

    # 移除上一次渲染遗留的子组（idempotent）；旧版命名一并清掉
    _legacy = {"VPS 节点", "外购", "静态 IP", "静态IP", "静态IP_ALL", "静态IP_Partial"}
    groups[:] = [g for g in groups if g.get("name") not in _legacy]
    # first 可能因为上一行被剔除（如果它就叫 "VPS 节点"），重新拿
    first = groups[0] if groups else _FlowMap({"name": "代理", "type": "select"})
    if not groups:
        groups.append(first)
        tpl["proxy-groups"] = groups

    # 把模板里已有的 group 也转成 _FlowMap（保证 flow style 输出）
    groups[:] = [_FlowMap(g) if not isinstance(g, _FlowMap) else g for g in groups]
    first = groups[0]

    # 主组 entries 顺序：
    #   off / 无静态资源 → [VPS 节点]
    #   on               → [VPS 节点, 静态IP, 外购?]   （默认仍以 VPS 优先）
    sub_entries = ["VPS 节点"]
    if static_node_names:
        sub_entries.append("静态IP")
    if external_names:
        sub_entries.append("外购")
    first["proxies"] = keep_front + sub_entries + keep_back

    groups.append(_FlowMap({"name": "VPS 节点", "type": "select", "proxies": vps_names}))
    if static_node_names:
        # 静态IP 组成员顺序：
        #   节点信息(服务包) + 节点信息(关键词)（用主密码 → 选中=回 VPS）
        #   → "VPS 节点" 子组引用 → "外购" 子组引用（仅在外购存在时）
        #   → 真静态节点 → DIRECT
        static_members = list(static_info_names)
        static_members.append("VPS 节点")
        if external_names:
            static_members.append("外购")
        static_members.extend(static_node_names)
        static_members.append("DIRECT")
        groups.append(_FlowMap({
            "name": "静态IP", "type": "select",
            "proxies": static_members,
        }))
    if external_names:
        groups.append(_FlowMap({"name": "外购", "type": "select", "proxies": ["DIRECT"] + external_names}))

    # ── on 模式：在 rules 头部注入 DOMAIN-KEYWORD,xxx,静态IP ─────────────
    if static_node_names:
        keywords = resolve_static_keywords(sub, defs)
        if keywords:
            existing_rules = list(tpl.get("rules") or [])
            injected = [f"DOMAIN-KEYWORD,{kw},静态IP" for kw in keywords]
            tpl["rules"] = injected + existing_rules

    out_dir = os.path.join(p["output"], sub["token"])
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "clash.yaml")
    dump_yaml(out_path, tpl)
    extra_parts = []
    if external:
        extra_parts.append(f"外购 {len(external)}")
    if static_nodes:
        extra_parts.append(f"静态 IP {len(static_nodes)}/{static_strategy}")
    extra = (", " + ", ".join(extra_parts)) if extra_parts else ""
    print(f"rendered: {sub['name']} → {out_path} ({len(real)} 节点{extra}, port={sub_port})")


def cmd_render(args):
    global _REFRESH_QUALITY_FLAG
    _REFRESH_QUALITY_FLAG = bool(getattr(args, "refresh_quality", False))
    subs = read_subs_normalized(args.base)
    if not subs:
        print("(无订阅可渲染)")
        return 0
    write_subs(args.base, subs)  # 把 normalize 补的字段持久化
    if args.all:
        targets = subs
    elif args.name:
        s = find_sub(subs, args.name)
        if not s:
            print(f"未找到订阅: {args.name}", file=sys.stderr)
            return 1
        targets = [s]
    else:
        targets = subs
    for s in targets:
        render_one(args.base, s)
    return 0


# ─── caddy-blocks ──────────────────────────────────────────────────
def expire_unix(expire_str):
    if not expire_str:
        return 0
    d = datetime.strptime(expire_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(d.timestamp())


def cmd_caddy_blocks(args):
    """输出 Caddy 块：一个统一的 handle_path /sub/* 反代到本机 serve.py。
    serve.py 在收到客户端拉取请求时按需触发流量入账 / enforce，并以最新数据
    动态写 Subscription-Userinfo / Profile-Update-Interval / Content-Disposition
    头，避免 Caddyfile 静态化和 reload。
    """
    # 任意有无订阅都输出一个固定块——内部路由由 serve.py 处理
    print(
        "  # Clash 订阅（按需刷新）：所有 /sub/<token>/clash.yaml 转给本机 serve.py\n"
        "  handle_path /sub/* {\n"
        "    reverse_proxy 127.0.0.1:13888\n"
        "  }"
    )
    return 0


# ─── sing-box / nftables / 计费（多端口、按订阅统计） ─────────────
def _outbound_tag(sp):
    """根据资源 (server, port, username, password) 算出稳定 outbound tag。
    同一份资源被多个订阅引用时复用同一个 outbound，避免重复挂连接。"""
    h = hashlib.sha1(
        f"{sp['server']}|{sp['port']}|{sp.get('username') or ''}|{sp['password']}".encode("utf-8")
    ).hexdigest()[:10]
    return f"static-{h}"


def cmd_sing_box_inbounds(args):
    """输出 sing-box config.json 的 inbounds[] 数组（多 anytls inbound，每订阅一个端口）。
    每订阅可挂多个 user：默认 user（走 direct）+ 每个静态 IP 资源 1 个 user
    （static-N 经 route.rules 路由到对应远端 socks5 outbound）。
    限流交给 nftables drop（避免 restart sing-box 冲断在线连接）。
    --tls-cert / --tls-key / --server-name 必填，由 sh 脚本统一传入。"""
    import json as _json
    subs = read_subs_normalized(args.base)
    defs = read_defaults(args.base)
    inbounds = []
    for s in subs:
        users = [{"name": s["name"], "password": s["password"]}]
        # 静态 IP user（仅在策略不是 off 且有资源 + 密码时挂）
        if resolve_static_strategy(s, defs) != "off":
            sps = resolve_static_proxies(s, defs)
            pwds = s.get("static_passwords") or []
            for i, _sp in enumerate(sps):
                if i >= len(pwds):
                    break
                users.append({
                    "name": _static_user_name(s["name"], i),
                    "password": pwds[i],
                })
        inbounds.append({
            "type": "anytls",
            "tag": f"in-{s['name']}",
            "listen": "0.0.0.0",
            "listen_port": int(s["port"]),
            "users": users,
            "padding_scheme": [],
            "tls": {
                "enabled": True,
                "server_name": args.server_name,
                "certificate_path": args.tls_cert,
                "key_path": args.tls_key,
            },
        })
    print(_json.dumps(inbounds, ensure_ascii=False, indent=2))
    return 0


def cmd_sing_box_outbounds(args):
    """输出 sing-box config.json 的 outbounds[] 数组。
    固定 direct + 全局/订阅去重后的静态 IP outbound（按 (server,port,user,pwd) 去重）。
    所有静态 IP 资源都按 socks5 outbound 注入：远端是公网 SOCKS5 服务器。"""
    import json as _json
    subs = read_subs_normalized(args.base)
    defs = read_defaults(args.base)
    outbounds = [{"type": "direct", "tag": "direct"}]
    seen = set()
    pool = []
    # 默认值池 + 各订阅自有池都收集（即使该订阅 strategy=off，资源对应的 outbound 也可保留无害）
    for s in subs:
        if resolve_static_strategy(s, defs) == "off":
            continue
        pool.extend(resolve_static_proxies(s, defs))
    for sp in pool:
        tag = _outbound_tag(sp)
        if tag in seen:
            continue
        seen.add(tag)
        kind = (sp.get("type") or "socks5").strip().lower()
        ob = {
            "type": kind,
            "tag": tag,
            "server": sp["server"],
            "server_port": int(sp["port"]),
        }
        # socks 在 sing-box 里走 username/password；anytls 用 password；其他先按 socks5 兜底
        if kind in ("socks", "socks5"):
            ob["type"] = "socks"
            ob["version"] = "5"
            if sp.get("username"):
                ob["username"] = sp["username"]
            ob["password"] = sp["password"]
        elif kind == "http":
            if sp.get("username"):
                ob["username"] = sp["username"]
            ob["password"] = sp["password"]
        else:
            # anytls / 其它带 password 的
            ob["password"] = sp["password"]
        outbounds.append(ob)
    print(_json.dumps(outbounds, ensure_ascii=False, indent=2))
    return 0


def cmd_sing_box_route_rules(args):
    """输出 sing-box config.json 的 route.rules[] 增量片段（auth_user → outbound 映射）。
    sh 脚本拼接到 route.rules 的尾部（在 sniff / dns hijack 之后、final=direct 之前）。
    sing-box 1.13+ 用 auth_user 匹配 inbound 已认证用户名，且需要显式 action=route。
    每条静态资源一个 user（static-N），同一份资源被多订阅引用时合并到同一条规则。"""
    import json as _json
    from collections import OrderedDict
    subs = read_subs_normalized(args.base)
    defs = read_defaults(args.base)
    by_ob = OrderedDict()
    for s in subs:
        if resolve_static_strategy(s, defs) == "off":
            continue
        sps = resolve_static_proxies(s, defs)
        pwds = s.get("static_passwords") or []
        for i, sp in enumerate(sps):
            if i >= len(pwds):
                break
            tag = _outbound_tag(sp)
            users = by_ob.setdefault(tag, [])
            users.append(_static_user_name(s["name"], i))
    rules = [
        {"auth_user": users, "action": "route", "outbound": tag}
        for tag, users in by_ob.items()
    ]
    print(_json.dumps(rules, ensure_ascii=False, indent=2))
    return 0


def cmd_nft_config(args):
    """输出 nftables 配置（独立 inet table clash_subs）：
    - 每端口两个 counter (c-in-<port> / c-out-<port>)
    - 一个 disabled_ports set，命中即 drop
    - input/output chain 分别按端口/源端口算字节
    """
    subs = read_subs_normalized(args.base)
    ports = sorted({int(s["port"]) for s in subs if s.get("port")})
    disabled_ports = sorted({int(s["port"]) for s in subs if s.get("port") and s.get("disabled")})

    if not ports:
        # 空表也要输出，让 sh 能创建并保留 table（避免 stats 阶段拿不到）
        print("table inet clash_subs {\n    set disabled_ports {\n        type inet_service\n        flags interval\n    }\n}")
        return 0

    lines = ["table inet clash_subs {"]
    for p in ports:
        lines.append(f"    counter c-in-{p} {{}}")
        lines.append(f"    counter c-out-{p} {{}}")
    lines.append("    set disabled_ports {")
    lines.append("        type inet_service")
    lines.append("        flags interval")
    if disabled_ports:
        lines.append("        elements = { " + ", ".join(str(p) for p in disabled_ports) + " }")
    lines.append("    }")
    lines.append("    chain input {")
    lines.append("        type filter hook input priority filter; policy accept;")
    lines.append("        tcp dport @disabled_ports counter drop")
    for p in ports:
        lines.append(f"        tcp dport {p} counter name c-in-{p}")
    lines.append("    }")
    lines.append("    chain output {")
    lines.append("        type filter hook output priority filter; policy accept;")
    for p in ports:
        lines.append(f"        tcp sport {p} counter name c-out-{p}")
    lines.append("    }")
    lines.append("}")
    print("\n".join(lines))
    return 0


def cmd_nft_disabled_ports(args):
    """只输出当前应禁用的端口（一行一个）。给轮询服务用：
    比对 nft set 的 elements，调 add/delete element 增量同步，避免 reload table 清零 counter。"""
    subs = read_subs_normalized(args.base)
    for s in subs:
        if s.get("disabled") and s.get("port"):
            print(int(s["port"]))
    return 0


def cmd_usage_from_nft(args):
    """从 `nft -j list table inet clash_subs` 的 JSON 输出中读 counter，做差分入账。
    state 文件保存在 base/.nft_state.yaml，记录每个 counter 上次的 bytes 值。
    第一次运行：建 state，零差分。后续：差分 = 当前 - 上次，累加到 usage。"""
    import json as _json
    raw = sys.stdin.read() if args.json == "-" else open(args.json).read()
    data = _json.loads(raw)
    counters = {}
    for entry in data.get("nftables", []):
        c = entry.get("counter")
        if not c:
            continue
        counters[c["name"]] = int(c.get("bytes", 0))

    state_path = os.path.join(args.base, ".nft_state.yaml")
    state = load_yaml(state_path) or {}
    prev = state.get("counters") or {}

    subs = read_subs_normalized(args.base)
    by_port = {int(s["port"]): s for s in subs if s.get("port")}

    new_state = {"counters": dict(counters), "last_at": now_iso()}
    changed = False
    for port, s in by_port.items():
        cin = counters.get(f"c-in-{port}", 0)
        cout = counters.get(f"c-out-{port}", 0)
        pin = prev.get(f"c-in-{port}", 0)
        pout = prev.get(f"c-out-{port}", 0)
        # 差分（counter 重置或回退则取当前值，不能为负）
        din = max(0, cin - pin) if cin >= pin else cin
        dout = max(0, cout - pout) if cout >= pout else cout
        delta = din + dout
        if delta > 0:
            u = s["usage"]
            u["period_bytes"] = int(u.get("period_bytes") or 0) + delta
            u["total_bytes"] = int(u.get("total_bytes") or 0) + delta
            u["last_at"] = now_iso()
            changed = True
            if args.verbose:
                print(f"  {s['name']:<16} port={port}  in={din} out={dout} → +{delta} B")

    if changed:
        write_subs(args.base, subs)
    dump_yaml(state_path, new_state)
    return 0


# ─── 旧 sing-box 单 inbound API（已废弃，方案 H 用每用户独立端口）─


def cmd_record_usage(args):
    """累加单订阅本周期 / 累计字节数。"""
    subs = read_subs_normalized(args.base)
    s = find_sub(subs, args.name)
    if not s:
        print(f"未找到订阅: {args.name}", file=sys.stderr)
        return 1
    delta = int(args.up or 0) + int(args.down or 0)
    if delta < 0:
        print("delta 不能为负", file=sys.stderr)
        return 1
    u = s["usage"]
    u["period_bytes"] = int(u.get("period_bytes") or 0) + delta
    u["total_bytes"]  = int(u.get("total_bytes") or 0)  + delta
    u["last_at"] = now_iso()
    write_subs(args.base, subs)
    return 0


def cmd_reset_period(args):
    """检查每条订阅是否进入新周期，是则清零 period_bytes 并更新 period_started。"""
    subs = read_subs_normalized(args.base)
    today = date.today()
    changed = False
    for s in subs:
        rd = int(s.get("reset_day", 1))
        expected = expected_period_start(today, rd)
        cur = s["usage"].get("period_started") or ""
        try:
            cur_d = parse_date(cur) if cur else None
        except ValueError:
            cur_d = None
        if cur_d != expected:
            s["usage"]["period_bytes"] = 0
            s["usage"]["period_started"] = expected.isoformat()
            changed = True
            print(f"reset: {s['name']} → 新周期起算 {expected.isoformat()}")
    if changed:
        write_subs(args.base, subs)
    return 0


def cmd_enforce(args):
    """根据流量 / 到期重新计算 disabled，输出变更。"""
    subs = read_subs_normalized(args.base)
    today = date.today()
    changed = False
    for s in subs:
        total_bytes = int(s.get("traffic_gb", 0)) * 1024 * 1024 * 1024
        used = int(s["usage"].get("period_bytes") or 0)
        over_quota = total_bytes > 0 and used >= total_bytes
        expired = False
        if s.get("expire"):
            try:
                expired = parse_date(s["expire"]) < today
            except ValueError:
                pass
        should_disable = bool(over_quota or expired)
        if bool(s.get("disabled")) != should_disable:
            s["disabled"] = should_disable
            reason = "quota" if over_quota else "expired" if expired else "ok"
            print(f"enforce: {s['name']} → disabled={should_disable} ({reason})")
            changed = True
    if changed:
        write_subs(args.base, subs)
    return 0


def cmd_set_disabled(args):
    subs = read_subs_normalized(args.base)
    s = find_sub(subs, args.name)
    if not s:
        print(f"未找到订阅: {args.name}", file=sys.stderr)
        return 1
    s["disabled"] = bool(args.value)
    write_subs(args.base, subs)
    print(f"{args.name}: disabled={s['disabled']}")
    return 0


def cmd_get_setting(args):
    """读单个 default 字段（给 shell 脚本用）。"""
    defs = read_defaults(args.base)
    key = args.key
    if key not in defs:
        print(f"未知字段: {key}", file=sys.stderr)
        return 1
    print(defs[key])
    return 0


def cmd_clear_external_cache(args):
    """清空外购订阅缓存目录，下次 render 时强制重新拉取。"""
    cache_dir = os.path.join(args.base, EXTERNAL_CACHE_DIR)
    if os.path.isdir(cache_dir):
        shutil.rmtree(cache_dir, ignore_errors=True)
    print(f"已清空外购缓存: {cache_dir}")
    return 0


def cmd_field_values(args):
    """输出某条订阅（或默认值）的当前字段，供 shell 菜单显示原值。
    每行 "<key>=<value>"，value 可能为空（表示未设置/继承）。
    """
    defs = read_defaults(args.base)
    if args.name:
        subs = read_subs_normalized(args.base)
        s = find_sub(subs, args.name)
        if not s:
            print(f"未找到订阅: {args.name}", file=sys.stderr)
            return 1
        out = {
            "rename": s.get("name", ""),
            "traffic_gb": str(s.get("traffic_gb", "")),
            "reset_day": str(s.get("reset_day", "")),
            "expire": s.get("expire", ""),
            "interval": str(s.get("update_interval_hours", "")),
            "password": s.get("password", ""),
            "port": str(s.get("port", "")),
        }
        if "external_url" in s:
            out["external_url"] = s["external_url"] or "(显式禁用)"
        else:
            gdef = defs.get("external_url", "") or ""
            out["external_url"] = f"(继承: {gdef})" if gdef else "(继承: 未启用)"
        if "static_strategy" in s:
            out["static_strategy"] = str(s.get("static_strategy") or "")
        else:
            out["static_strategy"] = f"(继承: {defs.get('static_strategy','off')})"
        if "static_service_packs" in s:
            out["static_service_packs"] = ",".join(s.get("static_service_packs") or []) or "(空)"
        else:
            gv = defs.get("static_service_packs") or []
            out["static_service_packs"] = f"(继承: {','.join(gv) if gv else '空'})"
        if "static_custom_keywords" in s:
            out["static_custom_keywords"] = ",".join(s.get("static_custom_keywords") or []) or "(空)"
        else:
            gv = defs.get("static_custom_keywords") or []
            out["static_custom_keywords"] = f"(继承: {','.join(gv) if gv else '空'})"
    else:
        # defaults 视图
        out = {
            "traffic_gb": str(defs.get("traffic_gb", "")),
            "reset_day": str(defs.get("reset_day", "")),
            "expire_days": str(defs.get("expire_days", "")),
            "interval": str(defs.get("update_interval_hours", "")),
            "stats_refresh_minutes": str(defs.get("stats_refresh_minutes", "")),
            "port_min": str(defs.get("port_min", "")),
            "port_max": str(defs.get("port_max", "")),
            "external_url": defs.get("external_url", "") or "(未启用)",
            "external_name_prefix": defs.get("external_name_prefix", ""),
            "static_strategy": str(defs.get("static_strategy", "off")),
            "static_service_packs": ",".join(defs.get("static_service_packs") or []) or "(空)",
            "static_custom_keywords": ",".join(defs.get("static_custom_keywords") or []) or "(空)",
            "static_name_prefix": defs.get("static_name_prefix", ""),
            "quality_check_enabled": defs.get("quality_check_enabled", "off"),
            "quality_check_for_self": defs.get("quality_check_for_self", "on"),
            "quality_check_for_static": defs.get("quality_check_for_static", "on"),
            "quality_source": defs.get("quality_source", "free"),
            "exit_ip_show_enabled": defs.get("exit_ip_show_enabled", "on"),
            "exit_ip_show_for_self": defs.get("exit_ip_show_for_self", "on"),
            "exit_ip_show_for_static": defs.get("exit_ip_show_for_static", "on"),
            "scamalytics_url": defs.get("scamalytics_url", "") or "(未配置)",
            "proxycheck_api_key": defs.get("proxycheck_api_key", "") or "(未配置，走免费匿名 100/天)",
        }
    for k, v in out.items():
        # 显示用，包括 "(继承: …)" 这种带空格/括号的字符串都安全
        print(f"{k}={v}")
    return 0


def cmd_parse_static_blob(args):
    """解析 blob([annotation:]host:port:user:password) → 标准化条目列表。
    用于 shell 端预览。每行输出: "<idx> <server>:<port> user=<u> anno=[<a>]"。
    无效行用 stderr 提示但继续。"""
    blob = args.blob if args.blob != "-" else sys.stdin.read()
    parsed = parse_static_proxies_blob(blob)
    if not parsed:
        print("(解析后无有效条目)")
        return 1
    print(f"共 {len(parsed)} 条")
    for i, p in enumerate(parsed, 1):
        user = p.get("username") or "-"
        anno = p.get("annotation") or ""
        anno_show = f"  anno=[{anno}]" if anno else ""
        print(f"  {i}  {p['server']}:{p['port']}  user={user}{anno_show}")
    return 0


def cmd_static_list(args):
    """列出某订阅当前生效的静态 IP 资源池（含索引），脚本可读格式。
    输出格式：每行 "<idx> <server>:<port> <user> <来源>"。
    --name 留空 = 列默认值。"""
    defs = read_defaults(args.base)
    if args.name:
        subs = read_subs_normalized(args.base)
        s = find_sub(subs, args.name)
        if not s:
            print(f"未找到订阅: {args.name}", file=sys.stderr)
            return 1
        proxies = resolve_static_proxies(s, defs)
        src = "订阅独立" if "static_proxies" in s and s["static_proxies"] else (
              "继承默认" if proxies else "未配置")
    else:
        proxies = _norm_static_list(defs.get("static_proxies"))
        src = "默认值"
    if not proxies:
        print(f"(无静态 IP 资源)  [{src}]")
        return 0
    print(f"共 {len(proxies)} 条静态 IP  [{src}]")
    for i, p in enumerate(proxies, 1):
        user = p.get("username") or "-"
        anno = p.get("annotation") or ""
        anno_show = f"  anno=[{anno}]" if anno else ""
        print(f"  {i}  {p['server']}:{p['port']}  user={user}  type={p.get('type','socks5')}{anno_show}")
    return 0


# ─── argparse 装配 ─────────────────────────────────────────────────
def build_parser():
    p = argparse.ArgumentParser(description="Clash 订阅管理 + 渲染")
    p.add_argument("--base", default="/opt/ai-stack/clash", help="clash 目录(默认 /opt/ai-stack/clash)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init")

    ls = sub.add_parser("list")
    g_ls = ls.add_mutually_exclusive_group()
    g_ls.add_argument("--brief", action="store_true", help="一行一条简要列表")
    g_ls.add_argument("--names", action="store_true", help="只输出名字（每行一个）")

    sh = sub.add_parser("show")
    sh.add_argument("name")

    a = sub.add_parser("add")
    a.add_argument("name")
    a.add_argument("--traffic-gb", dest="traffic_gb", type=int)
    a.add_argument("--reset-day", dest="reset_day", type=int)
    a.add_argument("--expire")
    a.add_argument("--interval", type=int)
    a.add_argument("--token")
    a.add_argument("--password")
    a.add_argument("--port", type=int)
    a.add_argument("--external-url", dest="external_url",
                   help='外购 URL；"-" 表示清空回继承全局；空串表示显式禁用')
    a.add_argument("--static-strategy", dest="static_strategy",
                   help='off/on；"-" = 清空回继承')
    a.add_argument("--static-service-packs", dest="static_service_packs",
                   help='on 模式预设服务包，逗号分隔（如 ai,streaming）；"-" = 清空回继承')
    a.add_argument("--static-custom-keywords", dest="static_custom_keywords",
                   help='on 模式自定义 DOMAIN-KEYWORD，逗号分隔；"-" = 清空回继承')
    a.add_argument("--static-proxies", dest="static_proxies",
                   help='整体替换静态 IP 资源池；多行格式 host:port:user:password；"-" = 清空回继承')
    a.add_argument("--static-proxy-add", dest="static_proxy_add", action="append", default=[],
                   help='追加单条/多条静态 IP（host:port:user:password；可重复 / 多行 / 逗号分隔）')
    a.add_argument("--static-proxy-remove", dest="static_proxy_remove", action="append", default=[],
                   help='删除静态 IP，参数为 1 起算的索引或 host:port；可重复')

    e = sub.add_parser("edit")
    e.add_argument("name")
    e.add_argument("--rename")
    e.add_argument("--traffic-gb", dest="traffic_gb", type=int)
    e.add_argument("--reset-day", dest="reset_day", type=int)
    e.add_argument("--expire")
    e.add_argument("--interval", type=int)
    e.add_argument("--password")
    e.add_argument("--port", type=int)
    e.add_argument("--external-url", dest="external_url",
                   help='外购 URL；"-" 表示清空回继承全局；空串表示显式禁用')
    e.add_argument("--static-strategy", dest="static_strategy",
                   help='off/on；"-" = 清空回继承')
    e.add_argument("--static-service-packs", dest="static_service_packs",
                   help='on 模式预设服务包，逗号分隔；"-" = 清空回继承')
    e.add_argument("--static-custom-keywords", dest="static_custom_keywords",
                   help='on 模式自定义关键词，逗号分隔；"-" = 清空回继承')
    e.add_argument("--static-proxies", dest="static_proxies",
                   help='整体替换静态 IP 资源池；"-" = 清空回继承')
    e.add_argument("--static-proxy-add", dest="static_proxy_add", action="append", default=[],
                   help='追加静态 IP；可重复')
    e.add_argument("--static-proxy-remove", dest="static_proxy_remove", action="append", default=[],
                   help='删除静态 IP（索引或 host:port）；可重复')

    r = sub.add_parser("remove")
    r.add_argument("name")

    d = sub.add_parser("defaults")
    d.add_argument("--show", action="store_true")
    d.add_argument("--traffic-gb", dest="traffic_gb", type=int)
    d.add_argument("--reset-day", dest="reset_day", type=int)
    d.add_argument("--expire-days", dest="expire_days", type=int)
    d.add_argument("--interval", type=int)
    d.add_argument("--stats-refresh-minutes", dest="stats_refresh_minutes", type=int)
    d.add_argument("--port-min", dest="port_min", type=int)
    d.add_argument("--port-max", dest="port_max", type=int)
    d.add_argument("--external-url", dest="external_url",
                   help="默认外购 URL（空字符串 = 不启用）")
    d.add_argument("--external-name-prefix", dest="external_name_prefix",
                   help="外购节点显示前缀")
    d.add_argument("--static-strategy", dest="static_strategy",
                   help="默认静态 IP 策略 off/on")
    d.add_argument("--static-service-packs", dest="static_service_packs",
                   help="默认 on 服务包，逗号分隔")
    d.add_argument("--static-custom-keywords", dest="static_custom_keywords",
                   help="默认 on 自定义关键词，逗号分隔")
    d.add_argument("--static-proxies", dest="static_proxies",
                   help="默认静态 IP 资源池，多行 host:port:user:password")
    d.add_argument("--static-proxy-add", dest="static_proxy_add", action="append", default=[],
                   help="追加默认静态 IP；可重复")
    d.add_argument("--static-proxy-remove", dest="static_proxy_remove", action="append", default=[],
                   help="删除默认静态 IP（索引或 host:port）；可重复")
    d.add_argument("--static-name-prefix", dest="static_name_prefix",
                   help="静态 IP 节点显示前缀")
    d.add_argument("--scamalytics-url", dest="scamalytics_url",
                   help="scamalytics 完整 URL（含 key & user），优先于 proxycheck")
    d.add_argument("--proxycheck-api-key", dest="proxycheck_api_key",
                   help="proxycheck.io API key（空走免费 100/天，有 key 走 1000/天）")
    d.add_argument("--quality-check-enabled", dest="quality_check_enabled",
                   help="IP 检测总开关 on/off")
    d.add_argument("--quality-check-for-self", dest="quality_check_for_self",
                   help="自建节点 IP 检测开关 on/off")
    d.add_argument("--quality-check-for-static", dest="quality_check_for_static",
                   help="静态 IP 节点检测开关 on/off")
    d.add_argument("--quality-source", dest="quality_source",
                   help="数据源：free=proxycheck 免费匿名 / scamalytics=用 scamalytics_url")
    d.add_argument("--exit-ip-show-enabled", dest="exit_ip_show_enabled",
                   help="节点名末尾(IP)显示总开关 on/off")
    d.add_argument("--exit-ip-show-for-self", dest="exit_ip_show_for_self",
                   help="自建节点(IP)显示开关 on/off")
    d.add_argument("--exit-ip-show-for-static", dest="exit_ip_show_for_static",
                   help="静态节点(IP)显示开关 on/off")
    d.add_argument("--refresh-mode", dest="refresh_mode",
                   help="自动刷新模式：interval(间隔) / daily(日刷新) / off(关闭)")
    d.add_argument("--daily-refresh-time", dest="daily_refresh_time",
                   help="日刷新模式：每天刷新时间 HH:MM（如 03:00）")
    d.add_argument("--refresh-force-recheck", dest="refresh_force_recheck",
                   help="定时刷新时是否强制重新检测 IP：true / false")
    d.add_argument("--ip-quality-cache-hours", dest="ip_quality_cache_hours", type=int,
                   help="IP 质量缓存有效期（小时）")

    rd = sub.add_parser("render")
    g = rd.add_mutually_exclusive_group()
    g.add_argument("--name")
    g.add_argument("--all", action="store_true")
    rd.add_argument("--refresh-quality", dest="refresh_quality", action="store_true",
                    help="强制重新探测出口 IP 和重新拉取风险评分(忽略缓存);"
                         "默认: stats_refresh_minutes==0 时优先用缓存")

    cb = sub.add_parser("caddy-blocks")
    cb.add_argument("--host", default="")

    sbi = sub.add_parser("sing-box-inbounds")
    sbi.add_argument("--tls-cert", dest="tls_cert", required=True)
    sbi.add_argument("--tls-key", dest="tls_key", required=True)
    sbi.add_argument("--server-name", dest="server_name", required=True)

    sub.add_parser("sing-box-outbounds")
    sub.add_parser("sing-box-route-rules")

    sub.add_parser("nft-config")
    sub.add_parser("nft-disabled-ports")

    un = sub.add_parser("usage-from-nft")
    un.add_argument("--json", required=True, help="nft -j JSON 文件路径，或 - 读 stdin")
    un.add_argument("--verbose", action="store_true")

    ru = sub.add_parser("record-usage")
    ru.add_argument("--name", required=True)
    ru.add_argument("--up", type=int, default=0)
    ru.add_argument("--down", type=int, default=0)

    sub.add_parser("reset-period")
    sub.add_parser("enforce")

    sd = sub.add_parser("set-disabled")
    sd.add_argument("name")
    sd.add_argument("--value", type=lambda v: v.lower() in ("1", "true", "yes", "on"), required=True)

    gs = sub.add_parser("get-setting")
    gs.add_argument("key")

    sub.add_parser("clear-external-cache")

    fv = sub.add_parser("field-values", help="输出 edit 菜单要显示的当前字段值（key=value 行）")
    fv.add_argument("--name", help="订阅名；省略则输出 defaults 字段")

    sl = sub.add_parser("static-list", help="列出静态 IP 资源（含索引）")
    sl.add_argument("--name", help="订阅名；省略则列默认值")

    psb = sub.add_parser("parse-static-blob", help="解析 [annotation:]host:port:user:password 列表（用于 shell 预览）")
    psb.add_argument("blob", help='blob 字符串；- = 从 stdin 读')

    return p


HANDLERS = {
    "init": cmd_init,
    "list": cmd_list,
    "show": cmd_show,
    "add": cmd_add,
    "edit": cmd_edit,
    "remove": cmd_remove,
    "defaults": cmd_defaults,
    "render": cmd_render,
    "caddy-blocks": cmd_caddy_blocks,
    "sing-box-inbounds": cmd_sing_box_inbounds,
    "sing-box-outbounds": cmd_sing_box_outbounds,
    "sing-box-route-rules": cmd_sing_box_route_rules,
    "nft-config": cmd_nft_config,
    "nft-disabled-ports": cmd_nft_disabled_ports,
    "usage-from-nft": cmd_usage_from_nft,
    "record-usage": cmd_record_usage,
    "reset-period": cmd_reset_period,
    "enforce": cmd_enforce,
    "set-disabled": cmd_set_disabled,
    "get-setting": cmd_get_setting,
    "clear-external-cache": cmd_clear_external_cache,
    "field-values": cmd_field_values,
    "static-list": cmd_static_list,
    "parse-static-blob": cmd_parse_static_blob,
}


def main():
    args = build_parser().parse_args()
    return HANDLERS[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
