"""验证显式采用代理 DNS 时不会更改已有访问规则或凭据."""

import contextlib
from copy import deepcopy
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dns_clash", ROOT / "ai_stack/doc/clash_subs.py")
clash = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(clash)


class DnsRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.path = self.base / "template.yaml"
        self.template = {
            "dns": {"enable": True, "listen": "127.0.0.1:1053", "enhanced-mode": "fake-ip",
                    "fake-ip-filter": ["*.internal"], "nameserver": ["192.0.2.53"],
                    "nameserver-policy": {"+.example.org": "192.0.2.53"},
                    "default-nameserver": ["192.0.2.53"], "fallback": ["198.51.100.53"],
                    "fallback-filter": {"geoip": True}, "proxy-server-nameserver-policy": {"old": "system"}},
            "proxy-groups": [{"name": "My Proxy", "type": "select", "proxies": ["DIRECT"]}],
            "rules": ["DOMAIN-SUFFIX,internal,DIRECT", "IP-CIDR,192.0.2.0/24,DIRECT,no-resolve", "MATCH,My Proxy"],
            "proxies": [{"name": "node", "password": "synthetic-secret"}],
        }
        clash.dump_yaml(str(self.path), self.template)

    def command(self, host="sub.example.com"):
        arguments = ["--base", str(self.base), "dns-routing", "--source-template", str(ROOT / "ai_stack/doc/vps.yaml")]
        if host:
            arguments += ["--subscription-host", host]
        args = clash.build_parser().parse_args(arguments)
        with contextlib.redirect_stdout(io.StringIO()):
            clash.HANDLERS[args.cmd](args)
        return yaml.safe_load(self.path.read_text())

    def test_removes_old_domain_split_preserves_rules_credentials_and_dns_listener(self):
        output = self.command()
        old, new = deepcopy(self.template), deepcopy(output)
        old.pop("dns")
        new.pop("dns")
        self.assertEqual(old, new)
        dns = output["dns"]
        self.assertEqual(dns["nameserver"], ["https://1.1.1.1/dns-query#My Proxy"])
        self.assertEqual(dns["direct-nameserver"], ["system"])
        self.assertEqual(dns["proxy-server-nameserver"], ["system"])
        self.assertEqual(dns["nameserver-policy"], {"sub.example.com": ["system"]})
        self.assertEqual(dns["listen"], "127.0.0.1:1053")
        self.assertEqual(dns["fake-ip-filter"], ["*.internal"])
        for key in ("fallback", "fallback-filter", "default-nameserver", "proxy-server-nameserver-policy"):
            self.assertNotIn(key, dns)

    def test_repeated_adoption_is_idempotent_and_no_domain_has_no_policy(self):
        first = self.command(host="")
        second = self.command(host="")
        self.assertEqual(first, second)
        self.assertNotIn("nameserver-policy", first["dns"])

    def test_missing_proxy_group_fails_before_template_write(self):
        self.template["proxy-groups"] = []
        clash.dump_yaml(str(self.path), self.template)
        before = self.path.read_bytes()
        with self.assertRaisesRegex(SystemExit, "主代理组"):
            self.command()
        self.assertEqual(before, self.path.read_bytes())

    def test_render_keeps_adopted_dns_on_repeated_render(self):
        template = self.command()
        def command(*extra):
            args = clash.build_parser().parse_args(["--base", str(self.base), *extra])
            with contextlib.redirect_stdout(io.StringIO()):
                clash.HANDLERS[args.cmd](args)
        command("node-endpoint", "--init", "--server", "node.example.com", "--verify-cert")
        command("init")
        command("add", "synthetic", "--token", "synthetic-token", "--password", "synthetic-password")
        with mock.patch.object(clash, "format_geo_label", return_value="synthetic"), \
                mock.patch.object(clash, "load_external_proxies", return_value=[]):
            for _ in range(2):
                command("render", "--all")
                output = yaml.safe_load((self.base / "output/synthetic-token/clash.yaml").read_text())
                self.assertEqual(output["dns"], template["dns"])
                self.assertEqual(output["rules"], template["rules"])


if __name__ == "__main__":
    unittest.main()
