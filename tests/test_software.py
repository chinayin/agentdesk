"""软件 CLI 的作用域和失败边界；mise 替身避免真实下载和 apt 操作。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SoftwareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.personal = self.base / '.config/mise'
        self.personal.mkdir(parents=True)
        (self.personal / 'config.toml').write_text('[tools]\nruff = "latest"\n')
        self.project = self.base / 'project'
        self.project.mkdir()
        (self.project / 'mise.toml').write_text('[tools]\nnode = "22"\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'calls.jsonl'
        mise = self.bin / 'mise'
        mise.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd(),
       'global': os.getenv('MISE_GLOBAL_CONFIG_FILE'),
       'system': os.getenv('MISE_SYSTEM_CONFIG_FILE'),
       'ignored': os.getenv('MISE_IGNORED_CONFIG_PATHS'),
       'proxy': os.getenv('https_proxy')}) + '\\n')
if '--version' in sys.argv: print('2026.10.15 test')
elif 'bin-paths' in sys.argv: pass
elif os.getenv('FAIL_MISE'): sys.exit(43)
elif os.getenv('FAIL_LOCKED_INSTALL') and 'install' in sys.argv and '--locked' in sys.argv: sys.exit(44)
''')
        mise.chmod(0o755)
        # 去掉开发机的 mise/XDG 与代理设置，结果不受本机环境影响。
        self.env = {**{k: v for k, v in os.environ.items() if not k.startswith(('MISE_', 'XDG_'))
                       and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')},
                    'HOME': str(self.base),
                    'PATH': f'{self.bin}:{os.environ["PATH"]}', 'CALL_LOG': str(self.log)}

    def invoke(self, *args):
        return subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), *args],
                              env=self.env, cwd=self.project, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_named_install_writes_personal_file_from_another_project(self):
        result = self.invoke('install', 'ruff', 'npm:prettier@3', 'apt:htop')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        tools = next(c for c in calls if 'use' in c['args'] and 'bootstrap' not in c['args'])
        self.assertIn('--global', tools['args'])
        self.assertIn('npm:prettier@3', tools['args'])
        apt = next(c for c in calls if 'bootstrap' in c['args'])
        self.assertIn('apt:htop', apt['args'])
        self.assertIsNone(tools['global'])
        # use 照常加载系统清单；只有 apt 包操作忽略它。
        self.assertIsNone(tools['ignored'])
        self.assertEqual(apt['ignored'], '/etc/mise')
        self.assertNotEqual(tools['cwd'], str(self.project))
        self.assertEqual((self.project / 'mise.toml').read_text(), '[tools]\nnode = "22"\n')
        self.assertFalse((self.base / '.agentdesk/mise.toml').exists())

    def test_upgrade_refreshes_personal_lock_and_never_prunes_shared_tools(self):
        result = self.invoke('upgrade')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        lock = next(c for c in calls if 'lock' in c['args'])
        self.assertIn('--bump', lock['args'])
        self.assertEqual(lock['ignored'], '/etc/mise')
        install = next(c for c in calls if 'install' in c['args'] and '--locked' in c['args'])
        # 忽略系统清单会让 mise 去改共享目录里的 global 链接，install 与 reshim 不能忽略。
        self.assertIsNone(install['ignored'])
        self.assertTrue(all(c['ignored'] is None for c in calls if 'reshim' in c['args']))
        self.assertTrue(all(c['ignored'] == '/etc/mise' for c in calls if 'bootstrap' in c['args']))
        # 参数形如 -C / SUBCOMMAND ...；只用 lock --bump + install，不调用 mise 的 upgrade/prune。
        self.assertFalse(any(c['args'][2] in ('upgrade', 'prune') for c in calls))
        self.assertFalse(any('files' in c['args'] for c in calls))

    def test_dry_run_neither_invokes_mise_nor_creates_configuration(self):
        (self.personal / 'config.toml').unlink()
        result = self.invoke('install', 'apt:htop', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.personal / 'config.toml').exists())

    def test_failure_propagates_and_stops_before_apt(self):
        self.env['FAIL_MISE'] = '1'
        result = self.invoke('install', 'ruff', 'apt:htop')
        self.assertEqual(result.returncode, 43, result.stderr)
        self.assertFalse(any('bootstrap' in c['args'] for c in self.calls()))

    def test_locked_install_failure_points_to_network_and_keeps_exit_code(self):
        # 锁定时下载失败的工具不进锁，install --locked 才失败。
        self.env['FAIL_LOCKED_INSTALL'] = '1'
        result = self.invoke('install')
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assertIn('Warning: some tools could not be locked or downloaded', result.stderr)
        self.assertFalse(any('bootstrap' in c['args'] for c in self.calls()))

    def test_bad_arguments_are_rejected_before_any_mise_action(self):
        for args in [('install', '--bogus'), ('install', 'apt:'),
                     ('install', 'ruff;touch bad'), ('upgrade', 'node@26'), ('update', 'node@26'),
                     ('run', '--system', 'hello'),
                     ('install', '--', '--system'), ('install', 'ruff', '--', '--system')]:
            result = self.invoke(*args)
            self.assertEqual(result.returncode, 1, (args, result.stderr))
        self.assertEqual(self.calls(), [])

    def test_proxy_option_reaches_mise_before_or_after_the_command(self):
        for args in [('install', '--proxy', 'http://proxy.example:3128', 'ruff'),
                     ('--proxy', 'http://proxy.example:3128', 'install', 'ruff')]:
            self.log.unlink(missing_ok=True)
            result = self.invoke(*args)
            self.assertEqual(result.returncode, 0, (args, result.stderr))
            use = next(c for c in self.calls() if 'use' in c['args'])
            self.assertEqual(use['proxy'], 'http://proxy.example:3128')
            self.assertNotIn('--proxy', use['args'])

    def test_run_keeps_proxy_flag_after_task_name_for_the_task(self):
        result = self.invoke('run', 'hello', '--proxy', 'x')
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if 'run' in c['args'])
        self.assertEqual(call['args'][-3:], ['hello', '--proxy', 'x'])
        self.assertIsNone(call['proxy'])

    def test_run_passes_task_arguments_and_uses_personal_context(self):
        result = self.invoke('run', 'hello', '--', 'two words')
        self.assertEqual(result.returncode, 0, result.stderr)
        call = next(c for c in self.calls() if 'run' in c['args'])
        self.assertEqual(call['args'][-3:], ['hello', '--', 'two words'])
        self.assertIsNone(call['global'])

    def test_symlink_entry_resolves_program_resources(self):
        link = self.bin / 'agentdesk'
        link.symlink_to(ROOT / 'agentdesk.sh')
        result = subprocess.run([str(link), 'install', 'ruff'], env=self.env,
                                cwd=self.project, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('use' in c['args'] for c in self.calls()))

    def test_system_preview_names_only_system_config(self):
        result = self.invoke('upgrade', '--system', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/etc/mise/config.local.toml', result.stderr)
        self.assertNotIn(str(self.personal), result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertLess(result.stderr.index('files apply'), result.stderr.index('packages upgrade'))

    def test_system_names_are_recorded_in_local_file_not_managed_list(self):
        result = self.invoke('install', '--system', '--dry-run', 'ruff', 'apt:htop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('use --path /etc/mise/config.local.toml ruff', result.stderr)
        self.assertIn('packages use --path /etc/mise/config.local.toml apt:htop', result.stderr)
        self.assertNotIn('--path /etc/mise/config.toml', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_system_environment_preserves_network_proxy_but_not_user_mise_settings(self):
        probe = self.bin / 'probe'
        # 不能设 MISE_SYSTEM_CONFIG_FILE：它会让 mise 只读 config.toml，忽略 config.local.toml。
        probe.write_text('#!/bin/sh\nprintf "%s\\n" "$https_proxy" "$MISE_IGNORED_CONFIG_PATHS" "${MISE_ENV-unset}" '
                         '"${MISE_SYSTEM_CONFIG_FILE-unset}"\n')
        probe.chmod(0o755)
        env = {**self.env, 'https_proxy': 'http://proxy.example:3128', 'MISE_ENV': 'unsafe'}
        result = subprocess.run(['bash', '-c',
            'source "$1/agentdesk.sh"; '
            'software_shared_permissions() { :; }; '
            'SOFTWARE_SYSTEM=1; SOFTWARE_MISE="$2"; software_mise version',
            '_', str(ROOT), str(probe)], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['http://proxy.example:3128',
            '/root/.config/mise', 'unset', 'unset'])


if __name__ == '__main__':
    unittest.main()
