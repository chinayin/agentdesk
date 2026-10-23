#!/usr/bin/env bash
set -euo pipefail
if [ ! -f /.dockerenv ] || [ "$(id -u)" -ne 0 ] || [ "$(cat /proc/1/comm 2>/dev/null)" != systemd ]; then
  echo 'Error: run only as root in a disposable Docker container with systemd' >&2
  exit 2
fi
ROOT=/opt/agentdesk
REPORT=/var/log/agentdesk-e2e
mkdir -p "$REPORT"
# 以桌面用户的登录 shell 运行，加载 /etc/profile.d/agentdesk.sh；代理沿用容器环境（可能为空）。
desktop_user() {
  # shellcheck disable=SC2016
  runuser -u desk -- env -i HOME=/home/desk USER=desk LOGNAME=desk \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=en_US.UTF-8 \
    http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
    all_proxy="${all_proxy:-}" no_proxy="${no_proxy:-}" \
    AGENTDESK_E2E_PROXY="${AGENTDESK_E2E_PROXY:-}" \
    bash -lc 'cd "$HOME"; "$@"' _ "$@"
}
verify() {
  # 不传参数：用户来自 /etc/agentdesk/agentdesk.yaml，监听来自 xrdp.ini。
  agentdesk verify
  # 连接信息：tunnel 模式给出 SSH 端口转发；普通用户也能查看。
  agentdesk info | tee "$REPORT/info.txt"
  grep -q 'ssh -N -L 13389:127.0.0.1:' "$REPORT/info.txt"
  grep -q '(password set)' "$REPORT/info.txt"
  desktop_user agentdesk info > /dev/null
  for tool in git node python go pnpm uv claude codex pi gh glab aws aliyun cloudflared \
    rg fd jq shellcheck yamlfmt bats direnv betterleaks tmux; do
    case "$tool" in
      go) desktop_user go version ;;
      tmux) desktop_user tmux -V ;;
      *) desktop_user "$tool" --version ;;
    esac
  done
  for package in google-chrome-stable code; do
    [ "$(dpkg-query -W -f='${Status}' "$package")" = 'install ok installed' ]
    dpkg-query -W -f='${Package} ${Version}\n' "$package"
  done
  # 检查安装包 postinst 注册源后仍能刷新，捕获 Signed-By 冲突。
  apt-get -o APT::Update::Error-Mode=any update -qq
}
case "${1:-}" in
  install)
    bash "$ROOT/install.sh" --user desk --theme none --rdp-mode tunnel
    # 一次性密码只进入容器内 chpasswd，不输出、不导出到宿主文件。
    python3 -c 'import secrets; print("desk:" + secrets.token_urlsafe(32))' | chpasswd
    verify
    grep -qx '  mode: tunnel' /etc/agentdesk/agentdesk.yaml
    # 管理员的本机增补写 config.local.toml，不改 AgentDesk 维护的 config.toml。
    agentdesk install --system apt:htop
    grep -q 'apt:htop' /etc/mise/config.local.toml
    cmp /etc/mise/config.toml "$ROOT/mise.toml"
    # 不带参数重跑 init：沿用已保存的 tunnel 等参数，系统清单、锁、密码与桌面默认值不变。
    sha256sum /etc/mise/config.toml /etc/mise/config.local.toml /etc/mise/mise.lock \
      /etc/X11/Xsession.d/21agentdesk /etc/xdg/agentdesk/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml \
      > "$REPORT/preserved.sha256"
    password_before="$(getent shadow desk | cut -d: -f2)"
    agentdesk init
    sha256sum --check "$REPORT/preserved.sha256"
    [ "$password_before" = "$(getent shadow desk | cut -d: -f2)" ]
    grep -q '^port=tcp://127.0.0.1:' /etc/xrdp/xrdp.ini
    unset password_before
    # 手改 AgentDesk 维护的清单：init 直接覆盖，local 文件保持不变。
    echo '# local edit' >> /etc/mise/config.toml
    agentdesk init
    cmp /etc/mise/config.toml "$ROOT/mise.toml"
    grep -q 'apt:htop' /etc/mise/config.local.toml
    agentdesk upgrade --system
    verify
    # 真正使用用户自定义工具；确认原生 mise 和 AgentDesk 写同一文件。
    sha256sum /etc/mise/config.toml /etc/mise/config.local.toml /etc/mise/mise.lock > "$REPORT/shared.sha256"
    desktop_user agentdesk install ruff
    desktop_user mise use -g ruff@latest
    desktop_user agentdesk upgrade
    desktop_user ruff --version
    sha256sum --check "$REPORT/shared.sha256"
    echo '[PASS] First install, saved settings, managed and local config, upgrades, personal software' >&2
    ;;
  check)
    verify
    desktop_user ruff --version
    install -d -m 0755 -o desk -g desk "$REPORT/gui"
    runtime="/run/user/$(id -u desk)"
    install -d -m 0700 -o desk -g desk "$runtime"
    # Xvfb 不经过 Xsession，手动带上 Xsession.d 设置的桌面默认值目录。
    desktop_user env XDG_RUNTIME_DIR="$runtime" XDG_CURRENT_DESKTOP=XFCE \
      XDG_CONFIG_DIRS=/etc/xdg/agentdesk:/etc/xdg \
      XDG_SESSION_TYPE=x11 DESKTOP_SESSION=xfce \
      timeout 300 xvfb-run -a -s '-screen 0 1440x900x24' \
      dbus-run-session -- bash "$ROOT/tests/e2e-gui.sh" "$REPORT/gui"
    echo '[PASS] Services and software survived container restart' >&2
    ;;
  *) echo 'Error: expected install or check' >&2; exit 1 ;;
esac
