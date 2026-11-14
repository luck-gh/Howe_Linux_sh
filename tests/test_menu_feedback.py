"""菜单只读查询的流式反馈、超时及失败关闭隔离回归."""

import os
from pathlib import Path
import shutil
import subprocess
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('HOWE_TEST_BASH') or shutil.which('bash')


@unittest.skipUnless(BASH and os.name != 'nt', '流式查询回归需要 Linux Bash/timeout')
class MenuFeedbackTests(unittest.TestCase):
    def execute(self, body):
        return subprocess.run([BASH, '-c', 'source "$1/lib/menu.sh"\n'+body, 'test', str(ROOT)],
                              capture_output=True, text=True, encoding='utf-8', timeout=5)

    def test_success_preserves_stdout(self):
        result = self.execute("howe_query synthetic 1 printf 'fresh\\n'")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'fresh\n')
        self.assertIn('查询中', result.stderr)
        self.assertIn('查询成功', result.stderr)

    def test_failure_preserves_exit_and_closes_sensitive_path(self):
        result = self.execute("howe_query synthetic 1 bash -c 'exit 23' || exit $?\nprintf MUTATION")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, '')
        self.assertIn('状态未知', result.stderr)
        self.assertNotIn('查询成功', result.stderr)

    def test_timeout_is_bounded_and_does_not_continue(self):
        started = time.monotonic()
        result = self.execute("howe_query synthetic 0.1 sleep 3 || exit $?\nprintf MUTATION")
        self.assertEqual(result.returncode, 124)
        self.assertLess(time.monotonic()-started, 2)
        self.assertEqual(result.stdout, '')
        self.assertIn('查询超时', result.stderr)

    def test_feedback_precedes_slow_query_completion(self):
        process = subprocess.Popen([BASH, '-c', 'source "$1/lib/menu.sh"; printf "TITLE\\n" >&2; '
                                    'howe_query synthetic 2 bash -c \'sleep 0.5; printf RESULT\'',
                                    'test', str(ROOT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding='utf-8')
        started = time.monotonic()
        try:
            self.assertEqual(process.stderr.readline(), 'TITLE\n')
            self.assertIn('查询中', process.stderr.readline())
            self.assertLess(time.monotonic()-started, 0.4)
            output, feedback = process.communicate(timeout=3)
            self.assertEqual(output, 'RESULT')
            self.assertIn('查询成功', feedback)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_main_title_precedes_public_ip_probe(self):
        script = r'''
source "$1/howe.sh"
clear() { :; }
detect_distro() { :; }
detect_public_ips() { sleep 0.5; echo PROBED; }
read() { return 1; }
main
'''
        process = subprocess.Popen([BASH, '-c', script, 'test', str(ROOT)],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding='utf-8')
        started = time.monotonic()
        try:
            seen = ''
            while '查询中' not in seen:
                line = process.stdout.readline()
                self.assertTrue(line)
                seen += line
            self.assertIn('初始化', seen)
            self.assertNotIn('PROBED', seen)
            self.assertLess(time.monotonic()-started, 0.4)
            output, _ = process.communicate(timeout=3)
            self.assertIn('PROBED', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
