"""只用合成目录与 mock 命令检验限定 TLS 回退, 不操作系统服务或生产文件."""

from contextlib import nullcontext
from copy import deepcopy
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("clash_rollback", ROOT / "ai_stack/clash_rollback.py")
rollback = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = rollback
SPEC.loader.exec_module(rollback)


class ClashRollbackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="howe-rollback-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base, self.snapshot = self.root / "live", self.root / "snapshot"
        self.base.mkdir()
        self.snapshot.mkdir()
        self.config = self.root / "config.json"
        self.cert, self.key = self.root / "old.crt", self.root / "old.key"
        self.cert.write_text("synthetic certificate")
        self.key.write_text("synthetic key")
        self.subscriptions = [
            {"name": "active", "token": "synthetic-active", "port": 15443, "password": "main-secret",
             "static_passwords": ["static-secret"], "disabled": False, "usage": {"total_bytes": 123456}},
            {"name": "disabled", "token": "synthetic-disabled", "port": 15444, "password": "other-secret",
             "static_passwords": [], "disabled": True, "usage": {"total_bytes": 654321}},
        ]
        self.write_yaml(self.base / "subs.yaml", {"subscriptions": self.subscriptions})
        old_nodes = {"nodes": [{"name": "self", "server": "node.example.com", "sni": "192.0.2.10",
                                "skip_cert_verify": True, "port": 0, "password": "PER_SUB"}]}
        new_nodes = deepcopy(old_nodes)
        new_nodes["nodes"][0].update(sni="node.example.com", skip_cert_verify=False)
        self.write_yaml(self.snapshot / "nodes.yaml", old_nodes)
        self.write_yaml(self.base / "nodes.yaml", new_nodes)
        (self.snapshot / "clash_subs.py").write_text("print('old generator')\n")
        (self.base / "clash_subs.py").write_text("print('new generator')\n")
        self.old_server = {"log": {"level": "warn"}, "inbounds": [],
                           "outbounds": [{"type": "direct", "tag": "direct"}], "route": {"final": "direct"}}
        for sub in self.subscriptions:
            users = [{"name": sub["name"], "password": sub["password"]}]
            users.extend({"name": sub["name"] + f"--static-{index}", "password": password}
                         for index, password in enumerate(sub["static_passwords"]))
            self.old_server["inbounds"].append({
                "type": "anytls", "listen": "0.0.0.0", "listen_port": sub["port"], "users": users,
                "tls": {"enabled": True, "server_name": "192.0.2.10",
                        "certificate_path": str(self.cert), "key_path": str(self.key)},
            })
            proxies = [{"name": "old remaining usage", "type": "anytls", "server": "node.example.com",
                        "port": sub["port"], "password": sub["password"], "sni": "192.0.2.10",
                        "skip-cert-verify": True},
                       {"name": "external", "type": "anytls", "server": "external.example.com", "port": 443,
                        "password": "external-secret", "sni": "external.example.com", "skip-cert-verify": False}]
            if sub["static_passwords"]:
                static = dict(proxies[0], name="static", password=sub["static_passwords"][0])
                proxies.append(static)
            old_output = {"dns": {"nameserver": ["223.5.5.5"]}, "rules": ["MATCH,proxy"], "proxies": proxies,
                          "proxy-groups": [{"name": "proxy", "type": "select",
                                            "proxies": [proxy["name"] for proxy in proxies]}]}
            new_output = deepcopy(old_output)
            for proxy in new_output["proxies"]:
                if proxy["server"] == "node.example.com":
                    proxy.update(sni="node.example.com", **{"skip-cert-verify": False})
            new_output["proxies"][0]["name"] = "new remaining usage"
            new_output["proxy-groups"][0]["proxies"][0] = "new remaining usage"
            relative = Path("output") / sub["token"] / "clash.yaml"
            for parent, data in ((self.snapshot, old_output), (self.base, new_output)):
                (parent / relative).parent.mkdir(parents=True)
                self.write_yaml(parent / relative, data)
        self.write_server(self.snapshot / "server.json", self.old_server)
        current_server = deepcopy(self.old_server)
        for inbound in current_server["inbounds"]:
            inbound["tls"].update(server_name="node.example.com", certificate_path="/new/managed.crt",
                                  key_path="/new/managed.key")
        self.write_server(self.config, current_server)
        self.argv = ["--snapshot", str(self.snapshot), "--base", str(self.base), "--config", str(self.config)]
        self.commands = []
        self.command_mock = mock.patch.object(rollback, "command", side_effect=self.fake_command)
        self.command_mock.start()
        self.addCleanup(self.command_mock.stop)

    @staticmethod
    def write_yaml(path, data):
        path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")

    @staticmethod
    def write_server(path, data):
        path.write_text(json.dumps(data), encoding="utf-8")

    def fake_command(self, arguments, label, timeout=20):
        self.commands.append(arguments)
        if "-pubkey" in arguments or "-pubout" in arguments:
            return b"synthetic matching public key"
        if "DER" in arguments:
            return b"synthetic leaf DER"
        return b""

    def prepare(self):
        return rollback.prepare(self.snapshot, self.base, self.config)

    def tree_state(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode)
                for path in self.root.rglob("*") if path.is_file()}

    def invoke(self, *flags):
        with mock.patch.object(rollback.sys, "platform", "linux"), \
                mock.patch.object(rollback, "maintenance_lock", return_value=nullcontext()), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            result = rollback.main(self.argv + list(flags))
        return result, output.getvalue(), errors.getvalue()

    def test_default_and_explicit_check_do_not_write_or_reload(self):
        before = self.tree_state()
        for flags in ((), ("--check",)):
            result, output, errors = self.invoke(*flags)
            self.assertEqual(result, 0, errors)
            self.assertIn("CHECK_OK", output)
            self.assertEqual(self.tree_state(), before)
        self.assertFalse(any(arguments[0] == "systemctl" for arguments in self.commands))
        self.assertTrue(any(arguments[:2] == ["sing-box", "check"] for arguments in self.commands))

    def test_snapshot_must_match_current_output_inventory(self):
        (self.snapshot / "output/synthetic-active/clash.yaml").unlink()
        with self.assertRaisesRegex(rollback.RollbackError, "集合"):
            self.prepare()

    def test_extra_snapshot_file_is_rejected(self):
        (self.snapshot / "subs.yaml").write_text("subscriptions: []\n")
        with self.assertRaisesRegex(rollback.RollbackError, "集合"):
            self.prepare()

    def test_token_path_traversal_is_rejected_before_any_command(self):
        for token in ("../escape", "a/b", "a\\b", ".", ".."):
            with self.subTest(token=token):
                data = deepcopy(self.subscriptions)
                data[0]["token"] = token
                self.write_yaml(self.base / "subs.yaml", {"subscriptions": data})
                with self.assertRaisesRegex(rollback.RollbackError, "路径"):
                    self.prepare()
        self.assertFalse(self.commands)

    @unittest.skipUnless(os.name == "posix", "符号链接与 inode 检查在 Linux 验证")
    def test_snapshot_symlink_and_symlink_parent_are_rejected(self):
        path = self.snapshot / "clash_subs.py"
        path.unlink()
        path.symlink_to(self.base / "clash_subs.py")
        with self.assertRaisesRegex(rollback.RollbackError, "符号链接"):
            self.prepare()
        path.unlink()
        path.write_text("print('old generator')\n")
        alias = self.root / "alias"
        alias.symlink_to(self.snapshot, target_is_directory=True)
        with self.assertRaisesRegex(rollback.RollbackError, "符号链接"):
            rollback.prepare(alias, self.base, self.config)
        with self.assertRaisesRegex(rollback.RollbackError, "符号链接"):
            rollback.checked_path(alias / "nodes.yaml")

    def test_malformed_document_is_rejected_without_secret_output(self):
        (self.snapshot / "nodes.yaml").write_text("nodes: [synthetic-secret")
        result, output, errors = self.invoke("--check")
        self.assertEqual(result, 1)
        self.assertNotIn("synthetic-secret", errors)
        self.assertNotIn("CHECK_OK", output)

    def test_changed_server_password_or_route_is_rejected(self):
        original = self.config.read_bytes()
        for change in ("password", "route"):
            with self.subTest(change=change):
                config = json.loads(original)
                if change == "password":
                    config["inbounds"][0]["users"][0]["password"] = "changed"
                else:
                    config["route"]["final"] = "different"
                self.write_server(self.config, config)
                with self.assertRaisesRegex(rollback.RollbackError, "非 TLS"):
                    self.prepare()
        self.config.write_bytes(original)

    def test_changed_current_subscription_password_is_rejected(self):
        self.subscriptions[0]["password"] = "changed-current-password"
        self.write_yaml(self.base / "subs.yaml", {"subscriptions": self.subscriptions})
        with self.assertRaisesRegex(rollback.RollbackError, "密码"):
            self.prepare()

    def test_other_strict_tls_snapshot_is_out_of_scope(self):
        path = self.snapshot / "nodes.yaml"
        data = yaml.safe_load(path.read_text())
        data["nodes"][0]["skip_cert_verify"] = False
        self.write_yaml(path, data)
        with self.assertRaisesRegex(rollback.RollbackError, "本轮"):
            self.prepare()

    def test_changed_dns_rules_groups_and_external_tls_are_rejected(self):
        path = self.base / "output/synthetic-active/clash.yaml"
        original = path.read_bytes()
        for change in ("dns", "rules", "groups", "external"):
            with self.subTest(change=change):
                data = yaml.safe_load(original)
                if change == "dns":
                    data["dns"]["nameserver"] = ["192.0.2.53"]
                elif change == "rules":
                    data["rules"] = ["MATCH,DIRECT"]
                elif change == "groups":
                    data["proxy-groups"][0]["proxies"].append("DIRECT")
                else:
                    data["proxies"][1]["skip-cert-verify"] = True
                self.write_yaml(path, data)
                with self.assertRaisesRegex(rollback.RollbackError, "显示名称以外"):
                    self.prepare()
        path.write_bytes(original)

    def test_missing_or_mismatched_original_key_is_rejected(self):
        self.key.unlink()
        with self.assertRaises(FileNotFoundError):
            self.prepare()
        self.key.write_text("synthetic key")
        def mismatched(arguments, label, timeout=20):
            return b"different key" if "-pubout" in arguments else self.fake_command(arguments, label, timeout)
        with mock.patch.object(rollback, "command", side_effect=mismatched):
            with self.assertRaisesRegex(rollback.RollbackError, "不匹配"):
                self.prepare()

    def test_write_failure_never_claims_success(self):
        before = self.tree_state()
        with mock.patch.object(rollback, "atomic_replace", side_effect=OSError("synthetic write failure")):
            result, output, errors = self.invoke("--apply")
        self.assertEqual(result, 1)
        self.assertNotIn("ROLLBACK_OK", output)
        self.assertIn("ROLLBACK_NOT_CONFIRMED", errors)
        self.assertEqual(self.tree_state(), before)

    @unittest.skipUnless(os.name == "posix", "原子恢复与权限保留在 Linux 验证")
    def test_apply_restores_only_targets_preserves_billing_permissions_and_active_probes(self):
        (self.base / "clash_subs.py").chmod(0o751)
        self.config.chmod(0o640)
        unrelated = self.base / "template.yaml"
        unrelated.write_text("unrelated template")
        before = (self.base / "subs.yaml").read_bytes()
        generator = (self.base / "clash_subs.py").read_bytes()
        prepared = self.prepare()
        with mock.patch.object(rollback, "wait_for_restored_service") as health:
            rollback.apply(prepared)
        self.assertEqual((self.base / "subs.yaml").read_bytes(), before)
        self.assertEqual((self.base / "clash_subs.py").read_bytes(), generator)
        self.assertEqual(unrelated.read_text(), "unrelated template")
        self.assertEqual(self.config.read_bytes(), (self.snapshot / "server.json").read_bytes())
        self.assertEqual([probe[0] for probe in health.call_args.args[0]], [15443])
        for replacement in prepared.files + [prepared.server]:
            self.assertEqual(replacement.target.read_bytes(), replacement.content)
            current = replacement.target.stat()
            self.assertEqual(stat.S_IMODE(current.st_mode), stat.S_IMODE(replacement.metadata.st_mode))
            self.assertEqual((current.st_uid, current.st_gid), (replacement.metadata.st_uid, replacement.metadata.st_gid))

    @unittest.skipUnless(os.name == "posix", "原子恢复与服务失败检查在 Linux 验证")
    def test_reload_failure_never_claims_success_or_touches_billing(self):
        billing = (self.base / "subs.yaml").read_bytes()
        def failing(arguments, label, timeout=20):
            if arguments[:2] == ["systemctl", "reload"]:
                raise rollback.RollbackError("synthetic reload failure")
            return self.fake_command(arguments, label, timeout)
        with mock.patch.object(rollback, "command", side_effect=failing):
            result, output, errors = self.invoke("--apply")
        self.assertEqual(result, 1)
        self.assertNotIn("ROLLBACK_OK", output)
        self.assertIn("ROLLBACK_NOT_CONFIRMED", errors)
        self.assertEqual((self.base / "subs.yaml").read_bytes(), billing)

    @unittest.skipUnless(os.name == "posix", "服务恢复核对在 Linux 验证")
    def test_tls_probe_failure_never_claims_success(self):
        with mock.patch.object(rollback, "wait_for_restored_service", side_effect=rollback.RollbackError("TLS mismatch")):
            result, output, errors = self.invoke("--apply")
        self.assertEqual(result, 1)
        self.assertNotIn("ROLLBACK_OK", output)
        self.assertIn("TLS mismatch", errors)

    @unittest.skipUnless(os.name == "posix", "只读锁检查在 Linux 验证")
    def test_check_lock_is_not_created_or_replaced(self):
        lock = self.root / "maintenance.lock"
        with mock.patch.object(rollback, "LOCK_PATH", lock):
            with self.assertRaises(FileNotFoundError), rollback.maintenance_lock():
                pass
            self.assertFalse(lock.exists())
            lock.write_bytes(b"existing lock")
            inode = lock.stat().st_ino
            with rollback.maintenance_lock():
                pass
            self.assertEqual(lock.read_bytes(), b"existing lock")
            self.assertEqual(lock.stat().st_ino, inode)


if __name__ == "__main__":
    unittest.main()
