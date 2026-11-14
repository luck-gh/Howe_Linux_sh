"""订阅菜单的隔离调用链、无副作用回归及可重复计时; 不访问生产配置."""

import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import statistics
import runpy
import subprocess
import sys
import tempfile
import time
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('HOWE_TEST_BASH') or shutil.which('bash')


class MenuFixture:
    def __init__(self, directory, shell_source=None):
        self.directory = Path(directory)
        self.base = self.directory/'stack'
        self.pool = self.base/'clash'
        self.pool.mkdir(parents=True)
        self.units = self.directory/'units'
        self.units.mkdir()
        self.trace = self.directory/'trace'
        self.shell = self.directory/'clash.sh'
        source = (shell_source or ROOT/'ai_stack/clash.sh').read_text(encoding='utf-8')
        # 仅测试副本重定向 unit 输出, 即使误入初始化也不触及宿主 /etc.
        self.shell.write_text(source.replace('/etc/systemd/system/', self.units.as_posix()+'/'), encoding='utf-8')
        for name in ('clash_subs.py', 'clash_subs_stats.py', 'clash_subs_serve.py'):
            shutil.copyfile(ROOT/'ai_stack/doc'/name, self.pool/name)
        self.defaults = {'defaults': {'refresh_mode': 'daily', 'daily_refresh_time': '03:00',
                                     'stats_refresh_minutes': 0, 'refresh_force_recheck': True,
                                     'port_min': 13443, 'port_max': 13458}}
        self.subscriptions = {'subscriptions': [
            {'name': f'synthetic-{i}', 'token': f'synthetic-token-{i}', 'password': f'synthetic-password-{i}',
             'port': 13443+i, 'traffic_gb': 100+i, 'expire': '2099-12-31',
             'reset_day': 1, 'disabled': i == 4, 'update_interval_hours': 24,
             'usage': {'period_bytes': i*1048576, 'total_bytes': i*2097152,
                       'period_started': '2026-11-01', 'last_at': 'synthetic-last-stat'}} for i in range(5)]}
        self.write('defaults.yaml', self.defaults)
        self.write('subs.yaml', self.subscriptions)
        self.write('nodes.yaml', {'nodes': [{'name': 'synthetic', 'server': 'node.example.com'}]})
        shutil.copyfile(ROOT/'ai_stack/doc/vps.yaml', self.pool/'template.yaml')
        guard = self.directory/'guard'
        guard.mkdir()
        (guard/'sitecustomize.py').write_text('''import os, socket, sys
if os.name == 'nt':
    sys.stdout.reconfigure(newline='\\n')
    sys.stderr.reconfigure(newline='\\n')
def denied(*args, **kwargs):
    with open(os.environ['MENU_TRACE'], 'a') as stream: stream.write('NETWORK_FORBIDDEN\\n')
    raise RuntimeError('network forbidden in isolated menu test')
socket.getaddrinfo = denied
socket.socket.connect = denied
socket.socket.connect_ex = denied
''', encoding='utf-8')
        self.env = dict(os.environ, PYTHONUTF8='1', PYTHONIOENCODING='utf-8',
                        PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=str(guard)+os.pathsep+os.environ.get('PYTHONPATH', ''),
                        MENU_PYTHON=Path(sys.executable).as_posix(), MENU_TRACE=self.trace.as_posix(), MENU_BASE=self.base.as_posix(),
                        MENU_SHELL=self.shell.as_posix(), MENU_REPO=(ROOT/'ai_stack').as_posix())

    def write(self, name, value):
        (self.pool/name).write_text(yaml.safe_dump(value, allow_unicode=True), encoding='utf-8')

    def snapshot(self):
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.pool.iterdir() if p.is_file()}

    def run(self, command='refresh_clash_subscription', user_input='3\n1\n0\n0\n'):
        self.trace.write_text('', encoding='utf-8')
        script = r'''
set -uo pipefail
source "$MENU_SHELL"
howe_query() { shift 2; "$@"; }
BASE_DIR=$MENU_BASE; _AI_STACK_DIR=$MENU_REPO
INST_SINGBOX=true; INST_CADDY=false
DOMAIN=example.com; PREFIX_VPS=sub; VPS_IP=192.0.2.10
CLASH_PORT_MIN=13443; CLASH_PORT_MAX=13458
W= C= N= DIM= G=
clock() { if [[ -n ${EPOCHREALTIME:-} ]]; then printf '%s' "$EPOCHREALTIME"; else command date +%s.%N; fi; }
log() { :; }; info() { :; }; warn() { printf '%s\n' "$*" >&2; }
print_header() { printf 'HEADER %s\n' "$(clock)" >> "$MENU_TRACE"; }
systemctl() {
  local started=$(clock)
  printf 'SYSTEMCTL %s %s %s\n' "$started" "$(clock)" "$*" >> "$MENU_TRACE"
}
curl() { echo EXTERNAL_FORBIDDEN >> "$MENU_TRACE"; return 98; }
wget() { echo EXTERNAL_FORBIDDEN >> "$MENU_TRACE"; return 98; }
nft() { echo EXTERNAL_FORBIDDEN >> "$MENU_TRACE"; return 98; }
ufw() { echo EXTERNAL_FORBIDDEN >> "$MENU_TRACE"; return 98; }
docker() { echo EXTERNAL_FORBIDDEN >> "$MENU_TRACE"; return 98; }
python3() {
  local started=$(clock) status tag=${4:-inline}
  case "$1" in *clash_subs_stats.py|*clash_subs_serve.py)
    echo MUTATION_FORBIDDEN >> "$MENU_TRACE"; return 98 ;;
  esac
  case "$tag" in render|edit|usage-from-nft|enforce|reset-period)
    echo MUTATION_FORBIDDEN >> "$MENU_TRACE"; return 98 ;;
  esac
  "$MENU_PYTHON" "$@"; status=$?
  printf 'PYTHON %s %s %s\n' "$started" "$(clock)" "$tag" >> "$MENU_TRACE"
  return "$status"
}
read() {
  printf 'PROMPT %s %s\n' "$(clock)" "${FUNCNAME[1]}" >> "$MENU_TRACE"
  builtin read "$@"
}
printf 'START %s\n' "$(clock)" >> "$MENU_TRACE"
'''+command+'\n'
        result = subprocess.run([BASH, '--noprofile', '--norc', '-c', script],
                                input=user_input.encode('utf-8'), capture_output=True,
                                env=self.env, timeout=30)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result, self.trace.read_text(encoding='utf-8').splitlines()


