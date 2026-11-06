#!/usr/bin/env python3
"""检查或恢复本轮 before-tls-publish 快照; 默认只读, --apply 才会写入及重载.

仅恢复节点池、已登记订阅输出及 sing-box 配置. 保留当前生成器和订阅账单,
不修改 Caddy、证书、DNS、防火墙或 Git. 客户端仍需更新到恢复后的订阅.
"""

import argparse
import ast
from collections import Counter
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time

import yaml


LOCK_PATH = Path("/run/clash_subs.lock")
SERVER_TLS_FIELDS = {"server_name", "certificate_path", "key_path"}


class RollbackError(Exception):
    """外部快照、运行状态或命令不满足本次恢复契约."""


def require(condition, message):
    if not condition:
        raise RollbackError(message)


def checked_path(value, directory=False):
    """拒绝路径穿越、符号链接和非普通文件, 包含所有祖先目录."""
    path = Path(value)
    require(".." not in path.parts, "路径不得包含上级目录跳转")
    path = path.absolute()
    for parent in reversed(path.parents):
        require(stat.S_ISDIR(parent.lstat().st_mode), "路径祖先必须是普通目录, 不得使用符号链接")
    mode = path.lstat().st_mode
    require(stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode),
            "目标必须是普通目录或文件, 不得使用符号链接")
    return path


def document(path, json_format=False):
    try:
        text = path.read_text(encoding="utf-8")
        value = json.loads(text) if json_format else yaml.safe_load(text)
    except (UnicodeError, json.JSONDecodeError, yaml.YAMLError) as exc:
        raise RollbackError("配置编码或 YAML/JSON 语法无效") from exc
    require(isinstance(value, dict), "配置根节点必须是对象")
    return value


def command(arguments, label, timeout=20):
    """捕获外部命令输出, 错误摘要不输出配置内容或凭据."""
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RollbackError(label + "无法完成") from exc
    require(result.returncode == 0, label + "失败")
    return result.stdout


@contextmanager
def maintenance_lock():
    # 统计服务已创建此锁. 演练不创建锁文件, 更不替换其 inode.
    import fcntl

    path = checked_path(LOCK_PATH)
    with path.open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def without_server_tls(config):
    result = deepcopy(config)
    require(isinstance(result.get("inbounds"), list), "服务端缺少入站列表")
    for inbound in result["inbounds"]:
        require(isinstance(inbound, dict), "服务端入站必须是对象")
        if inbound.get("type") == "anytls":
            require(isinstance(inbound.get("tls"), dict) and inbound["tls"].get("enabled") is True,
                    "AnyTLS 入站必须启用 TLS")
            for field in SERVER_TLS_FIELDS:
                inbound["tls"].pop(field, None)
    return result


def node_map(data):
    nodes = data.get("nodes")
    require(isinstance(nodes, list) and nodes, "节点池必须包含非空节点列表")
    result = {}
    for node in nodes:
        require(isinstance(node, dict) and isinstance(node.get("server"), str) and node["server"],
                "节点缺少连接地址")
        require(node["server"] not in result, "本工具不支持重复节点入口")
        require(isinstance(node.get("skip_cert_verify", True), bool), "节点校验模式必须是布尔值")
        require(isinstance(node.get("sni", node["server"]), str), "节点 SNI 必须是字符串")
        result[node["server"]] = node
    return result


def without_node_tls(data):
    result = deepcopy(data)
    for node in result["nodes"]:
        node.pop("sni", None)
        node.pop("skip_cert_verify", None)
    return result


def output_identity(data, nodes, subscription, users):
    """忽略显示名称, 将组成员按节点身份归一化; 其他路由配置原样比较."""
    require(isinstance(data.get("proxies"), list), "订阅输出缺少代理节点列表")
    identities, names = [], {}
    for proxy in data["proxies"]:
        require(isinstance(proxy, dict) and isinstance(proxy.get("name"), str)
                and isinstance(proxy.get("server"), str), "订阅代理缺少名称或连接地址")
        require(proxy["name"] not in names, "订阅代理名称重复")
        item = dict(proxy)
        name = item.pop("name")
        if item.get("server") in nodes:
            node = nodes[item["server"]]
            require(item.get("port") == subscription["port"] and item.get("password") in users,
                    "订阅输出与当前入站端口或凭据不一致")
            require(item.get("sni") == (node.get("sni") or node["server"])
                    and item.get("skip-cert-verify") is node.get("skip_cert_verify", True),
                    "订阅输出与节点池 TLS 设置不一致")
            item.pop("sni")
            item.pop("skip-cert-verify")
        try:
            identity = json.dumps(item, sort_keys=True, ensure_ascii=False)
        except (TypeError, ValueError) as exc:
            raise RollbackError("订阅代理字段无法解析为配置对象") from exc
        names[name] = identity
        identities.append(identity)
    remainder = deepcopy(data)
    remainder.pop("proxies")
    groups = remainder.get("proxy-groups", [])
    require(isinstance(groups, list), "代理组必须是列表")
    for group in groups:
        require(isinstance(group, dict), "代理组必须是对象")
        if "proxies" in group:
            require(isinstance(group["proxies"], list)
                    and all(isinstance(member, str) for member in group["proxies"]), "代理组成员无效")
            group["proxies"] = [("node", names[member]) if member in names else ("group", member)
                                for member in group["proxies"]]
    return Counter(identities), remainder


