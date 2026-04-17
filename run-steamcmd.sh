#!/usr/bin/env bash
# Compose-free launcher: runs the same container as docker-compose.yml via plain `podman run`.
# Override SAVES_DIR to point at any host folder you want mapped to DST saves.
#   SAVES_DIR=/path/to/my/saves ./run-steamcmd.sh
#   SAVES_DIR=./saves ./run-steamcmd.sh bash                # interactive shell
#   ./run-steamcmd.sh steamcmd +login anonymous +quit       # anonymous smoke test

set -euo pipefail

IMAGE="${IMAGE:-local/steamcmd:latest}"
SAVES_DIR="${SAVES_DIR:-$(pwd)/saves}"
MODS_DIR="${MODS_DIR:-$(pwd)/mods}"

mkdir -p "$SAVES_DIR" "$MODS_DIR"

# Mount flag `:U` makes Podman chown the bind-mount to the container's UID (1000).
# This matters on both Mac (libkrun userns) and Linux (rootless subuid mapping).
# If using plain Docker instead of Podman, drop `:U` and run: chown -R 1000:1000 "$SAVES_DIR"

exec podman run --rm -it \
  --platform=linux/amd64 \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v "$SAVES_DIR":/home/ubuntu/.klei:U \
  -v "$MODS_DIR":/home/ubuntu/dst-mods:U \
  "$IMAGE" "$@"
