#!/usr/bin/env bash
# run-steamcmd.sh — interactive / smoke-test launcher (NOT for production DST).
# For production, use run-dst.sh (detached, ports, restart policy, env file).
#
# Defaults to `steamcmd +login anonymous +quit` if no args given.
#
# Examples:
#   ./run-steamcmd.sh                                       # anonymous smoke test
#   ./run-steamcmd.sh bash                                  # interactive shell
#   ./run-steamcmd.sh steamcmd +login anonymous +quit       # explicit smoke test
#   SAVES_DIR=/path/to/my/saves ./run-steamcmd.sh bash      # custom save dir

set -euo pipefail

IMAGE="${IMAGE:-local/steamcmd:latest}"
SAVES_DIR="${SAVES_DIR:-$(pwd)/saves}"
MODS_DIR="${MODS_DIR:-$(pwd)/mods}"

mkdir -p "$SAVES_DIR" "$MODS_DIR"

# :U → Podman chowns the bind-mount to container UID 1000. Docker ignores :U,
# so on plain Docker drop it and run: chown -R 1000:1000 "$SAVES_DIR" "$MODS_DIR"

# Default command = anonymous smoke test (matches pre-refactor behaviour).
if [ $# -eq 0 ]; then
  set -- steamcmd +login anonymous +quit
fi

exec podman run --rm -it \
  --platform=linux/amd64 \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v "$SAVES_DIR":/home/ubuntu/.klei/DoNotStarveTogether:U \
  -v "$MODS_DIR":/home/ubuntu/user-mods:U \
  "$IMAGE" "$@"
