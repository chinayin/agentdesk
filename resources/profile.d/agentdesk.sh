# AgentDesk：登录 shell 与图形会话的工具路径；交互式 bash 启用 mise activate 与 direnv hook。
# 由 /etc/profile 加载（SSH 登录、xrdp 会话、XFCE 终端的登录 shell）；root 不受影响。
if [ "$(id -u)" -ne 0 ]; then
  export DISABLE_AUTOUPDATER=1
  case ":$PATH:" in
    *":/usr/local/share/mise/shims:"*) ;;
    *) PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/share/mise/shims:$PATH" ;;
  esac
  if command -v mise >/dev/null 2>&1; then
    # 离线解析已安装工具的路径，供图形应用使用；登录时不联网、不自动安装。
    if agentdesk_paths=$(MISE_AUTO_INSTALL=0 MISE_OFFLINE=1 mise -C / bin-paths 2>/dev/null); then
      agentdesk_paths=$(printf '%s' "$agentdesk_paths" | tr '\n' ':')
      [ -z "$agentdesk_paths" ] || PATH="${agentdesk_paths%:}:$PATH"
    fi
    unset agentdesk_paths
    # direnv 的 hook 须在最后，放在 mise activate 之后。
    case "$-" in
      *i*)
        if [ -n "${BASH_VERSION:-}" ]; then
          eval "$(mise activate bash)"
          if command -v direnv >/dev/null 2>&1; then eval "$(direnv hook bash)"; fi
        fi ;;
    esac
  fi
  export PATH
fi
