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
# Shards: DST clusters are two-shard by default — Master (overworld) + Caves
# (underground). Both are launched as separate DST processes from the same
# cluster dir. Each has its own stdin FIFO (fd 3 for Master, fd 4 for Caves).
#
# Save backup trigger: inotifywait on BOTH Master/save and Caves/save
# (close_write, recursive), 10-second debounce across both.
#
# Graceful shutdown: on SIGTERM/SIGINT, write `c_save()` then `c_shutdown(true)`
# into both FIFOs, wait for both processes to exit, final R2 push.

set -Eeuo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-qkation-cooperative}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"

STEAM_HOME="${STEAM_HOME:-$HOME/.local/share/Steam}"
DST_DIR="${DST_DIR:-$HOME/dst}"
KLEI_DIR="${KLEI_DIR:-$HOME/.klei}"
CLUSTER_DIR="$KLEI_DIR/DoNotStarveTogether/$CLUSTER_NAME"
MASTER_SAVE_DIR="$CLUSTER_DIR/Master/save"
CAVES_SAVE_DIR="$CLUSTER_DIR/Caves/save"
USER_MODS_SETUP="$HOME/user-mods/dedicated_server_mods_setup.lua"
DST_MODS_SETUP="$DST_DIR/mods/dedicated_server_mods_setup.lua"
MASTER_FIFO=/tmp/dst.master.stdin
CAVES_FIFO=/tmp/dst.caves.stdin
DST_BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"

INOTIFY_PID=""
MASTER_PID=""
CAVES_PID=""

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
  # rclone probes the bucket on first use (HEAD/PUT at the bucket root) to
  # check existence / auto-create. R2 API tokens with Object R/W scope
  # don't have bucket-level CreateBucket perms, so the probe 403s with a
  # bare <Code>AccessDenied</Code> body and the actual upload never runs.
  # Skip the probe — we know the bucket exists, the user created it.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
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

# DST needs cluster.ini + BOTH Master/server.ini and Caves/server.ini to launch
# a two-shard cluster without generating a new world. We treat anything less as
# "not ready" and refuse to auto-generate — the admin panel either uploads a
# zip or runs the template wizard (which writes both shards' ini files).
cluster_ready() {
  [ -f "$CLUSTER_DIR/cluster.ini" ] && \
  [ -f "$CLUSTER_DIR/Master/server.ini" ] && \
  [ -f "$CLUSTER_DIR/Caves/server.ini" ]
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
  log "required files once provisioned:"
  log "  cluster.ini + Master/server.ini + Caves/server.ini"
  log "  (two-shard cluster — both Master and Caves must be present)"
  log "============================"

  # Event-driven wait: inotifywait unblocks the moment the admin panel writes
  # any file under $KLEI_DIR/DoNotStarveTogether/, so DST starts within ~100ms
  # of the files landing instead of up-to-5s-later under the old poll.
  # -t 60 gives a fallback wake-up so we still emit a heartbeat even if the
  # admin panel takes an hour to provision, and so we don't hang forever if
  # the kernel drops events on a bind-mounted volume.
  # inotify-tools is already installed (Dockerfile line 17) and used by the
  # save-backup watcher — no new dependencies.
  mkdir -p "$KLEI_DIR/DoNotStarveTogether"
  local start_ts now last_beat
  start_ts=$(date +%s); last_beat=$start_ts
  while ! cluster_ready; do
    inotifywait -qq -t 60 -e create,close_write,moved_to \
      -r "$KLEI_DIR/DoNotStarveTogether" 2>/dev/null || true
    cluster_ready && break
    now=$(date +%s)
    if (( now - last_beat >= 60 )); then
      log "still waiting for cluster at $CLUSTER_DIR (elapsed $((now - start_ts))s)"
      last_beat=$now
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
  # Watches both shards' save dirs; a write to either one schedules a single
  # debounced backup of the whole cluster (Master + Caves are tarred together).
  mkdir -p "$MASTER_SAVE_DIR" "$CAVES_SAVE_DIR"
  (
    timer_pid=""
    inotifywait -m -e close_write -r "$MASTER_SAVE_DIR" "$CAVES_SAVE_DIR" 2>/dev/null \
      | while read -r _ _ _; do
          if [ -n "$timer_pid" ] && kill -0 "$timer_pid" 2>/dev/null; then
            kill "$timer_pid" 2>/dev/null || true
          fi
          ( sleep 10 && do_backup auto ) &
          timer_pid=$!
        done
  ) &
  INOTIFY_PID=$!
  log "save watcher started (PID $INOTIFY_PID), debounce 10s, watching Master + Caves"
}

