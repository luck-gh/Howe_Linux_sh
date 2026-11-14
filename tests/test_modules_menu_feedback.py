"""使用假命令验证模块查询失败不会伪造状态或触发管理操作."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")
BASH = shutil.which("bash") if os.name != "nt" else (
    str(Path(GIT).parent.parent / "bin" / "bash.exe") if GIT else None
)


@unittest.skipUnless(BASH and Path(BASH).is_file(), "需要 Bash")
class ModuleMenuFeedbackTests(unittest.TestCase):
    def run_shell(self, body):
        result = subprocess.run([BASH, "-c", body], cwd=ROOT, text=True,
                                encoding="utf-8", capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_ai_status_uses_one_snapshot(self):
        result = self.run_shell(r'''
source modules/mod_ai_stack.sh
section() { :; }; info() { :; }; warn() { echo "$*"; }
howe_query() { shift 2; "$@"; }
docker() { echo queried >&2; printf 'new-api|running\nai-db|exited\n'; }
systemctl() { return 3; }
_ai_stack_status
''')
        self.assertEqual(result.stderr.count("queried"), 1)
        self.assertIn("new-api", result.stdout)

    def test_unknown_docker_state_blocks_actions(self):
        result = self.run_shell(r'''
source modules/mod_docker.sh
clear() { :; }; break_end() { :; }; warn() { echo "$*"; }
howe_query() { shift 2; "$@"; }
docker() { if [[ "$1" == --version ]]; then echo Docker; else return 9; fi; }
mod_docker_main <<< 1 && exit 20
exit 0
''')
        self.assertIn("状态未知", result.stdout)
        self.assertNotIn("1. 容器管理", result.stdout)

    def test_fail2ban_status_is_read_only(self):
        result = self.run_shell(r'''
source modules/mod_security.sh
section() { :; }; howe_query() { shift 2; "$@"; }
fail2ban-client() { [[ "$1" == status ]] || exit 44; echo STATUS; }
f2b_status
''')
        self.assertEqual(result.stdout.strip(), "STATUS")

    def test_failed_snapshot_is_not_absent_services(self):
        result = self.run_shell(r'''
source modules/mod_ai_stack.sh
section() { :; }; warn() { echo "$*"; }
docker() { return 9; }; howe_query() { shift 2; "$@"; }
_ai_stack_status && exit 20
exit 0
''')
        self.assertIn("状态未知", result.stdout)
        self.assertNotIn("new-api", result.stdout)


if __name__ == "__main__":
    unittest.main()
