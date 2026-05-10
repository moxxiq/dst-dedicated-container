# DST + admin + bootstrap rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rewrite DST appliance (container + admin panel + Vultr bootstrap) from `docs/superpowers/specs/2026-05-10-dst-rewrite-design.md`. Three specialist roles, bottom-up, TDD at Python boundaries, shellcheck for bash, VPS smoke per role.

**Architecture:** `CREATE/CREATE.md §1` and `§4`. Five-module admin split, single-file bootstrap, entrypoint.sh + lib/r2.sh.

**Tech stack:** Podman 4.9+ (rootless), Python 3.12, FastAPI 0.115, Uvicorn, Jinja2, pytest, bash + shellcheck, Cloudflare R2 via rclone.

**Reference:**
- `CREATE/CREATE.md` — full architecture, data flow, tech matrix, historical rakes (§7), invariants (§10).
- `CREATE/AGENTS.md` — rules, anti-defensive prompting.
- `CREATE/potential_issues.md` — latent bugs to fix in this rewrite.
- `CREATE/old/` — reference implementation. Read for intent, do NOT copy verbatim.
- For admin reference (no admin in `CREATE/old/`): `git show origin/master:admin/app/main.py` shows the 1500-line monolith we're splitting into 5 modules.

**Working dir:** `/Users/mox/Projects/Claude1/steamCMD`, branch `re-create`. New code lands at repo root (not inside `CREATE/`).

---

## Role A — dst-container

### Task A.1: scaffolding (.gitignore, .env.example, root layout)

**Files:**
- Create: `.gitignore`, `.env.example`

- [ ] **Step 1**: write `.gitignore`

```gitignore
.env
saves/
parked/
mods/
__pycache__/
.pytest_cache/
*.pyc
.DS_Store
__MACOSX/
```

- [ ] **Step 2**: write `.env.example`

```dotenv
# --- Cluster ---
CLUSTER_NAME=qkation-cooperative

# Cluster token from https://accounts.klei.com/account/game/servers
CLUSTER_TOKEN=

# --- Cloudflare R2 backup (MANDATORY) ---
# All four required. Entrypoint exits if any are empty.
R2_ACCOUNT_ID=
R2_BUCKET=dst
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=

# --- Admin web panel + unified credentials ---
ADMIN_USER=dst
ADMIN_PASSWORD=

# --- DST container name (used by admin to podman-control) ---
DST_CONTAINER=dst
```

- [ ] **Step 3**: commit

```bash
git add .gitignore .env.example
git commit -m "feat(dst): scaffold root .gitignore + .env.example"
```

---

### Task A.2: Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1**: write `Dockerfile`

```dockerfile
# Pinned to ubuntu-24 tag (Ubuntu 24.04 LTS). Bump after checking
# https://hub.docker.com/r/steamcmd/steamcmd/tags
FROM --platform=linux/amd64 docker.io/steamcmd/steamcmd:ubuntu-24

USER root

# Required runtime packages:
#   libcurl3-gnutls — DST binary loads libcurl-gnutls.so.4 at runtime (rake from CREATE.md §7)
#   tini            — PID 1 reaper for clean signal forwarding
#   rclone          — R2 backup transport
#   inotify-tools   — do_wait_for_cluster watches saves dir
#   zip, unzip      — backup archive creation + restore
#   procps          — pgrep used in shard process counting
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      tini \
      locales \
      procps \
      curl \
      libcurl3-gnutls \
      rclone \
      inotify-tools \
      zip \
      unzip \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HOME=/home/ubuntu \
    STEAM_HOME=/home/ubuntu/.local/share/Steam \
    DST_DIR=/home/ubuntu/dst \
    KLEI_DIR=/home/ubuntu/.klei

RUN install -d -o ubuntu -g ubuntu \
      "$STEAM_HOME" \
      "$DST_DIR" \
      "$KLEI_DIR" \
      "$KLEI_DIR/DoNotStarveTogether" \
      /home/ubuntu/.steam \
      /home/ubuntu/Steam/logs \
      /home/ubuntu/user-mods \
    && ln -sf "$STEAM_HOME" /home/ubuntu/.steam/root \
    && ln -sf "$STEAM_HOME" /home/ubuntu/.steam/steam

COPY --chown=root:root lib /usr/local/lib/dst
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["dst"]
```

- [ ] **Step 2**: run shellcheck on referenced files (none yet — skip)

- [ ] **Step 3**: do NOT build yet (entrypoint.sh + lib/ not written). Commit.

```bash
git add Dockerfile
git commit -m "feat(dst): Dockerfile with libcurl3-gnutls + zip/unzip + rclone"
```

---

### Task A.3: lib/r2.sh

**Files:**
- Create: `lib/r2.sh`

- [ ] **Step 1**: write `lib/r2.sh`

```bash
#!/usr/bin/env bash
# R2 helpers — sourced by entrypoint.sh.
# Functions exported: r2_configured, r2_rclone_env, r2_require,
#                     do_backup, do_r2_restore_once, write_mods_sidecar,
#                     backup_history_name
# Required env in caller's scope: CLUSTER_NAME, CLUSTER_DIR, KLEI_DIR,
#                                  R2_ACCOUNT_ID, R2_BUCKET,
#                                  R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
#                                  LAST_CYCLES (from poll loop; -1 if not set)
# Required helpers from caller's scope: log

r2_configured() {
  [[ -n "${R2_ACCOUNT_ID:-}" && -n "${R2_BUCKET:-}" \
     && -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]]
}

r2_require() {
  if r2_configured; then return 0; fi
  log "ERROR: Cloudflare R2 is required but not fully configured."
  local v
  for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [[ -z "${!v:-}" ]] && log "  missing: $v"
  done
  log "set all four in .env and restart the container."
  exit 1
}

r2_rclone_env() {
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_REGION=auto
  # Mandatory: scoped R2 tokens lack CreateBucket; rclone's bucket-probe 403s
  # with a stripped error otherwise. See CREATE/CREATE.md §7 + §6.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

backup_history_name() {
  local tag="$1" ts="$2"
  if [[ "${LAST_CYCLES:--1}" -ge 0 ]]; then
    printf 'day-%04d-%s-%s.zip' "$LAST_CYCLES" "$ts" "$tag"
  else
    printf '%s-%s.zip' "$ts" "$tag"
  fi
}

write_mods_sidecar() {
  local out="$1"
  local setup_file="$HOME/user-mods/dedicated_server_mods_setup.lua"
  local master_mods="$CLUSTER_DIR/Master/modoverrides.lua"
  local caves_mods="$CLUSTER_DIR/Caves/modoverrides.lua"
  local ids
  ids=$(grep -hoE 'workshop-[0-9]+' "$setup_file" "$master_mods" "$caves_mods" 2>/dev/null \
        | sort -u | sed 's/workshop-//')
  {
    printf '{\n  "cluster_name": "%s",\n' "$CLUSTER_NAME"
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
  if [[ ! -d "$CLUSTER_DIR" ]]; then
    log "no cluster dir yet, skipping backup"
    return 0
  fi
  command -v zip >/dev/null || { log "zip not in image"; return 1; }
  r2_rclone_env
  local ts; ts="$(date -u +%Y-%m-%dT%H%M%SZ)"
  local hist; hist="$(backup_history_name "$tag" "$ts")"
  local tmp="/tmp/backup-$$-${ts}.zip"
  local meta="${tmp%.zip}.mods.json"
  if ! ( cd "$KLEI_DIR/DoNotStarveTogether" && zip -qrX "$tmp" "$CLUSTER_NAME" ); then
    log "zip failed (tag=$tag)"
    rm -f "$tmp"
    return 1
  fi
  write_mods_sidecar "$meta" || true
  rclone copyto "$tmp" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history/${hist}" --quiet \
    || log "R2 history upload failed"
  if [[ -s "$meta" ]]; then
    rclone copyto "$meta" "r2:$R2_BUCKET/clusters/$CLUSTER_NAME/history/${hist%.zip}.mods.json" --quiet \
      || log "R2 sidecar upload failed (non-fatal)"
  fi
  rm -f "$tmp" "$meta"
  log "backup pushed (tag=$tag day=${LAST_CYCLES:--1} → $hist)"
}

do_r2_restore_once() {
  r2_configured || return 1
  log "cluster missing locally — attempting R2 restore (newest history)"
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
  local ext="zip" tmp="/tmp/restore-$$.zip"
  [[ "$newest" == *.tar.gz ]] && { ext="tar.gz"; tmp="/tmp/restore-$$.tar.gz"; }
  if ! rclone copyto "$hist_dir/$newest" "$tmp" 2>/dev/null; then
    rm -f "$tmp"; log "rclone copyto failed for $hist_dir/$newest"; return 1
  fi
  if [[ "$ext" == "zip" ]]; then
    unzip -q "$tmp" -d "$KLEI_DIR/DoNotStarveTogether/"
  else
    tar xzf "$tmp" -C "$KLEI_DIR/DoNotStarveTogether/"
  fi
  rm -f "$tmp"
  log "restored cluster from R2 ($newest)"
}
```

- [ ] **Step 2**: shellcheck

```bash
shellcheck lib/r2.sh
```

Expected: exit 0 (no warnings) or only `SC1091` (sourced file not found) which is ignorable for this file.

- [ ] **Step 3**: commit

```bash
git add lib/r2.sh
git commit -m "feat(dst): lib/r2.sh — R2 helpers (configured/require/env/backup/restore/sidecar)"
```

---

### Task A.4: run-dst.sh

**Files:**
- Create: `run-dst.sh`

- [ ] **Step 1**: write `run-dst.sh`

```bash
#!/usr/bin/env bash
# Production launcher. Not compose. Reads .env via --env-file at runtime.
# --userns=keep-id:uid=1000,gid=1000 pins container ubuntu (UID 1000) to
# host dst (UID 1001); admin container also writes as host 1001 — all
# three identities align, no :U flag races. See CREATE.md §6 and §10.
set -Eeuo pipefail

IMAGE="${IMAGE:-local/dst:latest}"
CONTAINER="${CONTAINER:-dst}"
ENV_FILE="${ENV_FILE:-$(pwd)/.env}"
SAVES_DIR="${SAVES_DIR:-$(pwd)/saves}"
MODS_DIR="${MODS_DIR:-$(pwd)/mods}"
STOP_TIMEOUT="${STOP_TIMEOUT:-90}"

case "${1:-start}" in
  build)
    podman build --platform=linux/amd64 -t "$IMAGE" .
    ;;
  logs)
    exec podman logs -f "$CONTAINER"
    ;;
  stop)
    exec podman stop -t "$STOP_TIMEOUT" "$CONTAINER"
    ;;
  restart)
    podman stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null 2>&1 || true
    exec "$0" start
    ;;
  start)
    mkdir -p "$SAVES_DIR" "$MODS_DIR"
    local_env_args=()
    if [[ -f "$ENV_FILE" ]]; then
      local_env_args+=(--env-file "$ENV_FILE")
    else
      echo "[run-dst] warning: $ENV_FILE not found — running without env" >&2
    fi
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
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
      "${local_env_args[@]}" \
      -v steamcmd-home:/home/ubuntu/.local/share/Steam:U \
      -v dst-server:/home/ubuntu/dst:U \
      `# saves/ and mods/ have no :U on purpose — keep-id aligns identities,` \
      `# and admin writes there too at the same UID. Adding :U would race.` \
      -v "$SAVES_DIR":/home/ubuntu/.klei/DoNotStarveTogether \
      -v "$MODS_DIR":/home/ubuntu/user-mods \
      "$IMAGE" dst
    ;;
  *)
    echo "usage: $0 {build|start|stop|restart|logs}" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 2**: shellcheck + chmod

```bash
shellcheck run-dst.sh && chmod +x run-dst.sh
```

