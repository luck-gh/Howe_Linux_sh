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
    # 每订阅独立端口段（≤ 16 个用户）
    "port_min": 13443,
    "port_max": 13458,
    # 外购 Clash 订阅：默认 URL（空 = 不启用），节点显示前缀
    "external_url": "",
    "external_name_prefix": "[外购] ",
}

# 默认值字段类型（影响 cmd_defaults 转换）
INT_DEFAULT_KEYS = {
    "traffic_gb", "reset_day", "expire_days", "update_interval_hours",
    "stats_refresh_minutes", "port_min", "port_max",
}


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


def fetch_external_yaml(url, base, ttl_seconds, force=False):
    """拉取外购 Clash yaml，失败兜底用旧缓存。返回 dict 或 None。

    缓存命中（force=False 且未过期）→ 直接读缓存
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


def load_external_proxies(base, sub, defs, ttl_seconds):
    """拉外购 yaml，提取 proxies 列表，加前缀 + 命名去重。"""
    url = resolve_external_url(sub, defs)
    if not url:
        return []
    data = fetch_external_yaml(url, base, ttl_seconds)
    if not isinstance(data, dict):
        return []
    raw = data.get("proxies")
    if not isinstance(raw, list):
        sys.stderr.write(f"[external] {url}：未找到 proxies 列表，跳过\n")
        return []
    prefix = defs.get("external_name_prefix") or ""
    out = []
    seen = set()
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
        out.append(q)
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


def auto_node_name(node, base):
    """节点 name 为空时，根据 server 地址自动生成显示名。
    格式：[自建] 🇺🇸 United States · Los Angeles (1.2.3.4)
    name 非空则原样返回。
    """
    name = (node.get("name") or "").strip()
    if name:
        return name
    server = node.get("server", "")
    flag, country, city = lookup_ip_geo(server, base)
    parts = []
    if flag:
        parts.append(flag)
    if country:
        parts.append(country)
    if city and city != country:
        parts.append(f"· {city}")
    if server:
        parts.append(f"({server})")
    geo_str = " ".join(parts) if parts else server
    return f"[自建] {geo_str}" if geo_str else "[自建]"


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
    out.update({k: d[k] for k in BUILTIN_DEFAULTS if k in d})
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
        f"      外购源      : {ext_line}"
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
            sub["external_url"] = args.external_url


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
    ):
        v = getattr(args, attr, None)
        if v is None:
            continue
        defs[key] = int(v) if key in INT_DEFAULT_KEYS else str(v)
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
    real = [] if expired else [make_proxy(auto_node_name(n, base), n, pwd, sub_port) for n in nodes]

    # 外购订阅节点（不计流量、不受 nft 限流约束）
    ttl = int(defs.get("stats_refresh_minutes", 10)) * 60
    external = load_external_proxies(base, sub, defs, ttl)

    proxies = info + real + external
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

    # 移除上一次渲染遗留的子组（idempotent）
    groups[:] = [g for g in groups if g.get("name") not in ("VPS 节点", "外购")]
    # first 可能因为上一行被剔除（如果它就叫 "VPS 节点"），重新拿
    first = groups[0] if groups else _FlowMap({"name": "代理", "type": "select"})
    if not groups:
        groups.append(first)
        tpl["proxy-groups"] = groups

    # 把模板里已有的 group 也转成 _FlowMap（保证 flow style 输出）
    groups[:] = [_FlowMap(g) if not isinstance(g, _FlowMap) else g for g in groups]
    first = groups[0]

    sub_entries = ["VPS 节点"] + (["外购"] if external_names else [])
    first["proxies"] = keep_front + sub_entries + keep_back
    groups.append(_FlowMap({"name": "VPS 节点", "type": "select", "proxies": vps_names}))
    if external_names:
        groups.append(_FlowMap({"name": "外购", "type": "select", "proxies": ["DIRECT"] + external_names}))

    out_dir = os.path.join(p["output"], sub["token"])
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "clash.yaml")
    dump_yaml(out_path, tpl)
    extra = f", 外购 {len(external)}" if external else ""
    print(f"rendered: {sub['name']} → {out_path} ({len(real)} 节点{extra}, port={sub_port})")


def cmd_render(args):
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
def cmd_sing_box_inbounds(args):
    """输出 sing-box config.json 的 inbounds[] 数组（多 anytls inbound，每订阅一个端口）。
    所有订阅都输出，限流交给 nftables drop（避免 restart sing-box 冲断在线连接）。
    --tls-cert / --tls-key / --server-name 必填，由 sh 脚本统一传入。"""
    import json as _json
    subs = read_subs_normalized(args.base)
    inbounds = []
    for s in subs:
        inbounds.append({
            "type": "anytls",
            "tag": f"in-{s['name']}",
            "listen": "0.0.0.0",
            "listen_port": int(s["port"]),
            "users": [{"name": s["name"], "password": s["password"]}],
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

    rd = sub.add_parser("render")
    g = rd.add_mutually_exclusive_group()
    g.add_argument("--name")
    g.add_argument("--all", action="store_true")

    cb = sub.add_parser("caddy-blocks")
    cb.add_argument("--host", default="")

    sbi = sub.add_parser("sing-box-inbounds")
    sbi.add_argument("--tls-cert", dest="tls_cert", required=True)
    sbi.add_argument("--tls-key", dest="tls_key", required=True)
    sbi.add_argument("--server-name", dest="server_name", required=True)

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
    "nft-config": cmd_nft_config,
    "nft-disabled-ports": cmd_nft_disabled_ports,
    "usage-from-nft": cmd_usage_from_nft,
    "record-usage": cmd_record_usage,
    "reset-period": cmd_reset_period,
    "enforce": cmd_enforce,
    "set-disabled": cmd_set_disabled,
    "get-setting": cmd_get_setting,
    "clear-external-cache": cmd_clear_external_cache,
}


def main():
    args = build_parser().parse_args()
    return HANDLERS[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
