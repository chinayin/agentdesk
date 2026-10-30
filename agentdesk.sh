#!/usr/bin/env bash
# AgentDesk CLI：主机初始化、检查、桌面重置与软件命令；不执行用户的 mise task。
set -euo pipefail

VERSION="0.3.1-dev"
# 解析全局入口的软链，资源相对于真实程序目录。
agentdesk_source="${BASH_SOURCE[0]}"
while [ -L "$agentdesk_source" ]; do
  agentdesk_parent="$(cd "$(dirname "$agentdesk_source")" && pwd)"
  agentdesk_source="$(readlink "$agentdesk_source")"
  [[ "$agentdesk_source" = /* ]] || agentdesk_source="$agentdesk_parent/$agentdesk_source"
done
SCRIPT_DIR="$(cd "$(dirname "$agentdesk_source")" && pwd)"
unset agentdesk_source agentdesk_parent
DRY_RUN=0
AGENTDESK_REPO="chinayin/agentdesk"
SETTINGS_FILE=/etc/agentdesk/agentdesk.yaml
XRDP_INI=/etc/xrdp/xrdp.ini
SYS_VENDOR_FILE=/sys/class/dmi/id/sys_vendor
SSHD=/usr/sbin/sshd
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-agentdesk.conf
SSHD_RUNTIME_DIR=/run/sshd

die() { echo "Error: $*" >&2; exit 1; }
missing() { echo "Error: $*" >&2; exit 2; }
info() { echo "==> $*" >&2; }
warn() { echo "Warning: $*" >&2; }

# --proxy 只对本次运行生效，不保存；只接受 http(s)（apt 不支持 SOCKS）。
use_proxy() {
  [[ "$1" =~ ^https?://[^[:space:]/]+/?$ ]] || { usage >&2; die "--proxy must be an http(s)://host:port URL"; }
  export http_proxy="$1" https_proxy="$1" all_proxy="$1" HTTP_PROXY="$1" HTTPS_PROXY="$1" ALL_PROXY="$1"
  export no_proxy="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}"
  export NO_PROXY="$no_proxy"
}

# sudo 与 runuser 会清空环境：只透传已设置的代理变量，统一为小写名称。
proxy_env() {
  local name upper value
  PROXY_ENV=()
  for name in http_proxy https_proxy all_proxy no_proxy; do
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    value="${!name:-${!upper:-}}"
    [ -z "$value" ] || PROXY_ENV+=("$name=$value")
  done
}

# 程序结构固定：三个文件加 resources/，不另设清单。
program_files() {
  local root="$1"
  printf '%s\n' agentdesk.sh install.sh mise.toml
  [ -d "$root/resources" ] && [ ! -L "$root/resources" ] || missing "program directory missing or symlinked: resources"
  # 符号链接也列出，交给调用方统一拒绝。
  (cd "$root" && find resources \( -type f -o -type l \) | LC_ALL=C sort)
}

usage() {
  cat <<'EOF'
Usage: agentdesk COMMAND [OPTIONS]

Turn this server into an XFCE/xrdp remote desktop with mise-managed software.

Commands:
  init               Install or reconfigure the desktop
  verify             Check packages, SSH and RDP
  info               Show how to connect to this desktop
  rdp                Print an RDP URL (macOS: open "$(ssh HOST agentdesk rdp)")
  install [NAME...]  Add software to your list, or install what is missing
  upgrade            Upgrade installed software
  run TASK [ARGS]    Run a task from your mise config
  desktop-reset      Reset your XFCE settings to the defaults (requires --force)
  update             Update AgentDesk itself

Init options (saved to /etc/agentdesk/agentdesk.yaml and reused later):
  --user NAME        SSH and desktop user (default: agentdesk; saved settings take precedence)
  --theme NAME       whitesur | none (default: whitesur)
  --rdp-mode MODE    direct | tunnel (default: direct)
  --rdp-port PORT    RDP port (default: 3389)
  --locale NAME      en_US.UTF-8 | zh_CN.UTF-8 (default: en_US.UTF-8)

Other options:
  --system           install/upgrade: shared software for all users (admin)
  --ref REF          update: branch or tag to install (default: latest release)
  --proxy URL        HTTP(S) proxy for this run only
  --force            Confirm desktop-reset
  --dry-run          Show what would be done without changing anything
  -h, --help         Show this help
  --version          Show the version

Examples:
  agentdesk install gemini apt:htop
  agentdesk upgrade --system

Docs: https://github.com/chinayin/agentdesk
EOF
}

# 读取 init 写入的两层 YAML 子集，输出 key=value（嵌套键如 rdp.mode）。
settings_read() {
  # 单引号经 -v 传入，兼容 mawk。
  awk -v q="'" '
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      nested = (line ~ /^  [A-Za-z]/)
      sub(/^[[:space:]]+/, "", line)
      split_at = index(line, ":")
      if (split_at < 2) next
      key = substr(line, 1, split_at - 1)
      value = substr(line, split_at + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (!nested) section = ""
      if (!nested && value == "") { section = key; next }
      first = substr(value, 1, 1)
      if (length(value) >= 2 && (first == "\"" || first == q) && substr(value, length(value), 1) == first)
        value = substr(value, 2, length(value) - 2)
      print (nested && section != "" ? section "." : "") key "=" value
    }
  ' "$1"
}

# 所有人可读，不得写入凭据。
write_settings() {
  local file="$1"
  mkdir -p "${file%/*}"
  cat > "$file.tmp" <<EOF
# AgentDesk settings, written by "agentdesk init" and reused as defaults by later
# commands. Command-line options take precedence over this file.
user: $DESKTOP_USER
theme: $THEME
locale: $LOCALE_NAME
rdp:
  mode: $RDP_MODE
  port: $RDP_PORT
EOF
  chmod 0644 "$file.tmp"
  mv -f "$file.tmp" "$file"
}

parse_args() {
  local key value saved_user=""
  COMMAND=""
  THEME=whitesur
  RDP_MODE=direct
  RDP_PORT=3389
  LOCALE_NAME=en_US.UTF-8
  # 优先级：命令行 > 设置文件 > 默认值。
  if [ -r "$SETTINGS_FILE" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        user) saved_user="$value" ;;
        theme) THEME="$value" ;;
        locale) LOCALE_NAME="$value" ;;
        rdp.mode) RDP_MODE="$value" ;;
        rdp.port) RDP_PORT="$value" ;;
      esac
    done < <(settings_read "$SETTINGS_FILE")
  fi
  DESKTOP_USER="${saved_user:-agentdesk}"
  FORCE=0
  DRY_RUN=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) printf 'agentdesk %s\n' "$VERSION"; exit 0 ;;
      init|verify|info|rdp|desktop-reset)
        [ -z "$COMMAND" ] || { usage >&2; die "only one command is allowed"; }
        COMMAND="$1"; shift ;;
      --user|--theme|--rdp-mode|--rdp-port|--locale)
        [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || { usage >&2; die "$1 needs a value"; }
        case "$1" in
          --user) DESKTOP_USER="$2" ;; --theme) THEME="$2" ;;
          --rdp-mode) RDP_MODE="$2" ;; --rdp-port) RDP_PORT="$2" ;;
          --locale) LOCALE_NAME="$2" ;;
        esac
        shift 2 ;;
      --force) FORCE=1; shift ;;
      --proxy)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; die "--proxy needs a value"; }
        use_proxy "$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
  [ -n "$COMMAND" ] || { usage >&2; die "a command is required"; }
  [[ "$DESKTOP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$DESKTOP_USER" != root ] ||
    die "invalid desktop user"
  [[ "$RDP_PORT" =~ ^[0-9]{1,5}$ ]] || die "invalid RDP port"
  RDP_PORT=$((10#$RDP_PORT))
  [ "$RDP_PORT" -ge 1 ] && [ "$RDP_PORT" -le 65535 ] || die "invalid RDP port"
  case "$THEME" in whitesur|none) ;; *) die "theme must be whitesur or none" ;; esac
  case "$RDP_MODE" in direct|tunnel) ;; *) die "RDP mode must be direct or tunnel" ;; esac
  case "$LOCALE_NAME" in en_US.UTF-8|zh_CN.UTF-8) ;; *) die "unsupported locale" ;; esac
  if [ "$COMMAND" = desktop-reset ] && [ "$FORCE" -ne 1 ]; then
    usage >&2
    die "desktop-reset deletes personal XFCE settings; add --force to confirm"
  fi
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
  else
    "$@" >&2
  fi
}

# 已验证的版本直接通过；更早的版本缺少依赖，拒绝；其他 Debian 系（新版本、衍生版）警告后继续。
detect_platform() {
  local release="$1" arch="$2" ID ID_LIKE VERSION_ID
  [ -r "$release" ] || missing "cannot read os-release"
  # 在子 shell 里读取：os-release 的 VERSION 等变量不能覆盖本脚本的同名变量。
  # shellcheck disable=SC1090
  IFS='|' read -r ID VERSION_ID ID_LIKE < <(. "$release"; printf '%s|%s|%s\n' "${ID:-}" "${VERSION_ID:-}" "${ID_LIKE:-}")
  case "$arch" in amd64|arm64) ;; *) missing "unsupported architecture: $arch (amd64 or arm64 required)" ;; esac
  case "$ID:$VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;;
    ubuntu:1*|ubuntu:20.*|ubuntu:21.*|debian:[0-9]|debian:1[01])
      missing "unsupported OS: $ID $VERSION_ID (Ubuntu 22.04+ or Debian 12+ required)" ;;
    *)
      case " $ID $ID_LIKE " in
        *" debian "*|*" ubuntu "*) warn "untested OS: $ID $VERSION_ID; tested: Ubuntu 22.04/24.04/26.04, Debian 12/13" ;;
        *) missing "unsupported OS: $ID $VERSION_ID (Debian or Ubuntu family required)" ;;
      esac ;;
  esac
  info "Target: $ID $VERSION_ID / $arch"
}

# 锁文件只记录本机平台。
mise_platform() {
  case "$(uname -m)" in
    x86_64) echo linux-x64 ;;
    aarch64|arm64) echo linux-arm64 ;;
    *) missing "unsupported architecture: $(uname -m)" ;;
  esac
}

preflight() {
  [ "$(uname -s)" = Linux ] || missing "run on the target Linux server"
  command -v dpkg >/dev/null || missing "dpkg is required"
  detect_platform /etc/os-release "$(dpkg --print-architecture)"
  command -v systemctl >/dev/null && [ -d /run/systemd/system ] ||
    missing "a running systemd host is required"
  if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -ne 0 ]; then
    command -v sudo >/dev/null || missing "run as root or install sudo"
    # sudo 清空环境：参数已标准化，代理经 env 显式传入。
    local flags=("$COMMAND" --user "$DESKTOP_USER" --theme "$THEME"
      --rdp-mode "$RDP_MODE" --rdp-port "$RDP_PORT" --locale "$LOCALE_NAME")
    if [ "$FORCE" -eq 1 ]; then flags+=(--force); fi
    proxy_env
    exec sudo /usr/bin/env ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
      bash "$SCRIPT_DIR/agentdesk.sh" "${flags[@]}"
  fi
  if getent passwd "$DESKTOP_USER" >/dev/null; then
    [ "$(id -u "$DESKTOP_USER")" -ge 1000 ] || missing "choose a regular user (UID >= 1000)"
    DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
    [[ "$DESKTOP_HOME" = /* ]] && [ "$DESKTOP_HOME" != / ] && [ "$DESKTOP_HOME" != /root ] ||
      missing "invalid desktop HOME"
    case "$(getent passwd "$DESKTOP_USER" | cut -d: -f7)" in
      */nologin|*/false) missing "desktop user has a disabled login shell" ;;
    esac
  else
    [ "$COMMAND" = init ] || missing "desktop user does not exist"
    DESKTOP_HOME="/home/$DESKTOP_USER"
    if [ -e "$DESKTOP_HOME" ]; then missing "unowned home already exists: $DESKTOP_HOME"; fi
  fi
  # 防止生成的 shell/desktop 路径被换行或元字符破坏。
  case "$DESKTOP_HOME$SCRIPT_DIR" in
    *$'\n'*|*'"'*|*'`'*|*'$'*|*\\*|*'%'*) missing "unsupported characters in HOME or checkout path" ;;
  esac
}

