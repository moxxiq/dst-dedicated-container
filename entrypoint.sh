#!/usr/bin/env bash
# entrypoint.sh — orchestrator for SteamCMD / DST dedicated server.
#
# Dispatch (first argument):
#   dst           → full DST lifecycle (update → mods → restore → launch → backup → graceful stop)
#   steamcmd ...  → pass-through (ad-hoc SteamCMD invocation)
#   bash | sh     → pass-through (interactive debug)
#   <anything>    → pass-through (exec as-is)
#
# Environment (all optional unless noted):
#   CLUSTER_NAME            Cluster folder name.                        Default: qkation-cooperative
#   CLUSTER_TOKEN           If set and cluster_token.txt is empty, write it.
#   AUTO_UPDATE             "1" to run app_update 343050 on every start. Default: 1
#   R2_ACCOUNT_ID           Cloudflare R2 account ID. Unset → R2 features off.
#   R2_BUCKET               R2 bucket name.
#   R2_ACCESS_KEY_ID        R2 API key.
#   R2_SECRET_ACCESS_KEY    R2 API secret.
#
# Save backup trigger: inotifywait on the Master save dir (close_write, recursive),
# 10-second debounce (kill+restart timer on each batch of writes).
#
# Graceful shutdown: on SIGTERM/SIGINT, write `c_save()` then `c_shutdown(true)` to
# the server's stdin via a held-open FIFO (fd 3), wait for DST to exit, final R2 push.

set -Eeuo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-qkation-cooperative}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"

STEAM_HOME="${STEAM_HOME:-$HOME/.local/share/Steam}"
DST_DIR="${DST_DIR:-$HOME/dst}"
KLEI_DIR="${KLEI_DIR:-$HOME/.klei}"
CLUSTER_DIR="$KLEI_DIR/DoNotStarveTogether/$CLUSTER_NAME"
SAVE_SESSION_DIR="$CLUSTER_DIR/Master/save"
USER_MODS_SETUP="$HOME/user-mods/dedicated_server_mods_setup.lua"
DST_MODS_SETUP="$DST_DIR/mods/dedicated_server_mods_setup.lua"
FIFO=/tmp/dst.stdin
DST_BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"

INOTIFY_PID=""
DST_PID=""