Expected: exit 0.

- [ ] **Step 3**: commit

```bash
git add run-dst.sh
git commit -m "feat(dst): run-dst.sh launcher (keep-id, --stop-timeout 90, no :U on shared mounts)"
```

---

### Task A.5: entrypoint.sh — scaffold (consts, log, trap, source lib)

**Files:**
- Create: `entrypoint.sh`

- [ ] **Step 1**: write `entrypoint.sh` scaffold (top half — through helpers)

```bash
#!/usr/bin/env bash
# DST entrypoint. Lifecycle:
#   1. r2_require (sourced from lib/r2.sh) — exit if R2 not configured
#   2. do_app_update (steamcmd validate)
#   3. do_mods_sync (copy mods/dedicated_server_mods_setup.lua + sideload dirs)
#   4. do_wait_for_cluster (inotify on saves dir; R2 restore once if available)
#   5. do_cluster_token (write CLUSTER_TOKEN to cluster_token.txt)
#   6. FIFO setup (per-shard, O_RDWR so we don't self-deadlock)
#   7. launch shards in background, capture PIDs
#   8. start_save_poller (60s c_eval into master FIFO, parse cycles+players)
#   9. wait for shards; SIGTERM → graceful_stop
#
# No backups on shutdown/exit — poll triggers day/empty/manual only.
# See CREATE.md §5 (data flow) + §10 (invariants).

set -Eeuo pipefail

# shellcheck source=lib/r2.sh
. /usr/local/lib/dst/r2.sh

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"
CLUSTER_DIR="$KLEI_DIR/DoNotStarveTogether/$CLUSTER_NAME"
MASTER_SAVE_DIR="$CLUSTER_DIR/Master/save"
CAVES_SAVE_DIR="$CLUSTER_DIR/Caves/save"
USER_MODS_SETUP="$HOME/user-mods/dedicated_server_mods_setup.lua"
DST_MODS_SETUP="$DST_DIR/mods/dedicated_server_mods_setup.lua"
MASTER_FIFO=/tmp/dst.master.stdin
CAVES_FIFO=/tmp/dst.caves.stdin
DST_BIN="$DST_DIR/bin64/dontstarve_dedicated_server_nullrenderer_x64"

LAST_CYCLES=-1
LAST_PLAYERS=-1
POLLER_PID=""
MASTER_PID=""
CAVES_PID=""

log() { printf '[entrypoint %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Export so subshells (poll loop, sideloaded scripts) can call helpers.
export -f log
export CLUSTER_NAME CLUSTER_DIR KLEI_DIR LAST_CYCLES LAST_PLAYERS \
       R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY
```

- [ ] **Step 2**: chmod + shellcheck

```bash
chmod +x entrypoint.sh
shellcheck -x entrypoint.sh
```

