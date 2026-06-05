#!/usr/bin/env python3
"""
Clash 订阅流量统计 + 限流执法（轮询服务）

由 systemd timer 每 stats_refresh_minutes 分钟触发，单次执行：
  1. nft -j list table inet clash_subs → 拿当前 counter 值
  2. clash_subs.py usage-from-nft         → 差分入账到 subs.yaml
  3. clash_subs.py reset-period           → 跨月清零 period_bytes
  4. clash_subs.py enforce                → 按用量/到期算 disabled
  5. 同步 nft disabled_ports set          → 增量 add/delete element
       不 reload table（reload 会清零 counter，丢失下一周期数据）

并发保护：fcntl flock，避免和菜单操作（add/edit/remove）冲突写 subs.yaml。
"""
import argparse
import fcntl
import json
import os
import subprocess
import sys


CLASH_SUBS = "/opt/ai-stack/clash/clash_subs.py"
NFT_TABLE = "inet clash_subs"
LOCK_PATH = "/run/clash_subs.lock"


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def nft_dump_json():
    return run(["nft", "-j", "list", "table"] + NFT_TABLE.split()).stdout


def current_disabled_set():
    """读 nft 当前 disabled_ports set 的元素，返回端口集合。"""
    out = run(["nft", "-j", "list", "set"] + NFT_TABLE.split() + ["disabled_ports"]).stdout
    data = json.loads(out)
    ports = set()
    for entry in data.get("nftables", []):
        s = entry.get("set")
        if not s:
            continue
        for el in s.get("elem") or []:
            if isinstance(el, int):
                ports.add(el)
            elif isinstance(el, dict):
                # interval form
                rng = el.get("range")
                if rng and len(rng) == 2:
                    for p in range(int(rng[0]), int(rng[1]) + 1):
                        ports.add(p)
                elif "elem" in el:
                    ports.add(int(el["elem"]))
    return ports


def desired_disabled_set(clash_subs_py, base):
    out = run(["python3", clash_subs_py, "--base", base, "nft-disabled-ports"]).stdout
    return {int(x) for x in out.split() if x.strip()}


def sync_disabled_ports(clash_subs_py, base):
    """增量同步 disabled_ports set。"""
    cur = current_disabled_set()
    want = desired_disabled_set(clash_subs_py, base)
    to_add = want - cur
    to_del = cur - want
    for p in sorted(to_add):
        subprocess.run(["nft", "add", "element", "inet", "clash_subs",
                        "disabled_ports", "{ %d }" % p], check=False)
    for p in sorted(to_del):
        subprocess.run(["nft", "delete", "element", "inet", "clash_subs",
                        "disabled_ports", "{ %d }" % p], check=False)
    return to_add, to_del


def main():
    p = argparse.ArgumentParser(description="Clash 订阅流量统计 + 限流执法")
    p.add_argument("--base", default="/opt/ai-stack/clash")
    p.add_argument("--clash-subs", default=CLASH_SUBS, dest="clash_subs")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    if not os.path.exists(args.clash_subs):
        print(f"clash_subs.py 不存在: {args.clash_subs}", file=sys.stderr)
        return 1

    # 检查 nft table 是否存在；不存在直接退出（首装 / sing-box 未启用）
    r = subprocess.run(["nft", "list", "table"] + NFT_TABLE.split(),
                       capture_output=True)
    if r.returncode != 0:
        if args.verbose:
            print(f"nft table {NFT_TABLE} 不存在，跳过本轮")
        return 0

    # 互斥锁
    lock_fd = os.open(LOCK_PATH, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if args.verbose:
                print("已有实例在跑，跳过")
            return 0

        # 1. dump nft counters
        nft_json = nft_dump_json()

        # 2. 差分入账
        cs_args = ["python3", args.clash_subs, "--base", args.base, "usage-from-nft", "--json", "-"]
        if args.verbose:
            cs_args.append("--verbose")
        rec = subprocess.run(cs_args, input=nft_json, capture_output=True, text=True)
        if rec.returncode != 0:
            print(f"usage-from-nft 失败: {rec.stderr}", file=sys.stderr)
            return rec.returncode
        if args.verbose and rec.stdout.strip():
            print(rec.stdout, end="")

        # 3. reset-period
        subprocess.run(["python3", args.clash_subs, "--base", args.base, "reset-period"],
                       capture_output=not args.verbose)

        # 4. enforce
        en = subprocess.run(["python3", args.clash_subs, "--base", args.base, "enforce"],
                            capture_output=True, text=True)
        if args.verbose and en.stdout.strip():
            print(en.stdout, end="")

        # 4b. 重渲染所有订阅 yaml：让"剩余流量 / 距离重置 / 超额-到期告警"
        #     节点跟 subs.yaml 的最新值保持一致（按需触发的拉取也能看到改动）
        rr = subprocess.run(["python3", args.clash_subs, "--base", args.base, "render", "--all"],
                            capture_output=True, text=True)
        if args.verbose and rr.stdout.strip():
            print(rr.stdout, end="")

        # 5. 同步 disabled_ports（增量）
        added, removed = sync_disabled_ports(args.clash_subs, args.base)
        if args.verbose and (added or removed):
            print(f"disabled_ports: +{sorted(added)} -{sorted(removed)}")

    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except Exception:
            pass
        os.close(lock_fd)

    return 0


if __name__ == "__main__":
    sys.exit(main())
