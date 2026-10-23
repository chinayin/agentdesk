"""离线行为测试；不触碰主机配置、不调用真实 sudo/apt/云 CLI。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import json
import re
import xml.dom.minidom
import shutil

ROOT = Path(__file__).resolve().parents[1]
# 函数级测试在加载脚本后把设置文件指向不存在的路径，不读取开发机上的 /etc/agentdesk。
NO_SETTINGS = 'SETTINGS_FILE=/nonexistent/agentdesk/agentdesk.yaml; '
# 测试环境去掉开发机自带的代理变量，结果不受本机网络设置影响。
PROXY_KEYS = {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}


def clean_env(**extra):
    return {**{k: v for k, v in os.environ.items() if k.lower() not in PROXY_KEYS}, **extra}

# curl 替身：最新版本跳转返回 $RELEASE_URL，其余请求返回 $ARCHIVE 源码包。
CURL_STUB = """#!/bin/sh
echo "${https_proxy:-none}" > "$PROXY_LOG"
case "$*" in *url_effective*) printf "%s" "$RELEASE_URL"; exit 0 ;; esac
for a; do url="$a"; done
echo "$url" >> "$URL_LOG"
cat "$ARCHIVE"
"""


class HostTests(unittest.TestCase):
    def test_versions_resolve_without_github_api(self):
        # 关掉版本服务会让新主机按 IP 消耗 GitHub API 匿名限额，首次安装失败。
        import tomllib
        settings = tomllib.loads((ROOT / "mise.toml").read_text())["settings"]
        self.assertIs(settings.get("use_versions_host", True), True)

    def test_mise_comes_from_official_apt_repository(self):
        result = self.function('DRY_RUN=1; install_mise')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run: extrepo enable mise", result.stderr)
        self.assertIn("apt-get install -y --no-install-recommends mise", result.stderr)
        self.assertNotIn("github.com", result.stderr)

    def test_user_command_preview_does_not_print_proxy_credentials(self):
        result = self.function(
            'DRY_RUN=1; DESKTOP_USER=desk; '
            'HTTPS_PROXY=http://example-user:example-secret@proxy.invalid:3128; '
            'as_user echo probe'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('probe', result.stderr)
        self.assertNotIn('example-secret', result.stdout + result.stderr)

    def invoke(self, *args, env=None):
        return subprocess.run(
            ["bash", str(ROOT / "agentdesk.sh"), *args],
            text=True, capture_output=True, env=env,
        )

    def test_bare_command_shows_help_without_error(self):
        result = self.invoke()
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertTrue(result.stdout.startswith("Usage: agentdesk COMMAND"))
        result = self.invoke("--user", "desk")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Error: a command is required", result.stderr)

    def function(self, script, *args):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; ' + NO_SETTINGS + script, "_",
             str(ROOT / "agentdesk.sh"), *map(str, args)],
            text=True, capture_output=True,
        )

    def test_help_and_version_are_available_without_linux(self):
        result = self.invoke("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("desktop-reset", result.stdout)
        self.assertEqual(self.invoke("--version").returncode, 0)

    def test_bad_inputs_fail_before_system_changes(self):
        for args in [
            ["no-such-command"], ["init", "--user"], ["init", "--user", "root"],
            ["init", "--user", "desk;touch /tmp/unsafe"],
            ["init", "--rdp-port", "0"], ["init", "--rdp-port", "65536"],
            ["init", "--rdp-port", "x"], ["init", "--theme", "unknown"],
            ["init", "--rdp-mode", "invalid"], ["init", "--password", "secret"],
            ["desktop-reset"], ["desktop-reset", "--backup"], ["init", "--bogus"],
        ]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_proxy_option_exports_standard_variables_for_this_run(self):
        script = ('use_proxy "$1"; printf "%s|%s|%s|%s|%s" "$http_proxy" "$https_proxy" '
                  '"$all_proxy" "$HTTPS_PROXY" "$no_proxy"')
        url = "http://user:secret@proxy.example:3128"
        result = subprocess.run(["bash", "-c", 'source "$1"; shift; ' + script, "_", str(ROOT / "agentdesk.sh"), url],
                                env=clean_env(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "|".join([url] * 4 + ["localhost,127.0.0.1,::1"]))

    def test_proxy_option_rejects_socks_paths_and_bare_hosts(self):
        for value in ["socks5://proxy.example:1080", "http://proxy.example:3128/path", "proxy.example:3128"]:
            result = self.function('use_proxy "$1"', value)
            self.assertEqual(result.returncode, 1, (value, result.stderr))
        self.assertEqual(self.function("parse_args init --proxy").returncode, 1)

    def test_init_accepts_proxy(self):
        result = self.function('parse_args init --proxy http://proxy.example:8080; printf "%s" "$https_proxy"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "http://proxy.example:8080")

    def test_cli_sets_rdp_port(self):
        result = self.function('parse_args init --rdp-port 3390; printf "%s" "$RDP_PORT"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "3390")

    def test_default_desktop_user_is_the_invoking_user(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / "id"
            for uid, name, sudo_user, expected in [
                ("0", "root", "ubuntu", "ubuntu"),   # sudo 运行：取 SUDO_USER
                ("0", "root", "", "desk"),           # 直接以 root 运行：新建 desk
                ("0", "root", "root", "desk"),
                ("1000", "admin", "", "admin"),      # 普通用户运行：取自己
            ]:
                stub.write_text(f'#!/bin/sh\n[ "$1" = -u ] && echo {uid} || echo {name}\n')
                stub.chmod(0o755)
                env = {k: v for k, v in os.environ.items() if k != "SUDO_USER"}
                env.update(PATH=f"{tmp}:{os.environ['PATH']}", SUDO_USER=sudo_user)
                result = subprocess.run(
                    ["bash", "-c", 'source "$1"; ' + NO_SETTINGS + 'parse_args verify; printf "%s" "$DESKTOP_USER"',
                     "_", str(ROOT / "agentdesk.sh")], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected, (uid, sudo_user))

    def test_supported_system_matrix_and_architecture(self):
        with tempfile.TemporaryDirectory() as tmp:
            release = Path(tmp) / "os-release"
            for system, like, version, arch, status, warned in [
                ("ubuntu", "debian", "26.04", "amd64", 0, False), ("ubuntu", "debian", "24.04", "arm64", 0, False),
                ("ubuntu", "debian", "22.04", "amd64", 0, False), ("debian", "", "13", "arm64", 0, False),
                ("debian", "", "12", "amd64", 0, False),
                # 新版本与衍生版警告后继续；旧版本、非 Debian 系与其他架构拒绝。
                ("debian", "", "14", "amd64", 0, True), ("linuxmint", "ubuntu debian", "22", "amd64", 0, True),
                ("ubuntu", "debian", "20.04", "amd64", 2, False), ("debian", "", "11", "amd64", 2, False),
                ("fedora", "", "43", "amd64", 2, False), ("ubuntu", "debian", "26.04", "armhf", 2, False),
            ]:
                release.write_text(f'ID={system}\nID_LIKE="{like}"\nVERSION_ID="{version}"\n')
                result = self.function('detect_platform "$1" "$2"', release, arch)
                self.assertEqual(result.returncode, status, (system, version, arch, result.stderr))
                self.assertEqual("Warning: untested OS" in result.stderr, warned, result.stderr)

    def test_os_release_does_not_override_agentdesk_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            release = Path(tmp) / "os-release"
            release.write_text('NAME="Ubuntu"\nVERSION="26.04.1 LTS (Resolute Raccoon)"\nID=ubuntu\n'
                               'ID_LIKE=debian\nVERSION_ID="26.04"\n')
            result = self.function('before="$VERSION"; detect_platform "$1" amd64; [ "$VERSION" = "$before" ]', release)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Target: ubuntu 26.04 / amd64", result.stderr)

    def test_lock_platform_follows_machine_architecture(self):
        for machine, platform in [("x86_64", "linux-x64"), ("aarch64", "linux-arm64")]:
            result = self.function(f'uname() {{ echo {machine}; }}; mise_platform')
            self.assertEqual(result.stdout.strip(), platform, result.stderr)
        self.assertEqual(self.function('uname() { echo riscv64; }; mise_platform').returncode, 2)

    def test_dry_run_does_not_run_commands_or_create_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "never"
            result = self.function(
                'DRY_RUN=1; run touch "$1"; run mkdir "$1-dir"', target
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])
            self.assertEqual(result.stdout, "")
            self.assertIn("dry-run", result.stderr)

    def test_xrdp_listener_changes_only_global_section(self):
        original = (
            "[Globals]\nport=3389\nmax_bpp=32\nsecurity_layer=negotiate\n"
            "[Xorg]\nport=-1\ncode=20\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            src, dest = Path(tmp) / "in", Path(tmp) / "out"
            src.write_text(original)
            for mode, expected in [
                ("direct", "tcp://0.0.0.0:3391"),
                ("tunnel", "tcp://127.0.0.1:3391"),
            ]:
                result = self.function('render_xrdp "$1" "$2" "$3" "$4"',
                                       src, dest, mode, "3391")
                self.assertEqual(result.returncode, 0, result.stderr)
                rendered = dest.read_text()
                self.assertIn(f"port={expected}\n", rendered)
                self.assertIn("[Xorg]\nport=-1\ncode=20\n", rendered)
                self.assertIn("max_bpp=24\n", rendered)
                self.assertIn("security_layer=negotiate\n", rendered)

    def test_xrdp_rejects_missing_globals(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dest = Path(tmp) / "in", Path(tmp) / "out"
            src.write_text("[Xorg]\nport=-1\n")
            result = self.function('render_xrdp "$1" "$2" direct 3389', src, dest)
            self.assertNotEqual(result.returncode, 0)

    def test_read_only_verify_needs_no_force(self):
        result = self.function('parse_args verify --user desk; printf "%s" "$COMMAND"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "verify")

    def test_listener_check_requires_exact_address_and_port(self):
        for endpoint, status in [("127.0.0.1:3390", 0), ("0.0.0.0:3390", 1),
                                 ("127.0.0.1:339", 1)]:
            result = self.function(
                'printf "LISTEN 0 10 127.0.0.1:3390 0.0.0.0:*\\n" | listener_matches "$1"',
                endpoint,
            )
            self.assertEqual(result.returncode, status, result.stderr)

    def test_full_initialization_dry_run_does_not_write_user_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.function(
                'parse_args init --dry-run --theme none --user desk; '
                'DESKTOP_HOME="$1"; getent() { return 1; }; initialize', tmp,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])
            self.assertIn("xorgxrdp", result.stderr)
            self.assertIn("/etc/xdg/agentdesk", result.stderr)
            self.assertIn("agentdesk.yaml", result.stderr)

    def test_existing_password_is_never_reset(self):
        result = self.function(
            'parse_args init; getent() { return 0; }; '
            'passwd() { if [ "$1" = -S ]; then printf "desk P 2026-10-20 0 99999 7 -1\\n"; '
            'else echo "unexpected password reset" >&2; return 89; fi; }; configure_account'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("password reset", result.stderr)

    def test_proxy_whitelist_passes_only_set_values_in_lowercase(self):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; proxy_env; printf "%s\\n" "${PROXY_ENV[@]}"',
             "_", str(ROOT / "agentdesk.sh")],
            env={"PATH": os.environ["PATH"], "HTTPS_PROXY": "http://upper:3128",
                 "http_proxy": "http://lower:3128", "MISE_ENV": "unsafe"},
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["http_proxy=http://lower:3128", "https_proxy=http://upper:3128"])

    def test_program_files_follow_fixed_layout(self):
        result = self.function('program_files "$1"', ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = result.stdout.splitlines()
        for required in ["agentdesk.sh", "install.sh", "mise.toml", "resources/profile.d/agentdesk.sh",
                         "resources/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"]:
            self.assertIn(required, files)
        for item in files:
            self.assertTrue((ROOT / item).is_file(), item)
        self.assertFalse(any(i.startswith(("docs/", "tests/", "local/", "skills/")) for i in files))

    def test_program_files_reject_missing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "scripts").mkdir()
            result = self.function('program_files "$1"', tmp)
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_verify_reads_listener_from_xrdp_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini = Path(tmp) / "xrdp.ini"
            for content, status, endpoint in [
                ("[Globals]\nport=tcp://127.0.0.1:3390\n[Xorg]\nport=-1\n", 0, "127.0.0.1:3390"),
                ("[Globals]\nport = tcp://0.0.0.0:3389 \n", 0, "0.0.0.0:3389"),
                ("[Globals]\nport=3389\n", 1, ""),
                ("[Xorg]\nport=tcp://0.0.0.0:3389\n", 1, ""),
            ]:
                ini.write_text(content)
                result = self.function('xrdp_endpoint "$1"', ini)
                self.assertEqual(result.returncode, status, (content, result.stderr))
                self.assertEqual(result.stdout.strip(), endpoint)

    def test_options_may_precede_software_commands(self):
        result = self.invoke("--dry-run", "install", "ruff")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run", result.stderr)


class DesktopTests(unittest.TestCase):
    """系统级桌面默认值、登录环境、主题与重置；用临时根目录和替身命令，不碰主机。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, script, *args, env=None):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; ' + script, "_", str(ROOT / "agentdesk.sh"), *map(str, args)],
            env=env or os.environ.copy(), text=True, capture_output=True,
        )

    def test_defaults_follow_theme_and_locale(self):
        for theme, locale, gtk in [("whitesur", "zh_CN.UTF-8", "WhiteSur-Dark"),
                                   ("none", "en_US.UTF-8", "Greybird")]:
            with self.subTest(theme=theme):
                result = self.shell(f'THEME={theme}; LOCALE_NAME={locale}; write_desktop_defaults "$1"', self.root)
                self.assertEqual(result.returncode, 0, result.stderr)
                xdg = self.root / "etc/xdg/agentdesk"
                channels = xdg / "xfce4/xfconf/xfce-perchannel-xml"
                # 重置时移除的频道必须都有系统默认值。
                names = self.shell('printf "%s\\n" "${DESKTOP_CHANNELS[@]}"').stdout.split()
                self.assertEqual(len(names), 5)
                for name in names:
                    xml.dom.minidom.parse(str(channels / f"{name}.xml"))
                self.assertIn(f'value="{gtk}"', (channels / "xsettings.xml").read_text())
                self.assertIn(f'value="{gtk}"', (channels / "xfwm4.xml").read_text())
                session = self.root / "etc/X11/Xsession.d/21agentdesk"
                text = session.read_text()
                self.assertIn(f'LANG="{locale}"', text)
                self.assertIn('XDG_CONFIG_DIRS="/etc/xdg/agentdesk:${XDG_CONFIG_DIRS:-/etc/xdg}"', text)
                self.assertIn("unset DBUS_SESSION_BUS_ADDRESS", text)
                for path in [session, self.root / "etc/X11/Xsession.d/90agentdesk-input",
                             self.root / "etc/profile.d/agentdesk.sh"]:
                    # Xsession.d 与 profile.d 由 /bin/sh 加载，必须是 POSIX sh。
                    check = subprocess.run(["sh", "-n", str(path)], capture_output=True, text=True)
                    self.assertEqual(check.returncode, 0, (path, check.stderr))
                self.assertTrue((xdg / "autostart/org.fcitx.Fcitx5.desktop").is_file())
                self.assertIn("DefaultIM=pinyin", (xdg / "fcitx5/profile").read_text())
                # 模板占位符全部替换。
                rendered = [*xdg.rglob("*"), *(self.root / "etc/X11/Xsession.d").iterdir()]
                leftovers = [str(f) for f in rendered if f.is_file() and re.search(r"@[A-Z_]+@", f.read_text())]
                self.assertEqual(leftovers, [])

    def test_panel_launchers_reference_installed_applications(self):
        panel = (ROOT / "resources/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml").read_text()
        for app in ["xfce4-terminal", "thunar", "xfce4-appfinder"]:
            self.assertIn(f'value="{app}.desktop"', panel)
        self.assertNotIn("agentdesk.desktop", panel)

    def login_env(self, uid):
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        node = tools / "node"
        node.write_text("#!/bin/sh\nexit 0\n")
        node.chmod(0o755)
        stubs = self.root / "bin"
        stubs.mkdir(exist_ok=True)
        (stubs / "mise").write_text(f'#!/bin/sh\n[ "$1" = activate ] && exit 0\nprintf "%s\\n" "{tools}"\n')
        (stubs / "id").write_text(f"#!/bin/sh\necho {uid}\n")
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        return {"PATH": f"{stubs}:/usr/bin:/bin", "HOME": str(self.root)}, node

    def test_login_environment_adds_installed_tools_for_regular_users(self):
        env, node = self.login_env(1000)
        profile = ROOT / "resources/profile.d/agentdesk.sh"
        result = subprocess.run(["sh", "-c", '. "$1"; . "$1"; command -v node; printf "%s\\n" "$PATH"',
                                 "_", str(profile)], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], str(node))
        # 重复加载（嵌套登录 shell）不重复追加 shims。
        self.assertEqual(lines[1].split(":").count("/usr/local/share/mise/shims"), 1)

    def test_interactive_bash_enables_mise_then_direnv(self):
        env, _ = self.login_env(1000)
        stubs = self.root / "bin"
        (stubs / "mise").write_text(f'#!/bin/sh\n[ "$1" = activate ] && {{ echo \'HOOKS="mise"\'; exit 0; }}\n'
                                    f'printf "%s\\n" "{self.root / "tools"}"\n')
        (stubs / "direnv").write_text('#!/bin/sh\n[ "$1" = hook ] && echo \'HOOKS="$HOOKS direnv"\'\n')
        (stubs / "direnv").chmod(0o755)
        profile = str(ROOT / "resources/profile.d/agentdesk.sh")
        result = subprocess.run(["bash", "--norc", "--noprofile", "-i", "-c", '. "$1"; printf "%s" "$HOOKS"', "_", profile],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.stdout, "mise direnv", result.stderr)
        # 非交互 shell（图形会话、脚本）只加路径，不装 hook。
        result = subprocess.run(["sh", "-c", '. "$1"; printf "%s" "${HOOKS:-none}"', "_", profile],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.stdout, "none", result.stderr)

    def test_login_environment_leaves_root_untouched(self):
        env, _ = self.login_env(0)
        profile = ROOT / "resources/profile.d/agentdesk.sh"
        result = subprocess.run(["sh", "-c", '. "$1"; printf "%s" "$PATH"', "_", str(profile)],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, env["PATH"])

    def test_theme_download_failure_propagates(self):
        stubs = self.root / "bin"
        stubs.mkdir()
        (stubs / "git").write_text("#!/bin/sh\nexit 73\n")
        (stubs / "git").chmod(0o755)
        env = {**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}"}
        result = self.shell('install_theme "$1"', self.root / "sysroot", env=env)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertFalse((self.root / "sysroot/var/lib/agentdesk/theme").exists())

    def test_theme_dry_run_writes_nothing(self):
        result = self.shell('DRY_RUN=1; THEME=whitesur; configure_desktop')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run: install WhiteSur", result.stderr)

    def personal_settings(self):
        home = self.root / "home"
        channels = home / ".config/xfce4/xfconf/xfce-perchannel-xml"
        channels.mkdir(parents=True)
        for name in ["xfce4-panel", "xsettings", "keyboard-shortcuts"]:
            (channels / f"{name}.xml").write_text(f"personal {name}")
        (home / ".config/xfce4/panel").mkdir()
        (home / ".config/xfce4/panel/launcher-10").mkdir()
        return home, channels

    RESET = 'DESKTOP_USER=desk; DESKTOP_HOME="$1"; as_user() { "$@"; }; PGREP_STATUS="$2"; pgrep() { return "$PGREP_STATUS"; }; reset_desktop'

    def test_reset_returns_to_system_defaults(self):
        home, channels = self.personal_settings()
        result = self.shell(self.RESET, home, 1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((channels / "xfce4-panel.xml").exists())
        self.assertFalse((channels / "xsettings.xml").exists())
        self.assertFalse((home / ".config/xfce4/panel").exists())
        # 系统默认值不覆盖的个人设置保留。
        self.assertEqual((channels / "keyboard-shortcuts.xml").read_text(), "personal keyboard-shortcuts")
        # 不做备份，也不在家目录留下 AgentDesk 自己的文件。
        self.assertFalse((home / ".local/state/agentdesk").exists())

    def test_reset_refuses_active_session_without_changes(self):
        home, channels = self.personal_settings()
        result = self.shell(self.RESET, home, 0)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue((channels / "xfce4-panel.xml").exists())

    def test_reset_refuses_symlinked_settings(self):
        home, channels = self.personal_settings()
        target = self.root / "dotfiles.xml"
        target.write_text("dotfiles")
        (channels / "xsettings.xml").unlink()
        (channels / "xsettings.xml").symlink_to(target)
        result = self.shell(self.RESET, home, 1)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(target.read_text(), "dotfiles")
        self.assertTrue((channels / "xfce4-panel.xml").exists())


class SettingsTests(unittest.TestCase):
    """/etc/agentdesk/agentdesk.yaml：init 写入，之后的命令作为默认值读取。"""

    PRINT = 'printf "%s %s %s %s %s" "$DESKTOP_USER" "$THEME" "$LOCALE_NAME" "$RDP_MODE" "$RDP_PORT"'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = Path(self.tmp.name) / "etc/agentdesk/agentdesk.yaml"

    def shell(self, script, env=None):
        return subprocess.run(["bash", "-c", 'source "$1"; SETTINGS_FILE="$2"; shift 2; ' + script, "_",
                               str(ROOT / "agentdesk.sh"), str(self.file)],
                              env={**os.environ, **(env or {})}, text=True, capture_output=True)

    def test_init_options_round_trip_and_become_defaults(self):
        result = self.shell('parse_args init --user alice --theme none --rdp-mode tunnel --rdp-port 3390 '
                            '--locale zh_CN.UTF-8; write_settings "$SETTINGS_FILE"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o644)
        self.assertIn("rdp:\n  mode: tunnel\n  port: 3390\n", self.file.read_text())
        result = self.shell("parse_args verify; " + self.PRINT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "alice none zh_CN.UTF-8 tunnel 3390")

    def test_cli_overrides_file_and_environment_is_not_read(self):
        self.file.parent.mkdir(parents=True)
        self.file.write_text("user: alice\nrdp:\n  mode: tunnel\n  port: 3390\n")
        # 不支持 AGENTDESK_* 环境变量：设置了也不生效。
        result = self.shell("parse_args verify --user carol; " + self.PRINT,
                            {"AGENTDESK_USER": "bob", "AGENTDESK_RDP_PORT": "4000"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "carol whitesur en_US.UTF-8 tunnel 3390")

    def test_reader_accepts_comments_and_quotes_and_ignores_unknown_keys(self):
        self.file.parent.mkdir(parents=True)
        self.file.write_text('# managed\nuser: "alice"  # inline\ntheme: \'none\'\nfuture: x\n'
                             'rdp:\n  mode: tunnel\nextra:\n  mode: ignored\n')
        result = self.shell('settings_read "$SETTINGS_FILE"')
        self.assertEqual(result.stdout.splitlines(),
                         ["user=alice", "theme=none", "future=x", "rdp.mode=tunnel", "extra.mode=ignored"])
        result = self.shell("parse_args verify; " + self.PRINT)
        self.assertEqual(result.stdout, "alice none en_US.UTF-8 tunnel 3389")

    def test_invalid_saved_value_is_rejected(self):
        self.file.parent.mkdir(parents=True)
        self.file.write_text("rdp:\n  port: 99999\n")
        self.assertEqual(self.shell("parse_args verify").returncode, 1)


class InfoTests(unittest.TestCase):
    """agentdesk info：连接方式只来自本机事实，不猜公网地址、不需要 root。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.settings = self.base / "agentdesk.yaml"
        self.settings.write_text("user: desk\nrdp:\n  mode: tunnel\n  port: 3390\n")
        self.ini = self.base / "xrdp.ini"

    def info(self, listener, user="ubuntu", settings=None):
        self.ini.write_text(f"[Globals]\nport=tcp://{listener}\n")
        script = ('SETTINGS_FILE="$2"; XRDP_INI="$3"; USER="$4"; unset SUDO_USER; '
                  'hostname() { echo "172.31.20.80 172.17.0.1 fe80::1"; }; '
                  'timedatectl() { echo Etc/UTC; }; main info')
        return subprocess.run(["bash", "-c", 'source "$1"; ' + script, "_", str(ROOT / "agentdesk.sh"),
                               str(settings or self.settings), str(self.ini), user],
                              env=clean_env(), text=True, capture_output=True)

    def test_tunnel_mode_prints_ssh_forward(self):
        result = self.info("127.0.0.1:3390")
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("Desktop user  desk\n", result.stdout)
        self.assertIn("RDP listener  127.0.0.1:3390 (tunnel)", result.stdout)
        self.assertIn("ssh -N -L 13389:127.0.0.1:3390 ubuntu@SERVER", result.stdout)
        self.assertIn("Time zone     Etc/UTC", result.stdout)
        self.assertIn("local addresses: 172.31.20.80 172.17.0.1)", result.stdout)
        self.assertNotIn("fe80", result.stdout)

    def test_direct_mode_points_client_at_server_port(self):
        result = self.info("0.0.0.0:3389")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RDP client at SERVER:3389", result.stdout)
        self.assertIn("Allow only your own IP on TCP 3389", result.stdout)
        self.assertNotIn("ssh -N", result.stdout)

    def test_root_login_uses_placeholder_ssh_user(self):
        result = self.info("127.0.0.1:3390", user="root")
        self.assertIn("SSH_USER@SERVER", result.stdout)

    def test_uninitialized_host_is_reported(self):
        result = self.info("127.0.0.1:3390", settings=self.base / "absent.yaml")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not initialized", result.stderr)


class UpdateTests(unittest.TestCase):
    """agentdesk update：自我更新，相当于 brew update。下载交给已安装的 install.sh，这里用假 install.sh。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.settings = self.base / "agentdesk.yaml"
        self.settings.write_text("user: desk\n")
        self.program = self.base / "program"
        self.program.mkdir()
        (self.program / "install.sh").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CALL_LOG"\n')
        stubs = self.base / "bin"
        stubs.mkdir()
        (stubs / "curl").write_text(CURL_STUB)
        (stubs / "curl").chmod(0o755)
        self.calls, self.url = self.base / "calls", self.base / "url"
        self.env = {**clean_env(), "PATH": f"{stubs}:{os.environ['PATH']}", "CALL_LOG": str(self.calls),
                    "URL_LOG": str(self.url), "PROXY_LOG": str(self.base / "proxy"),
                    "RELEASE_URL": "https://github.com/chinayin/agentdesk/releases/tag/v9.9.9"}

    def shell(self, script, settings=None, **extra):
        return subprocess.run(["bash", "-c", 'source "$1"; SETTINGS_FILE="$2"; SCRIPT_DIR="$3"; shift 3; ' + script,
                               "_", str(ROOT / "agentdesk.sh"), str(settings or self.settings), str(self.program)],
                              env={**self.env, **extra}, text=True, capture_output=True)

    def invoke(self, *args, **extra):
        return subprocess.run(["bash", str(ROOT / "agentdesk.sh"), *args],
                              env={**self.env, **extra}, text=True, capture_output=True)

    def test_latest_release_is_resolved_from_redirect(self):
        result = self.shell('latest_release_tag "$AGENTDESK_REPO"')
        self.assertEqual((result.returncode, result.stdout), (0, "v9.9.9\n"), result.stderr)
        self.assertEqual(self.shell('latest_release_tag "$AGENTDESK_REPO"',
                                    RELEASE_URL="https://github.com/chinayin/agentdesk/releases").returncode, 1)

    def test_new_version_is_downloaded_by_installed_installer(self):
        result = self.shell("update_to_ref v9.9.9 0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["--remote", "--ref", "v9.9.9"])
        self.assertIn("-> 9.9.9", result.stderr)

    def test_same_version_is_up_to_date_unless_ref_is_explicit(self):
        result = self.shell("VERSION=9.9.9; update_to_ref v9.9.9 0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Already up to date", result.stderr)
        self.assertFalse(self.calls.exists())
        result = self.shell("VERSION=9.9.9; update_to_ref main 1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["--remote", "--ref", "main"])

    def test_update_requires_saved_settings(self):
        result = self.shell("self_update", settings=self.base / "absent.yaml")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("rerun install.sh", result.stderr)
        self.assertFalse(self.url.exists())

    def test_update_dry_run_downloads_nothing(self):
        result = self.shell("self_update --dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-> latest release", result.stderr)
        self.assertFalse(self.url.exists())

    def test_update_accepts_proxy(self):
        result = self.shell("self_update --proxy http://proxy.example:3128 --dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_update_arguments_are_rejected(self):
        for args in [("update", "--bogus"), ("update", "--ref", "main;rm"), ("update", "--ref")]:
            result = self.invoke(*args)
            self.assertEqual(result.returncode, 1, (args, result.stderr))
        self.assertFalse(self.url.exists())


class InstallerTests(unittest.TestCase):
    """install.sh：本地直接运行，远程下载源码包；用假 agentdesk.sh 和假 curl，不联网。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "agentdesk-main"
        self.source.mkdir()
        (self.source / "install.sh").write_bytes((ROOT / "install.sh").read_bytes())
        (self.source / "agentdesk.sh").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$(basename "$(dirname "$0")")" "$@" > "$CALL_LOG"\n')
        archive = self.base / "source.tar.gz"
        subprocess.run(["tar", "-czf", str(archive), "-C", str(self.base), "agentdesk-main"], check=True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        curl = self.bin / "curl"
        curl.write_text(CURL_STUB)
        curl.chmod(0o755)
        self.log, self.url, self.proxy = self.base / "calls", self.base / "url", self.base / "proxy"
        self.env = {**clean_env(), "PATH": f"{self.bin}:{os.environ['PATH']}", "PROXY_LOG": str(self.proxy),
                    "CALL_LOG": str(self.log), "URL_LOG": str(self.url), "ARCHIVE": str(archive),
                    "RELEASE_URL": "https://github.com/chinayin/agentdesk/releases/tag/v1.2.3"}

    def test_local_checkout_runs_init_without_download(self):
        result = subprocess.run(["bash", str(self.source / "install.sh"), "--user", "desk"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["agentdesk-main", "init", "--user", "desk"])
        self.assertFalse(self.url.exists())

    def test_piped_install_downloads_ref_and_passes_options(self):
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s", "--", "--ref", "v1.2.3", "--user", "desk"],
                                    stdin=script, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.url.read_text().strip(),
                         "https://github.com/chinayin/agentdesk/archive/v1.2.3.tar.gz")
        lines = self.log.read_text().splitlines()
        self.assertEqual(lines[1:], ["init", "--user", "desk"])
        self.assertNotEqual(lines[0], "agentdesk-main")

    def test_piped_install_defaults_to_latest_release(self):
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s"], stdin=script, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.url.read_text().strip(),
                         "https://github.com/chinayin/agentdesk/archive/v1.2.3.tar.gz")

    def test_piped_install_without_release_suggests_main(self):
        env = {**self.env, "RELEASE_URL": "https://github.com/chinayin/agentdesk/releases"}
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s"], stdin=script, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--ref main", result.stderr)
        self.assertFalse(self.url.exists())

    def test_piped_install_uses_proxy_without_passing_it_to_init(self):
        # sudo 会清空环境，所以代理以参数传入；install.sh 自己的下载和子进程 init 都继承它。
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s", "--", "--proxy", "http://proxy.example:3128", "--ref", "v1.2.3"],
                                    stdin=script, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.proxy.read_text().strip(), "http://proxy.example:3128")
        self.assertEqual(self.log.read_text().splitlines()[1:], ["init"])

    def test_invalid_proxy_is_rejected_before_download(self):
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s", "--", "--proxy", "socks5://proxy.example:1080"],
                                    stdin=script, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.proxy.exists())

    def test_remote_flag_downloads_even_inside_a_checkout(self):
        # agentdesk update 调用已安装的 install.sh，它旁边就有 agentdesk.sh，也必须下载新版本。
        result = subprocess.run(["bash", str(self.source / "install.sh"), "--remote", "--ref", "v1.2.3"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.url.read_text().strip(),
                         "https://github.com/chinayin/agentdesk/archive/v1.2.3.tar.gz")
        self.assertNotEqual(self.log.read_text().splitlines()[0], "agentdesk-main")

    def test_invalid_ref_is_rejected_before_download(self):
        with open(ROOT / "install.sh") as script:
            result = subprocess.run(["bash", "-s", "--", "--ref", "main;rm"], stdin=script,
                                    env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(self.url.exists())


if __name__ == "__main__":
    unittest.main()