def certificate_fingerprint(tls):
    require(all(isinstance(tls.get(field), str) and Path(tls[field]).is_absolute()
                for field in ("certificate_path", "key_path")), "原证书与私钥必须使用绝对文件路径")
    certificate = checked_path(tls["certificate_path"])
    key = checked_path(tls["key_path"])
    public_certificate = command(["openssl", "x509", "-in", str(certificate), "-pubkey", "-noout"], "原证书解析")
    public_key = command(["openssl", "pkey", "-in", str(key), "-pubout"], "原私钥解析")
    require(public_certificate == public_key, "原证书与私钥不匹配")
    der = command(["openssl", "x509", "-in", str(certificate), "-outform", "DER"], "原证书指纹读取")
    return hashlib.sha256(der).digest()


@dataclass
class Replacement:
    target: Path
    content: bytes
    metadata: os.stat_result


@dataclass
class PreparedRollback:
    files: list
    server: Replacement
    probes: list
    subs_path: Path
    subs_bytes: bytes


def prepare(snapshot, base, config):
    """锁内只读验证快照和当前配置, 固定待恢复内容, 避免执行时重读快照."""
    snapshot, base = checked_path(snapshot, True), checked_path(base, True)
    config = checked_path(config)
    subs_path = checked_path(base / "subs.yaml")
    subs_bytes = subs_path.read_bytes()
    subscriptions = document(subs_path).get("subscriptions")
    require(isinstance(subscriptions, list) and subscriptions, "当前订阅列表为空或无效")
    tokens, ports = set(), set()
    for sub in subscriptions:
        require(isinstance(sub, dict), "订阅必须是对象")
        token = sub.get("token")
        require(isinstance(token, str) and re.fullmatch(r"[A-Za-z0-9_-]+", token), "订阅 token 含非法路径字符")
        require(token not in tokens, "订阅 token 重复")
        require(type(sub.get("port")) is int and 1 <= sub["port"] <= 65535 and sub["port"] not in ports,
                "订阅端口无效或重复")
        require(isinstance(sub.get("name"), str) and isinstance(sub.get("password"), str), "订阅凭据缺失")
        require(isinstance(sub.get("disabled", False), bool), "订阅启停状态无效")
        tokens.add(token)
        ports.add(sub["port"])
    outputs = [Path("output") / sub["token"] / "clash.yaml" for sub in subscriptions]
    expected_files = {Path("nodes.yaml"), Path("clash_subs.py"), Path("server.json"), *outputs}
    expected_dirs = {Path("output"), *(relative.parent for relative in outputs)}
    actual_files = set()
    for directory, dirs, files in os.walk(snapshot, followlinks=False):
        for name in dirs:
            path = checked_path(Path(directory) / name, True)
            require(path.relative_to(snapshot) in expected_dirs, "快照包含非预期目录")
        for name in files:
            path = checked_path(Path(directory) / name)
            actual_files.add(path.relative_to(snapshot))
    require(actual_files == expected_files, "快照文件或订阅输出集合与当前订阅不匹配")
    try:
        ast.parse((snapshot / "clash_subs.py").read_text(encoding="utf-8"))
    except (UnicodeError, SyntaxError) as exc:
        raise RollbackError("快照生成器 Python 语法无效") from exc
    old_nodes, current_nodes = document(snapshot / "nodes.yaml"), document(checked_path(base / "nodes.yaml"))
    old_map, current_map = node_map(old_nodes), node_map(current_nodes)
    require(all(node.get("skip_cert_verify", True) for node in old_map.values()),
            "本工具仅恢复本轮原跳过证书校验模式, 不支持其他严格 TLS 快照")
    require(without_node_tls(old_nodes) == without_node_tls(current_nodes), "节点池存在本次 TLS 以外的变更")
    old_server, current_server = document(snapshot / "server.json", True), document(config, True)
    require(without_server_tls(old_server) == without_server_tls(current_server),
            "服务端端口、凭据、路由或其他非 TLS 配置已改变, 拒绝回退")
    inbounds = [item for item in old_server["inbounds"] if item.get("type") == "anytls"]
    require(all(type(item.get("listen_port")) is int for item in inbounds), "入站端口必须是整数")
    require(len(inbounds) == len(ports) and {item.get("listen_port") for item in inbounds} == ports,
            "当前订阅与快照 AnyTLS 入站端口不一致")
    by_port = {item["listen_port"]: item for item in inbounds}
    fingerprints, probes = {}, []
    for sub, relative in zip(subscriptions, outputs):
        inbound = by_port[sub["port"]]
        users = inbound.get("users")
        require(isinstance(users, list) and all(isinstance(user, dict)
                and isinstance(user.get("name"), str) and isinstance(user.get("password"), str)
                for user in users), "入站用户列表无效")
        expected_users = {sub["name"]: sub["password"]}
        static_passwords = sub.get("static_passwords", [])
        require(isinstance(static_passwords, list) and all(isinstance(password, str) for password in static_passwords),
                "当前静态入口密码列表无效")
        expected_users.update({f"{sub['name']}--static-{index}": password
                               for index, password in enumerate(static_passwords)})
        require(any(user.get("name") == sub["name"] and user.get("password") == sub["password"] for user in users)
                and all(user.get("name") in expected_users and user.get("password") == expected_users[user["name"]]
                        for user in users), "入站用户密码与当前订阅不一致")
        passwords = {user["password"] for user in users}
        old_output = document(snapshot / relative)
        current_output = document(checked_path(base / relative))
        require(output_identity(old_output, old_map, sub, passwords)
                == output_identity(current_output, current_map, sub, passwords),
                "订阅输出存在本次 TLS 与显示名称以外的变更")
        tls = inbound["tls"]
        require(all(isinstance(tls.get(field), str) for field in ("certificate_path", "key_path")),
                "原证书与私钥路径必须是字符串")
        identity = (tls.get("certificate_path"), tls.get("key_path"))
        if identity not in fingerprints:
            fingerprints[identity] = certificate_fingerprint(tls)
        if not sub.get("disabled", False):
            require(isinstance(tls.get("server_name"), str) and tls["server_name"], "原入站缺少 TLS 名称")
            probes.append((sub["port"], tls["server_name"], fingerprints[identity]))
    require(probes, "没有启用订阅可用于确认恢复, 拒绝回退")
    command(["sing-box", "check", "-c", str(snapshot / "server.json")], "快照 sing-box 配置检查")
    files = []
    for relative in [Path("nodes.yaml"), *outputs]:
        target = checked_path(base / relative)
        files.append(Replacement(target, (snapshot / relative).read_bytes(), target.stat()))
    return PreparedRollback(files, Replacement(config, (snapshot / "server.json").read_bytes(), config.stat()),
                            probes, subs_path, subs_bytes)


