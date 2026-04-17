#!/usr/bin/env bash
# The base image sets USER steam (UID 1000). We just exec the command.
# Bind-mount UID mismatch: if you bind-mount a host directory onto /home/steam/.klei,
# the host directory must be owned by UID 1000, or DST save writes will fail.
# Fix on the host with:  chown -R 1000:1000 ./saves
set -euo pipefail
exec "$@"
