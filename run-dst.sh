#!/usr/bin/env bash
# run-dst.sh — production DST launcher (detached, restart policy, ports, env file).
#
# Usage:
#   ./run-dst.sh              # start the container
#   ./run-dst.sh logs         # follow logs of the running DST container
#   ./run-dst.sh stop         # graceful stop (entrypoint's SIGTERM trap → c_save → c_shutdown → R2 push)
#
# Env overrides:
#   IMAGE=local/steamcmd:latest   image tag
#   SAVES_DIR=$(pwd)/saves        host save dir
#   MODS_DIR=$(pwd)/mods          host mods dir
#   ENV_FILE=$(pwd)/.env          env file with CLUSTER_TOKEN, R2_*
#   CONTAINER=dst                 container name

set -euo pipefail

IMAGE="${IMAGE:-local/steamcmd:latest}"
SAVES_DIR="${SAVES_DIR:-$(pwd)/saves}"
MODS_DIR="${MODS_DIR:-$(pwd)/mods}"
ENV_FILE="${ENV_FILE:-$(pwd)/.env}"
CONTAINER="${CONTAINER:-dst}"

# Graceful-stop: `podman stop` sends SIGTERM, then SIGKILL after --time.
# entrypoint.sh's trap needs up to ~60s to wait for DST's c_shutdown to finalize saves.
STOP_TIMEOUT="${STOP_TIMEOUT:-90}"

case "${1:-start}" in
  logs)
    exec podman logs -f "$CONTAINER"
    ;;
  stop)
    exec podman stop -t "$STOP_TIMEOUT" "$CONTAINER"
    ;;
  restart)
    podman stop -t "$STOP_TIMEOUT" "$CONTAINER" 2>/dev/null || true
    exec "$0" start
    ;;
  start|'')
    mkdir -p "$SAVES_DIR" "$MODS_DIR"

    ENV_ARGS=()
    if [ -f "$ENV_FILE" ]; then
      ENV_ARGS+=(--env-file "$ENV_FILE")
    else
      echo "[run-dst] warning: $ENV_FILE not found — running without CLUSTER_TOKEN/R2 vars" >&2
    fi

    # Remove any prior container with this name.
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true

    # --userns=keep-id:uid=1000,gid=1000 maps the host invoker (rootless dst,
    # UID 1001) to the container's ubuntu user (UID 1000). The admin panel
    # container also runs as host UID 1001 (rootless root maps there), so
    # both containers see bind-mounted files as the *same* UID and the
    # parked-cluster activate dance no longer creates files DST can't write.
    # Without this the default subuid mapping puts container ubuntu at host
    # UID 166535, while admin writes as host UID 1001 - permission mismatch
    # on every file admin produces inside saves/.
    exec podman run -d \
      --name "$CONTAINER" \
      --platform=linux/amd64 \
      --restart unless-stopped \
      --stop-timeout "$STOP_TIMEOUT" \
      --userns=keep-id:uid=1000,gid=1000 \
      -p 10999:10999/udp \
      -p 10998:10998/udp \
      -p 8766:8766/udp \
      -p 8768:8768/udp \
      -p 27016:27016/udp \
      -p 27018:27018/udp \
      "${ENV_ARGS[@]}" \
      -v steamcmd-home:/home/ubuntu/.local/share/Steam:U \
      -v dst-server:/home/ubuntu/dst:U \
      -v "$SAVES_DIR":/home/ubuntu/.klei/DoNotStarveTogether \
      -v "$MODS_DIR":/home/ubuntu/user-mods \
      "$IMAGE" dst
    ;;
  *)
    echo "usage: $0 [start|stop|restart|logs]" >&2
    exit 2
    ;;
esac