@unittest.skipUnless(BASH, '订阅菜单回归需要 Bash')
class ClashMenuTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='howe-clash-menu-')
        self.addCleanup(temporary.cleanup)
        self.fixture = MenuFixture(temporary.name)

    def test_read_only_menu_and_cancelled_edit_preserve_current_state(self):
        before = self.fixture.snapshot()
        result, trace = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('synthetic-last-stat', result.stdout)
        self.assertIn('synthetic-password-0', result.stdout)
        self.assertEqual(self.fixture.snapshot(), before)
        self.assertFalse(any(line.startswith('SYSTEMCTL') for line in trace))
        self.assertNotIn('NETWORK_FORBIDDEN', trace)
        self.assertNotIn('MUTATION_FORBIDDEN', trace)
        self.assertNotIn('EXTERNAL_FORBIDDEN', trace)

    def test_failed_settings_read_blocks_refresh_and_quality_actions(self):
        for action in ('_clash_menu_auto_refresh', '_refresh_toggle_force_recheck',
                       '_quality_toggle quality_check_enabled test', '_clash_menu_quality_check'):
            with self.subTest(action=action):
                result, trace = self.fixture.run('python3() { return 9; }; '+action, '1\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(line.startswith('SYSTEMCTL') for line in trace))
                self.assertFalse(any(line.startswith('PROMPT') for line in trace))

    def test_failed_originals_read_does_not_create_edit_defaults(self):
        result, trace = self.fixture.run(
            'python3() { return 9; }; originals=(sentinel); '
            '_clash_field_originals_from traffic_gb originals', '')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith('PROMPT') for line in trace))

    def test_menu_reads_changed_file_on_each_entry(self):
        first, _ = self.fixture.run()
        self.fixture.subscriptions['subscriptions'][0]['traffic_gb'] = 987
        self.fixture.write('subs.yaml', self.fixture.subscriptions)
        second, _ = self.fixture.run()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn('987 GB', second.stdout)
        self.assertNotEqual(first.stdout, second.stdout)

    def test_invalid_yaml_stops_before_edit_prompt(self):
        (self.fixture.pool/'subs.yaml').write_text('subscriptions: [broken', encoding='utf-8')
        result, trace = self.fixture.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.endswith('_clash_field_loop') for line in trace))
        self.assertFalse(any(line.startswith('SYSTEMCTL') for line in trace))

    def test_invalid_config_structure_stops_before_menu_prompt(self):
        for name, values in (
                ('defaults.yaml', ('', 'null', '[]', '{}', 'defaults: []', 'defaults: [broken')),
                ('subs.yaml', ('', 'null', '[]', '{}', 'subscriptions: {}', 'subscriptions: null'))):
            path = self.fixture.pool/name
            original = path.read_bytes()
            for value in values:
                with self.subTest(name=name, value=value):
                    path.write_text(value, encoding='utf-8')
                    result, trace = self.fixture.run(user_input='0\n')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(any(line.startswith(('PROMPT', 'SYSTEMCTL')) for line in trace))
            path.write_bytes(original)

    def test_explicit_empty_subscription_list_is_valid(self):
        self.fixture.write('subs.yaml', {'subscriptions': []})
        result, _ = self.fixture.run(user_input='0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('尚无订阅', result.stdout)

    def test_unknown_timer_blocks_refresh_settings(self):
        result, trace = self.fixture.run(command=r'''
systemctl() { echo TIMER_QUERY >> "$MENU_TRACE"; return 9; }
setup_clash_stats_timer() { echo MUTATION_FORBIDDEN >> "$MENU_TRACE"; }
_clash_menu_auto_refresh
''', user_input='1\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TIMER_QUERY', trace)
        self.assertNotIn('MUTATION_FORBIDDEN', trace)
        self.assertFalse(any(line.startswith('PROMPT') for line in trace))

    def test_missing_files_fail_without_reinitializing_or_installing(self):
        for name in ('clash_subs.py', 'defaults.yaml', 'subs.yaml', 'nodes.yaml', 'template.yaml'):
            with self.subTest(name=name):
                path = self.fixture.pool/name
                content = path.read_bytes()
                path.unlink()
                try:
                    result, trace = self.fixture.run(user_input='0\n')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                    self.assertFalse(path.exists())
                    self.assertFalse(any(x.startswith(('PYTHON', 'SYSTEMCTL', 'PROMPT')) for x in trace))
                finally:
                    path.write_bytes(content)

    def test_explicit_sync_keeps_full_setup_and_refresh_call_chain(self):
        body = r'''
setup_clash_subscription() { echo setup >> "$MENU_TRACE"; }
write_caddyfile() { echo caddy >> "$MENU_TRACE"; }
wait_clash_tls_certificate() { echo certificate >> "$MENU_TRACE"; }
reload_clash_subscription() { echo reload >> "$MENU_TRACE"; }
_clash_menu_list() { echo list >> "$MENU_TRACE"; }
python3() {
  if [[ "$4" == clear-external-cache ]]; then echo cache >> "$MENU_TRACE"
  elif [[ "$4 $5 $6" == 'render --all --refresh-quality' ]]; then echo render >> "$MENU_TRACE"
  else return 97; fi
}
_clash_menu_refresh
'''
        result, trace = self.fixture.run(command=body, user_input='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace[1:], ['setup', 'caddy', 'certificate', 'reload', 'cache', 'render', 'list'])


def benchmark(shell_source, repetitions):
    samples = []
    for _ in range(repetitions):
        with tempfile.TemporaryDirectory(prefix='howe-clash-menu-bench-') as directory:
            fixture = MenuFixture(directory, shell_source)
            result, trace = fixture.run()
            if result.returncode:
                raise RuntimeError('isolated menu failed: '+result.stderr)
            if any(x in trace for x in ('NETWORK_FORBIDDEN', 'MUTATION_FORBIDDEN', 'EXTERNAL_FORBIDDEN')):
                raise RuntimeError('isolated menu attempted network or data mutation')
            start = float(next(x.split()[1] for x in trace if x.startswith('START ')))
            prompts = [x.split() for x in trace if x.startswith('PROMPT ')]
            top = float(next(x[1] for x in prompts if x[2] == 'refresh_clash_subscription'))
            fields = float(next(x[1] for x in prompts if x[2] == '_clash_field_loop'))
            python_calls = [x.split() for x in trace if x.startswith('PYTHON ')]
            system_calls = [x.split() for x in trace if x.startswith('SYSTEMCTL ')]
            samples.append({'entry_seconds': top-start, 'edit_seconds': fields-top,
                            'python_seconds': sum(float(x[2])-float(x[1]) for x in python_calls),
                            'python_calls': len(python_calls), 'python_commands': [x[3] for x in python_calls],
                            'systemctl_seconds': sum(float(x[2])-float(x[1]) for x in system_calls),
                            'systemctl_calls': [' '.join(x[3:]) for x in system_calls]})
    # 解释器启动/模块导入和 YAML 读取另外计时, 不用注入 sleep 伪装实际性能.
    components = {}
    for label, code in [('python_start', 'pass'), ('imports', 'import runpy; runpy.run_path(sys.argv[1])')]:
        times = []
        for _ in range(repetitions):
            begin = time.perf_counter()
            subprocess.run([sys.executable, '-c', 'import sys; '+code, str(ROOT/'ai_stack/doc/clash_subs.py')],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
            times.append(time.perf_counter()-begin)
        components[label+'_median_seconds'] = statistics.median(times)
    module = runpy.run_path(str(ROOT/'ai_stack/doc/clash_subs.py'))
    with tempfile.TemporaryDirectory(prefix='howe-clash-menu-components-') as directory:
        fixture = MenuFixture(directory, shell_source)
        for label, operation in [
                ('yaml_read', lambda: (module['read_defaults'](str(fixture.pool)), module['read_subs'](str(fixture.pool)))),
                ('normalized_config', lambda: module['read_subs_normalized'](str(fixture.pool))),
                ('display', lambda: module['cmd_show'](argparse.Namespace(base=str(fixture.pool), name='synthetic-0')))]:
            times = []
            for _ in range(repetitions):
                begin = time.perf_counter()
                with contextlib.redirect_stdout(io.StringIO()):
                    operation()
                times.append(time.perf_counter()-begin)
            components[label+'_median_seconds'] = statistics.median(times)
    return {'python': sys.version.split()[0], 'platform': sys.platform, 'repetitions': repetitions,
            'systemctl': 'mocked immediate; no real daemon/service latency measured',
            'network': 'denied; no successful network requests', 'samples': samples,
            'median_entry_seconds': statistics.median(x['entry_seconds'] for x in samples),
            'median_edit_seconds': statistics.median(x['edit_seconds'] for x in samples), **components}


if __name__ == '__main__':
    if '--benchmark' in sys.argv:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--benchmark', action='store_true')
        parser.add_argument('--shell', type=Path, default=ROOT/'ai_stack/clash.sh')
        parser.add_argument('--repetitions', type=int, default=5)
        args = parser.parse_args()
        print(json.dumps(benchmark(args.shell, args.repetitions), indent=2))
    else:
        unittest.main()