as_user() {
  if [ "$DRY_RUN" -eq 1 ]; then
    # 预览不打印代理（可能含密码）。
    run runuser -u "$DESKTOP_USER" -- "$@"
    return
  fi
  proxy_env
  run runuser -u "$DESKTOP_USER" -- env -i \
    HOME="$DESKTOP_HOME" USER="$DESKTOP_USER" LOGNAME="$DESKTOP_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} TERM=xterm LANG="$LOCALE_NAME" "$@"
}

render_xrdp() {
  local input="$1" output="$2" mode="$3" port="$4" address="0.0.0.0"
  [ "$mode" != tunnel ] || address="127.0.0.1"
  awk -v listener="tcp://$address:$port" '
    function defaults() {
      if (inside && !seen_port) print "port=" listener
      if (inside && !seen_bpp) print "max_bpp=24"
    }
    /^[[:space:]]*\[/ {
      defaults()
      inside = ($0 ~ /^[[:space:]]*\[Globals\][[:space:]]*$/)
      if (inside) { found=1; seen_port=0; seen_bpp=0 }
    }
    inside && /^[[:space:]]*port[[:space:]]*=/ {
      if (!seen_port) print "port=" listener
      seen_port=1; next
    }
    inside && /^[[:space:]]*max_bpp[[:space:]]*=/ {
      if (!seen_bpp) print "max_bpp=24"
      seen_bpp=1; next
    }
    { print }
    END { defaults(); if (!found) exit 2 }
  ' "$input" > "$output"
}

install_packages() {
  info "Installing system packages without a full-system upgrade"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install \
    -y --no-install-recommends --no-upgrade \
    ca-certificates curl wget git gnupg sudo unzip tar gzip xz-utils bzip2 zstd \
    python3 python3-venv build-essential openssh-client openssh-server rsync file sed gawk \
    gettext-base tzdata less procps iproute2 locales fontconfig \
    xfce4 xfce4-terminal xfce4-whiskermenu-plugin xfce4-notifyd gvfs \
    xrdp xorgxrdp dbus-x11 dbus-user-session x11-xserver-utils \
    polkitd pkexec ssl-cert librsvg2-common adwaita-icon-theme greybird-gtk-theme \
    fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu-core \
    fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-qt5 \
    im-config sassc libglib2.0-dev-bin libxml2-utils gnome-themes-extra extrepo
}

# mise 来自官方 apt 源（经 extrepo 启用，带签名校验）。
SYSTEM_MISE=/usr/bin/mise

# /releases/latest 跳转到最新标签（不走有频率限制的 API）；还没有发布时返回 1。
latest_release_tag() {
  local url tag
  url="$(curl -fsSL --retry 3 --connect-timeout 20 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest")" || return 1
  tag="${url##*/}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s\n' "$tag"
}

