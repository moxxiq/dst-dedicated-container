#!/usr/bin/env bash
# entrypoint.sh — orchestrator for SteamCMD / DST dedicated server.
#
# Dispatch (first argument):
#   dst           → full DST lifecycle (update → mods → restore-or-wait → launch → backup → graceful stop)
#   steamcmd ...  → pass-through (ad-hoc SteamCMD invocation)
#   bash | sh     → pass-through (interactive debug)
#   <anything>    → pass-through (exec as-is)
#
# Fresh-boot policy (2026-04-20): if the local cluster dir is empty AND there is
# no R2 backup, the entrypoint WAITS (polls every 5 s, heartbeat every 60 s)
# for the admin panel to either upload a cluster zip or run the template wizard.
# It does NOT auto-generate a fresh world. This avoids shipping a random world
# under the user's chosen cluster name when their intent is to pick/create one.
#
# Environment:
#   CLUSTER_NAME            Cluster folder name.                        Default: qkation-cooperative
#   CLUSTER_TOKEN           If set and cluster_token.txt is empty, write it.
#   AUTO_UPDATE             "1" to run app_update 343050 on every start. Default: 1
#   R2_ACCOUNT_ID           Cloudflare R2 account ID.      REQUIRED — container exits if missing.
#   R2_BUCKET               R2 bucket name.                REQUIRED.
#   R2_ACCESS_KEY_ID        R2 API key.                    REQUIRED.
#   R2_SECRET_ACCESS_KEY    R2 API secret.                 REQUIRED.
#
# R2 is not optional: saves, restores, and the first-boot wait-for-cluster path
# all depend on it. If you really want to run without offsite backup, fork and
# strip the r2_require / do_backup / do_r2_restore_once calls yourself.
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

# Fail fast before doing anything expensive (app_update, tar, etc.) if R2
# isn't configured. Called once from launch_dst. Emits a list of which
# specific vars are missing so the operator can fix the .env in one pass.
r2_require() {
  if r2_configured; then
    return 0
  fi
  log "ERROR: Cloudflare R2 is required but not fully configured."
  local v
  for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    if [ -z "${!v:-}" ]; then
      log "  missing: $v"
    fi
  done
  log "set all four in .env (see .env.example) and restart the container."
  exit 1
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

# DST needs at least cluster.ini + Master/server.ini to launch without generating
# a new world. We treat anything less as "not ready" and refuse to auto-generate —
# the admin panel (Phase 3) either uploads a zip or runs the template wizard.
cluster_ready() {
  [ -f "$CLUSTER_DIR/cluster.ini" ] && [ -f "$CLUSTER_DIR/Master/server.ini" ]
}

do_r2_restore_once() {
  # R2 is guaranteed configured by launch_dst → r2_require. This function is
  # also callable from debug shells; guard left in for that edge case.
  r2_configured || return 1
  log "cluster missing locally — attempting R2 restore"
  r2_rclone_env
  mkdir -p "$KLEI_DIR/DoNotStarveTogether"
  local tmp=/tmp/restore.tar.gz
  if rclone copyto "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/latest.tar.gz" "$tmp" 2>/dev/null; then
    tar xzf "$tmp" -C "$KLEI_DIR/DoNotStarveTogether/"
    rm -f "$tmp"
    log "restored cluster from R2 (latest.tar.gz)"
    return 0
  fi
  rm -f "$tmp"
  log "no R2 backup at clusters/$CLUSTER_NAME/latest.tar.gz"
  return 1
}

# Policy (2026-04-20, per user): do NOT auto-generate a fresh world when both
# local saves and R2 are empty. Wait indefinitely for the admin panel to either
#   (a) drop in an uploaded cluster zip (park-and-pick), or
#   (b) run the template-server wizard to populate saves/<cluster>/.
# Container stays alive with clear status output; `podman logs -f` shows progress.
do_wait_for_cluster() {
  if cluster_ready; then
    log "cluster '$CLUSTER_NAME' present locally — skipping R2/wait"
    return 0
  fi

  do_r2_restore_once || true
  cluster_ready && return 0

  log "=== WAITING FOR CLUSTER ==="
  log "cluster '$CLUSTER_NAME' not found locally ($CLUSTER_DIR)"
  log "and no backup in R2 at clusters/$CLUSTER_NAME/latest.tar.gz"
  log ""
  log "container will wait until the admin panel provisions a cluster:"
  log "  - upload a cluster zip (park-and-pick), OR"
  log "  - run the template-server wizard"
  log ""
  log "required files once provisioned: cluster.ini + Master/server.ini"
  log "============================"

  local wait_ticks=0
  while ! cluster_ready; do
    sleep 5
    wait_ticks=$((wait_ticks + 1))
    # Heartbeat log every 60 s.
    if [ $((wait_ticks % 12)) -eq 0 ]; then
      log "still waiting for cluster at $CLUSTER_DIR (elapsed $((wait_ticks * 5))s)"
    fi
  done
  log "cluster detected — proceeding with launch"
}

do_backup() {
  local tag="${1:-auto}"
  # R2 is guaranteed configured by r2_require at launch. If an operator calls
  # do_backup by hand from a debug shell with a stripped env, fall through to
  # rclone which will error loudly — that's acceptable for an ad-hoc path.
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
  # R2 presence is enforced by r2_require at launch — no soft-skip here.
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
  # R2 is mandatory. Fail before doing any work if the operator forgot a key.
  r2_require

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
  do_wait_for_cluster
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
