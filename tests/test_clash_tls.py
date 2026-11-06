"""节点 TLS 隔离回归: 真实证书校验, 首装选择及失败阻断."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
LINUX_TOOLS = sys.platform.startswith("linux") and shutil.which("bash") and shutil.which("openssl")


@unittest.skipUnless(LINUX_TOOLS, "TLS Shell 和 OpenSSL 隔离回归在 Linux 验证")
class ClashTLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificates = tempfile.TemporaryDirectory(prefix="howe-tls-certificates-")
        cls.addClassCleanup(cls.certificates.cleanup)
        cls.cert_dir = Path(cls.certificates.name)
        cls.ca = cls.cert_dir / "root.crt"
        cls.openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", "root.key", "-out", "root.crt", "-days", "2",
                    "-subj", "/CN=Isolated TLS Test Root", "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        cls.openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", "issuer.key", "-out", "issuer.csr",
                    "-subj", "/CN=Isolated TLS Test Issuer")
        (cls.cert_dir / "issuer.ext").write_text(
            "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n",
            encoding="utf-8")
        cls.openssl("x509", "-req", "-in", "issuer.csr", "-CA", "root.crt", "-CAkey", "root.key",
                    "-set_serial", "2", "-days", "2", "-extfile", "issuer.ext", "-out", "issuer.crt")
        for serial, name, san, days in ((3, "node.example.com", True, 1),
                                        (4, "missing-san", False, 1),
                                        (5, "expired", True, 0)):
            cls.openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-keyout", name + ".key", "-out", name + ".csr",
                        "-subj", "/CN=node.example.com")
            extensions = "basicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n"
            if san:
                extensions += "subjectAltName=DNS:node.example.com\n"
            (cls.cert_dir / (name + ".ext")).write_text(extensions, encoding="utf-8")
            cls.openssl("x509", "-req", "-in", name + ".csr", "-CA", "issuer.crt", "-CAkey", "issuer.key",
                        "-set_serial", str(serial), "-days", str(days), "-extfile", name + ".ext",
                        "-out", name + ".crt")
            # Caddy 的证书文件含中间链; 测试信任库只包含根证书.
            with (cls.cert_dir / (name + ".crt")).open("ab") as certificate:
                certificate.write((cls.cert_dir / "issuer.crt").read_bytes())
        cls.openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-keyout", "untrusted.key", "-out", "untrusted.crt", "-days", "1",
                    "-subj", "/CN=node.example.com", "-addext", "subjectAltName=DNS:node.example.com")

    @classmethod
    def openssl(cls, *arguments):
        subprocess.run(["openssl", *arguments], cwd=cls.cert_dir, check=True,
                       text=True, capture_output=True)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="howe-tls-case-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.pool = self.base / "clash"
        self.pool.mkdir()
        shutil.copyfile(ROOT / "ai_stack/doc/clash_subs.py", self.pool / "clash_subs.py")
        self.environment = dict(os.environ, SSL_CERT_FILE=str(self.ca),
                                SSL_CERT_DIR=str(self.base / "empty-trust-directory"))

    def shell(self, body, *arguments, user_input="", check=True):
        preamble = r'''
set -euo pipefail
source "$1/lib/utils.sh"
source "$1/ai_stack/clash.sh"
source "$1/ai_stack/caddy.sh"
source "$1/ai_stack/lifecycle.sh"
BASE_DIR="$2"
_AI_STACK_DIR="$1/ai_stack"
INST_SINGBOX=true INST_CADDY=true
DOMAIN=example.com PREFIX_VPS=sub VPS_IP=192.0.2.10
W='' N='' C='' DIM=''
log() { :; }; info() { :; }; step() { :; }
warn() { printf '%s\n' "$*" >&2; }
unexpected() { printf 'UNEXPECTED_EXTERNAL_COMMAND %s\n' "$*" >&2; return 97; }
systemctl() { unexpected systemctl "$@"; }
caddy() { unexpected caddy "$@"; }
docker() { unexpected docker "$@"; }
curl() { unexpected curl "$@"; }
wget() { unexpected wget "$@"; }
apt-get() { unexpected apt-get "$@"; }
nft() { unexpected nft "$@"; }
ufw() { unexpected ufw "$@"; }
setup_clash_stats_timer() { :; }
setup_clash_serve_service() { :; }
'''
        result = subprocess.run(["bash", "-c", preamble + body, "tls-test", str(ROOT), str(self.base),
                                 *map(str, arguments)], input=user_input, env=self.environment,
                                text=True, capture_output=True)
        self.assertNotIn("UNEXPECTED_EXTERNAL_COMMAND", result.stderr)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def verify(self, name="node.example.com", domain="node.example.com", key=None):
        return self.shell('_verify_clash_tls_certificate "$3" "$4" "$5" || exit $?\n',
                          self.cert_dir / (name + ".crt"), self.cert_dir / ((key or name) + ".key"),
                          domain, check=False)

    def write_nodes(self, nodes):
        (self.pool / "nodes.yaml").write_text(yaml.safe_dump({"nodes": nodes}), encoding="utf-8")

    def test_valid_domain_chain_uses_test_root_and_intermediate(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrong_hostname_is_rejected(self):
        self.assertNotEqual(self.verify(domain="other.example.com").returncode, 0)

    def test_matching_common_name_without_dns_san_is_rejected(self):
        result = self.verify("missing-san")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺少 DNS SAN", result.stderr)

    def test_wrong_private_key_is_rejected(self):
        result = self.verify(key="missing-san")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("私钥不匹配", result.stderr)

    def test_untrusted_self_signed_certificate_is_rejected(self):
        self.assertNotEqual(self.verify("untrusted").returncode, 0)

    def test_expired_certificate_is_rejected(self):
        self.assertNotEqual(self.verify("expired").returncode, 0)

    def test_missing_certificate_or_key_is_rejected(self):
        for name, key in (("absent", "node.example.com"), ("node.example.com", "absent")):
            with self.subTest(name=name, key=key):
                result = self.verify(name, key=key)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("尚未就绪", result.stderr)

    def test_strict_domain_comes_from_sni_and_ignores_unverified_nodes(self):
        self.write_nodes([
            {"server": "different.example.com", "sni": "Node.Example.COM.", "skip_cert_verify": False},
            {"server": "192.0.2.10", "sni": "192.0.2.10", "skip_cert_verify": True},
            {"server": "node.example.com", "sni": "node.example.com", "skip_cert_verify": False},
        ])
        result = self.shell('_clash_tls_domain || exit $?\n')
        self.assertEqual(result.stdout.strip(), "node.example.com")

    def test_unverified_pool_needs_no_managed_certificate(self):
        self.write_nodes([{"server": "192.0.2.10", "skip_cert_verify": True}])
        self.assertEqual(self.shell('_clash_tls_domain || exit $?\n').stdout, "")

    def test_strict_domain_rejects_ips_invalid_sni_and_non_boolean_flags(self):
        invalid = [
            {"sni": "192.0.2.10", "skip_cert_verify": False},
            {"sni": "2001:db8::10", "skip_cert_verify": False},
            {"sni": "https://node.example.com", "skip_cert_verify": False},
            {"skip_cert_verify": False},
            {"sni": "node.example.com", "skip_cert_verify": "false"},
            {"sni": "node.example.com", "skip_cert_verify": 0},
        ]
        for node in invalid:
            with self.subTest(node=node):
                self.write_nodes([dict(server="node.example.com", **node)])
                result = self.shell('_clash_tls_domain || exit $?\n', check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_multiple_strict_domains_are_rejected(self):
        self.write_nodes([{"sni": domain, "skip_cert_verify": False}
                          for domain in ("node.example.com", "other.example.com")])
        result = self.shell('_clash_tls_domain || exit $?\n', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("同一个 SNI", result.stderr)

    def test_initial_domain_with_caddy_enables_verification(self):
        self.shell('setup_clash_subscription || exit $?\n', user_input="node.example.com\n")
        node = yaml.safe_load((self.pool / "nodes.yaml").read_text(encoding="utf-8"))["nodes"][0]
        self.assertEqual(node["sni"], "node.example.com")
        self.assertIs(node["skip_cert_verify"], False)

    def test_initial_domain_without_caddy_keeps_explicit_unverified_mode(self):
        self.shell('INST_CADDY=false\nsetup_clash_subscription || exit $?\n',
                   user_input="node.example.com\n")
        node = yaml.safe_load((self.pool / "nodes.yaml").read_text(encoding="utf-8"))["nodes"][0]
        self.assertEqual(node["sni"], "node.example.com")
        self.assertIs(node["skip_cert_verify"], True)

    def test_initial_ip_with_caddy_keeps_unverified_mode(self):
        self.shell('setup_clash_subscription || exit $?\n', user_input="192.0.2.10\n")
        node = yaml.safe_load((self.pool / "nodes.yaml").read_text(encoding="utf-8"))["nodes"][0]
        self.assertEqual(node["sni"], "192.0.2.10")
        self.assertIs(node["skip_cert_verify"], True)

    def install(self, certificate_status):
        body = r'''
INST_DIFY=false DEPLOY_MODE=standalone
record() { printf '%s\n' "$1" >> "$BASE_DIR/install-order"; }
preflight() { :; }; collect_config() { :; }; confirm_installation() { :; }
install_deps() { :; }; setup_dirs() { :; }; write_env() { :; }
write_compose() { :; }; write_litellm_config() { :; }; check_dns() { :; }
install_singbox() { record binary; }
setup_clash_subscription() { record nodes; }
configure_firewall() { record firewall; }
install_caddy() { record caddy-install; }
write_caddyfile() { record caddy-config; }
certificate_status="$3"
wait_clash_tls_certificate() { record certificate; return "$certificate_status"; }
write_singbox_config() { record singbox-config; }
render_clash_subscription() { record render; }
install_frp_server() { :; }
start_services() { record start; }
health_check() { :; }; print_summary() { :; }
install_or_update || exit $?
'''
        result = self.shell(body, certificate_status, user_input="\n", check=False)
        return result, (self.base / "install-order").read_text(encoding="utf-8").splitlines()

    def test_install_waits_for_certificate_before_server_and_subscriptions(self):
        result, order = self.install(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(order, ["binary", "nodes", "firewall", "caddy-install", "caddy-config",
                                 "certificate", "singbox-config", "render", "start"])

    def test_certificate_failure_stops_server_config_render_and_start(self):
        result, order = self.install(23)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(order[-1], "certificate")
        for step in ("singbox-config", "render", "start"):
            self.assertNotIn(step, order)

    def refresh(self, failure=""):
        (self.base / "refresh-order").write_text("", encoding="utf-8")
        body = r'''
failure="$3"
record() { printf '%s\n' "$1" >> "$BASE_DIR/refresh-order"; }
setup_clash_subscription() { record setup; }
write_caddyfile() { record caddy; }
wait_clash_tls_certificate() { record certificate; [[ "$failure" != certificate ]]; }
reload_clash_subscription() { record reload; [[ "$failure" != reload ]]; }
render_clash_subscription() { record render; }
_clash_menu_list() { record list; }
python3() {
  case "${4:-}" in
    clear-external-cache) return 0 ;;
    render) record render ;;
    *) unexpected python3 "$@" ;;
  esac
}
_clash_menu_refresh || exit $?
'''
        result = self.shell(body, failure, check=False)
        return result, (self.base / "refresh-order").read_text(encoding="utf-8").splitlines()

    def test_refresh_verifies_certificate_and_reloads_before_rendering(self):
        result, order = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(order, ["setup", "caddy", "certificate", "reload", "render", "list"])

    def test_refresh_certificate_or_reload_failure_stops_publication(self):
        for failure, expected in (("certificate", ["setup", "caddy", "certificate"]),
                                  ("reload", ["setup", "caddy", "certificate", "reload"])):
            with self.subTest(failure=failure):
                result, order = self.refresh(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(order, expected)

    def test_reload_propagates_restart_failure_after_config_change(self):
        target = self.base / "reload-config.json"
        target.write_text('{"version":"old"}\n', encoding="utf-8")
        source = (ROOT / "ai_stack/services.sh").read_text(encoding="utf-8")
        self.assertIn("/etc/sing-box/config.json", source)
        isolated = self.base / "services-reload.sh"
        isolated.write_text(source.replace("/etc/sing-box/config.json", str(target)), encoding="utf-8")
        body = r'''
source "$BASE_DIR/services-reload.sh"
sing-box() { unexpected sing-box "$@"; }
write_singbox_config() { printf '{"version":"new"}\n' > "$BASE_DIR/reload-config.json"; }
setup_clash_nft() { :; }; _sync_clash_ufw() { :; }
systemctl() {
  case "$*" in
    'is-active sing-box') return 0 ;;
    'restart sing-box') printf 'restart\n' > "$BASE_DIR/restart-attempt"; return 23 ;;
    *) unexpected systemctl "$@" ;;
  esac
}
reload_clash_subscription || exit $?
'''
        result = self.shell(body, check=False)
        self.assertTrue((self.base / "restart-attempt").exists())
        self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"version": "new"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restart 失败", result.stderr)

    def singbox(self, certificate_dir):
        # 只将真实函数的两个宿主绝对路径换到临时目录, 其余实现原样运行.
        source = (ROOT / "ai_stack/services.sh").read_text(encoding="utf-8")
        for original, isolated in (("/etc/systemd/system/sing-box.service", self.base / "sing-box.service"),
                                    ("/var/log/sing-box.log", self.base / "sing-box.log")):
            self.assertIn(original, source)
            source = source.replace(original, str(isolated))
        service_source = self.base / "services.sh"
        service_source.write_text(source, encoding="utf-8")
        body = r'''
source "$BASE_DIR/services.sh"
SINGBOX_DIR="$BASE_DIR/sing-box"
mkdir -p "$SINGBOX_DIR"
certificate_dir="$3"
use_current_ipv4() { VPS_IP=192.0.2.10; }
_caddy_node_cert_dir() { printf '%s\n' "$certificate_dir"; }
systemctl() { printf '%s\n' "$*" >> "$BASE_DIR/systemctl-calls"; }
openssl() {
  if [[ "$1" == req ]]; then
    printf 'unexpected self-sign\n' > "$BASE_DIR/self-sign-attempt"
    return 98
  fi
  command openssl "$@"
}
write_singbox_config || exit $?
'''
        return self.shell(body, certificate_dir, check=False)

    def test_invalid_managed_certificate_preserves_existing_singbox_config(self):
        self.write_nodes([{"sni": "node.example.com", "skip_cert_verify": False}])
        target = self.base / "sing-box/config.json"
        target.parent.mkdir()
        target.write_bytes(b'{"existing":"do-not-replace"}\n')
        before = target.read_bytes()
        invalid_dir = self.base / "invalid-certificate"
        invalid_dir.mkdir()
        shutil.copyfile(self.cert_dir / "node.example.com.crt", invalid_dir / "node.example.com.crt")
        shutil.copyfile(self.cert_dir / "missing-san.key", invalid_dir / "node.example.com.key")
        result = self.singbox(invalid_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("私钥不匹配", result.stderr)
        self.assertEqual(target.read_bytes(), before)
        self.assertFalse((self.base / "self-sign-attempt").exists())
        self.assertFalse((self.base / "systemctl-calls").exists())
        self.assertFalse((self.base / "sing-box.service").exists())

    @unittest.skipUnless(shutil.which("jq"), "完整 sing-box 配置生成需要 jq")
    def test_strict_singbox_config_uses_managed_certificate_without_self_signing(self):
        self.shell('setup_clash_subscription || exit $?\n', user_input="node.example.com\n")
        result = self.singbox(self.cert_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads((self.base / "sing-box/config.json").read_text(encoding="utf-8"))
        self.assertTrue(config["inbounds"])
        for inbound in config["inbounds"]:
            self.assertEqual(inbound["type"], "anytls")
            self.assertEqual(inbound["tls"]["server_name"], "node.example.com")
            self.assertEqual(inbound["tls"]["certificate_path"], str(self.cert_dir / "node.example.com.crt"))
            self.assertEqual(inbound["tls"]["key_path"], str(self.cert_dir / "node.example.com.key"))
        self.assertFalse((self.base / "self-sign-attempt").exists())
        self.assertFalse((self.base / "sing-box/cert.pem").exists())
        self.assertFalse((self.base / "sing-box/key.pem").exists())
        self.assertIn("enable --now sing-box", (self.base / "systemctl-calls").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
