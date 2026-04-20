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

    exec podman run -d \
      --name "$CONTAINER" \
      --platform=linux/amd64 \
      --restart unless-stopped \
      --stop-timeout "$STOP_TIMEOUT" \
      -p 10999:10999/udp \
      -p 8766:8766/udp \
      -p 27016:27016/udp \
      "${ENV_ARGS[@]}" \
      -v steamcmd-home:/home/ubuntu/.local/share/Steam \
      -v dst-server:/home/ubuntu/dst \
      -v "$SAVES_DIR":/home/ubuntu/.klei/DoNotStarveTogether:U \
      -v "$MODS_DIR":/home/ubuntu/user-mods:U \
      "$IMAGE" dst
    ;;
  *)
    echo "usage: $0 [start|stop|restart|logs]" >&2
    exit 2
    ;;
esac
