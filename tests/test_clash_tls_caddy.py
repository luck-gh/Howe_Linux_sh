"""隔离检查节点证书的 Caddy 配置持久性与默认存储边界."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("jq"),
                     "需要 Linux bash/jq; 不调用宿主服务或网络")
class CaddyNodeCertificateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        (self.base / "caddy").mkdir()
        self.environment = dict(os.environ, TEST_ROOT=str(ROOT), BASE_DIR=str(self.base))

    def shell(self, script, **environment):
        return subprocess.run(
            ["bash", "-c", 'set -uo pipefail; source "$TEST_ROOT/ai_stack/caddy.sh"\n'
             'warn() { printf "%s\\n" "$*" >&2; }; log() { :; }; info() { :; }; err() { return 1; }\n'
             + script], env=dict(self.environment, **environment),
            text=True, capture_output=True, timeout=20,
        )

    def render(self, validation_result=0, domain="example.com"):
        return self.shell(r'''
INST_CADDY=true INST_SINGBOX=true DOMAIN="$TEST_DOMAIN" EMAIL=
INST_NEWAPI=false INST_WEBUI=false INST_LITELLM=false INST_SUB2API=false INST_DIFY=false
INST_KIRO=false INST_9ROUTER=false PREFIX_VPS=sub
_clash_tls_domain() { echo node.example.com; }
_caddy_node_cert_dir() { echo "$BASE_DIR/certificates/$1"; }
_clash_py() { echo "$BASE_DIR/no-subscription-script"; }
caddy() {
  [[ "$1" == validate && "$2" == --config && -f "$3" ]] || return 97
  return "$TEST_VALIDATE_RC"
}
runuser() { [[ "$1" == -u && "$2" == caddy && "$3" == -- ]] || return 97; shift 3; "$@"; }
ln() { [[ "$1" == -sf && "$3" == /etc/caddy/Caddyfile ]]; }
systemctl() { printf '%s\n' "$*" >> "$BASE_DIR/service-events"; }
write_caddyfile
''', TEST_VALIDATE_RC=str(validation_result), TEST_DOMAIN=domain)

    def test_node_site_survives_refresh_with_fixed_issuer(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.base / "caddy/Caddyfile"
        first = path.read_text()
        self.assertIn("node.example.com {", first)
        self.assertIn("issuer acme https://acme-v02.api.letsencrypt.org/directory", first)
        self.assertIn("respond 404", first)
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), first)

    def test_node_site_also_exists_without_web_root_domain(self):
        result = self.render(domain="")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.base / "caddy/Caddyfile").read_text()
        self.assertIn(":8080 {", config)
        self.assertIn("node.example.com {", config)

    def test_invalid_candidate_keeps_current_file_and_service(self):
        target = self.base / "caddy/Caddyfile"
        target.write_text("existing site configuration\n")
        result = self.render(validation_result=42)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "existing site configuration\n")
        self.assertFalse((self.base / "service-events").exists())
        self.assertEqual(list((self.base / "caddy").iterdir()), [target])

    def storage(self, config="{}", home="/var/lib/caddy", unit_environment="", envfiles="", user="caddy"):
        return self.shell(r'''
systemctl() {
  case "$*" in
    'show caddy --property=User --value') printf '%s\n' "$TEST_USER" ;;
    'show caddy --property=Environment --value') printf '%s\n' "$TEST_ENVIRONMENT" ;;
    'show caddy --property=EnvironmentFiles --value') printf '%s\n' "$TEST_ENVFILES" ;;
    *) return 97 ;;
  esac
}
getent() { printf 'caddy:x:999:999:caddy:%s:/usr/sbin/nologin\n' "$TEST_HOME"; }
caddy() {
  [[ "$*" == 'adapt --config /etc/caddy/Caddyfile --adapter caddyfile' ]] || return 97
  printf '%s\n' "$TEST_CONFIG"
}
_caddy_node_cert_dir node.example.com
''', TEST_CONFIG=config, TEST_HOME=home, TEST_ENVIRONMENT=unit_environment,
                          TEST_ENVFILES=envfiles, TEST_USER=user)

    def test_official_service_has_one_deterministic_certificate_location(self):
        result = self.storage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "/var/lib/caddy/.local/share/caddy/certificates/"
                         "acme-v02.api.letsencrypt.org-directory/node.example.com")

    def test_custom_storage_or_service_environment_is_rejected(self):
        for changes in (
            {"config": '{"storage":{"module":"file_system","root":"/custom"}}'},
            {"home": "/custom"}, {"user": "root"},
            {"unit_environment": "HOME=/custom"},
            {"unit_environment": "XDG_DATA_HOME=/custom"},
            {"envfiles": "/custom/environment (ignore_errors=no)"},
        ):
            with self.subTest(changes=changes):
                result = self.storage(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("/certificates/", result.stdout)


if __name__ == "__main__":
    unittest.main()
