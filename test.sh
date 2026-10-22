#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")" || exit 1
status=0
python3 -m unittest discover -s tests -v || status=1
while IFS= read -r file; do
  bash -n "$file" || status=1
done < <(find . -name '*.sh' -not -path './local/*')
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck agentdesk.sh install.sh tests/*.sh test.sh || status=1
  # 会话文件由 /bin/sh 加载，按 POSIX sh 检查。
  shellcheck -s sh resources/profile.d/agentdesk.sh resources/Xsession.d/* || status=1
else
  echo "Warning: shellcheck unavailable; static analysis skipped" >&2
fi
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' ./*.sh tests/*.sh resources/profile.d/*.sh resources/Xsession.d/*; then
  echo "Error: brace variable names before non-ASCII text" >&2
  status=1
fi
exit "$status"
