"""AI 菜单只读状态查询的隔离回归."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("HOWE_TEST_BASH") or shutil.which("bash")


@unittest.skipUnless(BASH, "需要 Bash")
class AiMenuFeedbackTests(unittest.TestCase):
    def run_shell(self, body):
        result = subprocess.run([BASH, "-c", body], cwd=ROOT, text=True,
                                encoding="utf-8", capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_snapshot_failure_clears_old_state_and_blocks_detection(self):
        self.run_shell(r"""
source ai_stack/detect.sh
howe_query() { shift 2; "$@"; }
warn() { :; }
docker() { return 7; }
_DOCKER_PS_ALL=new-api
_DOCKER_PS_RUN=new-api
if detect_installed_services; then exit 10; fi
[[ -z $_DOCKER_PS_ALL && -z $_DOCKER_PS_RUN ]] || exit 11
[[ $SVC_NEWAPI_INSTALLED == unknown ]] || exit 12
""")

    def test_one_snapshot_distinguishes_installed_and_running(self):
        self.run_shell(r"""
source ai_stack/detect.sh
howe_query() { shift 2; "$@"; }
docker() { printf '%s\n' 'new-api|running' 'ai-db|exited'; }
_docker_ps_refresh || exit 10
svc_check docker ai-db || exit 11
svc_running docker new-api || exit 12
if svc_running docker ai-db; then exit 13; fi
""")

    def test_systemd_unknown_is_not_stopped(self):
        self.run_shell(r"""
source ai_stack/detect.sh
howe_query() { shift 2; "$@"; }
systemctl() { printf '%s\n' inactive; }
svc_running systemd caddy; [[ $? == 1 ]] || exit 10
systemctl() { return 9; }
svc_running systemd caddy; [[ $? == 2 ]] || exit 11
# systemctl show 的 rc3 是查询失败; inactive 必须由成功的属性查询确认.
systemctl() { printf '%s\n' inactive; return 3; }
svc_running systemd caddy; [[ $? == 2 ]] || exit 12
""")

    def test_version_menu_does_not_query_registry_on_entry(self):
        source = (ROOT / "ai_stack/view.sh").read_text(encoding="utf-8")
        menu = source.split("upgrade_rollback_menu() {", 1)[1]
        entry = menu.split("local _cache_age_hint=", 1)[0]
        self.assertNotIn("_update_cache_refresh", entry)

    def test_unknown_cli_version_blocks_update_before_install_source(self):
        self.run_shell(r'''
source ai_stack/main.sh
print_header() { :; }; detect_ai_agents() { :; }; warn() { :; }
claude() { :; }; _agent_cur_ver() { return 9; }
AGENT_PKGS=('claude|Synthetic|synthetic-package')
input_choose() { INPUT_RESULT=0; }
_agent_install_method() { echo UNEXPECTED; exit 90; }
update_ai_agents && exit 10
[[ $? == 1 ]] || exit 11
''')

    def test_retention_directory_failure_never_removes_backups(self):
        self.run_shell(r"""
source ai_stack/backup_lib.sh
sandbox=$(mktemp -d)
trap 'command rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/backups/20260101"
backup_root() { printf '%s\n' "$sandbox/backups"; }
timeout() { shift; "$@"; }
ls() { return 13; }
rm() { printf 'unexpected remove\n' > "$sandbox/removed"; }
backup_apply_retention 1
[[ $? == 13 ]] || exit 10
[[ ! -e "$sandbox/removed" ]] || exit 11
[[ -d "$sandbox/backups/20260101" ]] || exit 12
""")

    def test_retention_uses_one_snapshot_and_keeps_latest_per_scope(self):
        self.run_shell(r"""
source ai_stack/backup_lib.sh
sandbox=$(mktemp -d)
trap 'command rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/backups/20260101" "$sandbox/backups/20260102" "$sandbox/backups/20260103"
# 最新数据库与较旧的唯一文件备份均需保留.
touch "$sandbox/backups/20260101/ai-pg.tar.gz" "$sandbox/backups/20260102/ai-data.tar.gz" "$sandbox/backups/20260103/ai-pg.tar.gz"
backup_root() { printf '%s\n' "$sandbox/backups"; }
timeout() { shift; "$@"; }
ls() { printf 'query\n' >> "$sandbox/queries"; command ls "$@"; }
rm() { printf '%s\n' "${@: -1}" >> "$sandbox/removed"; }
removed=$(backup_apply_retention 1) || exit 10
[[ $removed == 1 ]] || exit 11
[[ $(wc -l < "$sandbox/queries") == 1 ]] || exit 12
[[ $(cat "$sandbox/removed") == "$sandbox/backups/20260101" ]] || exit 13
""")
