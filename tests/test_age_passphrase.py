"""使用 Linux 伪终端验证 age 口令交互, 只使用合成数据和测试口令."""

import errno
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import tempfile
import time
import unittest


@unittest.skipUnless(os.name == "posix" and shutil.which("age") and os.environ.get("HOWE_TEST_AGE_PASSPHRASE") == "1", "age 交互测试需 Linux、age 和显式启用的资源充足测试环境")
class AgePassphraseTests(unittest.TestCase):
    def test_encrypted_bundle_roundtrip(self):
        import pty

        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="howe-age-test-") as temporary:
            fixture = Path(temporary)
            script = f'''set -uo pipefail
BACKUP_CONF_FILE={shlex.quote(str(fixture / 'backup.conf'))}
source {shlex.quote(str(repo / 'ai_stack/ai-stack-setup.sh'))}
BASE_DIR={shlex.quote(str(fixture / 'base'))}
BACKUP_AI_BASE="$BASE_DIR"
backup_root() {{ printf '%s\\n' {shlex.quote(str(fixture / 'backups'))}; }}
mkdir -p "$BASE_DIR" "$(backup_root)/sample"
printf 'services: {{}}\\n' > "$BASE_DIR/docker-compose.yml"
_bk_do_ai_config "$(backup_root)/sample" || exit 1
printf '{{"scopes_ok":["ai-config"],"scopes_fail":[]}}\\n' > "$(backup_root)/sample/manifest.json"
mig_write_manifest_v2 "$(backup_root)/sample" age-pass ai-config || exit 1
bundle=$(mig_pack_bundle sample age-pass {shlex.quote(str(fixture / 'bundles'))}) || exit 1
mv "$(backup_root)/sample" {shlex.quote(str(fixture / 'original'))}
restored=$(mig_unpack_bundle "$bundle" age-pass) || exit 1
cmp {shlex.quote(str(fixture / 'original/ai-config.tar.gz'))} "$(backup_root)/$restored/ai-config.tar.gz"
'''
            pid, terminal = pty.fork()
            if pid == 0:
                os.execlp("bash", "bash", "-c", script)
            pending = b""
            output = b""
            prompts = [b"Enter passphrase", b"Confirm passphrase", b"Enter passphrase"]
            answered = 0
            deadline = time.monotonic() + 90
            try:
                while time.monotonic() < deadline:
                    readable, _, _ = select.select([terminal], [], [], .2)
                    if not readable:
                        continue
                    try:
                        chunk = os.read(terminal, 8192)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    output += chunk
                    pending += chunk
                    while answered < len(prompts) and prompts[answered] in pending:
                        pending = pending.split(prompts[answered], 1)[1]
                        os.write(terminal, b"synthetic-age-test-passphrase\n")
                        answered += 1
                else:
                    os.killpg(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                    self.fail("age 口令交互超时")
                _, status = os.waitpid(pid, 0)
                self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode("utf-8", errors="replace")[-1500:])
                self.assertEqual(answered, 3)
            finally:
                os.close(terminal)


if __name__ == "__main__":
    unittest.main()
