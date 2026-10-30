#!/usr/bin/env bash
# AgentDesk 安装入口：管道运行时下载最新发布版本（或 --ref），源码目录内直接使用本地文件，
# 默认执行 init；--update-only 只替换程序。本脚本不认识的参数原样交给 init。
set -euo pipefail

REPO="chinayin/agentdesk"
REF=""
REMOTE=0
UPDATE_ONLY=0

die() { echo "Error: $*" >&2; exit 1; }
missing() { echo "Error: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage: install.sh [--ref REF] [--proxy URL] [--update-only | INIT OPTIONS]

Install AgentDesk on this server and run "agentdesk init".

  curl -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh | sudo bash
  curl -x URL -fsSL https://raw.githubusercontent.com/chinayin/agentdesk/main/install.sh \
    | sudo bash -s -- --proxy URL
  sudo bash install.sh          # inside a source checkout

Options:
  --ref REF     Branch or tag to download (default: latest release)
  --proxy URL   HTTP(S) proxy for this installation (download, apt, mise, git); not saved.
                sudo drops exported proxies, so pass it here when piping to "sudo bash"
  --remote      Download even when run from a source checkout (used by "agentdesk update")
  --update-only Replace program files only; leave host configuration and software unchanged
  -h, --help    Show help
  All other options are passed to "agentdesk init"; see "agentdesk --help".
EOF
}

# 与 agentdesk.sh 相同：只对本次运行生效，不保存；apt 不支持 SOCKS。
use_proxy() {
  [[ "$1" =~ ^https?://[^[:space:]/]+/?$ ]] || { usage >&2; die "--proxy must be an http(s)://host:port URL"; }
  export http_proxy="$1" https_proxy="$1" all_proxy="$1" HTTP_PROXY="$1" HTTPS_PROXY="$1" ALL_PROXY="$1"
  export no_proxy="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}"
  export NO_PROXY="$no_proxy"
}

fetch() { curl -fsSL --retry 3 --connect-timeout 20 "$@"; }

# /releases/latest 跳转到最新标签；还没有发布时停在 releases 页面。
latest_ref() {
  local url
  url="$(fetch -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" || return 1
  [[ "${url##*/}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  printf '%s\n' "${url##*/}"
}

run_source() {
  local root="$1"; shift
  if [ "$UPDATE_ONLY" -eq 1 ]; then
    grep -q '^install_program_only() {' "$root/agentdesk.sh" ||
      missing "this AgentDesk version does not support --update-only; no files changed"
    bash -c 'source "$1"; install_program_only' _ "$root/agentdesk.sh"
    echo '==> AgentDesk program updated. To apply host configuration, run: sudo agentdesk init' >&2
  else
    bash "$root/agentdesk.sh" init "$@"
  fi
}

# 包在 main 中：管道运行时先读完整个脚本，子进程读 stdin 不会吃掉后续内容。
main() {
  local args=() script root
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; die "--ref needs a value"; }
        REF="$2"; shift 2 ;;
      --proxy)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; die "--proxy needs a value"; }
        use_proxy "$2"; shift 2 ;;
      --remote) REMOTE=1; shift ;;
      --update-only) UPDATE_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [ "$UPDATE_ONLY" -eq 1 ] && [ "${#args[@]}" -gt 0 ]; then
    die "--update-only cannot be combined with init options"
  fi

  # 管道运行时 BASH_SOURCE 为空。
  script="${BASH_SOURCE[0]:-}"
  if [ "$REMOTE" -eq 0 ] && [ -n "$script" ] && [ -f "$script" ]; then
    root="$(cd "$(dirname "$script")" && pwd)"
    if [ -f "$root/agentdesk.sh" ]; then
      run_source "$root" ${args[@]+"${args[@]}"}
      return
    fi
  fi

  [ -z "$REF" ] || [[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid ref: ${REF}"
  command -v curl >/dev/null || missing "curl is required"
  command -v tar >/dev/null || missing "tar is required"
  if [ -z "$REF" ]; then
    REF="$(latest_ref)" ||
      missing "no AgentDesk release found; install the development branch with: bash -s -- --ref main"
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "==> Downloading AgentDesk ${REF}" >&2
  fetch "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xzf - -C "$tmp" --strip-components=1
  [ -f "$tmp/agentdesk.sh" ] || die "downloaded AgentDesk ${REF} does not contain agentdesk.sh"
  run_source "$tmp" ${args[@]+"${args[@]}"}
}

main "$@"