def atomic_replace(replacement):
    descriptor, temporary = tempfile.mkstemp(prefix=".clash-rollback-", dir=replacement.target.parent)
    path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(replacement.content)
            stream.flush()
            os.fchown(stream.fileno(), replacement.metadata.st_uid, replacement.metadata.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(replacement.metadata.st_mode))
            os.fsync(stream.fileno())
        path.replace(replacement.target)
    finally:
        path.unlink(missing_ok=True)


def wait_for_restored_service(probes):
    # 回退对象可能是原自签证书; 直接固定已验证的快照证书指纹, 不信任任意证书.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    deadline = time.monotonic() + 20
    for port, name, expected in probes:
        while time.monotonic() < deadline:
            active = subprocess.run(["systemctl", "is-active", "--quiet", "sing-box"],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=3)
            if active.returncode == 0:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=2) as raw:
                        with context.wrap_socket(raw, server_hostname=name) as secured:
                            observed = hashlib.sha256(secured.getpeercert(binary_form=True)).digest()
                    if observed == expected:
                        break
                except (OSError, ssl.SSLError):
                    pass
            time.sleep(0.2)
        else:
            raise RollbackError("文件已恢复, 但未确认启用端口呈现原证书; 回退尚未验收")


def apply(prepared):
    # 先恢复客户端文件, 使旧跳过校验配置在证书切换前后均可更新获取.
    for replacement in prepared.files:
        atomic_replace(replacement)
    atomic_replace(prepared.server)
    command(["systemctl", "reload", "sing-box"], "sing-box 重载", timeout=30)
    wait_for_restored_service(prepared.probes)
    require(prepared.subs_path.read_bytes() == prepared.subs_bytes, "订阅账单在恢复期间发生变化, 未确认完整恢复")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--base", type=Path, default=Path("/opt/ai-stack/clash"))
    parser.add_argument("--config", type=Path, default=Path("/etc/sing-box/config.json"))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="只读验证快照与恢复条件 (默认)")
    mode.add_argument("--apply", action="store_true", help="恢复指定文件并重载 sing-box, 会中断现有代理连接")
    args = parser.parse_args(argv)
    try:
        require(sys.platform.startswith("linux"), "恢复工具仅支持 Linux")
        with maintenance_lock():
            prepared = prepare(args.snapshot, args.base, args.config)
            if args.apply:
                apply(prepared)
                print("ROLLBACK_OK: 已恢复指定文件并核对原证书; 请更新客户端订阅")
            else:
                print("CHECK_OK: 快照及恢复条件验证通过; 未写文件、未重载服务")
        return 0
    except (RollbackError, OSError, subprocess.TimeoutExpired) as exc:
        # 不打印底层命令输出或配置对象, 避免异常携带凭据.
        message = str(exc) if isinstance(exc, RollbackError) else type(exc).__name__
        print("ROLLBACK_NOT_CONFIRMED: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
