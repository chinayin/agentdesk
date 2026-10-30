"""用真实 sshd 解析临时配置；不触碰主机 SSH 服务或账户。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SSHD = shutil.which("sshd") or "/usr/sbin/sshd"


@unittest.skipUnless(Path(SSHD).is_file(), "sshd is required for SSH configuration tests")
class SshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.key = self.base / "host_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.directory = self.base / "sshd_config.d"
        self.directory.mkdir()
        self.dropin = self.directory / "00-agentdesk.conf"
        self.config = self.base / "sshd_config"
        self.config.write_text(
            f"Include {self.directory}/*.conf\nPort 22\nHostKey {self.key}\n"
            "PasswordAuthentication no\nPubkeyAuthentication yes\n"
            "AuthenticationMethods publickey\nPermitEmptyPasswords no\nPermitRootLogin prohibit-password\n"
        )
        self.calls = self.base / "service.calls"

    def configure(self, user="agentdesk", extra=":", fail_reload=False, active="ssh"):
        # 仅替换文件所有者检查和 systemd 边界，配置解析、写入及恢复均执行真实逻辑。
        script = (
            'source "$1"; SSHD_CONFIG="$2"; SSHD_DROPIN="$3"; SSHD="$4"; SSHD_RUNTIME_DIR="$6"; '
            'SETTINGS_FILE=/nonexistent/agentdesk.yaml; parse_args init --user "$5"; '
            'stat() { case "$1 $2" in "-c %u") echo 0 ;; "-c %a") echo 755 ;; '
            '*) command stat "$@" ;; esac; }; '
            'systemctl() { printf "%s\\n" "$*" >> "$SERVICE_CALLS"; '
            'case "$1" in is-active) [ "$3" = "$ACTIVE_SERVICE" ] ;; reload) return "$FAIL_RELOAD" ;; '
            '*) return 0 ;; esac; }; ' + extra + '; configure_ssh'
        )
        return subprocess.run(
            ["bash", "-c", script, "_", str(ROOT / "agentdesk.sh"), str(self.config),
             str(self.dropin), SSHD, user, str(self.base / "run/sshd")],
            env={**os.environ, "SERVICE_CALLS": str(self.calls), "FAIL_RELOAD": str(int(fail_reload)),
                 "ACTIVE_SERVICE": active},
            text=True, capture_output=True,
        )

    def effective(self, user):
        result = subprocess.run(
            [SSHD, "-T", "-f", str(self.config), "-C",
             f"user={user},host=client,addr=192.0.2.2,laddr=192.0.2.1,lport=22"],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split(" ", 1) for line in result.stdout.splitlines())

    def test_password_login_enabled_only_for_selected_user(self):
        original = self.config.read_bytes()
        before = {user: self.effective(user) for user in ["root", "ubuntu"]}
        result = self.configure(extra=":")
        self.assertEqual(result.returncode, 0, result.stderr)
        account = self.effective("agentdesk")
        self.assertEqual(account["passwordauthentication"], "yes")
        self.assertEqual(account["authenticationmethods"], "any")
        self.assertEqual(account["permitemptypasswords"], "no")
        self.assertEqual(account["pubkeyauthentication"], "yes")
        self.assertEqual(self.config.read_bytes(), original)
        for user in before:
            self.assertEqual(self.effective(user), before[user])
        self.assertIn("reload ssh", self.calls.read_text())

    def test_rerun_is_idempotent_and_user_change_removes_old_exception(self):
        self.assertEqual(self.configure(extra=":").returncode, 0)
        before = self.dropin.read_bytes()
        self.calls.unlink()
        self.assertEqual(self.configure(extra=":").returncode, 0)
        self.assertEqual(self.dropin.read_bytes(), before)
        self.assertNotIn("reload ssh", self.calls.read_text() if self.calls.exists() else "")
        result = self.configure(user="developer", extra=":")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.effective("developer")["passwordauthentication"], "yes")
        self.assertEqual(self.effective("agentdesk")["passwordauthentication"], "no")

    def test_ignored_dropin_fails_without_changing_existing_config(self):
        self.config.write_text(self.config.read_text().split("\n", 1)[1])
        result = self.configure(extra=":")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.dropin.exists())
        self.assertNotIn("reload ssh", self.calls.read_text() if self.calls.exists() else "")

    def test_invalid_candidate_is_removed_before_reload(self):
        result = self.configure(extra='render_ssh() { echo InvalidSshDirective; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.dropin.exists())
        self.assertNotIn("reload ssh", self.calls.read_text() if self.calls.exists() else "")

    def test_conditional_include_is_rejected(self):
        include, rest = self.config.read_text().split("\n", 1)
        for condition in ["Match Address 127.0.0.1", "Match=Address *,!10.0.0.0/8",
                          "Match = Address *,!10.0.0.0/8"]:
            with self.subTest(condition=condition):
                self.config.write_text(rest + condition + "\n" + include + "\n")
                result = self.configure()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("global Include", result.stderr)
                self.assertFalse(self.dropin.exists())

    def test_existing_match_local_port_is_supported(self):
        with self.config.open("a") as config:
            config.write("Match LocalPort 22\n    X11Forwarding no\n")
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.effective("agentdesk")["passwordauthentication"], "yes")

    def test_inactive_service_is_started_but_active_socket_is_preserved(self):
        result = self.configure(active="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / "run/sshd").is_dir())
        self.assertIn("enable --now ssh", self.calls.read_text())
        self.calls.unlink()
        result = self.configure(active="ssh.socket")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("enable --now", self.calls.read_text())
        self.assertNotIn("reload ssh", self.calls.read_text())

    def test_failed_reload_restores_previous_config(self):
        self.assertEqual(self.configure(extra=":").returncode, 0)
        original = self.dropin.read_bytes()
        result = self.configure(user="developer", extra=":", fail_reload=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.dropin.read_bytes(), original)
        self.assertEqual(self.effective("agentdesk")["passwordauthentication"], "yes")
        self.assertEqual(self.effective("developer")["passwordauthentication"], "no")

    def test_symlinked_dropin_is_not_followed(self):
        target = self.base / "untouched"
        target.write_text("keep me\n")
        self.dropin.symlink_to(target)
        result = self.configure(extra=":")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "keep me\n")

    def test_dry_run_does_not_write_or_reload(self):
        result = self.configure(extra="DRY_RUN=1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.dropin.exists())
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