# Send c_save() + c_shutdown(true) to a single shard by writing into its FIFO.
# $1 = shard label (for logging)
# $2 = fd number to echo into (3 = master, 4 = caves)
shard_soft_shutdown() {
  local label="$1" fd="$2"
  log "  → $label: c_save()"
  eval "echo 'c_save()' >&$fd"   || true
  sleep 2
  log "  → $label: c_shutdown(true)"
  eval "echo 'c_shutdown(true)' >&$fd" || true
}

# Wait up to $1 seconds for a PID to exit, escalating TERM then KILL if not.
wait_or_kill() {
  local label="$1" pid="$2" deadline="$3"
  [ -n "$pid" ] || return 0
  for _ in $(seq 1 "$deadline"); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "$label (PID $pid) didn't exit within ${deadline}s — sending TERM"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

graceful_stop() {
  log "signal received — initiating graceful shutdown of both shards"
  shard_soft_shutdown Master 3
  shard_soft_shutdown Caves  4
  # Give both shards up to 60s to flush saves and exit on their own.
  wait_or_kill Master "${MASTER_PID:-}" 60
  wait_or_kill Caves  "${CAVES_PID:-}"  60
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

  # FIFO per shard so we can route c_save/c_shutdown to each independently.
  # Each write end is held open in this shell (fds 3 and 4) — without a held
  # writer, the server's read end hits EOF immediately on first line.
  #
  # NOTE: open in read/write mode (`<>`) rather than write-only (`>`). On Linux
  # `open(fifo, O_WRONLY)` blocks until a reader exists, but we haven't launched
  # the DST binary (the reader) yet — that's a self-deadlock. `open(fifo, O_RDWR)`
  # does not block and still lets us write; bash's `echo 'c_save()' >&3` works
  # the same way either way because the fd is still writable.
  rm -f "$MASTER_FIFO" "$CAVES_FIFO"
  mkfifo "$MASTER_FIFO" "$CAVES_FIFO"
  exec 3<> "$MASTER_FIFO"
  exec 4<> "$CAVES_FIFO"

  start_inotify_watcher
  trap graceful_stop TERM INT

  cd "$DST_DIR/bin64"

  log "launching DST shard=Master (cluster=$CLUSTER_NAME)"
  ./dontstarve_dedicated_server_nullrenderer_x64 \
    -persistent_storage_root "$KLEI_DIR" \
    -conf_dir DoNotStarveTogether \
    -cluster "$CLUSTER_NAME" \
    -shard Master \
    < "$MASTER_FIFO" &
  MASTER_PID=$!
  log "Master shard started (PID $MASTER_PID)"

  log "launching DST shard=Caves (cluster=$CLUSTER_NAME)"
  ./dontstarve_dedicated_server_nullrenderer_x64 \
    -persistent_storage_root "$KLEI_DIR" \
    -conf_dir DoNotStarveTogether \
    -cluster "$CLUSTER_NAME" \
    -shard Caves \
    < "$CAVES_FIFO" &
  CAVES_PID=$!
  log "Caves shard started (PID $CAVES_PID)"

  # Block until EITHER shard exits. The master is authoritative: if it leaves,
  # we tear the whole cluster down. If caves crash on their own, master will
  # typically survive — in that case we escalate to a full shutdown anyway so
  # `podman restart` can bring up a known-good state.
  wait -n "$MASTER_PID" "$CAVES_PID" || true
  if ! kill -0 "$MASTER_PID" 2>/dev/null; then
    log "Master shard exited — shutting Caves down"
    shard_soft_shutdown Caves 4
    wait_or_kill Caves "$CAVES_PID" 60
  elif ! kill -0 "$CAVES_PID" 2>/dev/null; then
    log "Caves shard exited — shutting Master down"
    shard_soft_shutdown Master 3
    wait_or_kill Master "$MASTER_PID" 60
  fi

  # Collect exit codes. Whichever shard exited first is the "cause"; prefer
  # its non-zero rc over the one we sent a graceful_shutdown to.
  wait "$MASTER_PID" 2>/dev/null; MASTER_RC=$?
  wait "$CAVES_PID"  2>/dev/null; CAVES_RC=$?
  log "Master exited rc=$MASTER_RC, Caves exited rc=$CAVES_RC"

  [ -n "${INOTIFY_PID:-}" ] && kill "$INOTIFY_PID" 2>/dev/null || true
  # Best-effort crash-path backup.
  do_backup exit || true
  if [ "$MASTER_RC" -ne 0 ]; then exit "$MASTER_RC"; fi
  exit "$CAVES_RC"
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