# 每次 init 都装到官方源的最新版。
install_mise() {
  info "Installing mise from its official APT repository"
  run extrepo enable mise
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mise
}

configure_locale() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: enable en_US.UTF-8 and zh_CN.UTF-8; keep system default locale"
    return
  fi
  local language
  for language in en_US.UTF-8 zh_CN.UTF-8; do
    if ! grep -qxF "$language UTF-8" /etc/locale.gen; then
      printf '%s UTF-8\n' "$language" >> /etc/locale.gen
    fi
  done
  locale-gen >&2
}

configure_account() {
  if ! getent passwd "$DESKTOP_USER" >/dev/null; then
    run useradd --create-home --shell /bin/bash --user-group "$DESKTOP_USER"
    # 使用密码 sudo，不生成 NOPASSWD 配置。
    run usermod -aG sudo "$DESKTOP_USER"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: preserve desktop password"
  elif [ "$(passwd -S "$DESKTOP_USER" | awk '{print $2}')" != P ]; then
    warn "SSH and RDP password login is not ready: run sudo passwd $DESKTOP_USER before connecting"
  fi
}

# 仅为工作账户启用密码认证；Match all 结束作用域，后续配置继续正常解析。
render_ssh() {
  cat <<EOF
# Managed by AgentDesk.
Match User $DESKTOP_USER
    PasswordAuthentication yes
    AuthenticationMethods any
    PermitEmptyPasswords no
Match all
EOF
}

ssh_password_enabled() {
  local effective
  effective="$("$SSHD" -T -f "$SSHD_CONFIG" \
    -C "user=${DESKTOP_USER},host=client,addr=192.0.2.2,laddr=192.0.2.1,lport=22")" || return 1
  awk '
    $1 == "passwordauthentication" { password = ($2 == "yes") }
    $1 == "permitemptypasswords" { nonempty = ($2 == "no") }
    $1 == "authenticationmethods" {
      for (i = 2; i <= NF; i++) if ($i == "any" || $i == "password") single = 1
    }
    END { exit !(password && nonempty && single) }
  ' <<< "$effective"
}

# 只支持主配置在首个 Match 前直接 Include 受管文件或标准目录通配符。
ssh_dropin_included() {
  awk -v file="$SSHD_DROPIN" -v pattern="${SSHD_DROPIN%/*}/*.conf" '
    tolower($1) ~ /^match(=|$)/ { exit }
    tolower($1) == "include" {
      for (i = 2; i <= NF && $i !~ /^#/; i++) {
        path = $i; gsub(/^"|"$/, "", path)
        if (path == file || path == pattern) found = 1
      }
    }
    END { exit !found }
  ' "$SSHD_CONFIG"
}

configure_ssh() (
  set -euo pipefail
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: enable SSH password login for $DESKTOP_USER in $SSHD_DROPIN"
    return
  fi
  local directory="${SSHD_DROPIN%/*}" item work changed=0 reload_attempted=0
  for item in "${SSHD_CONFIG%/*}" "$SSHD_CONFIG" "$directory" "$SSHD_DROPIN" "$SSHD_RUNTIME_DIR"; do
    [ ! -L "$item" ] || missing "refusing symlinked SSH configuration: $item"
    if [ -e "$item" ]; then
      [ "$(stat -c %u "$item")" = 0 ] &&
        [ "$((8#$(stat -c %a "$item") & 022))" -eq 0 ] || missing "unsafe SSH configuration: $item"
    fi
  done
  [ ! -e "$SSHD_DROPIN" ] || [ -f "$SSHD_DROPIN" ] || missing "not a regular file: $SSHD_DROPIN"
  ssh_dropin_included || missing "SSH requires a global Include ${directory}/*.conf before any Match in $SSHD_CONFIG"
  install -d -m 0755 "$SSHD_RUNTIME_DIR"
  "$SSHD" -t -f "$SSHD_CONFIG"
  install -d -m 0755 "$directory"
  work="$(mktemp -d)"
  # EXIT trap 调用。
  # shellcheck disable=SC2329
  restore_ssh() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$changed" -eq 1 ]; then
      if [ -f "$work/previous" ]; then cp -p "$work/previous" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
      if [ "$reload_attempted" -eq 1 ]; then systemctl reload ssh >/dev/null 2>&1 || true; fi
      warn "SSH configuration restored after failure"
    fi
    rm -rf "$work"
  }
  trap restore_ssh EXIT
  render_ssh > "$work/new"
  if ! cmp -s "$work/new" "$SSHD_DROPIN"; then
    [ ! -f "$SSHD_DROPIN" ] || cp -p "$SSHD_DROPIN" "$work/previous"
    changed=1
    install -m 0644 "$work/new" "$SSHD_DROPIN"
  fi
  "$SSHD" -t -f "$SSHD_CONFIG"
  ssh_password_enabled || missing "SSH password login is blocked for $DESKTOP_USER; check Include and Match rules in $SSHD_CONFIG"
  if systemctl is-active --quiet ssh; then
    if [ "$changed" -eq 1 ]; then
      reload_attempted=1
      systemctl reload ssh
    fi
  elif ! systemctl is-active --quiet ssh.socket; then
    systemctl enable --now ssh
  fi
  info "SSH password authentication enabled for $DESKTOP_USER"
)

