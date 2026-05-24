#!/usr/bin/env python3
"""
Clash 订阅按需刷新 HTTP 服务

监听 127.0.0.1:13888，由 caddy 反代 /sub/* 过来。每次客户端拉
/sub/<token>/clash.yaml：
  1. 触发一次 stats 流水线（5s 防抖；并发请求只跑一次）
  2. 重新读 subs.yaml 拿最新 usage / disabled
  3. 动态写 Subscription-Userinfo / Profile-Update-Interval /
     Content-Disposition 头，再 file_server 出渲染好的 yaml
  4. 超额 / 到期不返回 410——yaml 里会渲染告警节点；
     断网由 nft disabled_ports drop 完成

systemd: clash-subs-serve.service —— Type=simple，常驻
"""
import argparse
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import yaml


DEFAULT_BASE = "/opt/ai-stack/clash"
DEFAULT_STATS = "/opt/ai-stack/clash/clash_subs_stats.py"
DEFAULT_CLASH_SUBS = "/opt/ai-stack/clash/clash_subs.py"
DEBOUNCE_SECONDS = 5

_refresh_lock = threading.Lock()
_last_refresh_ts = 0.0


def trigger_refresh(stats_py, base, clash_subs_py):
    """跑一次 stats 流水线，带 5s 防抖；并发请求只让一个真跑，其它直接跳过。"""
    global _last_refresh_ts
    if not _refresh_lock.acquire(blocking=False):
        return
    try:
        if time.monotonic() - _last_refresh_ts < DEBOUNCE_SECONDS:
            return
        try:
            subprocess.run(
                ["python3", stats_py, "--base", base, "--clash-subs", clash_subs_py],
                capture_output=True, timeout=20,
            )
        except Exception as e:
            sys.stderr.write(f"[serve] stats refresh failed: {e}\n")
        _last_refresh_ts = time.monotonic()
    finally:
        _refresh_lock.release()


def load_sub_by_token(base, token):
    p = os.path.join(base, "subs.yaml")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        data = yaml.safe_load(f) or {}
    for s in data.get("subscriptions") or []:
        if s.get("token") == token:
            return s
    return None


def expire_unix(expire_str):
    if not expire_str:
        return 0
    d = datetime.strptime(expire_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(d.timestamp())


def build_userinfo(sub):
    total = int(sub.get("traffic_gb", 0)) * 1024 * 1024 * 1024
    used = int((sub.get("usage") or {}).get("period_bytes") or 0)
    exp = expire_unix(sub.get("expire"))
    return f"upload=0; download={used}; total={total}; expire={exp}"


class Handler(BaseHTTPRequestHandler):
    server_version = "ClashSubsServe/1.0"

    # 类属性，main 启动时填好
    base = DEFAULT_BASE
    stats_py = DEFAULT_STATS
    clash_subs_py = DEFAULT_CLASH_SUBS

    def log_message(self, fmt, *args):
        sys.stderr.write("[serve] %s - %s\n" % (self.address_string(), fmt % args))

    def _send_text(self, status, body, extra_headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        self._serve(head_only=False)

    def _serve(self, head_only):
        path = urlsplit(self.path).path
        # caddy 经 handle_path /sub/* 已剥掉前缀；此处兼容剥与不剥两种
        rel = path[len("/sub/"):] if path.startswith("/sub/") else path.lstrip("/")
        rel = rel.rstrip("/")
        # 支持两种形式：<token>  或  <token>/clash.yaml（老 URL 兼容）
        if "/" in rel:
            parts = rel.split("/", 1)
            if len(parts) != 2 or not parts[1].endswith(".yaml"):
                self._send_text(404, "not found\n")
                return
            token = parts[0]
        else:
            token = rel
        if not token or "/" in token or ".." in token:
            self._send_text(404, "not found\n")
            return

        # 1. 先校验 token 存在；不存在直接 404，不触发 refresh
        #    （否则恶意请求 /sub/<随机>/ 就能不断打 stats 流水线）
        sub = load_sub_by_token(self.base, token)
        if not sub:
            self._send_text(404, "subscription not found\n")
            return

        # 2. 触发按需刷新（防抖；失败不阻断响应——还能用上次的快照）
        trigger_refresh(self.stats_py, self.base, self.clash_subs_py)

        # 3. 重新读最新（refresh 可能更新了 usage / disabled）
        sub = load_sub_by_token(self.base, token) or sub

        userinfo = build_userinfo(sub)

        # 4. 不再因 disabled 返回 410：客户端仍可下载 yaml；yaml 里渲染
        #    超额 / 到期告警节点。真正断网由 nft disabled_ports drop 完成。

        # 5. 流出 output/<token>/clash.yaml
        out_path = os.path.join(self.base, "output", token, "clash.yaml")
        try:
            st = os.stat(out_path)
            f = open(out_path, "rb")
        except FileNotFoundError:
            self._send_text(404, "rendered file missing\n",
                            extra_headers={"Subscription-Userinfo": userinfo})
            return

        try:
            interval = int(sub.get("update_interval_hours", 24))
            self.send_response(200)
            self.send_header("Content-Type", "application/yaml; charset=utf-8")
            self.send_header("Content-Length", str(st.st_size))
            self.send_header("Subscription-Userinfo", userinfo)
            self.send_header("Profile-Update-Interval", str(interval))
            self.send_header(
                "Content-Disposition",
                f'attachment; filename=VPS_{sub["name"]}.yaml',
            )
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if not head_only:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        finally:
            f.close()


def main():
    p = argparse.ArgumentParser(description="Clash 订阅按需刷新 HTTP 服务")
    p.add_argument("--base", default=DEFAULT_BASE)
    p.add_argument("--stats-py", default=DEFAULT_STATS, dest="stats_py")
    p.add_argument("--clash-subs", default=DEFAULT_CLASH_SUBS, dest="clash_subs_py")
    p.add_argument("--listen", default="127.0.0.1")
    p.add_argument("--port", type=int, default=13888)
    args = p.parse_args()

    Handler.base = args.base
    Handler.stats_py = args.stats_py
    Handler.clash_subs_py = args.clash_subs_py

    httpd = ThreadingHTTPServer((args.listen, args.port), Handler)
    sys.stderr.write(f"[serve] listening on {args.listen}:{args.port} base={args.base}\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
