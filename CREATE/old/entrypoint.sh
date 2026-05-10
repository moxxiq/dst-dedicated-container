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
# Save backup trigger: 60s poll loop that c_evals into the master shard's
# stdin FIFO and parses TheWorld.state.cycles + #AllPlayers from server_log.
# Backup fires ONLY on day rollover or when the last player leaves. No
# shutdown/exit/crash backups - those produced near-duplicate archives.
# Operator can hit "Backup to R2 now" in the admin UI for an ad-hoc snapshot.
# Format: zip (history-only, no latest pointer; admin scans the history/
# directory for the lexicographically newest entry). Sidecar
# <name>.mods.json next to each zip lists workshop IDs for fast UI preview.
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

POLLER_PID=""
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

  # Sideload: copy every directory under user-mods/user-mods/ into the DST
  # install's mods/ tree. Admin's /mods/upload endpoint extracts uploads
  # there. Each subdir becomes one mod folder visible to DST exactly the
  # same way workshop downloads end up under mods/workshop-NNNN/.
  local sideload_root="$HOME/user-mods/user-mods"
  if [ -d "$sideload_root" ]; then
    local count=0
    for d in "$sideload_root"/*/; do
      [ -d "$d" ] || continue
      local name; name="$(basename "$d")"
      [ "$name" = "." ] || [ "$name" = ".." ] && continue
      cp -r "$d" "$DST_DIR/mods/$name"
      count=$((count + 1))
    done
    if (( count > 0 )); then
      log "synced $count sideloaded mod folder(s) into DST install"
    fi
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
  #
  # No `latest` pointer is maintained any more — we scan the history dir for
  # the lexicographically newest entry. Filenames are `day-NNNN-<utc-ts>-<tag>`
  # so lexicographic sort = in-game-time sort = wall-clock sort, all the same.
  # Both `.zip` (current) and `.tar.gz` (legacy) are recognised.
  r2_configured || return 1
  log "cluster missing locally — attempting R2 restore (newest history entry)"
  r2_rclone_env
  mkdir -p "$KLEI_DIR/DoNotStarveTogether"
  local hist_dir="r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history"
  local newest
  newest=$(rclone lsf --files-only "$hist_dir" 2>/dev/null \
           | grep -E '\.(zip|tar\.gz)$' | sort | tail -1)
  if [[ -z "$newest" ]]; then
    log "no R2 backup found under $hist_dir"
    return 1
  fi
  local ext="${newest##*.}"        # "zip" or "gz"
  local tmp="/tmp/restore.${newest##*-}"   # any unique suffix - we'll dispatch on extension
  tmp="/tmp/restore-$$.${newest##*.}"
  if [[ "$newest" == *.tar.gz ]]; then tmp="/tmp/restore-$$.tar.gz"; ext="tar.gz"; fi
  if ! rclone copyto "$hist_dir/$newest" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log "rclone copyto failed for $hist_dir/$newest"
    return 1
  fi
  if [[ "$ext" == "zip" ]]; then
    if ! command -v unzip >/dev/null; then
      rm -f "$tmp"
      log "unzip not available in image - rebuild after pulling latest Dockerfile"
      return 1
    fi
    unzip -q "$tmp" -d "$KLEI_DIR/DoNotStarveTogether/"
  else
    tar xzf "$tmp" -C "$KLEI_DIR/DoNotStarveTogether/"
  fi
  rm -f "$tmp"
  log "restored cluster from R2 ($newest)"
  return 0
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

# Global state shared with the poll watcher. Updated by poll_step on each
# successful c_eval round-trip; consumed by do_backup for filename composition.
LAST_CYCLES=-1
LAST_PLAYERS=-1

# Compose the R2 history filename so day-prefixed entries sort lexicographically
# in cycle order, while ad-hoc tags (manual, shutdown) keep the iso-timestamp
# leading. Both shapes still embed the trigger tag for debugging.
backup_history_name() {
  local tag="$1" ts="$2"
  if [[ $LAST_CYCLES -ge 0 ]]; then
    printf 'day-%04d-%s-%s.zip' "$LAST_CYCLES" "$ts" "$tag"
  else
    printf '%s-%s.zip' "$ts" "$tag"
  fi
}

# Build a small JSON sidecar listing the workshop IDs and per-shard
# modoverrides bodies so the admin UI can preview what mods this backup
# carried without downloading the full archive. Best-effort: missing files
# turn into empty fields rather than failing the whole backup.
write_mods_sidecar() {
  local out="$1"
  local setup_file="$HOME/user-mods/dedicated_server_mods_setup.lua"
  local master_mods="$CLUSTER_DIR/Master/modoverrides.lua"
  local caves_mods="$CLUSTER_DIR/Caves/modoverrides.lua"

  # Pull `workshop-NNNN` IDs out of every file we can find.
  local ids
  ids=$(grep -hoE 'workshop-[0-9]+' "$setup_file" "$master_mods" "$caves_mods" 2>/dev/null \
        | sort -u | sed 's/workshop-//')

  # Render JSON without jq dependency (we use it elsewhere, but this
  # sidecar must succeed even if jq is somehow missing).
  {
    printf '{\n'
    printf '  "cluster_name": "%s",\n' "$CLUSTER_NAME"
    printf '  "captured_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "in_game_day": %d,\n' "${LAST_CYCLES:-0}"
    printf '  "workshop_ids": ['
    local first=1
    for id in $ids; do
      if (( first )); then first=0; else printf ', '; fi
      printf '"%s"' "$id"
    done
    printf ']\n}\n'
  } > "$out"
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
  if ! command -v zip >/dev/null; then
    log "zip binary not found — rebuild image after pulling latest Dockerfile"
    return 1
  fi
  r2_rclone_env
  local ts; ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
  local hist; hist="$(backup_history_name "$tag" "$ts")"
  local tmp="/tmp/backup-$$-${ts}.zip"
  local meta="${tmp%.zip}.mods.json"
  # zip wants to be cd'd into the parent so paths in the archive start with
  # CLUSTER_NAME/. -q suppresses per-file output, -r recurses, -X strips
  # extra-attributes that vary by host.
  if ! ( cd "$KLEI_DIR/DoNotStarveTogether" && zip -qrX "$tmp" "$CLUSTER_NAME" ); then
    log "zip failed for backup (tag=$tag)"
    rm -f "$tmp"
    return 1
  fi
  write_mods_sidecar "$meta" || true

  # Single uploaded artifact per backup. No `latest.zip` pointer is
  # maintained any more — list-newest scans the history dir directly.
  rclone copyto "$tmp" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history/${hist}" --quiet \
    || log "R2 history upload failed"
  if [[ -s "$meta" ]]; then
    rclone copyto "$meta" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history/${hist%.zip}.mods.json" --quiet \
      || log "R2 sidecar upload failed (non-fatal)"
  fi
  rm -f "$tmp" "$meta"
  log "backup pushed to R2 (tag=$tag day=${LAST_CYCLES} → $hist)"
}

# Export so subshells can call into these functions.
export -f do_backup r2_configured r2_rclone_env log backup_history_name
export CLUSTER_NAME CLUSTER_DIR KLEI_DIR R2_ACCOUNT_ID R2_BUCKET \
       R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY LAST_CYCLES LAST_PLAYERS

# Send a c_eval to the master shard via FIFO 3, then read the freshest
# ADMINBPOLL: line out of master's server_log. Returns "cycles:players" on
# stdout, or non-zero if the round-trip didn't complete (DST not ready, FIFO
# closed, no fresh response). The Lua side guards against TheWorld being nil
# (worldgen) and AllPlayers being undefined (early boot).
poll_query_state() {
  local log="$CLUSTER_DIR/Master/server_log.txt"
  [[ -f "$log" ]] || return 1
  # Use a uniqueness token so we ignore stale ADMINBPOLL lines from earlier polls.
  local nonce; nonce="$(date +%s%N)"
  local pre_lines; pre_lines=$(wc -l < "$log" 2>/dev/null || echo 0)
  echo "c_eval([[print('ADMINBPOLL:${nonce}:'..tostring(TheWorld and TheWorld.state.cycles or -1)..':'..(_G['AllPlayers'] and #AllPlayers or 0))]])" >&3 2>/dev/null || return 1
  # Wait up to ~6s for the response to land in the log.
  local i
  for i in 1 2 3 4 5 6; do
    sleep 1
    local line
    line=$(tail -n 200 "$log" 2>/dev/null | grep -oE "ADMINBPOLL:${nonce}:-?[0-9]+:[0-9]+" | tail -1)
    if [[ -n "$line" ]]; then
      # strip "ADMINBPOLL:<nonce>:" prefix → "cycles:players"
      echo "${line#ADMINBPOLL:${nonce}:}"
      return 0
    fi
  done
  return 1
}

# One iteration of the poll loop. Reads current state, decides whether the
# transition since LAST_* warrants a backup, fires it, then commits the new
# state into LAST_*.
poll_step() {
  local response cycles players reason
  response=$(poll_query_state) || return 0
  cycles=${response%:*}
  players=${response#*:}
  # -1 cycles means TheWorld not initialized yet (still in worldgen). Skip.
  [[ "$cycles" == "-1" || -z "$cycles" || -z "$players" ]] && return 0

  reason=""
  if (( LAST_CYCLES < 0 )); then
    : # First successful poll - just record, no backup.
  elif (( cycles > LAST_CYCLES )); then
    reason="day"
  elif (( LAST_PLAYERS > 0 && players == 0 )); then
    reason="empty"
  fi

  LAST_CYCLES=$cycles
  LAST_PLAYERS=$players

  if [[ -n "$reason" ]]; then
    log "trigger: $reason (day=$cycles, players=$players)"
    do_backup "$reason" || true
  fi
}

start_save_poller() {
  # R2 presence is enforced by r2_require at launch — no soft-skip here.
  # Replaces the previous inotify-on-every-close_write watcher (~every save,
  # so every minute or two of play). Now polls DST state every 60s and only
  # fires a backup on day rollover or when the last player leaves. Big
  # bandwidth + R2-history-bloat reduction at the cost of up to ~1 in-game
  # day of replay on host crash. Graceful shutdown still calls do_backup so
  # podman stop / SIGTERM never loses progress.
  ( while true; do
      sleep 60
      poll_step
    done
  ) &
  POLLER_PID=$!
  log "save poller started (PID $POLLER_PID): 60s cadence, triggers=day-rollover|all-players-left"
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
  [ -n "${POLLER_PID:-}" ] && kill "$POLLER_PID" 2>/dev/null || true
  # No R2 push here on purpose. The poll loop's day-rollover and
  # empty-server triggers cover the meaningful save events; pushing on
  # every shutdown produced duplicate near-identical archives in R2 with
  # no extra recoverable state. Operator can hit "Backup to R2 now" in
  # the admin UI before stopping if they want a guaranteed snapshot.
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

  start_save_poller
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

  [ -n "${POLLER_PID:-}" ] && kill "$POLLER_PID" 2>/dev/null || true
  # No crash-path backup here either. If both shards exited unexpectedly
  # the most recent in-game state is whatever the poll loop captured
  # (day-rollover or empty-server trigger), which is the same data we'd
  # tar up here anyway. Re-pushing on exit only adds an "exit"-tagged
  # near-duplicate.
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