Expected: exit 0 (the `-x` flag follows the `. /usr/local/lib/dst/r2.sh` source).

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): entrypoint.sh scaffold — consts, log, source lib/r2.sh"
```

---

### Task A.6: entrypoint.sh — do_app_update + do_mods_sync (with sideload)

**Files:**
- Modify: `entrypoint.sh` (append functions)

- [ ] **Step 1**: append to `entrypoint.sh`

```bash
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
  if [[ -f "$USER_MODS_SETUP" ]]; then
    install -m 0644 "$USER_MODS_SETUP" "$DST_MODS_SETUP"
    log "synced dedicated_server_mods_setup.lua into DST install"
  else
    log "no user mods setup found at $USER_MODS_SETUP (ok)"
  fi
  # Sideload: copy each dir under user-mods/user-mods/ into DST install/mods/
  # Admin /mods/upload extracts uploads to this path. Each subdir is one mod.
  local sideload_root="$HOME/user-mods/user-mods"
  if [[ -d "$sideload_root" ]]; then
    local count=0
    for d in "$sideload_root"/*/; do
      [[ -d "$d" ]] || continue
      local name; name="$(basename "$d")"
      [[ "$name" == "." || "$name" == ".." ]] && continue
      cp -r "$d" "$DST_DIR/mods/$name"
      count=$((count + 1))
    done
    (( count > 0 )) && log "synced $count sideloaded mod folder(s)"
  fi
}
```

- [ ] **Step 2**: shellcheck

```bash
shellcheck -x entrypoint.sh
```

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): do_app_update + do_mods_sync (with user-mods sideload)"
```

---

### Task A.7: entrypoint.sh — cluster_ready + do_wait_for_cluster + do_cluster_token

**Files:**
- Modify: `entrypoint.sh` (append functions)

- [ ] **Step 1**: append

```bash
cluster_ready() {
  [[ -f "$CLUSTER_DIR/cluster.ini" \
     && -f "$CLUSTER_DIR/Master/server.ini" \
     && -f "$CLUSTER_DIR/Caves/server.ini" ]]
}

do_cluster_token() {
  local tokfile="$CLUSTER_DIR/cluster_token.txt"
  if [[ -s "$tokfile" ]]; then return 0; fi
  if [[ -n "${CLUSTER_TOKEN:-}" ]]; then
    printf '%s' "$CLUSTER_TOKEN" > "$tokfile"
    chmod 0600 "$tokfile"
    log "wrote cluster_token.txt from \$CLUSTER_TOKEN"
  else
    log "WARNING: no cluster_token.txt and no \$CLUSTER_TOKEN — DST will reject players"
  fi
}

do_wait_for_cluster() {
  if cluster_ready; then
    log "cluster '$CLUSTER_NAME' present locally — skipping R2/wait"
    return 0
  fi
  do_r2_restore_once || true
  cluster_ready && return 0

  log "=== WAITING FOR CLUSTER ==="
  log "cluster '$CLUSTER_NAME' not found locally ($CLUSTER_DIR)"
  log "admin panel can upload a zip, restore from R2, or use the template wizard."

  local start_ts last_beat
  start_ts=$(date +%s); last_beat=$start_ts
  while ! cluster_ready; do
    inotifywait -qq -t 60 -e create,close_write,moved_to \
      -r "$KLEI_DIR/DoNotStarveTogether" 2>/dev/null || true
    cluster_ready && break
    local now; now=$(date +%s)
    if (( now - last_beat >= 60 )); then
      log "still waiting (elapsed $((now - start_ts))s)"
      last_beat=$now
    fi
  done
  log "cluster detected — proceeding with launch"
}
```

- [ ] **Step 2**: shellcheck

```bash
shellcheck -x entrypoint.sh
```

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): cluster_ready + wait_for_cluster (inotify) + cluster_token"
```

---

### Task A.8: entrypoint.sh — FIFOs + graceful_stop + signal trap

**Files:**
- Modify: `entrypoint.sh` (append)

- [ ] **Step 1**: append

```bash
# Per-shard FIFOs let us send `c_save()` / `c_shutdown(true)` independently.
# Must open O_RDWR (`<>`) not O_WRONLY (`>`) — O_WRONLY blocks until a
# reader exists, but the DST binary (the reader) launches AFTER this point.
# Self-deadlock if we use `>`. See CREATE/CREATE.md §7 rake.
setup_fifos() {
  rm -f "$MASTER_FIFO" "$CAVES_FIFO"
  mkfifo "$MASTER_FIFO" "$CAVES_FIFO"
  exec 3<> "$MASTER_FIFO"
  exec 4<> "$CAVES_FIFO"
}

shard_soft_shutdown() {
  local label="$1" fd="$2"
  log "  → $label: c_save()"
  eval "echo 'c_save()' >&$fd" || true
  sleep 2
  log "  → $label: c_shutdown(true)"
  eval "echo 'c_shutdown(true)' >&$fd" || true
}

wait_or_kill() {
  local label="$1" pid="$2" deadline="$3"
  [[ -n "$pid" ]] || return 0
  local i
  for ((i=0; i<deadline; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "$label (PID $pid) didn't exit in ${deadline}s — TERM"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

graceful_stop() {
  log "signal — graceful shutdown of both shards"
  shard_soft_shutdown Master 3
  shard_soft_shutdown Caves  4
  wait_or_kill Master "${MASTER_PID:-}" 60
  wait_or_kill Caves  "${CAVES_PID:-}"  60
  [[ -n "${POLLER_PID:-}" ]] && kill "$POLLER_PID" 2>/dev/null || true
  # No R2 push here — poll triggers (day/empty/manual) cover meaningful
  # state changes; shutdown push produced near-duplicates. See spec §6.
  exit 0
}
```

- [ ] **Step 2**: shellcheck

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): per-shard FIFOs (O_RDWR) + graceful_stop (no shutdown R2 push)"
```

---

### Task A.9: entrypoint.sh — poll loop (day rollover + empty server triggers)

**Files:**
- Modify: `entrypoint.sh` (append)

- [ ] **Step 1**: append

```bash
# Poll loop: c_eval into Master FIFO with a per-poll nonce so we never
# confuse a stale ADMINBPOLL line in the log with the fresh round.
# Lua guards against TheWorld being nil (worldgen) and AllPlayers
# being undefined (early boot).
poll_query_state() {
  local log_file="$CLUSTER_DIR/Master/server_log.txt"
  [[ -f "$log_file" ]] || return 1
  local nonce; nonce="$(date +%s%N)"
  echo "c_eval([[print('ADMINBPOLL:${nonce}:'..tostring(TheWorld and TheWorld.state.cycles or -1)..':'..(_G['AllPlayers'] and #AllPlayers or 0))]])" >&3 2>/dev/null || return 1
  local i line
  for ((i=0; i<6; i++)); do
    sleep 1
    line=$(tail -n 200 "$log_file" 2>/dev/null \
           | grep -oE "ADMINBPOLL:${nonce}:-?[0-9]+:[0-9]+" | tail -1)
    if [[ -n "$line" ]]; then
      echo "${line#ADMINBPOLL:${nonce}:}"
      return 0
    fi
  done
  return 1
}

poll_step() {
  local response cycles players reason
  response=$(poll_query_state) || return 0
  cycles=${response%:*}
  players=${response#*:}
  [[ "$cycles" == "-1" || -z "$cycles" || -z "$players" ]] && return 0

  reason=""
  if (( LAST_CYCLES < 0 )); then
    : # first poll — record only
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
  ( while true; do sleep 60; poll_step; done ) &
  POLLER_PID=$!
  log "save poller started (PID $POLLER_PID): 60s cadence, triggers=day|empty"
}
```

- [ ] **Step 2**: shellcheck

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): poll loop (60s, c_eval + log-tail nonce, day/empty triggers)"
```

---

### Task A.10: entrypoint.sh — launch_dst + main dispatch

**Files:**
- Modify: `entrypoint.sh` (append)

- [ ] **Step 1**: append

```bash
launch_dst() {
  r2_require
  if [[ ! -x "$DST_BIN" ]]; then
    log "DST binary missing — running app_update first"
    do_app_update
  else
    do_app_update
  fi
  do_mods_sync
  do_wait_for_cluster
  do_cluster_token

  setup_fifos
  start_save_poller
  trap graceful_stop TERM INT

  cd "$DST_DIR/bin64"
  log "launching Master shard"
  ./dontstarve_dedicated_server_nullrenderer_x64 \
    -persistent_storage_root "$KLEI_DIR" -conf_dir DoNotStarveTogether \
    -cluster "$CLUSTER_NAME" -shard Master < "$MASTER_FIFO" &
  MASTER_PID=$!
  log "Master started (PID $MASTER_PID)"

  log "launching Caves shard"
  ./dontstarve_dedicated_server_nullrenderer_x64 \
    -persistent_storage_root "$KLEI_DIR" -conf_dir DoNotStarveTogether \
    -cluster "$CLUSTER_NAME" -shard Caves < "$CAVES_FIFO" &
  CAVES_PID=$!
  log "Caves started (PID $CAVES_PID)"

  # Whichever shard exits first, kill the other so we exit together.
  wait -n
  local first_exit=$?
  log "one shard exited (rc=$first_exit) — bringing other down"
  [[ -n "$MASTER_PID" ]] && kill "$MASTER_PID" 2>/dev/null || true
  [[ -n "$CAVES_PID" ]]  && kill "$CAVES_PID"  2>/dev/null || true
  wait "$MASTER_PID" 2>/dev/null; local mrc=$?
  wait "$CAVES_PID"  2>/dev/null; local crc=$?
  log "Master rc=$mrc, Caves rc=$crc"
  [[ -n "${POLLER_PID:-}" ]] && kill "$POLLER_PID" 2>/dev/null || true
  # No exit-path R2 push — poll triggers already covered the meaningful state.
  if (( mrc != 0 )); then exit "$mrc"; fi
  exit "$crc"
}

# --- main dispatch -----------------------------------------------------------
case "${1:-dst}" in
  dst)  launch_dst ;;
  *)    exec "$@" ;;
esac
```

- [ ] **Step 2**: final shellcheck of complete entrypoint.sh

```bash
shellcheck -x entrypoint.sh
```

Expected: exit 0. Permitted-to-suppress codes (with `# shellcheck disable=`): none planned. Fix any flagged issue.

- [ ] **Step 3**: commit

```bash
git add entrypoint.sh
git commit -m "feat(dst): launch_dst + main dispatch (wait -n, no shutdown/exit R2 push)"
```

---

### Task A.SMOKE: build image + container smoke test

**Files:** none modified

- [ ] **Step 1**: build

```bash
podman build --platform=linux/amd64 -t local/dst:latest .
```

Expected: succeeds. If `pasta` error → that's a bootstrap-level issue (host packages); not blocking image build itself.

- [ ] **Step 2**: smoke 1 (steamcmd dry-run, no real .env needed)

```bash
podman run --rm local/dst:latest steamcmd +quit
```

Expected: exit 0, log contains `Loading Steam API...OK` (no full app_update; we just want to verify the binary works).

- [ ] **Step 3**: smoke 2 (entrypoint dispatch sanity — pass `bash` to bypass dst lifecycle)

```bash
podman run --rm local/dst:latest bash -c 'command -v zip && command -v unzip && command -v rclone && command -v inotifywait && echo OK'
```

Expected: stdout ends with `OK`. Verifies all required tools are in the image.

- [ ] **Step 4**: smoke 3 (on Vultr VPS only; **stop role A here on dev box**, run smoke 3 only on real VPS later in cross-role smoke)

Documented but not blocking task completion. Marked DONE for Role A.

- [ ] **Step 5**: commit (none — smoke is verification only)

Role A complete when steps 1-3 pass.

---

## Role B — admin-panel

### Task B.1: scaffold admin dir + dependencies

**Files:**
- Create: `admin/requirements.txt`, `admin/pyproject.toml`, `admin/app/__init__.py`, `admin/tests/__init__.py`, `admin/.gitignore`

- [ ] **Step 1**: create directory layout

```bash
mkdir -p admin/app/templates admin/app/static admin/tests
touch admin/app/__init__.py admin/tests/__init__.py
```

- [ ] **Step 2**: write `admin/requirements.txt`

```
fastapi==0.115.0
uvicorn[standard]==0.32.0
jinja2==3.1.4
python-multipart==0.0.12
```

- [ ] **Step 3**: write `admin/pyproject.toml` (minimal — pytest config only)

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
python_files = ["test_*.py"]
addopts = "-v --tb=short"
```

- [ ] **Step 4**: write `admin/.gitignore`

```
__pycache__/
*.pyc
.pytest_cache/
.venv/
```

- [ ] **Step 5**: commit

```bash
git add admin/
git commit -m "feat(admin): scaffold admin/ dir, requirements, pytest config"
```

---

### Task B.2: conftest.py — base fixtures (tmp project root + subprocess mock)

**Files:**
- Create: `admin/tests/conftest.py`

- [ ] **Step 1**: write `admin/tests/conftest.py`

```python
"""Shared pytest fixtures.

`fake_data` provides a tmp_path-based fake project root that admin modules
expect: /data/saves, /data/parked, /data/mods, /data/.env.

`mock_subprocess` patches subprocess.run globally so no test ever invokes
real rclone or podman. Tests register canned responses per (cmd_prefix)
match; uncovered calls fail loudly so we don't silently no-op.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.fixture
def fake_data(tmp_path, monkeypatch):
    """tmp_path-based /data layout. Sets DATA env var so modules pick it up."""
    data = tmp_path / "data"
    (data / "saves").mkdir(parents=True)
    (data / "parked").mkdir()
    (data / "mods").mkdir()
    (data / ".env").write_text(
        "CLUSTER_NAME=testcluster\n"
        "R2_ACCOUNT_ID=acct\n"
        "R2_BUCKET=bkt\n"
        "R2_ACCESS_KEY_ID=ak\n"
        "R2_SECRET_ACCESS_KEY=sk\n"
        "ADMIN_PASSWORD=pw\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("DATA_DIR", str(data))
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    return data


@pytest.fixture
def mock_subprocess(monkeypatch):
    """Patch subprocess.run. Tests register handlers:

        mock_subprocess.handle(
            cmd_starts_with=["rclone", "lsjson"],
            returncode=0,
            stdout='[{"Name":"foo.zip","Size":1024,"ModTime":"2026-01-01T00:00:00Z"}]',
        )
    """
    class Mock:
        def __init__(self):
            self.handlers: list[dict] = []
            self.calls: list[list[str]] = []

        def handle(self, cmd_starts_with, returncode=0, stdout="", stderr=""):
            self.handlers.append({
                "prefix": list(cmd_starts_with),
                "rc": returncode,
                "stdout": stdout,
                "stderr": stderr,
            })

        def __call__(self, cmd, **kwargs):
            self.calls.append(list(cmd) if isinstance(cmd, (list, tuple)) else [cmd])
            for h in self.handlers:
                if list(cmd[:len(h["prefix"])]) == h["prefix"]:
                    return subprocess.CompletedProcess(
                        args=cmd,
                        returncode=h["rc"],
                        stdout=h["stdout"],
                        stderr=h["stderr"],
                    )
            raise AssertionError(
                f"Unhandled subprocess.run call: {cmd!r}. "
                f"Register with mock_subprocess.handle(cmd_starts_with=[...])"
            )

    m = Mock()
    monkeypatch.setattr(subprocess, "run", m)
    return m


@pytest.fixture(autouse=True)
def _add_admin_to_path(monkeypatch):
    """Make `from app import ...` work in tests."""
    admin_root = Path(__file__).parent.parent
    monkeypatch.syspath_prepend(str(admin_root))
```

- [ ] **Step 2**: install deps locally for test runs

```bash
cd admin && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt pytest
```

- [ ] **Step 3**: smoke test fixture (run a trivial pytest)

```bash
cd admin && .venv/bin/pytest tests/ -v
```

Expected: `no tests ran` (no test files yet) — fixture import must succeed.

- [ ] **Step 4**: commit

```bash
git add admin/tests/conftest.py
git commit -m "test(admin): pytest fixtures — fake_data + mock_subprocess"
```

---

### Task B.3: archive.py + tests (TDD, 9 tests)

**Files:**
- Create: `admin/tests/test_archive.py`, `admin/app/archive.py`

- [ ] **Step 1**: write `admin/tests/test_archive.py`

```python
"""archive.py — magic-byte detect, junk strip, flatten, safe extract."""
from __future__ import annotations

import io
import tarfile
import zipfile
from pathlib import Path

import pytest

from app import archive


def test_detect_format_zip():
    assert archive.detect_format(b"PK\x03\x04rest") == "zip"


def test_detect_format_tar_gz():
    assert archive.detect_format(b"\x1f\x8b\x08\x00rest") == "tar.gz"


def test_detect_format_unknown():
    assert archive.detect_format(b"\x00\x00\x00\x00") is None


def test_strip_archive_junk_removes_macosx_recursive(tmp_path):
    (tmp_path / "real" / "__MACOSX").mkdir(parents=True)
    (tmp_path / "real" / "__MACOSX" / "stuff").write_text("x")
    (tmp_path / "real" / "cluster.ini").write_text("ok")
    archive._strip_archive_junk(tmp_path)
    assert not (tmp_path / "real" / "__MACOSX").exists()
    assert (tmp_path / "real" / "cluster.ini").is_file()


def test_strip_archive_junk_removes_dsstore_files(tmp_path):
    (tmp_path / ".DS_Store").write_bytes(b"\x00")
    (tmp_path / "sub" / ".DS_Store").parent.mkdir()
    (tmp_path / "sub" / ".DS_Store").write_bytes(b"\x00")
    archive._strip_archive_junk(tmp_path)
    assert not (tmp_path / ".DS_Store").exists()
    assert not (tmp_path / "sub" / ".DS_Store").exists()


def test_flatten_single_top_dir_hoists(tmp_path):
    inner = tmp_path / "wrapper"
    inner.mkdir()
    (inner / "cluster.ini").write_text("ok")
    (inner / "Master").mkdir()
    archive._flatten_single_top_dir(tmp_path)
    assert (tmp_path / "cluster.ini").is_file()
    assert (tmp_path / "Master").is_dir()
    assert not inner.exists()


def test_flatten_no_op_when_cluster_ini_at_root(tmp_path):
    (tmp_path / "cluster.ini").write_text("ok")
    (tmp_path / "wrapper").mkdir()
    archive._flatten_single_top_dir(tmp_path)
    assert (tmp_path / "wrapper").is_dir()
    assert (tmp_path / "cluster.ini").is_file()


def test_flatten_ignores_macosx_when_counting_children(tmp_path):
    (tmp_path / "__MACOSX").mkdir()
    (tmp_path / "wrapper").mkdir()
    (tmp_path / "wrapper" / "cluster.ini").write_text("ok")
    # Strip junk first, then flatten, mirroring the production order.
    archive._strip_archive_junk(tmp_path)
    archive._flatten_single_top_dir(tmp_path)
    assert (tmp_path / "cluster.ini").is_file()


def test_extract_rejects_path_traversal_zip(tmp_path):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("../evil.txt", "no")
    buf.seek(0)
    with pytest.raises(archive.UnsafeArchive):
        archive.extract_archive(buf.read(), tmp_path)
```

- [ ] **Step 2**: run tests to verify they fail (module doesn't exist yet)

```bash
cd admin && .venv/bin/pytest tests/test_archive.py -v
```

Expected: all 9 fail with `ModuleNotFoundError: app.archive` or `AttributeError`.

- [ ] **Step 3**: write `admin/app/archive.py`

```python
"""Archive operations — magic-byte detect, junk strip, flatten, safe extract.

Used by the cluster upload + R2 fetch paths. Both flows ingest opaque
archive bytes from an untrusted source (user upload or R2 download)
and must produce a clean cluster-shaped directory at a target path.

Defensive guards are limited to system boundaries — path traversal in
archive entries (real attacker surface) and Mac/Windows zip junk
(real real-world surface). Internal callers trusted otherwise.
"""
from __future__ import annotations

import io
import shutil
import tarfile
import zipfile
from pathlib import Path

ARCHIVE_JUNK = frozenset({"__MACOSX", ".DS_Store", "Thumbs.db", "desktop.ini"})


class UnsafeArchive(ValueError):
    """Raised when an archive entry would escape the destination directory."""


def detect_format(head: bytes) -> str | None:
    """Magic-byte sniff. Returns 'zip', 'tar.gz', or None."""
    if head[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"):
        return "zip"
    if head[:2] == b"\x1f\x8b":
        return "tar.gz"
    return None


def _strip_archive_junk(root: Path) -> None:
    """Remove __MACOSX/, .DS_Store, etc anywhere under `root`. Walk a snapshot
    because we mutate the tree."""
    for entry in list(root.rglob("*")):
        if entry.name in ARCHIVE_JUNK:
            if entry.is_dir():
                shutil.rmtree(entry, ignore_errors=True)
            else:
                try:
                    entry.unlink()
                except OSError:
                    pass


def _flatten_single_top_dir(dest: Path) -> None:
    """If `dest` contains exactly one real subdir (ignoring junk + dotfiles)
    and no cluster.ini at its own root, hoist that subdir's contents up.
    DST cluster format wants cluster.ini directly under the parked slot."""
    children = [
        c for c in dest.iterdir()
        if not c.name.startswith(".") and c.name not in ARCHIVE_JUNK
    ]
    if (
        len(children) == 1
        and children[0].is_dir()
        and not (dest / "cluster.ini").exists()
    ):
        inner = children[0]
        for item in inner.iterdir():
            shutil.move(str(item), str(dest / item.name))
        inner.rmdir()


def extract_archive(raw: bytes, dest: Path) -> None:
    """Extract raw archive bytes into dest (must not pre-exist as non-empty).
    Detects format by magic bytes. Raises UnsafeArchive on path traversal."""
    fmt = detect_format(raw)
    if fmt == "zip":
        with zipfile.ZipFile(io.BytesIO(raw)) as zf:
            for n in zf.namelist():
                p = Path(n)
                if p.is_absolute() or ".." in p.parts:
                    raise UnsafeArchive(f"unsafe zip entry: {n}")
            dest.mkdir(parents=True, exist_ok=True)
            zf.extractall(dest)
    elif fmt == "tar.gz":
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
            for m in tf.getmembers():
                p = Path(m.name)
                if p.is_absolute() or ".." in p.parts:
                    raise UnsafeArchive(f"unsafe tar entry: {m.name}")
            dest.mkdir(parents=True, exist_ok=True)
            tf.extractall(dest)
    else:
        raise ValueError("Unsupported archive format (expected zip or tar.gz)")
    _strip_archive_junk(dest)
    _flatten_single_top_dir(dest)
```

- [ ] **Step 4**: run tests — expect all pass

```bash
cd admin && .venv/bin/pytest tests/test_archive.py -v
```

Expected: 9 passed.

- [ ] **Step 5**: commit

```bash
git add admin/tests/test_archive.py admin/app/archive.py
git commit -m "feat(admin): archive.py — magic-byte detect, junk strip, flatten, safe extract"
```

---

### Task B.4: mods.py + tests (TDD, 5 tests)

**Files:**
- Create: `admin/tests/test_mods.py`, `admin/app/mods.py`

- [ ] **Step 1**: write `admin/tests/test_mods.py`

```python
from __future__ import annotations

from pathlib import Path

from app import mods


def _make_layout(root: Path) -> Path:
    """Replicate /data/mods + /data/saves/<cluster> structure."""
    (root / "mods").mkdir()
    (root / "saves" / "testcluster" / "Master").mkdir(parents=True)
    (root / "saves" / "testcluster" / "Caves").mkdir()
    return root


def test_workshop_ids_from_setup_file(tmp_path, monkeypatch):
    layout = _make_layout(tmp_path)
    (layout / "mods" / "dedicated_server_mods_setup.lua").write_text(
        'ServerModSetup("123456")\nServerModSetup("789012")\n'
    )
    monkeypatch.setattr(mods, "MODS_DIR", layout / "mods")
    monkeypatch.setattr(mods, "SAVES_DIR", layout / "saves")
    monkeypatch.setattr(mods, "CLUSTER_NAME", "testcluster")
    out = mods.summarize_mods()
    assert "123456" in out["workshop_ids"]
    assert "789012" in out["workshop_ids"]


def test_workshop_ids_combine_setup_and_modoverrides(tmp_path, monkeypatch):
    layout = _make_layout(tmp_path)
    (layout / "mods" / "dedicated_server_mods_setup.lua").write_text(
        'ServerModSetup("111")\n'
    )
    (layout / "saves" / "testcluster" / "Master" / "modoverrides.lua").write_text(
        'return { ["workshop-222"] = { enabled = true } }\n'
    )
    (layout / "saves" / "testcluster" / "Caves" / "modoverrides.lua").write_text(
        'return { ["workshop-333"] = { enabled = true } }\n'
    )
    monkeypatch.setattr(mods, "MODS_DIR", layout / "mods")
    monkeypatch.setattr(mods, "SAVES_DIR", layout / "saves")
    monkeypatch.setattr(mods, "CLUSTER_NAME", "testcluster")
    out = mods.summarize_mods()
    assert set(out["workshop_ids"]) == {"111", "222", "333"}


def test_workshop_ids_dedupe(tmp_path, monkeypatch):
    layout = _make_layout(tmp_path)
    (layout / "mods" / "dedicated_server_mods_setup.lua").write_text(
        'ServerModSetup("111")\n'
    )
    (layout / "saves" / "testcluster" / "Master" / "modoverrides.lua").write_text(
        'return { ["workshop-111"] = { enabled = true } }\n'
    )
    monkeypatch.setattr(mods, "MODS_DIR", layout / "mods")
    monkeypatch.setattr(mods, "SAVES_DIR", layout / "saves")
    monkeypatch.setattr(mods, "CLUSTER_NAME", "testcluster")
    out = mods.summarize_mods()
    assert out["workshop_ids"] == ["111"]


def test_sideloaded_folders_listed(tmp_path, monkeypatch):
    layout = _make_layout(tmp_path)
    (layout / "mods" / "user-mods" / "MyMod").mkdir(parents=True)
    (layout / "mods" / "user-mods" / "OtherMod").mkdir()
    monkeypatch.setattr(mods, "MODS_DIR", layout / "mods")
    monkeypatch.setattr(mods, "SAVES_DIR", layout / "saves")
    monkeypatch.setattr(mods, "CLUSTER_NAME", "testcluster")
    out = mods.summarize_mods()
    assert out["sideloaded"] == ["MyMod", "OtherMod"]


def test_sideloaded_ignores_archive_junk(tmp_path, monkeypatch):
    layout = _make_layout(tmp_path)
    (layout / "mods" / "user-mods" / "MyMod").mkdir(parents=True)
    (layout / "mods" / "user-mods" / "__MACOSX").mkdir()
    (layout / "mods" / "user-mods" / ".DS_Store").write_bytes(b"\x00")
    monkeypatch.setattr(mods, "MODS_DIR", layout / "mods")
    monkeypatch.setattr(mods, "SAVES_DIR", layout / "saves")
    monkeypatch.setattr(mods, "CLUSTER_NAME", "testcluster")
    out = mods.summarize_mods()
    assert out["sideloaded"] == ["MyMod"]
```

- [ ] **Step 2**: run tests — expect all fail

```bash
cd admin && .venv/bin/pytest tests/test_mods.py -v
```

Expected: 5 fail.

- [ ] **Step 3**: write `admin/app/mods.py`

```python
"""Mods summary — workshop IDs from setup + modoverrides, sideload folders.

Used by the dashboard render context. Pure file-read; no DST or podman
side effects."""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from app.archive import ARCHIVE_JUNK

DATA = Path(os.environ.get("DATA_DIR", "/data"))
MODS_DIR = DATA / "mods"
SAVES_DIR = DATA / "saves"
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "qkation-cooperative")

_WORKSHOP_ID_RE = re.compile(r"workshop-(\d+)|ServerModSetup\(\"(\d+)\"\)")


def _cluster_dir() -> Path:
    return SAVES_DIR / CLUSTER_NAME


def summarize_mods() -> dict[str, Any]:
    """Return {workshop_ids: [str], sideloaded: [folder_name]}."""
    workshop_ids: set[str] = set()
    setup = MODS_DIR / "dedicated_server_mods_setup.lua"
    if setup.is_file():
        text = setup.read_text(encoding="utf-8", errors="ignore")
        for m in _WORKSHOP_ID_RE.finditer(text):
            workshop_ids.add(m.group(1) or m.group(2))

    cd = _cluster_dir()
    for shard in ("Master", "Caves"):
        f = cd / shard / "modoverrides.lua"
        if f.is_file():
            text = f.read_text(encoding="utf-8", errors="ignore")
            for m in _WORKSHOP_ID_RE.finditer(text):
                workshop_ids.add(m.group(1) or m.group(2))

    sideloaded: list[str] = []
    sideload_dir = MODS_DIR / "user-mods"
    if sideload_dir.is_dir():
        for child in sorted(sideload_dir.iterdir()):
            if (
                child.is_dir()
                and not child.name.startswith(".")
                and child.name not in ARCHIVE_JUNK
            ):
                sideloaded.append(child.name)

    return {
        "workshop_ids": sorted(workshop_ids, key=lambda s: int(s)),
        "sideloaded": sideloaded,
    }
```

- [ ] **Step 4**: run tests

```bash
cd admin && .venv/bin/pytest tests/test_mods.py -v
```

Expected: 5 passed.

- [ ] **Step 5**: commit

```bash
git add admin/tests/test_mods.py admin/app/mods.py
git commit -m "feat(admin): mods.py — workshop IDs summary + sideload folder listing"
```

---

### Task B.5: r2.py + tests (TDD, 7 tests)

**Files:**
- Create: `admin/tests/test_r2.py`, `admin/app/r2.py`

- [ ] **Step 1**: write `admin/tests/test_r2.py`

```python
from __future__ import annotations

import json
from pathlib import Path

import pytest

from app import r2


def test_env_ready_all_set():
    env = {
        "R2_ACCOUNT_ID": "a", "R2_BUCKET": "b",
        "R2_ACCESS_KEY_ID": "k", "R2_SECRET_ACCESS_KEY": "s",
    }
    assert r2.r2_env_ready(env) is True


def test_env_ready_missing_one_false():
    env = {
        "R2_ACCOUNT_ID": "a", "R2_BUCKET": "",
        "R2_ACCESS_KEY_ID": "k", "R2_SECRET_ACCESS_KEY": "s",
    }
    assert r2.r2_env_ready(env) is False


def test_rclone_env_sets_no_check_bucket():
    env = {
        "R2_ACCOUNT_ID": "a", "R2_BUCKET": "b",
        "R2_ACCESS_KEY_ID": "k", "R2_SECRET_ACCESS_KEY": "s",
    }
    out = r2.r2_rclone_env(env)
    assert out["RCLONE_CONFIG_R2_NO_CHECK_BUCKET"] == "true"
    assert out["RCLONE_CONFIG_R2_ENDPOINT"] == "https://a.r2.cloudflarestorage.com"
    assert out["RCLONE_CONFIG_R2_PROVIDER"] == "Cloudflare"


def test_newest_history_key_prefers_day_prefix():
    files = [
        {"Name": "2026-01-01T0000Z-manual.zip"},
        {"Name": "day-0005-2026-01-05T0000Z-day.zip"},
        {"Name": "day-0003-2026-01-03T0000Z-empty.zip"},
    ]
    n = r2._newest_history_key(files)
    assert n["Name"] == "day-0005-2026-01-05T0000Z-day.zip"


def test_newest_history_key_sorts_iso_legacy_correctly():
    # All iso-prefixed (pre-day-NNNN migration). Lex-sort = chrono-sort.
    files = [
        {"Name": "2026-01-01T0000Z-manual.zip"},
        {"Name": "2026-01-03T0000Z-manual.zip"},
        {"Name": "2026-01-02T0000Z-manual.zip"},
    ]
    n = r2._newest_history_key(files)
    assert n["Name"] == "2026-01-03T0000Z-manual.zip"


def test_newest_history_key_returns_none_on_empty():
    assert r2._newest_history_key([]) is None
    assert r2._newest_history_key([{"Name": "sidecar.mods.json"}]) is None


def test_list_r2_clusters_empty_on_rclone_error(monkeypatch, mock_subprocess, fake_data):
    mock_subprocess.handle(
        cmd_starts_with=["rclone", "lsjson"],
        returncode=1, stdout="", stderr="connection refused",
    )
    # r2.py reads .env via read_env_file — already in fake_data.
    out = r2.list_r2_clusters()
    assert out == []
```

- [ ] **Step 2**: run — expect fails

```bash
cd admin && .venv/bin/pytest tests/test_r2.py -v
```

- [ ] **Step 3**: write `admin/app/r2.py`

```python
"""R2 backup operations via rclone subprocess wrapper.

Public:
  r2_env_ready(env)      — bool, are the 4 R2 vars set
  r2_rclone_env(env)     — dict to pass as subprocess env; sets
                           NO_CHECK_BUCKET=true (mandatory; see CREATE.md §7)
  list_r2_clusters()     — [{name, size_mb, mtime, newest_archive, history_count}]
  list_r2_history(name)  — [{name, size_mb, mtime, sidecar}], newest first
  read_r2_mods_sidecar(name, sidecar_filename) — dict from sidecar JSON
  fetch_r2_cluster_to(name, dest, archive_name=None) — (ok, msg)
  run_backup(tag)        — (ok, msg). Manual backup.

Private:
  _history_path(bucket, name)
  _newest_history_key(files)  — pick lex-largest archive from rclone lsjson list

Subprocess.run is mocked in tests; never invoked directly here. Callers
trust that errors propagate via the (returncode, stdout, stderr) tuple
returned by run_backup / fetch_r2_cluster_to — no silent swallows."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import zipfile
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.archive import extract_archive, ARCHIVE_JUNK
from app.cluster import read_env_file, cluster_dir, cluster_is_ready  # noqa: F401  (cluster.py landed in Task B.6)

DATA = Path(os.environ.get("DATA_DIR", "/data"))
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "qkation-cooperative")


def r2_env_ready(env: dict[str, str]) -> bool:
    return all(
        env.get(k)
        for k in ("R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
    )


def r2_rclone_env(env: dict[str, str]) -> dict[str, str]:
    out = os.environ.copy()
    out.update({
        "RCLONE_CONFIG_R2_TYPE": "s3",
        "RCLONE_CONFIG_R2_PROVIDER": "Cloudflare",
        "RCLONE_CONFIG_R2_ACCESS_KEY_ID": env["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY": env["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_R2_ENDPOINT": f"https://{env['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        "RCLONE_CONFIG_R2_REGION": "auto",
        "RCLONE_CONFIG_R2_NO_CHECK_BUCKET": "true",
    })
    return out


def _history_path(bucket: str, cluster: str) -> str:
    return f"r2:{bucket}/clusters/{cluster}/history/"


def _newest_history_key(files: list[dict]) -> dict | None:
    archives = [f for f in files if (f.get("Name") or "").endswith((".zip", ".tar.gz"))]
    if not archives:
        return None
    archives.sort(key=lambda f: f.get("Name") or "")
    return archives[-1]


def list_r2_clusters() -> list[dict]:
    env = read_env_file()
    if not r2_env_ready(env):
        return []
    bucket = env["R2_BUCKET"]
    rclone_env = r2_rclone_env(env)
    proc = subprocess.run(
        ["rclone", "lsjson", f"r2:{bucket}/clusters/", "--dirs-only"],
        capture_output=True, text=True, env=rclone_env, timeout=20,
    )
    if proc.returncode != 0:
        return []
    try:
        dirs = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return []
    out: list[dict] = []
    for d in dirs:
        name = d.get("Name") or d.get("Path")
        if not name:
            continue
        s = subprocess.run(
            ["rclone", "lsjson", _history_path(bucket, name), "--files-only"],
            capture_output=True, text=True, env=rclone_env, timeout=20,
        )
        if s.returncode != 0:
            continue
        try:
            files = json.loads(s.stdout or "[]")
        except json.JSONDecodeError:
            continue
        newest = _newest_history_key(files)
        if newest is None:
            continue
        out.append({
            "name": name,
            "size_mb": round(int(newest.get("Size", 0)) / (1024 * 1024), 1),
            "mtime": (newest.get("ModTime") or "")[:16].replace("T", " "),
            "newest_archive": newest.get("Name") or "",
            "history_count": len([f for f in files if (f.get("Name") or "").endswith((".zip", ".tar.gz"))]),
        })
    out.sort(key=lambda x: x["name"])
    return out


def list_r2_history(cluster_name: str) -> list[dict]:
    env = read_env_file()
    if not r2_env_ready(env):
        return []
    bucket = env["R2_BUCKET"]
    rclone_env = r2_rclone_env(env)
    proc = subprocess.run(
        ["rclone", "lsjson", _history_path(bucket, cluster_name), "--files-only"],
        capture_output=True, text=True, env=rclone_env, timeout=20,
    )
    if proc.returncode != 0:
        return []
    try:
        files = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return []
    sidecars = {f.get("Name") for f in files if (f.get("Name") or "").endswith(".mods.json")}
    out: list[dict] = []
    for f in files:
        n = f.get("Name") or ""
        if not n.endswith((".zip", ".tar.gz")):
            continue
        stem = n[:-len(".tar.gz")] if n.endswith(".tar.gz") else n[:-len(".zip")]
        out.append({
            "name": n,
            "size_mb": round(int(f.get("Size", 0)) / (1024 * 1024), 2),
            "mtime": (f.get("ModTime") or "")[:16].replace("T", " "),
            "sidecar": f"{stem}.mods.json" if f"{stem}.mods.json" in sidecars else None,
        })
    out.sort(key=lambda x: x["name"], reverse=True)
    return out


def read_r2_mods_sidecar(cluster_name: str, sidecar_name: str) -> dict:
    env = read_env_file()
    if not r2_env_ready(env):
        return {}
    bucket = env["R2_BUCKET"]
    rclone_env = r2_rclone_env(env)
    src = f"{_history_path(bucket, cluster_name)}{sidecar_name}"
    proc = subprocess.run(
        ["rclone", "cat", src],
        capture_output=True, text=True, env=rclone_env, timeout=15,
    )
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def fetch_r2_cluster_to(name: str, dest_dir: Path, archive_name: str | None = None) -> tuple[bool, str]:
    env = read_env_file()
    if not r2_env_ready(env):
        return False, "R2 env vars not set in .env"
    bucket = env["R2_BUCKET"]
    rclone_env = r2_rclone_env(env)

    if archive_name is None:
        s = subprocess.run(
            ["rclone", "lsjson", _history_path(bucket, name), "--files-only"],
            capture_output=True, text=True, env=rclone_env, timeout=20,
        )
        if s.returncode != 0:
            return False, f"rclone lsjson history: {s.stderr.strip() or 'unknown error'}"
        try:
            files = json.loads(s.stdout or "[]")
        except json.JSONDecodeError:
            return False, "could not parse rclone lsjson output"
        newest = _newest_history_key(files)
        if newest is None:
            return False, f"no archive under clusters/{name}/history/"
        archive_name = newest.get("Name") or ""

    src = f"{_history_path(bucket, name)}{archive_name}"
    suffix = ".tar.gz" if archive_name.endswith(".tar.gz") else ".zip"
    tmp = Path(f"/tmp/r2-fetch-{os.getpid()}-{name}{suffix}")
    try:
        proc = subprocess.run(
            ["rclone", "copyto", src, str(tmp), "--quiet"],
            capture_output=True, text=True, env=rclone_env, timeout=600,
        )
        if proc.returncode != 0:
            return False, f"rclone copyto {src}: {proc.stderr.strip() or 'unknown error'}"
        if not tmp.is_file() or tmp.stat().st_size == 0:
            return False, "downloaded archive is empty"
        extract_archive(tmp.read_bytes(), dest_dir)
        return True, f"restored {archive_name} ({tmp.stat().st_size // 1024} KiB)"
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def run_backup(tag: str = "manual") -> tuple[bool, str]:
    env = read_env_file()
    if not r2_env_ready(env):
        return False, "R2 env vars not set in .env"
    if not cluster_is_ready():
        return False, f"cluster '{CLUSTER_NAME}' not provisioned yet"
    rclone_env = r2_rclone_env(env)
    bucket = env["R2_BUCKET"]
    ts = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    fname = f"{ts}-{tag}.zip"
    tmp = Path(f"/tmp/backup-{ts}-{tag}.zip")
    try:
        cd = cluster_dir()
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for fp in cd.rglob("*"):
                if fp.is_file() and fp.name not in ARCHIVE_JUNK:
                    zf.write(fp, arcname=str(Path(CLUSTER_NAME) / fp.relative_to(cd)))
        hist_dst = f"{_history_path(bucket, CLUSTER_NAME)}{fname}"
        proc = subprocess.run(
            ["rclone", "copyto", str(tmp), hist_dst, "--quiet"],
            capture_output=True, text=True, env=rclone_env, timeout=600,
        )
        if proc.returncode != 0:
            return False, f"rclone failed: {proc.stderr.strip()}"
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
    return True, f"backup pushed ({fname})"
```

- [ ] **Step 4**: run tests — expect pass after Task B.6 lands cluster.py. The import `from app.cluster import …` requires cluster.py to exist for tests that don't touch it. Workaround: write a tiny `app/cluster.py` stub now with `read_env_file` and `cluster_dir`/`cluster_is_ready` placeholders.

Actually, defer r2.py tests until B.6 lands. Mark this task complete after B.6 verifies r2 tests still pass.

For now, write a minimal cluster.py stub so import resolves:

```python
# admin/app/cluster.py — STUB, fleshed out in Task B.6
from pathlib import Path
import os
DATA = Path(os.environ.get("DATA_DIR", "/data"))

def read_env_file() -> dict:
    env_path = DATA / ".env"
    if not env_path.is_file():
        return {}
    out = {}
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out

def cluster_dir() -> Path:
    return DATA / "saves" / os.environ.get("CLUSTER_NAME", "qkation-cooperative")

def cluster_is_ready() -> bool:
    cd = cluster_dir()
    return (cd / "cluster.ini").is_file() and (cd / "Master" / "server.ini").is_file() and (cd / "Caves" / "server.ini").is_file()
```

```bash
cd admin && .venv/bin/pytest tests/test_r2.py -v
```

Expected: 7 passed.

- [ ] **Step 5**: commit

```bash
git add admin/tests/test_r2.py admin/app/r2.py admin/app/cluster.py
git commit -m "feat(admin): r2.py — env/rclone wrappers, list/fetch/restore, NO_CHECK_BUCKET mandatory"
```

---

### Task B.6: cluster.py + tests (TDD, 7 tests)

**Files:**
- Create: `admin/tests/test_cluster.py`
- Modify: `admin/app/cluster.py` (expand from stub)

- [ ] **Step 1**: write `admin/tests/test_cluster.py`

```python
from __future__ import annotations

import logging
from pathlib import Path

import pytest

from app import cluster


def _make_cluster(root: Path, *, has_master_ini=True, has_caves_ini=True, has_cluster_ini=True):
    cd = root / "saves" / "testcluster"
    (cd / "Master").mkdir(parents=True)
    (cd / "Caves").mkdir()
    if has_cluster_ini:
        (cd / "cluster.ini").write_text(
            "[GAMEPLAY]\ngame_mode = survival\nmax_players = 10\npvp = true\n\n"
            "[NETWORK]\ncluster_name = testcluster\ncluster_password = secret\n"
            "cluster_description = hello world\n",
            encoding="utf-8",
        )
    if has_master_ini:
        (cd / "Master" / "server.ini").write_text("[NETWORK]\nserver_port = 10999\n", encoding="utf-8")
    if has_caves_ini:
        (cd / "Caves" / "server.ini").write_text("[NETWORK]\nserver_port = 10998\n", encoding="utf-8")
    return cd


def test_cluster_is_ready_requires_all_three(tmp_path, monkeypatch):
    _make_cluster(tmp_path)
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    assert cluster.cluster_is_ready() is True


def test_cluster_is_ready_missing_caves(tmp_path, monkeypatch):
    _make_cluster(tmp_path, has_caves_ini=False)
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    assert cluster.cluster_is_ready() is False


def test_list_parked_marks_invalid_when_missing(tmp_path, monkeypatch):
    parked = tmp_path / "parked" / "incomplete"
    parked.mkdir(parents=True)
    (parked / "cluster.ini").write_text("ok")
    # No Master/server.ini or Caves/server.ini → invalid.
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    out = cluster.list_parked()
    assert len(out) == 1
    assert out[0]["name"] == "incomplete"
    assert out[0]["valid"] is False


def test_list_parked_valid_when_all_present(tmp_path, monkeypatch):
    parked = tmp_path / "parked" / "good"
    (parked / "Master").mkdir(parents=True)
    (parked / "Caves").mkdir()
    (parked / "cluster.ini").write_text("ok")
    (parked / "Master" / "server.ini").write_text("ok")
    (parked / "Caves" / "server.ini").write_text("ok")
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    out = cluster.list_parked()
    assert out[0]["valid"] is True


def test_read_active_settings_defaults_when_no_ini(tmp_path, monkeypatch):
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    out = cluster.read_active_cluster_settings()
    assert out == cluster.WIZARD_DEFAULTS | {"cluster_name": "testcluster", "password": "testcluster"}


def test_read_active_settings_reads_live_values(tmp_path, monkeypatch):
    _make_cluster(tmp_path)
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    out = cluster.read_active_cluster_settings()
    assert out["game_mode"] == "survival"
    assert out["max_players"] == 10
    assert out["pvp"] is True
    assert out["password"] == "secret"
    assert out["description"] == "hello world"


def test_read_active_settings_logs_on_parse_error(tmp_path, monkeypatch, caplog):
    cd = tmp_path / "saves" / "testcluster"
    (cd / "Master").mkdir(parents=True)
    (cd / "Caves").mkdir()
    (cd / "cluster.ini").write_text("not\nactually\nini\nformat[broken")
    (cd / "Master" / "server.ini").write_text("ok")
    (cd / "Caves" / "server.ini").write_text("ok")
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    monkeypatch.setenv("CLUSTER_NAME", "testcluster")
    with caplog.at_level(logging.WARNING):
        out = cluster.read_active_cluster_settings()
    assert any("parse error" in rec.message.lower() for rec in caplog.records)
    # Defaults returned despite the broken file (but the warning was logged).
    assert out["game_mode"] == cluster.WIZARD_DEFAULTS["game_mode"]
```

- [ ] **Step 2**: run — expect fails

- [ ] **Step 3**: rewrite `admin/app/cluster.py` (full version)

```python
"""Cluster + parked + env operations. Pure file IO + INI parsing; no
podman / no rclone calls. Routes call into here; tests cover the
contract directly via tmp_path fixtures."""
from __future__ import annotations

import configparser
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

DATA = Path(os.environ.get("DATA_DIR", "/data"))


def _cluster_name() -> str:
    return os.environ.get("CLUSTER_NAME", "qkation-cooperative")


def cluster_dir() -> Path:
    return DATA / "saves" / _cluster_name()


def cluster_is_ready() -> bool:
    cd = cluster_dir()
    return (
        (cd / "cluster.ini").is_file()
        and (cd / "Master" / "server.ini").is_file()
        and (cd / "Caves" / "server.ini").is_file()
    )


def shard_status() -> dict[str, bool]:
    cd = cluster_dir()
    return {
        "cluster_ini": (cd / "cluster.ini").is_file(),
        "master": (cd / "Master" / "server.ini").is_file(),
        "caves":  (cd / "Caves"  / "server.ini").is_file(),
    }


def read_env_file() -> dict[str, str]:
    env_path = DATA / ".env"
    if not env_path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def list_parked() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    parked_dir = DATA / "parked"
    if not parked_dir.exists():
        return out
    for child in sorted(parked_dir.iterdir()):
        if not child.is_dir():
            continue
        st = child.stat()
        has_cluster_ini = (child / "cluster.ini").is_file()
        has_master = (child / "Master" / "server.ini").is_file()
        has_caves  = (child / "Caves"  / "server.ini").is_file()
        size_mb = round(
            sum(f.stat().st_size for f in child.rglob("*") if f.is_file()) / (1024 * 1024),
            2,
        )
        out.append({
            "name": child.name,
            "mtime": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat(),
            "valid": has_cluster_ini and has_master and has_caves,
            "has_master": has_master,
            "has_caves":  has_caves,
            "size_mb": size_mb,
        })
    return out


WIZARD_DEFAULTS: dict[str, Any] = {
    "cluster_name": "qkation-cooperative",
    "password":     "qkation-cooperative",
    "max_players":  6,
    "game_mode":    "relaxed",
    "pvp":          False,
    "description":  "Friendly cooperative world.",
}


def read_active_cluster_settings() -> dict[str, Any]:
    out = dict(WIZARD_DEFAULTS)
    name = _cluster_name()
    out["cluster_name"] = name
    out["password"] = name  # default mirrors old behavior
    ini = cluster_dir() / "cluster.ini"
    if not ini.is_file():
        return out
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    try:
        cp.read(ini, encoding="utf-8")
    except (configparser.Error, OSError) as exc:
        # Fix for latent issue #2 in CREATE/potential_issues.md — log loudly
        # instead of silently falling back. UI route should surface this in
        # the wizard banner so the user knows defaults were used.
        logger.warning("cluster.ini parse error at %s: %s — returning defaults", ini, exc)
        return out
    g = cp["GAMEPLAY"] if "GAMEPLAY" in cp else {}
    n = cp["NETWORK"]  if "NETWORK"  in cp else {}
    if "game_mode"          in g: out["game_mode"]   = g["game_mode"].strip()
    if "pvp"                in g: out["pvp"]         = g["pvp"].strip().lower() == "true"
    if "cluster_password"   in n: out["password"]    = n["cluster_password"].strip()
    if "cluster_description" in n: out["description"] = n["cluster_description"].strip()
    if "cluster_name"       in n:
        v = n["cluster_name"].strip()
        if v: out["cluster_name"] = v
    if "max_players" in g:
        try:
            out["max_players"] = int(g["max_players"].strip())
        except ValueError:
            pass
    return out
```

- [ ] **Step 4**: run all tests so far

```bash
cd admin && .venv/bin/pytest tests/ -v
```

Expected: archive (9) + mods (5) + r2 (7) + cluster (7) = 28 passed.

- [ ] **Step 5**: commit

```bash
git add admin/tests/test_cluster.py admin/app/cluster.py
git commit -m "feat(admin): cluster.py — parked listing, env read, wizard prefill (logs parse errors)"
```

---

### Task B.6.5: cluster.py — template wizard writer + INI/Lua templates

**Files:**
- Modify: `admin/app/cluster.py` (append templates + writer)
- Modify: `admin/tests/test_cluster.py` (append 2 tests)

- [ ] **Step 1**: write tests for the template writer

Append to `admin/tests/test_cluster.py`:

```python
def test_write_template_cluster_creates_files(tmp_path, monkeypatch):
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    dest = tmp_path / "saves" / "testcluster"
    cluster.write_template_cluster(
        dest, cluster_name="testcluster", password="pw",
        max_players=8, game_mode="survival", pvp=False,
        description="Hello world",
    )
    assert (dest / "cluster.ini").is_file()
    assert (dest / "Master" / "server.ini").is_file()
    assert (dest / "Caves" / "server.ini").is_file()
    assert (dest / "Master" / "modoverrides.lua").is_file()
    assert (dest / "Caves" / "modoverrides.lua").is_file()
    assert (dest / "Caves" / "worldgenoverride.lua").is_file()
    ini = (dest / "cluster.ini").read_text()
    assert "cluster_name = testcluster" in ini
    assert "game_mode = survival" in ini
    assert "max_players = 8" in ini


def test_write_template_cluster_random_key_per_call(tmp_path, monkeypatch):
    monkeypatch.setattr(cluster, "DATA", tmp_path)
    dest1 = tmp_path / "saves" / "a"
    dest2 = tmp_path / "saves" / "b"
    cluster.write_template_cluster(dest1, cluster_name="a", password="", max_players=6,
                                    game_mode="relaxed", pvp=False, description="")
    cluster.write_template_cluster(dest2, cluster_name="b", password="", max_players=6,
                                    game_mode="relaxed", pvp=False, description="")
    key1 = [l for l in (dest1 / "cluster.ini").read_text().splitlines() if l.startswith("cluster_key")][0]
    key2 = [l for l in (dest2 / "cluster.ini").read_text().splitlines() if l.startswith("cluster_key")][0]
    assert key1 != key2  # randomness check
```

- [ ] **Step 2**: run tests — expect fails

- [ ] **Step 3**: append to `admin/app/cluster.py`:

```python
import secrets

CLUSTER_INI_TEMPLATE = """\
[GAMEPLAY]
game_mode = {game_mode}
max_players = {max_players}
pvp = {pvp}
pause_when_empty = true
vote_enabled = true

[NETWORK]
cluster_name = {cluster_name}
cluster_description = {cluster_description}
cluster_password = {password}
cluster_intention = cooperative
lan_only_cluster = false
offline_cluster = false

[MISC]
console_enabled = true

[SHARD]
shard_enabled = true
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10888
cluster_key = {cluster_key}
"""

MASTER_SERVER_INI = """\
[NETWORK]
server_port = 10999

[SHARD]
is_master = true
name = Master

[STEAM]
authentication_port = 8766
master_server_port = 27016
"""

CAVES_SERVER_INI = """\
[NETWORK]
server_port = 10998

[SHARD]
is_master = false
name = Caves

[STEAM]
authentication_port = 8768
master_server_port = 27018
"""

MODOVERRIDES_EMPTY = "return {\n}\n"
WORLDGENOVERRIDE_CAVES = 'return {\n  override_enabled = true,\n  preset = "DST_CAVE",\n}\n'


def write_template_cluster(
    dest: Path, *, cluster_name: str, password: str, max_players: int,
    game_mode: str, pvp: bool, description: str,
) -> None:
    """Write cluster.ini + both shard server.ini + per-shard modoverrides
    + Caves worldgenoverride into `dest`. Generates a fresh random
    cluster_key per call (shard auth secret). Caller ensures dest does
    NOT pre-exist."""
    (dest / "Master").mkdir(parents=True, exist_ok=False)
    (dest / "Caves").mkdir(parents=True, exist_ok=False)
    cluster_key = secrets.token_hex(16)
    (dest / "cluster.ini").write_text(
        CLUSTER_INI_TEMPLATE.format(
            cluster_name=cluster_name,
            cluster_description=description.replace("\n", " "),
            password=password,
            game_mode=game_mode,
            max_players=max_players,
            pvp="true" if pvp else "false",
            cluster_key=cluster_key,
        ),
        encoding="utf-8",
    )
    (dest / "Master" / "server.ini").write_text(MASTER_SERVER_INI, encoding="utf-8")
    (dest / "Caves"  / "server.ini").write_text(CAVES_SERVER_INI,  encoding="utf-8")
    (dest / "Master" / "modoverrides.lua").write_text(MODOVERRIDES_EMPTY, encoding="utf-8")
    (dest / "Caves"  / "modoverrides.lua").write_text(MODOVERRIDES_EMPTY, encoding="utf-8")
    (dest / "Caves"  / "worldgenoverride.lua").write_text(WORLDGENOVERRIDE_CAVES, encoding="utf-8")
    (dest / "adminlist.txt").write_text("", encoding="utf-8")
```

- [ ] **Step 4**: run tests — expect 2 new passes (total cluster: 9)

```bash
cd admin && .venv/bin/pytest tests/test_cluster.py -v
```

- [ ] **Step 5**: commit

```bash
git add admin/app/cluster.py admin/tests/test_cluster.py
git commit -m "feat(admin): cluster.py write_template_cluster + INI/Lua templates"
```

---

### Task B.7: main.py — FastAPI routes wiring the four modules

**Files:**
- Create: `admin/app/main.py`

Routes — copy structure from `git show origin/master:admin/app/main.py` but call into the new modules. No business logic in this file — routes call `cluster.*`, `r2.*`, `mods.*`, `archive.*`.

- [ ] **Step 1**: write `admin/app/main.py`

```python
"""FastAPI app. Routes only — business logic lives in cluster.py, r2.py,
mods.py, archive.py. Dashboard template gets context wired here.

Authentication: HTTP Basic. ADMIN_USER + ADMIN_PASSWORD from .env via
read_env_file. No password = endpoint returns 500 (fail-closed).
"""
from __future__ import annotations

import io
import json
import logging
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import (
    Depends, FastAPI, File, Form, HTTPException, Request, Response, UploadFile,
)
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.archive import extract_archive, ARCHIVE_JUNK, UnsafeArchive
from app.cluster import (
    DATA, WIZARD_DEFAULTS, cluster_dir, cluster_is_ready, list_parked,
    read_active_cluster_settings, read_env_file, shard_status,
)
from app.mods import summarize_mods
from app.r2 import (
    fetch_r2_cluster_to, list_r2_clusters, list_r2_history,
    r2_env_ready, read_r2_mods_sidecar, run_backup,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

APP_ROOT = Path(__file__).parent
TEMPLATES = Jinja2Templates(directory=str(APP_ROOT / "templates"))

DST_CONTAINER = os.environ.get("DST_CONTAINER", "dst")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "qkation-cooperative")
PARKED_DIR = DATA / "parked"
SAVES_DIR = DATA / "saves"
MODS_DIR = DATA / "mods"

app = FastAPI(title="DST admin", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(APP_ROOT / "static")), name="static")

security = HTTPBasic()


def require_auth(creds: HTTPBasicCredentials = Depends(security)) -> str:
    env = read_env_file()
    user = env.get("ADMIN_USER", "dst")
    pw = env.get("ADMIN_PASSWORD")
    if not pw:
        raise HTTPException(status_code=500, detail="ADMIN_PASSWORD not set")
    if creds.username != user or creds.password != pw:
        raise HTTPException(status_code=401, headers={"WWW-Authenticate": "Basic"})
    return creds.username


def safe_name(s: str) -> str:
    bad = set('/\\:*?"<>|')
    out = "".join(c for c in s if c not in bad and c.isprintable())
    return out.strip()[:64] or "unnamed"


def podman(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Subprocess wrapper. Returns CompletedProcess; caller decides policy.
    No silent catches here — see CREATE/AGENTS.md anti-defensive section."""
    return subprocess.run(["podman", *args], capture_output=True, text=True, timeout=timeout)


def _dst_status() -> dict[str, Any]:
    proc = podman("inspect", DST_CONTAINER, "--format", "{{.State.Status}}|{{.State.StartedAt}}")
    if proc.returncode != 0:
        return {"exists": False, "state": "absent", "started_at": None}
    state, started = (proc.stdout.strip().split("|", 1) + [""])[:2]
    return {"exists": True, "state": state, "started_at": started or None}


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, _: str = Depends(require_auth)) -> HTMLResponse:
    env = read_env_file()
    cd = cluster_dir()
    adminlist = (cd / "adminlist.txt").read_text(encoding="utf-8") if (cd / "adminlist.txt").is_file() else ""
    mods_setup = (MODS_DIR / "dedicated_server_mods_setup.lua").read_text(encoding="utf-8") if (MODS_DIR / "dedicated_server_mods_setup.lua").is_file() else ""
    mom = (cd / "Master" / "modoverrides.lua").read_text(encoding="utf-8") if (cd / "Master" / "modoverrides.lua").is_file() else ""
    moc = (cd / "Caves" / "modoverrides.lua").read_text(encoding="utf-8") if (cd / "Caves" / "modoverrides.lua").is_file() else ""
    return TEMPLATES.TemplateResponse(
        request=request, name="index.html",
        context={
            "cluster_name": CLUSTER_NAME,
            "cluster_ready": cluster_is_ready(),
            "cluster_exists": cluster_dir().exists(),
            "shards": shard_status(),
            "dst": _dst_status(),
            "parked": list_parked(),
            "r2_clusters": list_r2_clusters(),
            "r2_ready": r2_env_ready(env),
            "wizard": read_active_cluster_settings(),
            "mod_summary": summarize_mods(),
            "adminlist": adminlist,
            "mods_setup": mods_setup,
            "modoverrides_master": mom,
            "modoverrides_caves": moc,
            "env_keys": sorted(env.keys()),
        },
    )


@app.get("/api/status")
def api_status(_: str = Depends(require_auth)) -> Response:
    return Response(content=json.dumps({
        "dst": _dst_status(),
        "cluster_ready": cluster_is_ready(),
        "cluster_exists": cluster_dir().exists(),
        "shards": shard_status(),
        "r2_ready": r2_env_ready(read_env_file()),
        "logs": {"container": [], "master": [], "caves": []},
        "ts": datetime.now(timezone.utc).isoformat(),
    }), media_type="application/json")


@app.post("/server/start")
def server_start(_: str = Depends(require_auth)) -> RedirectResponse:
    podman("start", DST_CONTAINER)
    return RedirectResponse("/", status_code=303)


@app.post("/server/stop")
def server_stop(_: str = Depends(require_auth)) -> RedirectResponse:
    podman("stop", "-t", "90", DST_CONTAINER, timeout=120)
    return RedirectResponse("/", status_code=303)


@app.post("/server/restart")
def server_restart(_: str = Depends(require_auth)) -> RedirectResponse:
    podman("restart", "-t", "90", DST_CONTAINER, timeout=120)
    return RedirectResponse("/", status_code=303)


@app.post("/backup/trigger")
def backup_trigger(_: str = Depends(require_auth)) -> RedirectResponse:
    ok, msg = run_backup("manual")
    if not ok:
        raise HTTPException(status_code=502, detail=msg)
    return RedirectResponse("/", status_code=303)


@app.post("/cluster/upload")
async def cluster_upload(
    archive_field: UploadFile = File(..., alias="archive"),
    park_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(park_name)
    dest = PARKED_DIR / name
    if dest.exists():
        raise HTTPException(status_code=409, detail=f"Parked slot '{name}' exists")
    raw = await archive_field.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty upload")
    try:
        extract_archive(raw, dest)
    except UnsafeArchive as exc:
        shutil.rmtree(dest, ignore_errors=True)
        raise HTTPException(status_code=400, detail=str(exc))
    except ValueError as exc:
        shutil.rmtree(dest, ignore_errors=True)
        raise HTTPException(status_code=400, detail=str(exc))
    return RedirectResponse("/", status_code=303)


@app.post("/cluster/r2-restore")
def cluster_r2_restore(
    cluster_name: str = Form(...),
    archive_name: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(cluster_name)
    arch = archive_name.strip() or None
    staging = SAVES_DIR / f".r2-staging-{os.getpid()}-{name}"
    if staging.exists():
        shutil.rmtree(staging)
    ok, msg = fetch_r2_cluster_to(name, staging, archive_name=arch)
    if not ok:
        shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(status_code=502, detail=msg)
    if not (staging / "cluster.ini").is_file():
        shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(status_code=400, detail=f"R2 backup '{name}' has no cluster.ini after extract")
    podman("stop", "-t", "90", DST_CONTAINER, timeout=120)
    cd = cluster_dir()
    if cd.exists():
        ts = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        PARKED_DIR.mkdir(exist_ok=True)
        shutil.move(str(cd), str(PARKED_DIR / f"{CLUSTER_NAME}-archived-{ts}"))
    SAVES_DIR.mkdir(exist_ok=True)
    shutil.move(str(staging), str(cd))
    podman("start", DST_CONTAINER)
    return RedirectResponse("/", status_code=303)


@app.post("/cluster/r2-park")
def cluster_r2_park(
    cluster_name: str = Form(...),
    archive_name: str = Form(""),
    park_name: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    src = safe_name(cluster_name)
    dest_name = safe_name(park_name) if park_name else src
    PARKED_DIR.mkdir(exist_ok=True)
    dest = PARKED_DIR / dest_name
    if dest.exists():
        raise HTTPException(status_code=409, detail=f"Parked slot '{dest_name}' exists")
    ok, msg = fetch_r2_cluster_to(src, dest, archive_name=archive_name.strip() or None)
    if not ok:
        shutil.rmtree(dest, ignore_errors=True)
        raise HTTPException(status_code=502, detail=msg)
    return RedirectResponse("/", status_code=303)


@app.get("/api/r2/history/{cluster_name}")
def api_r2_history(cluster_name: str, _: str = Depends(require_auth)) -> Response:
    return Response(
        content=json.dumps({"cluster": safe_name(cluster_name), "history": list_r2_history(safe_name(cluster_name))}),
        media_type="application/json",
    )


@app.get("/api/r2/mods/{cluster_name}/{sidecar}")
def api_r2_mods(cluster_name: str, sidecar: str, _: str = Depends(require_auth)) -> Response:
    if not sidecar.endswith(".mods.json") or "/" in sidecar or ".." in sidecar:
        raise HTTPException(status_code=400, detail="invalid sidecar name")
    return Response(
        content=json.dumps(read_r2_mods_sidecar(safe_name(cluster_name), sidecar)),
        media_type="application/json",
    )


@app.post("/cluster/template")
def cluster_template(
    cluster_name: str = Form(...),
    password: str = Form(""),
    max_players: int = Form(6),
    game_mode: str = Form("relaxed"),
    pvp: bool = Form(False),
    description: str = Form(""),
    target: str = Form("active"),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    from app.cluster import write_template_cluster
    name = safe_name(cluster_name)
    if max_players < 1 or max_players > 64:
        raise HTTPException(status_code=400, detail="max_players out of range (1-64)")
    if game_mode not in {"relaxed", "survival", "endless", "wilderness"}:
        raise HTTPException(status_code=400, detail="invalid game_mode")
    if target == "parked":
        PARKED_DIR.mkdir(exist_ok=True)
        dest = PARKED_DIR / name
        if dest.exists():
            raise HTTPException(status_code=409, detail=f"Parked '{name}' already exists")
        write_template_cluster(dest, cluster_name=name, password=password,
                                max_players=max_players, game_mode=game_mode,
                                pvp=pvp, description=description)
    else:
        if cluster_is_ready():
            raise HTTPException(status_code=409, detail="active cluster exists; park first or use target=parked")
        SAVES_DIR.mkdir(exist_ok=True)
        write_template_cluster(cluster_dir(), cluster_name=name, password=password,
                                max_players=max_players, game_mode=game_mode,
                                pvp=pvp, description=description)
    return RedirectResponse("/", status_code=303)


@app.post("/admins")
def admins_save(adminlist: str = Form(""), _: str = Depends(require_auth)) -> RedirectResponse:
    if not cluster_is_ready():
        raise HTTPException(status_code=400, detail="Cluster not provisioned")
    cleaned = [l.strip() for l in adminlist.splitlines() if l.strip().startswith("KU_")]
    (cluster_dir() / "adminlist.txt").write_text("\n".join(cleaned) + ("\n" if cleaned else ""), encoding="utf-8")
    return RedirectResponse("/", status_code=303)


@app.post("/mods")
def mods_save(
    mods_setup: str = Form(""),
    modoverrides_master: str = Form(""),
    modoverrides_caves: str = Form(""),
    restart: str = Form("0"),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    MODS_DIR.mkdir(exist_ok=True)
    (MODS_DIR / "dedicated_server_mods_setup.lua").write_text(mods_setup, encoding="utf-8")
    if cluster_is_ready():
        cd = cluster_dir()
        (cd / "Master" / "modoverrides.lua").write_text(modoverrides_master, encoding="utf-8")
        (cd / "Caves"  / "modoverrides.lua").write_text(modoverrides_caves,  encoding="utf-8")
    if restart == "1":
        # Fix for latent issue #1 — restart failure surfaces as 500, not silent redirect.
        proc = podman("restart", "-t", "90", DST_CONTAINER, timeout=120)
        if proc.returncode != 0:
            raise HTTPException(status_code=500, detail=f"podman restart failed: {proc.stderr.strip()}")
    return RedirectResponse("/", status_code=303)
```

- [ ] **Step 2**: run all admin tests still pass (no new tests for main.py; routes are integration-tested via VPS smoke)

```bash
cd admin && .venv/bin/pytest tests/ -v
```

- [ ] **Step 3**: commit

```bash
git add admin/app/main.py
git commit -m "feat(admin): main.py — FastAPI routes wiring cluster/r2/mods/archive modules"
```

---

### Task B.8: templates/index.html

**Files:**
- Create: `admin/app/templates/index.html`

- [ ] **Step 1**: port `index.html` from `git show origin/master:admin/app/templates/index.html`. Adjust for the route/context names used in `main.py` above. Verify all `{{ wizard.x }}`, `{{ r2_clusters }}`, `{{ mod_summary }}`, `{{ parked }}`, `{{ shards }}`, `{{ dst }}`, etc. tokens resolve against the dashboard context.

Reference: full template from master branch; new modular context provides the same keys.

- [ ] **Step 2**: render check (offline)

```bash
cd admin && .venv/bin/python -c "
from jinja2 import Environment, FileSystemLoader
env = Environment(loader=FileSystemLoader('app/templates'))
env.get_template('index.html')
print('parse OK')
"
```

Expected: `parse OK`.

- [ ] **Step 3**: commit

```bash
git add admin/app/templates/index.html
git commit -m "feat(admin): index.html — dashboard template (ported from master, modular context)"
```

---

### Task B.9: static/style.css

**Files:**
- Create: `admin/app/static/style.css`

- [ ] **Step 1**: port from `git show origin/master:admin/app/static/style.css`.

- [ ] **Step 2**: commit

```bash
git add admin/app/static/style.css
git commit -m "feat(admin): style.css (ported from master)"
```

---

### Task B.10: Dockerfile + docker-compose.yml

**Files:**
- Create: `admin/Dockerfile`, `admin/docker-compose.yml`

- [ ] **Step 1**: write `admin/Dockerfile`

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      podman rclone ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

- [ ] **Step 2**: write `admin/docker-compose.yml`

```yaml
# Admin panel stack. Separate compose from DST.
# DO NOT add :U to the /data bind mount — see CREATE/CREATE.md §10 invariant 4.
services:
  admin:
    build:
      context: .
      platforms: ["linux/amd64"]
    image: local/dst-admin:latest
    platform: linux/amd64
    container_name: dst-admin
    restart: unless-stopped
    ports: ["8080:8080"]
    env_file:
      - ../.env
    environment:
      DST_CONTAINER: "${DST_CONTAINER:-dst}"
      CLUSTER_NAME: "${CLUSTER_NAME:-qkation-cooperative}"
      DATA_DIR: /data
    volumes:
      - ..:/data
      - ${XDG_RUNTIME_DIR:-/run/user/1000}/podman/podman.sock:/run/podman/podman.sock
```

- [ ] **Step 3**: commit

```bash
git add admin/Dockerfile admin/docker-compose.yml
git commit -m "feat(admin): Dockerfile + compose (no :U on /data, mounts podman socket)"
```

---

### Task B.SMOKE: build + run + curl

**Files:** none modified

- [ ] **Step 1**: build

```bash
podman build --platform=linux/amd64 -t local/dst-admin:latest admin
```

Expected: succeeds.

- [ ] **Step 2**: pytest summary

```bash
cd admin && .venv/bin/pytest tests/ -v --tb=short
```

Expected: ≥22 passed.

- [ ] **Step 3** (VPS only): run admin against a real DST setup, hit endpoints. Documented; not blocking task completion on dev box.

Role B complete when steps 1-2 pass.

---

## Role C — bootstrap

### Task C.1: bootstrap.vars.example

**Files:**
- Create: `bootstrap/bootstrap.vars.example`

- [ ] **Step 1**: write file

```bash
# Pre-fill and pass via: sudo ./bootstrap.sh --vars /root/bootstrap.vars
# This file is the template — copy to bootstrap.vars and fill in.

CLUSTER_NAME=qkation-cooperative
CLUSTER_TOKEN=
ADMIN_PASSWORD=

R2_ACCOUNT_ID=
R2_BUCKET=dst
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=

# Optional Beszel monitoring (NOT YET REWRITTEN in this branch)
INSTALL_BESZEL=n
BESZEL_USER_EMAIL=admin@dst.local
```

- [ ] **Step 2**: commit

```bash
git add bootstrap/bootstrap.vars.example
git commit -m "feat(bootstrap): bootstrap.vars.example template"
```

---

### Task C.2: vultr-bootstrap.sh

**Files:**
- Create: `bootstrap/vultr-bootstrap.sh`

Port `CREATE/old/vultr-bootstrap.sh` (411 lines) but apply rules from the design spec:
- `passt` in apt list (rake fix)
- `podman-restart.service` enabled for dst (reboot recovery)
- `podman-api-dst.service` system unit (uses `rm -rf` not `rm -f` for socket cleanup)
- `set -a; . .env; set +a` subshells for every compose-up
- `podman-compose down` before `up -d` for every stack
- Pre-touch `monitoring/.env` only if `INSTALL_BESZEL=y` (Beszel is deferred — keep guard)
- INSTALL_BESZEL=n skips the entire Beszel block

- [ ] **Step 1**: write the file. Use `CREATE/old/vultr-bootstrap.sh` as starting point; apply the deltas listed above. Final file ~430 lines.

(Code excerpt for the key delta sections — full file ported from old/, these blocks REPLACE the originals:)

```bash
# apt section — passt added, libcurl3-gnutls not needed (host doesn't run DST binary)
apt-get install -y --no-install-recommends \
    podman podman-compose git rsync ca-certificates curl jq uidmap ufw \
    slirp4netns passt fuse-overlayfs dbus-user-session systemd-container

# podman-restart.service for reboot recovery (new vs old)
loginctl enable-linger "$DST_USER"
systemctl --user --machine="${DST_USER}@.host" enable podman-restart.service \
    >/dev/null 2>&1 || warn "could not enable podman-restart.service"

# podman-api-dst.service unit — rm -rf in ExecStartPre (rake fix)
cat > /etc/systemd/system/podman-api-dst.service <<UNIT
[Unit]
Description=Podman REST API socket for user ${DST_USER} (bootstrap-managed)
After=network-online.target user-runtime-dir@${DST_UID}.service
Wants=network-online.target user-runtime-dir@${DST_UID}.service
[Service]
Type=exec
User=${DST_USER}
Group=${DST_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${DST_UID}
ExecStartPre=/bin/mkdir -p /run/user/${DST_UID}/podman
ExecStartPre=/bin/chown -R ${DST_USER}:${DST_USER} /run/user/${DST_UID}/podman
ExecStartPre=-/bin/rm -rf /run/user/${DST_UID}/podman/podman.sock
ExecStart=/usr/bin/podman system service --time=0 unix:///run/user/${DST_UID}/podman/podman.sock
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now podman-api-dst.service

# Admin compose — down first, source .env for parse-time substitution
as_dst bash -c "set -a; . '$TARGET/.env'; set +a; cd '$TARGET/admin' && podman-compose down 2>/dev/null || true"
as_dst bash -c "set -a; . '$TARGET/.env'; set +a; cd '$TARGET/admin' && podman-compose up -d"

# Beszel guard
if [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]]; then
    warn "Beszel install requested but Beszel is not yet rewritten in this branch."
    warn "Skipping. Re-run after Beszel is re-added."
fi
```

The full ported script body lives in the committed file; the agent executing this task reads `CREATE/old/vultr-bootstrap.sh` and applies the deltas above, mechanically.

- [ ] **Step 2**: shellcheck + chmod

```bash
shellcheck bootstrap/vultr-bootstrap.sh && chmod +x bootstrap/vultr-bootstrap.sh
```

- [ ] **Step 3**: commit

```bash
git add bootstrap/vultr-bootstrap.sh
git commit -m "feat(bootstrap): vultr-bootstrap.sh — ports old/ with passt, restart.service, rm -rf, down-before-up"
```

---

### Task C.3: vultr-startup-script.sh wrapper

**Files:**
- Create: `bootstrap/vultr-startup-script.sh`

- [ ] **Step 1**: write thin wrapper that bakes in vars + invokes `vultr-bootstrap.sh`.

Port `CREATE/old/vultr-startup-script.sh` directly; only line that needs review is the `RAW_URL` at the top pointing at the GitHub master. Update to point at `re-create` branch for staging, OR keep `master` if the rewrite has been merged.

- [ ] **Step 2**: shellcheck

- [ ] **Step 3**: commit

```bash
git add bootstrap/vultr-startup-script.sh
git commit -m "feat(bootstrap): vultr-startup-script.sh wrapper"
```

---

### Task C.4: bootstrap/README.md

**Files:**
- Create: `bootstrap/README.md`

- [ ] **Step 1**: port `CREATE/old/` README content (the design spec references it in `CREATE/CREATE.md §3` for the three running modes). Update troubleshooting table to include the rakes from `CREATE/CREATE.md §7` (libcurl3-gnutls, passt, podman-restart, podman-ps-hang, __MACOSX).

- [ ] **Step 2**: commit

```bash
git add bootstrap/README.md
git commit -m "docs(bootstrap): README with three running modes + troubleshooting table"
```

---

### Task C.SMOKE: VPS

**Files:** none modified

- [ ] **Step 1**: provision fresh Ubuntu 24.04 Vultr VPS.

- [ ] **Step 2**: smoke per DoD §3-4

```bash
ssh root@<vps>
curl -fsSL https://raw.githubusercontent.com/<repo>/re-create/bootstrap/vultr-bootstrap.sh -o bootstrap.sh
curl -fsSL https://raw.githubusercontent.com/<repo>/re-create/bootstrap/bootstrap.vars.example -o bootstrap.vars
$EDITOR bootstrap.vars
chmod +x bootstrap.sh && sudo ./bootstrap.sh --vars /root/bootstrap.vars
# expect exit 0
podman ps     # expect dst + dst-admin Up
curl http://localhost:8080  # expect 401 then 200 with auth
sudo ./bootstrap.sh --vars /root/bootstrap.vars  # expect exit 0, no destructive ops
```

- [ ] **Step 3**: cross-role smoke — `docs/superpowers/specs/2026-05-10-dst-rewrite-design.md §Cross-role`.

Role C complete when smoke 1-3 pass.

---

## Final task: merge to master

- [ ] **Step 1**: invoke `superpowers:finishing-a-development-branch` to verify all tests + present merge/PR options.

- [ ] **Step 2**: open PR `re-create → master`. PR body lists role commits + DoD checklist + the locked decisions table from the spec.

- [ ] **Step 3**: merge after review.