configure_rdp() (
  set -euo pipefail
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: configure xrdp mode=$RDP_MODE port=$RDP_PORT"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  render_xrdp "$XRDP_INI" "$tmp" "$RDP_MODE" "$RDP_PORT"
  if ! cmp -s "$tmp" "$XRDP_INI"; then
    cat "$tmp" > "$XRDP_INI"
    info "Updated $XRDP_INI: mode=$RDP_MODE port=$RDP_PORT"
    if systemctl is-active --quiet xrdp; then
      warn "RDP config changed; log out and run: sudo systemctl restart xrdp"
    fi
  fi
  usermod -aG ssl-cert xrdp
)

install_program() {
  local program_only="${1:-0}" root="${2:-}" item mode parent
  local destination="$root/usr/local/lib/agentdesk" link="$root/usr/local/bin/agentdesk"
  local software_config="$root/etc/mise/config.toml"
  local directories=("$root/usr/local" "$root/usr/local/lib" "$root/usr/local/bin" "$destination")
  if [ "$program_only" -eq 0 ]; then directories+=("$root/etc/mise" "${SETTINGS_FILE%/*}"); fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: install root-owned program at $destination; link /usr/local/bin/agentdesk"
    if [ "$program_only" -eq 0 ]; then
      info "dry-run: replace AgentDesk-managed /etc/mise/config.toml; keep /etc/mise/config.local.toml"
    fi
    return
  fi
  local listing files=()
  listing="$(program_files "$SCRIPT_DIR")" || exit "$?"
  while IFS= read -r item; do files+=("$item"); done <<< "$listing"
  for item in "${files[@]}"; do
    case "$item" in
      */*)
        parent="$destination/${item%/*}"
        while [ "$parent" != "$destination" ]; do
          directories+=("$parent")
          parent="${parent%/*}"
        done ;;
    esac
  done
  for item in "${directories[@]}"; do
    [ ! -L "$item" ] || missing "refusing symlinked installation directory: $item"
    if [ -e "$item" ]; then
      [ "$(stat -c %u "$item")" = 0 ] &&
        [ "$((8#$(stat -c %a "$item") & 022))" -eq 0 ] || missing "unsafe installation directory: $item"
    fi
  done
  if [ -e "$link" ] || [ -L "$link" ]; then
    [ -L "$link" ] &&
      [ "$(readlink "$link")" = "$destination/agentdesk.sh" ] ||
      missing "$link already exists and is not the managed link"
  fi
  for item in "${files[@]}"; do
    [ -f "$SCRIPT_DIR/$item" ] && [ ! -L "$SCRIPT_DIR/$item" ] || missing "program file missing or symlinked: $item"
    [ ! -L "$destination/$item" ] || missing "refusing symlinked program file: $item"
  done
  if [ "$program_only" -eq 0 ] && { [ -e "$software_config" ] || [ -L "$software_config" ]; }; then
    [ ! -L "$software_config" ] && [ -f "$software_config" ] || missing "unsafe $software_config"
  fi
  # 前两项 /usr/local、/usr/local/lib 只做检查，不改其权限。
  install -d -m 0755 "${directories[@]:2}"
  if [ "$SCRIPT_DIR" != "$destination" ]; then
    for item in "${files[@]}"; do
      mode=0644
      case "$item" in *.sh) mode=0755 ;; esac
      install -m "$mode" "$SCRIPT_DIR/$item" "$destination/$item"
    done
  fi
  if [ ! -L "$link" ]; then
    ln -s "$destination/agentdesk.sh" "$link"
  fi
  [ "$program_only" -eq 0 ] || return 0
  # 通用清单随版本直接覆盖；本机增补在 config.local.toml。
  if ! cmp -s "$SCRIPT_DIR/mise.toml" "$software_config"; then
    install -m 0644 "$SCRIPT_DIR/mise.toml" "$software_config"
    info "Installed AgentDesk software list: $software_config"
  fi
}

# install.sh 的独立更新入口；旧版本没有此入口时必须拒绝，不能退回 init。
install_program_only() {
  install_program 1
}

# WhiteSur 主题固定提交，不跟随默认分支更新。
THEME_GTK_REV="d5782652d412137e26fb8ff55b55a5572e4c6995"
THEME_ICON_REV="73d8040da51a9ed74e47c7366e7e9ff437601a5c"
# 系统默认值覆盖的 XFCE 频道；desktop-reset 移除用户的同名文件以回到默认值。
DESKTOP_CHANNELS=(xfce4-panel xsettings xfwm4 xfce4-desktop xfce4-terminal)

theme_checkout() {
  local repository="$1" revision="$2" path="$3"
  if [ ! -d "$path/.git" ]; then
    git init --quiet "$path"
    git -C "$path" remote add origin "$repository"
  fi
  if ! git -C "$path" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$path" fetch --quiet --depth 1 origin "$revision"
  fi
  git -C "$path" checkout --quiet --detach "$revision"
  [ "$(git -C "$path" rev-parse HEAD)" = "$revision" ] || die "unexpected theme revision"
}

# 主题装到系统目录，全机共用；参数为根目录前缀（测试用临时目录）。
install_theme() {
  local root="$1"
  local cache="$root/var/cache/agentdesk/themes" marker="$root/var/lib/agentdesk/theme"
  local themes="$root/usr/share/themes" icons="$root/usr/share/icons"
  local revision="$THEME_GTK_REV $THEME_ICON_REV" gtk_status=0
  if [ -r "$marker" ] && [ "$(cat "$marker")" = "$revision" ] &&
    [ -f "$themes/WhiteSur-Dark/gtk-3.0/gtk.css" ] && [ -f "$themes/WhiteSur-Dark/xfwm4/themerc" ] &&
    [ -f "$icons/WhiteSur-dark/index.theme" ]; then
    info "Keeping installed WhiteSur revision"
    return
  fi
  mkdir -p "$cache" "$themes" "$icons" "${marker%/*}"
  theme_checkout https://github.com/vinceliuice/WhiteSur-gtk-theme.git "$THEME_GTK_REV" "$cache/gtk-$THEME_GTK_REV"
  theme_checkout https://github.com/vinceliuice/WhiteSur-icon-theme.git "$THEME_ICON_REV" "$cache/icons-$THEME_ICON_REV"
  info "Installing WhiteSur; third-party installer output: $cache/install.log"
  # 上游无活动 XFCE 会话时 fix_whiskermenu 可能失败，以最终产物为准。
  (cd "$cache/gtk-$THEME_GTK_REV" && TERM=xterm bash install.sh -d "$themes" -c dark -o normal) \
    > "$cache/install.log" 2>&1 || gtk_status=$?
  [ -f "$themes/WhiteSur-Dark/gtk-3.0/gtk.css" ] && [ -f "$themes/WhiteSur-Dark/xfwm4/themerc" ] ||
    die "GTK theme incomplete; inspect $cache/install.log"
  [ "$gtk_status" -eq 0 ] || warn "GTK installer returned $gtk_status; theme files exist, inspect $cache/install.log"
  (cd "$cache/icons-$THEME_ICON_REV" && TERM=xterm bash install.sh -d "$icons") >> "$cache/install.log" 2>&1
  [ -f "$icons/WhiteSur-dark/index.theme" ] || die "icon theme incomplete; inspect $cache/install.log"
  printf '%s\n' "$revision" > "$marker"
}

# 默认值写到 /etc/xdg/agentdesk 并置于 XDG_CONFIG_DIRS 最前，不覆盖软件包的 /etc/xdg；
# 用户的 ~/.config 仍优先。参数为根目录前缀。
write_desktop_defaults() {
  local root="$1" item theme_name=Greybird icon_name=Adwaita
  local xdg="$root/etc/xdg/agentdesk"
  if [ "$THEME" = whitesur ]; then theme_name=WhiteSur-Dark; icon_name=WhiteSur-dark; fi
  # 占位符的取值都是校验过的固定选项，不含 sed 特殊字符。
  local placeholders=(-e "s/@THEME_NAME@/$theme_name/g" -e "s/@ICON_THEME@/$icon_name/g" -e "s/@LOCALE@/$LOCALE_NAME/g")
  render() { sed "${placeholders[@]}" "$1" > "$2"; chmod 0644 "$2"; }
  while IFS= read -r item; do
    mkdir -p "$xdg/$(dirname "$item")"
    render "$SCRIPT_DIR/resources/xdg/$item" "$xdg/$item"
  done < <(cd "$SCRIPT_DIR/resources/xdg" && find . -type f | LC_ALL=C sort)
  mkdir -p "$root/etc/X11/Xsession.d" "$root/etc/profile.d"
  for item in 21agentdesk 90agentdesk-input; do
    render "$SCRIPT_DIR/resources/Xsession.d/$item" "$root/etc/X11/Xsession.d/$item"
  done
  install -m 0644 "$SCRIPT_DIR/resources/profile.d/agentdesk.sh" "$root/etc/profile.d/agentdesk.sh"
}

configure_desktop() {
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$THEME" != whitesur ] || info "dry-run: install WhiteSur GTK@$THEME_GTK_REV and icons@$THEME_ICON_REV into /usr/share"
    info "dry-run: write desktop defaults to /etc/xdg/agentdesk, /etc/X11/Xsession.d and /etc/profile.d"
    return
  fi
  if [ "$THEME" = whitesur ]; then install_theme ""; fi
  write_desktop_defaults ""
  info "Desktop defaults written; users without their own XFCE settings get them at next login"
}

initialize() {
  # 首次安装暂时 mask，防止包的 postinst 在 tunnel 配置写入前开放公网 RDP。
  local masked=0
  if [ "$DRY_RUN" -eq 0 ] && ! dpkg-query -W -f='${Status}' xrdp 2>/dev/null | grep -qx 'install ok installed'; then
    [ ! -e /run/systemd/system/xrdp.service ] && [ ! -L /run/systemd/system/xrdp.service ] ||
      missing "xrdp already has a runtime unit override"
    systemctl mask --runtime xrdp.service xrdp-sesman.service >&2
    masked=1
    trap 'systemctl unmask --runtime xrdp.service xrdp-sesman.service >/dev/null 2>&1' EXIT
  fi
  install_packages
  configure_account
  configure_ssh
  configure_locale
  install_mise
  configure_rdp
  install_program
  run bash /usr/local/lib/agentdesk/agentdesk.sh install --system
  configure_desktop
  if [ "$masked" -eq 1 ]; then
    systemctl unmask --runtime xrdp.service xrdp-sesman.service >&2
    trap - EXIT
  fi
  run systemctl enable xrdp.service xrdp-sesman.service
  # start 不会重启已经运行的服务。
  run systemctl start xrdp.service
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: save options to $SETTINGS_FILE"
  else
    write_settings "$SETTINGS_FILE"
  fi
  info "Host initialization finished (agentdesk $VERSION)"
  info "Personal software: agentdesk install NAME; upgrade shared software: agentdesk upgrade --system"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: print connection details (agentdesk info)"
  else
    show_info
  fi
}

# 云主机的公网地址：按 DMI 厂商只查对应平台的实例元数据（AWS IMDSv2、阿里云），
# 绕过代理；拿不到时为空，不做推测。其他机器不发请求。
public_address() {
  local vendor token ip=""
  vendor="$(cat "$SYS_VENDOR_FILE" 2>/dev/null)" || return 0
  case "$vendor" in
    "Amazon EC2")
      token="$(curl -fsS --noproxy '*' --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token 2>/dev/null)" &&
        ip="$(curl -fsS --noproxy '*' --max-time 2 -H "X-aws-ec2-metadata-token: ${token}" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)" ;;
    "Alibaba Cloud")
      token="$(curl -fsS --noproxy '*' --max-time 2 -X PUT -H 'X-aliyun-ecs-metadata-token-ttl-seconds: 60' \
        http://100.100.100.200/latest/api/token 2>/dev/null)" || return 0
      ip="$(curl -fsS --noproxy '*' --max-time 2 -H "X-aliyun-ecs-metadata-token: ${token}" \
        http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null)" ||
        ip="$(curl -fsS --noproxy '*' --max-time 2 -H "X-aliyun-ecs-metadata-token: ${token}" \
          http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null)" ;;
  esac
  if [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then printf '%s\n' "$ip"; fi
}

# 连接所需的本机事实，写入调用方声明的 conn_* 变量：监听、模式、公网地址（可能为空）
# 和 RDP 客户端要连的地址（隧道模式为本机转发端口）。
load_connection() {
  [ -r "$SETTINGS_FILE" ] || missing "AgentDesk is not initialized on this host; run install.sh first"
  conn_endpoint="$(xrdp_endpoint "$XRDP_INI" 2>/dev/null)" || missing "no RDP listener in ${XRDP_INI}; rerun agentdesk init"
  conn_port="${conn_endpoint##*:}"
  conn_mode=direct
  [ "${conn_endpoint%:*}" != 127.0.0.1 ] || conn_mode=tunnel
  conn_server="$(public_address)"
  conn_target="${conn_server:+${conn_server}:${conn_port}}"
  [ "$conn_mode" = direct ] || conn_target=127.0.0.1:13389
}

# 地址和用户名已校验；编码值中的冒号，兼容 macOS 的 URL 解析。
rdp_url() {
  printf 'rdp://full%%20address=s%%3A%s&username=s%%3A%s\n' "${1//:/%3A}" "$DESKTOP_USER"
}

# 链接输出到 stdout，可直接交给 macOS open。
show_rdp() {
  local conn_endpoint conn_port conn_mode conn_server conn_target
  load_connection
  [ "$conn_mode" = tunnel ] || [ -n "$conn_server" ] ||
    missing "cannot find this server's public address; see agentdesk info"
  rdp_url "$conn_target"
}

# 连接方式，init 结束时与 agentdesk info 输出到 stdout。只报告本机事实与云平台元数据，
# 不输出任何凭据。
show_info() {
  local conn_endpoint conn_port conn_mode conn_server conn_target
  local password="" addresses zone
  load_connection
  # 只有 root 能读其他账户的密码状态。
  if [ "$EUID" -eq 0 ]; then
    if password_ready "$DESKTOP_USER"; then
      password=" (password set)"
    else
      password=" (no password yet: sudo passwd ${DESKTOP_USER})"
    fi
  fi
  zone="$(timedatectl show -p Timezone --value 2>/dev/null)" || zone=""
  [ -n "$zone" ] || zone="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
  cat <<EOF
AgentDesk $VERSION

Login user      ${DESKTOP_USER}${password}
RDP listener    ${conn_endpoint} (${conn_mode})
Public address  ${conn_server:-unknown}
Time zone       ${zone:-unknown}

EOF
  if [ -z "$conn_server" ]; then
    addresses="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | paste -sd ' ' -)" || addresses=""
    cat <<EOF
Connection address unavailable
  Get the server address from your cloud console or administrator.
  Local IPv4      ${addresses:-unknown}
EOF
    return
  fi
  if [ "$conn_mode" = tunnel ]; then
    cat <<EOF
Connect (SSH tunnel)
  Start on your computer and leave running:
    ssh -N -L 13389:127.0.0.1:${conn_port} ${DESKTOP_USER}@${conn_server}
EOF
  else
    echo "Connect (direct)"
  fi
  cat <<EOF
  Address       ${conn_target}
  Session       Xorg
EOF
  [ "$conn_mode" != direct ] || echo "  Allow your IP on TCP ${conn_port} in the security group or firewall."
  cat <<EOF

On your computer (choose one)
  macOS / Windows App:
    open '$(rdp_url "$conn_target")'

  Windows:
    mstsc /v:${conn_target}

SSH terminal (same user and password)
  ssh ${DESKTOP_USER}@${conn_server}
  Allow your IP on TCP 22 in the security group or firewall.
EOF
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

password_ready() {
  passwd -S "$1" | awk '{exit ($2 != "P")}'
}

listener_matches() {
  awk -v endpoint="$1" '$4 == endpoint {found=1} END {exit !found}'
}

listener_ready() {
  ss -H -ltn | listener_matches "$1"
}

ssh_active() {
  systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket
}

ssh_listener_ready() {
  ss -H -ltn | awk '$4 ~ /:22$/ { found=1 } END { exit !found }'
}

# 读取 init 写入 xrdp.ini 的 tcp://地址:端口。
xrdp_endpoint() {
  awk '
    /^[[:space:]]*\[/ { inside = ($0 ~ /^[[:space:]]*\[Globals\][[:space:]]*$/) }
    inside && /^[[:space:]]*port[[:space:]]*=/ {
      sub(/^[[:space:]]*port[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      if ($0 ~ /^tcp:\/\/(0\.0\.0\.0|127\.0\.0\.1):[0-9]+$/) { sub(/^tcp:\/\//, ""); print; found = 1 }
      exit
    }
    END { exit !found }
  ' "$1"
}

verify() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: check packages, mise, account, session files, SSH and RDP"
    return
  fi
  local failures=0 package endpoint
  # 检查结果是产物，写 stdout。
  check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      echo "[PASS] $label"
    else
      echo "[FAIL] $label"
      failures=$((failures + 1))
    fi
  }
  for package in xfce4 gvfs gvfs-daemons xrdp xorgxrdp openssh-server fcitx5 fcitx5-chinese-addons fonts-noto-cjk librsvg2-common mise; do
    check "$package installed" package_installed "$package"
  done
  check "xrdp active" systemctl is-active --quiet xrdp
  check "xrdp enabled" systemctl is-enabled --quiet xrdp
  check "xrdp-sesman active" systemctl is-active --quiet xrdp-sesman
  check "SSH active" ssh_active
  check "SSH listener TCP 22" ssh_listener_ready
  check "SSH password authentication for $DESKTOP_USER" ssh_password_enabled
  check "SSH and RDP password set" password_ready "$DESKTOP_USER"
  check "desktop defaults present" test -f /etc/xdg/agentdesk/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml
  check "desktop session environment present" test -f /etc/X11/Xsession.d/21agentdesk
  check "login environment present" test -f /etc/profile.d/agentdesk.sh
  check "global command available" test -x /usr/local/bin/agentdesk
  check "system software config present" test -r /etc/mise/config.toml
  check "agentdesk settings present" test -r "$SETTINGS_FILE"
  if endpoint="$(xrdp_endpoint "$XRDP_INI" 2>/dev/null)"; then
    RDP_PORT="${endpoint##*:}"
    RDP_MODE=direct
    [ "${endpoint%:*}" != 127.0.0.1 ] || RDP_MODE=tunnel
    check "RDP listener $endpoint" listener_ready "$endpoint"
  else
    check "RDP listener configured in $XRDP_INI" false
  fi
  info "External SSH password login, GUI login, Chinese input, installed apps and firewall still require manual verification"
  info "Connection details: agentdesk info"
  [ "$failures" -eq 0 ]
}

# 删除系统默认值覆盖范围内的个人 XFCE 设置。
reset_desktop() {
  local xfce="$DESKTOP_HOME/.config/xfce4" channel
  if pgrep -u "$DESKTOP_USER" -x xfce4-session >/dev/null || pgrep -u "$DESKTOP_USER" -x xfconfd >/dev/null; then
    missing "log out of all desktop sessions of $DESKTOP_USER before reset"
  fi
  if [ ! -e "$xfce" ]; then
    info "No personal XFCE settings; already using system defaults"
    return
  fi
  # 由 dotfiles 软链管理时，删除会改到 dotfiles 本身，因此拒绝。
  [ ! -L "$DESKTOP_HOME/.config" ] && [ ! -L "$xfce" ] && [ -z "$(find "$xfce" -type l -print -quit)" ] ||
    missing "XFCE settings contain symlinks; manage these dotfiles explicitly before reset"
  for channel in "${DESKTOP_CHANNELS[@]}"; do
    as_user rm -f "$xfce/xfconf/xfce-perchannel-xml/$channel.xml"
  done
  as_user rm -rf "$xfce/panel"
  info "Desktop reset to system defaults for $DESKTOP_USER; other personal settings retained"
}

# 软件命令只分派原生 mise；系统层由 mise 合并 config.toml 与 config.local.toml（后者优先）。
SHARED_MISE_FILES=(/etc/mise/config.toml /etc/mise/config.local.toml /etc/mise/mise.lock /etc/mise/mise.local.lock)

software_exec() {
  if [ "$DRY_RUN" -eq 1 ]; then run "$@"; else "$@"; fi
}

software_shared_permissions() {
  # mise 原子生成的锁可能为 0600；共享清单和锁必须能被普通用户读取。
  local shared_file
  for shared_file in "${SHARED_MISE_FILES[@]}"; do
    [ -e "$shared_file" ] || continue
    [ ! -L "$shared_file" ] && [ -f "$shared_file" ] &&
      [ "$(stat -c '%u' "$shared_file")" = 0 ] || missing "unsafe shared config file: $shared_file"
    chmod 0644 "$shared_file"
  done
}

software_mise() {
  if [ "$DRY_RUN" -eq 1 ]; then
    # 预览不打印代理等环境值。
    run "$SOFTWARE_MISE" -C / "$@"
    return
  fi
  if [ "$SOFTWARE_SYSTEM" -eq 1 ]; then
    # 只读系统配置：忽略调用者环境、项目和 root 的个人配置。
    # 不设 MISE_SYSTEM_CONFIG_FILE，否则只加载单个文件，config.local.toml 会被忽略。
    proxy_env
    software_exec env -i HOME=/root USER=root LOGNAME=root \
      PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
      ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
      LANG=C.UTF-8 MISE_IGNORED_CONFIG_PATHS=/root/.config/mise \
      MISE_INSTALLS_DIR=/usr/local/share/mise/installs \
      MISE_SHIMS_DIR=/usr/local/share/mise/shims \
      "$SOFTWARE_MISE" -C / "$@"
    software_shared_permissions
  else
    software_exec "$SOFTWARE_MISE" -C / "$@"
  fi
}

# 锁定时下载失败的工具不会进锁，到 install --locked 才报错；补一句排查方向，保留原退出码。
locked_install_failed() {
  warn "some tools could not be locked or downloaded; check access to GitHub (or pass --proxy URL) and rerun"
  return "$1"
}

# 个人操作里，锁定与 apt 包只看个人清单：不改系统锁，也不替用户升级共享应用。
# use、install、reshim 照常加载系统清单，与用户直接运行 mise 一致；忽略它会让 mise
# 去改共享目录里每个工具的 global 链接，而那需要 root。
personal_only() {
  if [ "$SOFTWARE_SYSTEM" -eq 1 ]; then
    software_mise "$@"
  else
    MISE_IGNORED_CONFIG_PATHS=/etc/mise software_mise "$@"
  fi
}

software_main() (
  local action="$1" item config paths raw platform options_done=0
  shift
  local tools=() packages=() task_args=() config_args=(--global)
  SOFTWARE_SYSTEM=0
  DRY_RUN=0
  # 单次解析：-- 之前的选项随处可写；run 的任务名之后全部原样交给任务。
  while [ "$#" -gt 0 ]; do
    item="$1"
    shift
    if [ "$options_done" -eq 0 ]; then
      case "$item" in
        --system) SOFTWARE_SYSTEM=1; continue ;;
        --dry-run) DRY_RUN=1; continue ;;
        --proxy)
          [ "$#" -ge 1 ] && [ -n "$1" ] || { usage >&2; die "--proxy needs a value"; }
          use_proxy "$1"; shift; continue ;;
        -h|--help) usage; return ;;
        --version) printf 'agentdesk %s\n' "$VERSION"; return ;;
        --) options_done=1; continue ;;
        -*) usage >&2; die "unknown software option: $item" ;;
      esac
    fi
    if [ "$action" = run ]; then
      [[ "$item" != -* ]] || { usage >&2; die "run requires a task name"; }
      task_args=("$item" "$@")
      break
    fi
    [ "$action" = install ] || { usage >&2; die "upgrade takes no names; edit the config or use native mise for selective upgrades"; }
    # 名称原样交给 mise 解析。
    [[ "$item" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:@+~-]*$ ]] || die "invalid software name: $item"
    case "$item" in
      apt:) die "apt package name is required" ;;
      apt:*) packages+=("$item") ;;
      *) tools+=("$item") ;;
    esac
  done
  if [ "$action" = run ]; then
    [ "$SOFTWARE_SYSTEM" -eq 0 ] || die "run does not support --system"
    [ "${#task_args[@]}" -gt 0 ] || { usage >&2; die "run requires a task name"; }
  fi
  if [ "$SOFTWARE_SYSTEM" -eq 1 ]; then
    # 只写 local 文件；config.toml 会被 update 覆盖。
    config=/etc/mise/config.local.toml
    config_args=(--path "$config")
    SOFTWARE_MISE="$SYSTEM_MISE"
  else
    [ "$EUID" -ne 0 ] || missing "run personal software commands as the desktop user; use --system for shared software"
    config="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
    SOFTWARE_MISE=mise
  fi
  info "Software config: $config"
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$SOFTWARE_SYSTEM" -eq 1 ]; then
      [ "$(uname -s)" = Linux ] || missing "system software operations require Linux"
      if [ "$EUID" -ne 0 ]; then
        proxy_env
        exec sudo /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
          PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
          ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
          /bin/bash "$SCRIPT_DIR/agentdesk.sh" "$action" --system \
          ${tools[@]+"${tools[@]}"} ${packages[@]+"${packages[@]}"}
      fi
      # 系统配置及其目录须 root 所有且他人不可写；local 文件与锁可能尚不存在。
      for item in /etc /etc/mise /etc/mise/config.toml "${SHARED_MISE_FILES[@]:1}"; do
        if [ ! -e "$item" ] && [ ! -L "$item" ]; then
          [ "$item" != /etc ] && [ "$item" != /etc/mise ] && [ "$item" != /etc/mise/config.toml ] ||
            missing "expected a regular system config path: $item"
          continue
        fi
        [ ! -L "$item" ] || missing "refusing symlinked system config path: $item"
        raw="$(stat -c '%u %a' "$item")"
        [ "${raw%% *}" = 0 ] && [ "$((8#${raw#* } & 022))" -eq 0 ] ||
          missing "system config must be root-owned and not group/world writable: $item"
      done
      [ -x "$SOFTWARE_MISE" ] || missing "system mise not found: $SOFTWARE_MISE; run agentdesk init"
    else
      command -v mise >/dev/null || missing "mise is required"
      SOFTWARE_MISE="$(command -v mise)"
      # 固定在 / 下执行，避开调用者的项目配置。
      cd /
      # npm 等后端需要共享 Node 等工具的路径。
      paths="$(MISE_AUTO_INSTALL=0 MISE_OFFLINE=1 "$SOFTWARE_MISE" -C / bin-paths)"
      if [ -n "$paths" ]; then
        paths="$(printf '%s' "$paths" | tr '\n' ':')"
        export PATH="${paths%:}:$PATH"
      fi
      # 锁设置不依赖系统清单：个人的锁定与 apt 命令会忽略它。
      if [ "$action" != run ]; then export MISE_LOCKFILE=1 MISE_LOCKFILE_MODE=merge; fi
    fi
  fi
  if [ "$action" = run ]; then
    software_mise run "${task_args[@]}"
  elif [ "${#tools[@]}" -gt 0 ] || [ "${#packages[@]}" -gt 0 ]; then
    if [ "${#tools[@]}" -gt 0 ]; then
      software_mise use "${config_args[@]}" "${tools[@]}"
      software_mise reshim
    fi
    if [ "${#packages[@]}" -gt 0 ]; then
      personal_only bootstrap packages use "${config_args[@]}" "${packages[@]}"
    fi
  else
    # upgrade 和新主机先 --bump，避免把缓存中的旧版本当作 latest；其余沿用锁。不删除旧版本。
    platform="$(mise_platform)"
    if [ "$action" = upgrade ] || { [ "$SOFTWARE_SYSTEM" -eq 1 ] && [ ! -e /etc/mise/mise.lock ]; }; then
      personal_only lock --global --bump --platform "$platform"
    else
      personal_only lock --global --platform "$platform"
    fi
    if [ "$SOFTWARE_SYSTEM" -eq 1 ]; then
      software_mise install --system --locked || locked_install_failed "$?"
      software_mise reshim --system
      # 先写入厂商源等系统文件，再装 apt 包。
      software_mise bootstrap files apply --yes
    else
      software_mise install --locked || locked_install_failed "$?"
      software_mise reshim
    fi
    if [ "$action" = upgrade ]; then
      personal_only bootstrap packages upgrade --yes
    else
      personal_only bootstrap packages apply --yes
    fi
  fi
)

# 自我更新只替换程序；主机配置由 init 应用，软件由 upgrade 升级。
# explicit=1 表示显式 --ref，版本相同也重装。
update_to_ref() {
  local ref="$1" explicit="$2"
  if [ "$explicit" -eq 0 ] && [ "${ref#v}" = "$VERSION" ]; then
    info "Already up to date: agentdesk $VERSION"
    return
  fi
  info "Updating agentdesk $VERSION -> ${ref#v}"
  bash "$SCRIPT_DIR/install.sh" --remote --update-only --ref "$ref"
}

self_update() {
  local ref="" explicit=0
  DRY_RUN=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; die "--ref needs a value"; }
        ref="$2"; explicit=1; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --proxy)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; die "--proxy needs a value"; }
        use_proxy "$2"; shift 2 ;;
      -h|--help) usage; return ;;
      --version) printf 'agentdesk %s\n' "$VERSION"; return ;;
      *) usage >&2; die "unknown update option: $1" ;;
    esac
  done
  [ -z "$ref" ] || [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid ref: ${ref}"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "dry-run: agentdesk $VERSION -> ${ref:-latest release}; program files only"
    return
  fi
  [ "$(uname -s)" = Linux ] || missing "run on the target Linux server"
  if [ "$EUID" -ne 0 ]; then
    command -v sudo >/dev/null || missing "run as root or install sudo"
    proxy_env
    exec sudo /usr/bin/env ${PROXY_ENV[@]+"${PROXY_ENV[@]}"} \
      bash "$SCRIPT_DIR/agentdesk.sh" update ${ref:+--ref "$ref"}
  fi
  command -v curl >/dev/null || missing "curl is required"
  if [ -z "$ref" ]; then
    ref="$(latest_release_tag "$AGENTDESK_REPO")" ||
      missing "no AgentDesk release found; use --ref main to follow the development branch"
  fi
  update_to_ref "$ref" "$explicit"
}

main() {
  local arg index=0 skip=0 command=""
  # 不带参数时显示帮助，不当作错误。
  if [ "$#" -eq 0 ]; then usage; return; fi
  # 选项可写在子命令前：跳过带值选项的值，第一个位置参数即子命令。
  for arg in "$@"; do
    index=$((index + 1))
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$arg" in
      --user|--theme|--rdp-mode|--rdp-port|--locale|--ref|--proxy) skip=1 ;;
      -*) ;;
      *) command="$arg"; break ;;
    esac
  done
  case "$command" in
    install|upgrade|run)
      software_main "$command" "${@:1:index-1}" "${@:index+1}"
      return ;;
    update)
      self_update "${@:1:index-1}" "${@:index+1}"
      return ;;
  esac
  parse_args "$@"
  # info 与 rdp 只读本机信息，不需要 root。
  case "$COMMAND" in
    info) show_info; return ;;
    rdp) show_rdp; return ;;
  esac
  preflight
  case "$COMMAND" in
    init) initialize ;;
    verify) verify ;;
    desktop-reset) reset_desktop ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