log() { printf '[entrypoint %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

r2_configured() {
  [ -n "${R2_ACCOUNT_ID:-}" ] && [ -n "${R2_BUCKET:-}" ] && \
  [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ]
}

r2_rclone_env() {
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_REGION=auto
}

do_app_update() {
  log "steamcmd +app_update 343050 validate"
  steamcmd \
    +force_install_dir "$DST_DIR" \
    +login anonymous \
    +app_update 343050 validate \
    +quit
}

do_mods_sync() {
  mkdir -p "$DST_DIR/mods"
  if [ -f "$USER_MODS_SETUP" ]; then
    install -m 0644 "$USER_MODS_SETUP" "$DST_MODS_SETUP"
    log "synced dedicated_server_mods_setup.lua into DST install"
  else
    log "no user mods setup found at $USER_MODS_SETUP (ok — no workshop mods)"
  fi
}

do_cluster_token() {
  local tokfile="$CLUSTER_DIR/cluster_token.txt"
  if [ -s "$tokfile" ]; then
    return 0
  fi
  if [ -n "${CLUSTER_TOKEN:-}" ]; then
    mkdir -p "$CLUSTER_DIR"
    printf '%s' "$CLUSTER_TOKEN" > "$tokfile"
    chmod 0600 "$tokfile"
    log "wrote cluster_token.txt from \$CLUSTER_TOKEN"
  else
    log "WARNING: no cluster_token.txt and no \$CLUSTER_TOKEN — DST will not accept players"
  fi
}

do_restore_if_empty() {
  if [ -d "$CLUSTER_DIR" ] && [ -n "$(ls -A "$CLUSTER_DIR" 2>/dev/null)" ]; then
    log "cluster dir populated — skipping R2 restore"
    return 0
  fi
  if ! r2_configured; then
    log "cluster dir empty, R2 not configured — fresh world will be generated"
    return 0
  fi
  log "cluster dir empty — attempting R2 restore"
  r2_rclone_env
  mkdir -p "$KLEI_DIR/DoNotStarveTogether"
  local tmp=/tmp/restore.tar.gz
  if rclone copyto "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/latest.tar.gz" "$tmp" 2>/dev/null; then
    tar xzf "$tmp" -C "$KLEI_DIR/DoNotStarveTogether/"
    rm -f "$tmp"
    log "restored cluster from R2 (latest.tar.gz)"
  else
    log "no R2 backup at clusters/$CLUSTER_NAME/latest.tar.gz — fresh world"
  fi
}

do_backup() {
  local tag="${1:-auto}"
  if ! r2_configured; then
    return 0
  fi
  if [ ! -d "$CLUSTER_DIR" ]; then
    log "no cluster dir yet, skipping backup"
    return 0
  fi
  r2_rclone_env
  local tmp="/tmp/backup-$$-$(date +%s).tar.gz"
  if ! tar czf "$tmp" -C "$KLEI_DIR/DoNotStarveTogether" "$CLUSTER_NAME"; then
    log "tar failed for backup (tag=$tag)"
    rm -f "$tmp"
    return 1
  fi
  rclone copyto "$tmp" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/latest.tar.gz" --quiet \
    || log "R2 latest upload failed"
  local ts; ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
  rclone copyto "$tmp" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history/${ts}-${tag}.tar.gz" --quiet \
    || log "R2 history upload failed"
  rm -f "$tmp"
  log "backup pushed to R2 (tag=$tag)"
}

# Export so the subshell running inotifywait can call it.
export -f do_backup r2_configured r2_rclone_env log
export CLUSTER_NAME CLUSTER_DIR KLEI_DIR R2_ACCOUNT_ID R2_BUCKET \
       R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY

start_inotify_watcher() {
  if ! r2_configured; then
    log "R2 not configured — save watcher disabled"
    return 0
  fi
  mkdir -p "$SAVE_SESSION_DIR"
  (
    timer_pid=""
    inotifywait -m -e close_write -r "$SAVE_SESSION_DIR" 2>/dev/null \
      | while read -r _ _ _; do
          if [ -n "$timer_pid" ] && kill -0 "$timer_pid" 2>/dev/null; then
            kill "$timer_pid" 2>/dev/null || true
          fi
          ( sleep 10 && do_backup auto ) &
          timer_pid=$!
        done
  ) &
  INOTIFY_PID=$!
  log "save watcher started (PID $INOTIFY_PID), debounce 10s"
}

graceful_stop() {
  log "signal received — initiating graceful shutdown"
  # Fire `c_save()` then `c_shutdown(true)` into DST's stdin FIFO.
  if [ -w "$FIFO" ] || [ -p "$FIFO" ]; then
    echo 'c_save()'         >&3 || true
    sleep 3
    echo 'c_shutdown(true)' >&3 || true
  fi
  if [ -n "${DST_PID:-}" ]; then
    for _ in $(seq 1 60); do
      kill -0 "$DST_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$DST_PID" 2>/dev/null; then
      log "DST didn't exit within 60s — sending TERM"
      kill -TERM "$DST_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$DST_PID" 2>/dev/null || true
    fi
  fi
  [ -n "${INOTIFY_PID:-}" ] && kill "$INOTIFY_PID" 2>/dev/null || true
  do_backup shutdown || true
  exit 0
}

launch_dst() {
  if [ ! -x "$DST_BIN" ]; then
    log "DST binary missing — forcing first-time app_update"
    do_app_update
  elif [ "$AUTO_UPDATE" = "1" ]; then
    do_app_update
  else
    log "AUTO_UPDATE=0 — skipping app_update"
  fi

  if [ ! -x "$DST_BIN" ]; then
    log "ERROR: DST binary still not at $DST_BIN after update"
    exit 1
  fi

  do_mods_sync
  do_restore_if_empty
  do_cluster_token

  rm -f "$FIFO"
  mkfifo "$FIFO"
  # Open the write end in this shell and keep it open (fd 3).
  # Without a writer held open, the server's read end would hit EOF immediately.
  exec 3> "$FIFO"

  start_inotify_watcher
  trap graceful_stop TERM INT

  log "launching DST (cluster=$CLUSTER_NAME, shard=Master)"
  cd "$DST_DIR/bin64"
  ./dontstarve_dedicated_server_nullrenderer_x64 \
    -persistent_storage_root "$KLEI_DIR" \
    -conf_dir DoNotStarveTogether \
    -cluster "$CLUSTER_NAME" \
    -shard Master \
    < "$FIFO" &
  DST_PID=$!
  log "DST started (PID $DST_PID)"

  wait "$DST_PID" || DST_RC=$?
  DST_RC="${DST_RC:-0}"
  log "DST exited with code $DST_RC"

  [ -n "${INOTIFY_PID:-}" ] && kill "$INOTIFY_PID" 2>/dev/null || true
  # Best-effort crash-path backup.
  do_backup exit || true
  exit "$DST_RC"
}

cmd="${1:-dst}"
case "$cmd" in
  dst)
    launch_dst
    ;;
  *)
    # Pass-through: `steamcmd +...`, `bash`, etc. Keeps the image useful for debugging.
    exec "$@"
    ;;
esac
