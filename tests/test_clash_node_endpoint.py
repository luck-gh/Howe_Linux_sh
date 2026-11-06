"""自建节点入口回归: 精确更新, 域名保留, 输入边界及首次安装流程."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("clash_subs", ROOT / "ai_stack/doc/clash_subs.py")
clash = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(clash)


class NodeEndpointTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name) / "clash"
        self.base.mkdir()
        self.path = self.base / "nodes.yaml"

    def command(self, *arguments):
        args = clash.build_parser().parse_args(["--base", str(self.base), *arguments])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            clash.HANDLERS[args.cmd](args)
        return output.getvalue()

    def read_nodes(self):
        return yaml.safe_load(self.path.read_text(encoding="utf-8"))

    def test_initial_domain_and_ip_modes(self):
        for server, expected in (("Node.Example.COM.", "node.example.com"),
                                 ("192.0.2.10", "192.0.2.10"),
                                 ("2001:db8::10", "2001:db8::10")):
            with self.subTest(server=server):
                self.command("node-endpoint", "--init", "--server", server)
                node = self.read_nodes()["nodes"][0]
                self.assertEqual(node["server"], expected)
                self.assertEqual(node["sni"], expected)
                self.assertTrue(node["skip_cert_verify"])
                self.path.unlink()

    def test_init_can_enable_certificate_verification(self):
        self.command("node-endpoint", "--init", "--server", "node.example.com", "--verify-cert")
        self.assertFalse(self.read_nodes()["nodes"][0]["skip_cert_verify"])

    def test_init_never_overwrites_existing_pool(self):
        self.command("node-endpoint", "--init", "--server", "node.example.com")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(SystemExit, "已存在"):
            self.command("node-endpoint", "--init", "--server", "192.0.2.20")
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_endpoint_is_rejected_before_writing(self):
        for server in ("", "https://node.example.com", "node.example.com:443",
                       "node.example.com/path", "node example.com", "node.example.com..",
                       "999.0.0.1", "-node.example.com", "node_.example.com",
                       "YOUR_IP", "[2001:db8::10]", "fe80::1%eth0"):
            with self.subTest(server=server), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    self.command("node-endpoint", "--init", "--server=" + server)
                self.assertFalse(self.path.exists())

    def test_update_selects_exact_server_and_preserves_tls_and_other_fields(self):
        data = {"notes": "retain", "nodes": [
            {"server": "192.0.2.10", "sni": "192.0.2.10", "password": "synthetic-a"},
            {"server": "192.0.2.10", "sni": "tls.example.com", "skip_cert_verify": False},
            {"server": "other.example.com", "sni": "other-tls.example.com"},
        ]}
        clash.dump_yaml(str(self.path), data)
        self.command("node-endpoint", "--from-server", "192.0.2.10",
                     "--server", "node.example.com")
        data["nodes"][0]["server"] = "node.example.com"
        data["nodes"][1]["server"] = "node.example.com"
        self.assertEqual(self.read_nodes(), data)

    def test_explicit_sni_and_missing_selection(self):
        self.command("node-endpoint", "--init", "--server", "192.0.2.10")
        self.command("node-endpoint", "--from-server", "192.0.2.10",
                     "--server", "node.example.com", "--sni", "tls.example.com")
        self.assertEqual(self.read_nodes()["nodes"][0]["sni"], "tls.example.com")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(SystemExit, "未找到"):
            self.command("node-endpoint", "--from-server", "192.0.2.10",
                         "--server", "different.example.com")
        self.assertEqual(self.path.read_bytes(), before)

    def test_verify_certificate_only_changes_selected_tls_fields(self):
        data = {"nodes": [
            {"name": "self", "server": "node.example.com", "sni": "192.0.2.10",
             "port": 13443, "password": "synthetic-self", "skip_cert_verify": True},
            {"name": "other", "server": "other.example.com", "sni": "other-tls.example.com",
             "port": 443, "password": "synthetic-other", "skip_cert_verify": True},
        ]}
        clash.dump_yaml(str(self.path), data)
        self.command("node-endpoint", "--from-server", "node.example.com",
                     "--server", "node.example.com", "--sni", "node.example.com", "--verify-cert")
        data["nodes"][0]["sni"] = "node.example.com"
        data["nodes"][0]["skip_cert_verify"] = False
        self.assertEqual(self.read_nodes(), data)
        self.assertIn("verify_cert=on", self.command("node-endpoint"))

    def test_verify_certificate_requires_explicit_selection(self):
        self.command("node-endpoint", "--init", "--server", "node.example.com")
        before = self.path.read_bytes()
        with self.assertRaisesRegex(SystemExit, "--verify-cert"):
            self.command("node-endpoint", "--verify-cert")
        self.assertEqual(self.path.read_bytes(), before)

    def test_unspecified_sni_uses_node_server(self):
        node = {"server": "node.example.com", "port": 443,
                "password": "synthetic", "skip_cert_verify": False}
        self.assertEqual(clash.make_proxy("self", node)["sni"], node["server"])
        node["sni"] = ""
        self.assertEqual(clash.make_proxy("self", node)["sni"], node["server"])

    def test_listing_does_not_expose_credentials(self):
        self.command("node-endpoint", "--init", "--server", "node.example.com")
        data = self.read_nodes()
        data["nodes"][0]["password"] = "synthetic-password-not-for-output"
        clash.dump_yaml(str(self.path), data)
        output = self.command("node-endpoint")
        self.assertIn("server=node.example.com", output)
        self.assertNotIn("password", output)
        self.assertNotIn("synthetic-password-not-for-output", output)

    def test_repeated_render_keeps_domain_for_self_and_static_nodes(self):
        self.command("node-endpoint", "--init", "--server", "192.0.2.10")
        self.command("node-endpoint", "--from-server", "192.0.2.10",
                     "--server", "node.example.com")
        self.command("init")
        clash.write_defaults(str(self.base), {
            "quality_check_enabled": "off", "exit_ip_show_enabled": "off",
            "static_strategy": "on", "static_proxies": [
                {"server": "192.0.2.70", "port": 1080, "password": "synthetic-static"},
            ],
        })
        self.command("add", "sample", "--password", "synthetic-self", "--port", "13443",
                     "--token", "synthetic-token", "--expire", "2099-12-31")
        clash.dump_yaml(str(self.base / "template.yaml"), {
            "proxy-groups": [{"name": "代理", "type": "select", "proxies": ["DIRECT"]}],
            "rules": ["MATCH,代理"],
        })
        external = {"name": "external", "type": "anytls", "server": "external.example.com",
                    "port": 443, "password": "synthetic-external", "sni": "external-tls.example.com"}
        for verify_cert in (False, True):
            if verify_cert:
                self.command("node-endpoint", "--from-server", "node.example.com",
                             "--server", "node.example.com", "--sni", "node.example.com", "--verify-cert")
            before = self.path.read_bytes()
            expected_sni = "node.example.com" if verify_cert else "192.0.2.10"
            for _ in range(2):
                with mock.patch.object(clash, "load_external_proxies", return_value=[external]), \
                        mock.patch.object(clash, "format_geo_label", return_value="synthetic-exit"):
                    self.command("render", "--all")
                output = yaml.safe_load((self.base / "output/synthetic-token/clash.yaml").read_text(encoding="utf-8"))
                proxies = output["proxies"]
                self.assertIn(external, proxies)
                local_nodes = [node for node in proxies if node["name"] != "external"]
                self.assertTrue(any(node["name"].startswith("[静态]") for node in local_nodes))
                self.assertTrue(all(node["server"] == "node.example.com" for node in local_nodes))
                self.assertTrue(all(node["sni"] == expected_sni for node in local_nodes))
                self.assertTrue(all(node["skip-cert-verify"] is not verify_cert for node in local_nodes))
                self.assertEqual(self.path.read_bytes(), before)

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_prompts_once_and_preserves_domain(self):
        self.run_shell_setup("node.example.com\n")
        before = self.path.read_bytes()
        self.run_shell_setup("")
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.read_nodes()["nodes"][0]["server"], "node.example.com")

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_eof_stops_without_creating_nodes(self):
        result = self.run_shell_setup("", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("已停止初始化", result.stderr)
        self.assertFalse(self.path.exists())
        self.assertFalse((self.base / "template.yaml").exists())

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_invalid_node_leaves_no_template_for_retry(self):
        result = self.run_shell_setup("https://node.example.com\n", check=False, domain="old.example.com")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.path.exists())
        self.assertFalse((self.base / "template.yaml").exists())
        self.run_shell_setup("node.example.com\n", domain="new.example.com")
        template = yaml.safe_load((self.base / "template.yaml").read_text(encoding="utf-8"))
        self.assertIn("DOMAIN,vps.new.example.com,DIRECT", template["rules"])
        self.assertNotIn("vps.old.example.com", template["dns"]["nameserver-policy"])

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_propagates_initialization_command_failures(self):
        for step in ("init", "defaults", "list", "add"):
            with self.subTest(step=step):
                result = self.run_shell_setup("node.example.com\n", check=False, fail_step=step)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("injected failure: " + step, result.stderr)
                self.assertFalse((self.base.parent / "stats-setup").exists())
                self.assertFalse((self.base.parent / "serve-setup").exists())

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_explicit_empty_line_selects_current_ip(self):
        self.run_shell_setup("\n")
        self.assertEqual(self.read_nodes()["nodes"][0]["server"], "192.0.2.10")

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_sets_subscription_domain_in_rule_and_dns(self):
        self.run_shell_setup("node.example.com\n", domain="example.com", prefix="sub")
        template = yaml.safe_load((self.base / "template.yaml").read_text(encoding="utf-8"))
        self.assertIn("DOMAIN,sub.example.com,DIRECT", template["rules"])
        self.assertNotIn("DOMAIN,YOUR_SUB_DOMAIN,DIRECT", template["rules"])
        policy = template["dns"]["nameserver-policy"]
        self.assertNotIn("YOUR_SUB_DOMAIN", policy)
        self.assertEqual(policy["sub.example.com"], [
            "https://dns.alidns.com/dns-query#DIRECT", "https://doh.pub/dns-query#DIRECT",
        ])

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_without_domain_removes_subscription_placeholders(self):
        self.run_shell_setup("\n", domain="")
        template = yaml.safe_load((self.base / "template.yaml").read_text(encoding="utf-8"))
        self.assertNotIn("DOMAIN,YOUR_SUB_DOMAIN,DIRECT", template["rules"])
        self.assertNotIn("YOUR_SUB_DOMAIN", template["dns"]["nameserver-policy"])
        self.assertFalse(any(rule.startswith("DOMAIN,vps.,") for rule in template["rules"]))
        self.assertNotIn("vps.", template["dns"]["nameserver-policy"])
        self.assertIn("+.google.com", template["dns"]["nameserver-policy"])

    @unittest.skipUnless(os.name == "posix", "首次安装 Shell 流程在 Linux 验证")
    def test_shell_setup_preserves_existing_template(self):
        target = self.base / "template.yaml"
        existing = b"# user template\nrules: ['DOMAIN-SUFFIX,example.com,DIRECT']\ndns: {nameserver: [192.0.2.53]}\n"
        target.write_bytes(existing)
        self.run_shell_setup("node.example.com\n", domain="different.example.com")
        self.assertEqual(target.read_bytes(), existing)

    def run_shell_setup(self, user_input, check=True, domain="example.com", prefix="vps", fail_step=""):
        script = r'''
set -euo pipefail
W='' N=''
source "$1/lib/utils.sh"
source "$1/ai_stack/clash.sh"
BASE_DIR="$2"
_AI_STACK_DIR="$1/ai_stack"
INST_SINGBOX=true
VPS_IP=192.0.2.10
DOMAIN="$3"
PREFIX_VPS="$4"
_fail_step="$5"
CLASH_PORT_MIN=15443 CLASH_PORT_MAX=15458
python3() {
  if [[ "${1##*/}" == clash_subs.py && "${4:-}" == "$_fail_step" ]]; then
    printf 'injected failure: %s\n' "$_fail_step" >&2
    return 23
  fi
  command python3 "$@"
}
log() { :; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
setup_clash_stats_timer() { touch "$BASE_DIR/stats-setup"; }
setup_clash_serve_service() { touch "$BASE_DIR/serve-setup"; }
# 与生产调用方一致, 不依赖 set -e 帮函数隐式中断.
setup_clash_subscription || exit $?
'''
        return subprocess.run(["bash", "-c", script, "endpoint-test", str(ROOT), str(self.base.parent), domain, prefix, fail_step],
                              input=user_input, text=True, capture_output=True, check=check)


if __name__ == "__main__":
    unittest.main()
