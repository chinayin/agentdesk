"""可选真实 mise 集成：AGENTDESK_TEST_MISE=/path/to/mise bash test.sh。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MISE = os.environ.get('AGENTDESK_TEST_MISE')


@unittest.skipUnless(MISE, 'set AGENTDESK_TEST_MISE for native mise integration')
class NativeMiseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        (self.base / 'bin').mkdir()
        (self.base / 'bin/mise').symlink_to(MISE)
        self.personal = self.base / '.config/mise'
        self.personal.mkdir(parents=True)
        self.config = self.personal / 'config.toml'
        self.config.write_text('[settings]\nlockfile = true\n[tasks.hello]\nrun = "printf HELLO"\n')
        self.project = self.base / 'project'
        self.project.mkdir()
        (self.project / 'mise.toml').write_text('invalid toml = [')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('MISE_', 'XDG_'))}
        self.env.update(HOME=str(self.base), PATH=f'{self.base}/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                        MISE_CACHE_DIR=str(self.base / 'cache'), MISE_STATE_DIR=str(self.base / 'state'))

    def test_task_stdout_and_working_directory_are_preserved(self):
        result = subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), 'run', 'hello'],
                                env=self.env, cwd=self.project, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'HELLO')
        self.assertNotIn('Error loading', result.stderr)
        self.config.write_text('[tasks.where]\nrun = "pwd"\n')
        result = subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), 'run', 'where'],
                                env=self.env, cwd=self.project, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.base))

    def test_session_native_global_write_uses_same_personal_file(self):
        # 显式 --no-install 只验证写入；任何平台都不安装系统包。
        self.env.update(MISE_IGNORED_CONFIG_PATHS='/etc/mise')
        result = subprocess.run([MISE, '-C', '/', 'bootstrap', 'packages', 'use',
                                 '-g', '--no-install', 'apt:htop'], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"apt:htop" = "latest"', self.config.read_text())
        self.assertFalse((self.base / '.agentdesk/mise.toml').exists())
        result = subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), 'run', 'hello'],
                                env=self.env, cwd=self.project, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'HELLO')

    def test_native_xdg_config_is_respected_without_session_environment(self):
        target = self.base / 'custom-config/mise'
        target.mkdir(parents=True)
        self.config.rename(target / 'config.toml')
        self.env['XDG_CONFIG_HOME'] = str(target.parent)
        result = subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), 'run', 'hello'],
                                env=self.env, cwd=self.project, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'HELLO')

    def test_empty_scope_is_valid(self):
        self.env.update(MISE_IGNORED_CONFIG_PATHS='/etc/mise')
        result = subprocess.run([MISE, '-C', '/', 'lock', '--global'], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ignored_paths_isolate_system_and_personal_scopes(self):
        # 替代空 TOML：两个方向都只看到本层声明。
        system = self.base / 'system'
        system.mkdir()
        (system / 'config.toml').write_text('[tools]\njq = "1.7"\n')
        self.config.write_text('[tools]\nshellcheck = "0.11"\n')
        self.env.update(MISE_SYSTEM_CONFIG_FILE=str(system / 'config.toml'), MISE_OFFLINE='1')
        for ignored, present, absent in [(str(system), 'shellcheck', 'jq'),
                                         (str(self.personal), 'jq', 'shellcheck')]:
            result = subprocess.run([MISE, '-C', '/', 'config', 'ls'],
                                    env={**self.env, 'MISE_IGNORED_CONFIG_PATHS': ignored},
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(present, result.stdout)
            self.assertNotIn(absent, result.stdout)

    def test_system_local_file_extends_and_overrides_managed_list(self):
        # AgentDesk 维护 config.toml，本机管理员写 config.local.toml；mise 原生合并，local 优先。
        system = self.base / 'etc-mise'
        system.mkdir()
        (system / 'config.toml').write_text('[tools]\nnode = "24"\njq = "1.7"\n')
        (system / 'config.local.toml').write_text('[tools]\nnode = "22"\n')
        env = {**self.env, 'MISE_SYSTEM_CONFIG_DIR': str(system), 'MISE_OFFLINE': '1',
               'MISE_IGNORED_CONFIG_PATHS': str(self.personal)}
        listed = subprocess.run([MISE, '-C', '/', 'config', 'ls'], env=env, text=True, capture_output=True)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertLess(listed.stdout.index('config.toml'), listed.stdout.index('config.local.toml'))
        current = subprocess.run([MISE, '-C', '/', 'ls', '--current', 'node'], env=env,
                                 text=True, capture_output=True)
        self.assertIn('22', current.stdout)
        self.assertIn('config.local.toml', current.stdout)

    def test_empty_personal_install_does_not_require_an_apt_section(self):
        self.config.write_text('[settings]\nlockfile = true\n')
        for action in ('install', 'upgrade'):
            result = subprocess.run(['bash', str(ROOT / 'agentdesk.sh'), action],
                                    env=self.env, cwd=self.project, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
