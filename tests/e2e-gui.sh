#!/usr/bin/env bash
# 普通用户在独立 Xvfb/DBus 会话中启动真实应用；不接受条款、不登录账号。
set -euo pipefail
REPORT="${1:?report directory required}"
proxy_flags=()
if [ -n "${AGENTDESK_E2E_PROXY:-}" ]; then
  proxy_flags=("--proxy-server=$AGENTDESK_E2E_PROXY" '--proxy-bypass-list=localhost;127.0.0.1;[::1]')
fi
xfce4-session > "$REPORT/xfce.log" 2>&1 &
session_pid=$!
trap 'kill "$session_pid" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<30; attempt++)); do
  if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'; then break; fi
  sleep 1
done
xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'
# 验证真实会话已加载左侧 Dock，且五个启动器都解析成实际文件；不能只检查模板中的 ID。
python3 - "$REPORT" <<'PY'
from pathlib import Path
import json
import subprocess
import sys
import time
from urllib.parse import unquote

def query(path):
    return subprocess.check_output(
        ["xfconf-query", "-c", "xfce4-panel", "-p", path], text=True, stderr=subprocess.DEVNULL).strip()

for attempt in range(30):
    try:
        assert query("/panels/panel-2/position") == "p=7;x=0;y=0"
        assert query("/panels/panel-2/mode") == "1"
        launchers = {}
        for plugin in [14, 15, 10, 11, 12]:
            items = [line.strip() for line in query(f"/plugins/plugin-{plugin}/items").splitlines()
                     if line.strip().endswith(".desktop")]
            assert len(items) == 1, (plugin, items)
            item = items[0]
            if item.startswith("file://"):
                path = Path(unquote(item[7:]))
            elif item.startswith("/"):
                path = Path(item)
            else:
                path = Path.home() / ".config/xfce4/panel" / f"launcher-{plugin}" / item
            assert path.is_file(), str(path)
            launchers[str(plugin)] = str(path)
        break
    except (AssertionError, subprocess.CalledProcessError):
        if attempt == 29:
            raise
        time.sleep(1)
Path(sys.argv[1], "dock-launchers.json").write_text(json.dumps(launchers, indent=2) + "\n")
PY
xfconf-query -c xfce4-panel -lv > "$REPORT/panel-properties.txt"
echo '[PASS] Left dock and five application launchers are loaded' >&2
gio info -a standard::type trash:/// > "$REPORT/trash.txt"
echo '[PASS] GIO trash backend is available' >&2
launch() {
  local name="$1" class="$2" attempt window=''
  shift 2
  "$@" > "$REPORT/$name.log" 2>&1 &
  for ((attempt=0; attempt<45; attempt++)); do
    window="$(xdotool search --onlyvisible --class "$class" 2>/dev/null | head -n 1 || true)"
    [ -z "$window" ] || break
    sleep 1
  done
  if [ -z "$window" ]; then
    echo "[FAIL] No visible window: $name" >&2
    tail -n 30 "$REPORT/$name.log" >&2
    return 1
  fi
  xdotool windowactivate --sync "$window"
  sleep 3
  xwininfo -id "$window" > "$REPORT/$name-window.txt"
  scrot "$REPORT/$name.png"
  echo "[PASS] Visible application window: $name" >&2
}
launch chrome 'google-chrome' google-chrome --no-first-run ${proxy_flags[@]+"${proxy_flags[@]}"}
# 本地 Docker 中 VS Code 沙箱建不了用户命名空间而崩溃；真实 Ubuntu 主机由 apparmor 包的
# vscode 配置放行，沙箱留给真机验收。--verbose 让日志留在 code.log。
# VS Code 新版的窗口类名为 com.microsoft.VSCode，旧版为 Code。
launch code '^(Code|com\.microsoft\.VSCode)$' code --no-sandbox --verbose --disable-workspace-trust ${proxy_flags[@]+"${proxy_flags[@]}"}
