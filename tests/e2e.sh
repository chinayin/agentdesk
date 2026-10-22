#!/usr/bin/env bash
# 本地一次性 systemd 容器；不挂载宿主目录、Docker socket 或云凭据。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
DRY_RUN=0
PROXY="${AGENTDESK_E2E_PROXY:-}"
BASE=ubuntu:26.04
ARCH=""
usage() {
  cat <<'EOF'
Usage: bash tests/e2e.sh [--image IMAGE] [--arch amd64|arm64] [--proxy URL] [--keep] [--dry-run]
Run installation, repeat/update, restart and GUI smoke tests in a systemd container.
Requires a local Docker daemon supporting privileged systemd containers.
--image IMAGE Base image, e.g. debian:13 or ubuntu:22.04 (default: ubuntu:26.04).
--arch ARCH   amd64 or arm64 (default: the Docker daemon's architecture).
--proxy URL HTTP(S) proxy reachable from the container; loopback stays direct.
            AGENTDESK_E2E_PROXY sets the same; the flag takes precedence.
--keep      Keep this run's container for debugging (default: remove on exit).
--dry-run   Print the plan without calling Docker or creating files.
Logs/screenshots: local/e2e/<unique-run>/ (no account login or model requests).
Exit: 0 passed/help; 1 usage/test failure; 2 missing prerequisite.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --proxy)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; echo 'Error: --proxy requires a URL' >&2; exit 1; }
      PROXY="$2"; shift ;;
    --image)
      [ "$#" -ge 2 ] && [[ "$2" =~ ^[a-z0-9][a-z0-9./:_-]*$ ]] || { usage >&2; echo 'Error: --image requires an image name' >&2; exit 1; }
      BASE="$2"; shift ;;
    --arch)
      case "${2:-}" in
        amd64|arm64) ARCH="$2"; shift ;;
        *) usage >&2; echo 'Error: --arch must be amd64 or arm64' >&2; exit 1 ;;
      esac ;;
    --keep) KEEP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Build ${BASE} ${ARCH:-native} test image; start isolated privileged systemd container." >&2
  echo 'Copy program files; install; verify; repeat; update; restart; launch GUI apps.' >&2
  if [ -n "$PROXY" ]; then echo 'Pass the proxy to the image build and container environment.' >&2; fi
  echo 'Export logs/screenshots to local/e2e; remove container unless --keep.' >&2
  exit 0
fi
command -v docker >/dev/null || { echo 'Error: Docker is required' >&2; exit 2; }
# 特权容器只允许本地 daemon；DOCKER_CONTEXT 优先于 DOCKER_HOST。
if [ -n "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ]; then
  endpoint="$DOCKER_HOST"
else
  endpoint="$(docker context inspect "${DOCKER_CONTEXT:-$(docker context show)}" --format '{{.Endpoints.docker.Host}}')"
fi
case "$endpoint" in
  unix://*|npipe://*) ;;
  *) echo 'Error: a local Docker Unix socket or named pipe is required; remote endpoints are refused' >&2; exit 2 ;;
esac
docker info >/dev/null || { echo 'Error: Docker daemon is unavailable' >&2; exit 2; }
if [ -z "$ARCH" ]; then
  case "$(docker info --format '{{.Architecture}}')" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo 'Error: unsupported Docker architecture; pass --arch amd64 or --arch arm64' >&2; exit 2 ;;
  esac
fi

# 代理只进入构建参数和一次性容器的环境；产品脚本自行透传给子进程。
proxy_vars=()
if [ -n "$PROXY" ]; then
  for key in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    proxy_vars+=("$key=$PROXY")
  done
  proxy_vars+=("no_proxy=localhost,127.0.0.1,::1" "NO_PROXY=localhost,127.0.0.1,::1"
    "AGENTDESK_E2E_PROXY=$PROXY")
fi
build_args=()
run_args=()
for item in ${proxy_vars[@]+"${proxy_vars[@]}"}; do
  build_args+=(--build-arg "$item")
  run_args+=(-e "$item")
done

mkdir -p "$ROOT/local/e2e"
OUTPUT="$(mktemp -d "$ROOT/local/e2e/run-XXXXXXXX")"
NAME="agentdesk-e2e-${OUTPUT##*/}"
IMAGE="agentdesk-e2e:${BASE//[:\/]/-}-${ARCH}"
CREATED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$CREATED" -eq 1 ]; then
    docker logs "$NAME" > "$OUTPUT/systemd.log" 2>&1 || true
    docker exec "$NAME" journalctl --no-pager -u xrdp -u xrdp-sesman > "$OUTPUT/xrdp.log" 2>&1 || true
    docker cp "$NAME:/var/log/agentdesk-e2e/." "$OUTPUT/" >/dev/null 2>&1 || true
    if [ "$KEEP" -eq 1 ]; then
      echo "Container retained: $NAME" >&2
    else
      docker rm -f "$NAME" >/dev/null || status=1
    fi
  fi
  echo "Test artifacts: $OUTPUT" >&2
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# stdin Dockerfile：构建器收不到 local/、.aws/ 或其他工作目录内容。
docker build --platform "linux/$ARCH" --build-arg "BASE_IMAGE=$BASE" ${build_args[@]+"${build_args[@]}"} -t "$IMAGE" - \
  < "$ROOT/tests/e2e.Dockerfile" 2>&1 | tee "$OUTPUT/build.log"
docker create --name "$NAME" --platform "linux/$ARCH" --privileged --cgroupns private \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp --shm-size 1g \
  ${run_args[@]+"${run_args[@]}"} "$IMAGE" >/dev/null
CREATED=1
docker start "$NAME" >/dev/null
wait_systemd() {
  local attempt state
  for ((attempt=0; attempt<60; attempt++)); do
    state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
      running|degraded)
        if ! docker exec "$NAME" systemctl is-active --quiet systemd-journald.service ||
           ! docker exec "$NAME" systemctl is-active --quiet dbus.service; then
          echo "Error: journald/DBus is unavailable; use a Docker runtime with working systemd support for ${ARCH}." >&2
          return 2
        fi
        return 0 ;;
    esac
    sleep 1
  done
  echo 'Error: systemd did not become ready' >&2
  return 1
}
wait_systemd
docker exec "$NAME" mkdir -p /opt/agentdesk
# 只复制程序结构（与 install_program 一致）和容器内测试脚本，不带 local/ 等目录。
COPYFILE_DISABLE=1 tar -C "$ROOT" -cf - agentdesk.sh install.sh mise.toml resources \
  tests/e2e-container.sh tests/e2e-gui.sh | docker cp - "$NAME:/opt/agentdesk"
docker exec "$NAME" timeout 3600 bash /opt/agentdesk/tests/e2e-container.sh install 2>&1 | tee "$OUTPUT/install.log"
docker restart "$NAME" >/dev/null
wait_systemd
docker exec "$NAME" timeout 900 bash /opt/agentdesk/tests/e2e-container.sh check 2>&1 | tee "$OUTPUT/check.log"
echo '[PASS] Docker installation E2E and GUI smoke tests' >&2
