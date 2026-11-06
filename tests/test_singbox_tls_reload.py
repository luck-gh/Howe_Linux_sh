"""独立回环 AnyTLS 的证书验证与热加载, 不接触生产配置或服务.

Linux 显式启用: HOWE_TEST_SINGBOX_TLS_RELOAD=1 python3 -m unittest discover \
    -s tests -p test_singbox_tls_reload.py -v
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(
    os.name == "posix" and os.environ.get("HOWE_TEST_SINGBOX_TLS_RELOAD") == "1"
    and shutil.which("sing-box") and shutil.which("openssl"),
    "证书热加载测试需 Linux、sing-box、openssl 和 HOWE_TEST_SINGBOX_TLS_RELOAD=1",
)
class SingboxTLSReloadTests(unittest.TestCase):
    def test_verified_handshake_and_atomic_key_certificate_reload(self):
        hostname = "node.reload.example.invalid"
        binary = shutil.which("sing-box")
        version = subprocess.run([binary, "version"], check=True, capture_output=True,
                                 text=True, timeout=10).stdout.splitlines()[0]
        with tempfile.TemporaryDirectory(prefix="howe-tls-reload-") as temporary:
            fixture = Path(temporary)
            self.assertEqual(fixture.stat().st_mode & 0o777, 0o700)
            for number in (1, 2):
                subprocess.run([
                    "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-nodes", "-days", "1", "-subj", f"/CN=rotation-{number}.example.invalid",
                    "-addext", f"subjectAltName=DNS:{hostname}",
                    "-keyout", str(fixture / f"key-{number}.pem"),
                    "-out", str(fixture / f"cert-{number}.pem"),
                ], check=True, capture_output=True, timeout=15)
            certificates = [(fixture / f"cert-{number}.pem").read_text() for number in (1, 2)]
            fingerprints = [hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).digest() for pem in certificates]
            self.assertNotEqual(fingerprints[0], fingerprints[1])
            self.assertNotEqual((fixture / "key-1.pem").read_bytes(), (fixture / "key-2.pem").read_bytes())
            certificate = fixture / "active-cert.pem"
            key = fixture / "active-key.pem"
            shutil.copyfile(fixture / "cert-1.pem", certificate)
            shutil.copyfile(fixture / "key-1.pem", key)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            configuration = {
                "log": {"level": "info", "disabled": False},
                "inbounds": [{
                    "type": "anytls", "listen": "127.0.0.1", "listen_port": port,
                    "users": [{"name": "synthetic", "password": "synthetic-tls-reload-test"}],
                    "tls": {"enabled": True, "server_name": hostname,
                            "certificate_path": str(certificate), "key_path": str(key)},
                }],
                "outbounds": [{"type": "direct", "tag": "direct"}],
                "route": {"final": "direct"},
            }
            config_path = fixture / "config.json"
            config_path.write_text(json.dumps(configuration), encoding="utf-8")
            subprocess.run([binary, "check", "-c", str(config_path)], check=True,
                           capture_output=True, timeout=15)
            # 不载入系统信任库; 正例客户端仅信任本测试生成的两张证书.
            trusted = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            trusted.load_verify_locations(cadata="\n".join(certificates))
            untrusted = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            self.assertEqual(trusted.cert_store_stats()["x509_ca"], 2)
            self.assertEqual(untrusted.cert_store_stats()["x509_ca"], 0)

            def peer_fingerprint(context, server_name):
                with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
                    with context.wrap_socket(connection, server_hostname=server_name) as secured:
                        return hashlib.sha256(secured.getpeercert(binary_form=True)).digest()

            log_path = fixture / "sing-box.log"
            with log_path.open("wb") as log:
                process = subprocess.Popen([binary, "run", "-c", str(config_path)],
                                           stdout=log, stderr=subprocess.STDOUT, cwd=fixture)
                initial_pid = process.pid
                try:
                    def wait_for_log(message):
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            self.assertIsNone(process.poll(), "独立 sing-box 进程提前退出")
                            if message in log_path.read_text(encoding="utf-8"):
                                return
                            time.sleep(0.05)
                        self.fail("未观察到预期的独立 TLS 进程事件: " + message)

                    wait_for_log("sing-box started")
                    self.assertEqual(peer_fingerprint(trusted, hostname), fingerprints[0])
                    with self.assertRaises(ssl.SSLCertVerificationError) as mismatch:
                        peer_fingerprint(trusted, "wrong.reload.example.invalid")
                    self.assertIn("hostname", mismatch.exception.verify_message.lower())
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        peer_fingerprint(untrusted, hostname)

                    # 等待密钥不匹配事件后再握手, 证明旧证书继续生效而非尚未收到变更.
                    pending_key = fixture / "pending-key.pem"
                    shutil.copyfile(fixture / "key-2.pem", pending_key)
                    pending_key.replace(key)
                    wait_for_log("reload key pair")
                    self.assertEqual(peer_fingerprint(trusted, hostname), fingerprints[0])
                    pending_certificate = fixture / "pending-cert.pem"
                    shutil.copyfile(fixture / "cert-2.pem", pending_certificate)
                    pending_certificate.replace(certificate)
                    wait_for_log("reloaded TLS certificate")
                    self.assertEqual(peer_fingerprint(trusted, hostname), fingerprints[1])
                    self.assertIsNone(process.poll())
                    self.assertEqual(process.pid, initial_pid)
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        peer_fingerprint(trusted, "wrong.reload.example.invalid")
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        peer_fingerprint(untrusted, hostname)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
            # 只输出结论; 私钥、配置、端口与详细日志随隔离目录一起清理.
            print(json.dumps({"version": version, "loopback_only": True,
                              "trusted_handshakes_passed": True,
                              "wrong_hostname_and_untrusted_rejected": True,
                              "key_only_change_kept_active_certificate": True,
                              "certificate_reloaded_without_restart": True}))


if __name__ == "__main__":
    unittest.main()
