#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  monitoring/autowire.sh
#
#  Post-"podman-compose up" helper. Automates the one-time "Add new system"
#  dance that otherwise needs clicks in Beszel's web UI:
#
#     1. Wait for hub to respond on /api/health.
#     2. Fetch the hub's SSH public key (the agent trusts inbound connections
#        signed by it). Tries the API first; falls back to podman exec.
#     3. Write BESZEL_AGENT_KEY=<pubkey> into monitoring/.env.
#     4. Log in as the seeded admin user and POST a systems record pointing at
#        this host's local agent (127.0.0.1:45876). Idempotent - no-ops if a
#        record with the same name already exists.
#     5. Restart the agent so it picks up the key env var.
#
#  Credentials come from the project-root .env (ADMIN_PASSWORD, same as the
#  DST admin panel). Re-runnable: any step that's already done is skipped.
#
#  Requires: bash, curl, jq, podman / podman-compose.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_URL="${BESZEL_HUB_URL:-http://127.0.0.1:8090}"
SYSTEM_NAME="${BESZEL_SYSTEM_NAME:-$(hostname -s)}"
LOCAL_ENV="$MONITOR_DIR/.env"
PROJECT_ENV="$MONITOR_DIR/../.env"

log() { printf '[autowire-beszel] %s\n' "$*"; }
die() { printf '[autowire-beszel] ERROR: %s\n' "$*" >&2; exit 1; }

command -v jq    >/dev/null || die "jq not installed (apt install jq)"
command -v curl  >/dev/null || die "curl not installed"
[[ -f "$PROJECT_ENV" ]] || die "project .env missing at $PROJECT_ENV"

# shellcheck disable=SC1090
set -a; . "$PROJECT_ENV"; set +a

USER_EMAIL="${BESZEL_USER_EMAIL:-admin@dst.local}"
USER_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set in ../.env}"

# ---- 1. Wait for hub --------------------------------------------------------
log "waiting for hub at $HUB_URL"
for i in $(seq 1 60); do
    if curl -fsS "$HUB_URL/api/health" >/dev/null 2>&1; then
        log "hub responsive (${i}s)"
        break
    fi
    sleep 1
    (( i == 60 )) && die "hub not responding after 60s - is 'beszel' container up?"
done

# ---- 2. Authenticate with hub -----------------------------------------------
# Login *before* trying to fetch the pubkey: in newer Beszel builds
# /api/beszel/getkey is auth-only, so unauthenticated GETs come back as
# 401 + empty body and we'd silently fall through to file fallbacks. Try
# the superuser collection first (Beszel admin = PocketBase superuser),
# fall back to the regular users collection for older versions.
auth_json=""
AUTH_COLL=""
for coll in _superusers users; do
    if body=$(curl -fsS -X POST "$HUB_URL/api/collections/$coll/auth-with-password" \
            -H 'Content-Type: application/json' \
            -d "{\"identity\":\"$USER_EMAIL\",\"password\":\"$USER_PASSWORD\"}" 2>/dev/null); then
        if [[ $(echo "$body" | jq -r '.token // empty') ]]; then
            auth_json="$body"
            AUTH_COLL="$coll"
            break
        fi
    fi
done
[[ -n "$auth_json" ]] || die "login failed as $USER_EMAIL - check ADMIN_PASSWORD in ../.env"
TOKEN=$(echo "$auth_json"   | jq -r '.token')
USER_ID=$(echo "$auth_json" | jq -r '.record.id')
log "authenticated as $USER_EMAIL (collection=$AUTH_COLL, id=$USER_ID)"

# ---- 3. Fetch hub public key ------------------------------------------------
# The hub exposes its SSH public key in several places depending on version.
# Try every known path and log which one hit, so the next time this fails on
# a future Beszel version we can point at the actual location.
PUBKEY=""
PUBKEY_SOURCE=""
try_key_source() {
    local label="$1" out="$2"
    if [[ -n "$out" && "$out" == ssh-ed25519* ]]; then
        PUBKEY="$out"
        PUBKEY_SOURCE="$label"
        return 0
    fi
    return 1
}

# 3a. Authenticated /api/beszel/getkey (newer versions). Some builds also
# accept the same endpoint without auth - it's harmless to try unauth first
# in case auth itself broke against an older build, but the auth'd attempt
# is the most reliable.
for hdr in "Authorization: $TOKEN" ""; do
    if body=$(curl -fsS ${hdr:+-H "$hdr"} "$HUB_URL/api/beszel/getkey" 2>/dev/null); then
        candidate=$(echo "$body" | jq -r '.key // .data.key // empty' 2>/dev/null || true)
        if try_key_source "/api/beszel/getkey${hdr:+ (auth)}" "$candidate"; then break; fi
    fi
done

# 3b. Read from the hub container's filesystem. Beszel has shifted the path
# across releases - cover all the historical and current locations. We end
# with a wide find as a backstop so future relocations still work.
if [[ -z "$PUBKEY" ]]; then
    for path in \
        /beszel_data/id_ed25519.pub \
        /beszel_data/pb_data/id_ed25519.pub \
        /beszel_data/data/id_ed25519.pub \
        /beszel_data/keys/id_ed25519.pub \
        /data/id_ed25519.pub \
        /pb_data/id_ed25519.pub
    do
        if cand=$(podman exec beszel cat "$path" 2>/dev/null); then
            try_key_source "podman exec beszel cat $path" "$cand" && break
        fi
    done
fi

# 3c. Last-resort wide search inside the container. Slow on a populated FS
# but Beszel data dir is tiny.
if [[ -z "$PUBKEY" ]]; then
    if found=$(podman exec beszel sh -c 'find / -name id_ed25519.pub -not -path "*/proc/*" 2>/dev/null | head -1'); then
        if [[ -n "$found" ]]; then
            cand=$(podman exec beszel cat "$found" 2>/dev/null || true)
            try_key_source "podman exec find: $found" "$cand" || true
        fi
    fi
fi

if [[ -z "$PUBKEY" ]]; then
    log "exhausted pubkey sources. Tried API and these container paths:"
    log "  /beszel_data/id_ed25519.pub /beszel_data/pb_data/... /beszel_data/data/..."
    log "  /beszel_data/keys/... /data/... /pb_data/... + find / -name id_ed25519.pub"
    log "Add the agent manually in the UI and copy the key into monitoring/.env"
    log "as BESZEL_AGENT_KEY=, then podman-compose up -d agent."
    die "could not retrieve hub public key"
fi
log "hub public key retrieved (source: $PUBKEY_SOURCE)"

# ---- 4. Persist key to monitoring/.env --------------------------------------
touch "$LOCAL_ENV"
chmod 600 "$LOCAL_ENV"
if grep -q '^BESZEL_AGENT_KEY=' "$LOCAL_ENV"; then
    # Escape forward slashes for sed. The SSH key format doesn't contain "|".
    sed -i "s|^BESZEL_AGENT_KEY=.*|BESZEL_AGENT_KEY=\"$PUBKEY\"|" "$LOCAL_ENV"
else
    printf 'BESZEL_AGENT_KEY="%s"\n' "$PUBKEY" >> "$LOCAL_ENV"
fi
if ! grep -q '^BESZEL_SYSTEM_NAME=' "$LOCAL_ENV"; then
    printf 'BESZEL_SYSTEM_NAME="%s"\n' "$SYSTEM_NAME" >> "$LOCAL_ENV"
fi
log "BESZEL_AGENT_KEY written to monitoring/.env"

# Check if a system with this name already exists (idempotency).
filter_enc=$(jq -rn --arg n "$SYSTEM_NAME" '"name=\"\($n)\""' | jq -sRr @uri)
existing=$(curl -fsS -H "Authorization: $TOKEN" \
    "$HUB_URL/api/collections/systems/records?filter=$filter_enc" 2>/dev/null || echo '{}')
count=$(echo "$existing" | jq -r '.totalItems // 0')

if (( count > 0 )); then
    log "system '$SYSTEM_NAME' already registered in hub - skipping create"
else
    payload=$(jq -cn \
        --arg n "$SYSTEM_NAME" \
        --arg h "127.0.0.1" \
        --arg p "45876" \
        --arg u "$USER_ID" \
        '{name:$n, host:$h, port:$p, users:[$u]}')
    if curl -fsS -X POST "$HUB_URL/api/collections/systems/records" \
            -H "Authorization: $TOKEN" \
            -H 'Content-Type: application/json' \
            -d "$payload" >/dev/null 2>&1; then
        log "system '$SYSTEM_NAME' registered in hub"
    else
        # Non-fatal: the user can add it manually in the UI. Key is already
        # persisted so the agent will be trusted either way.
        log "WARN: system record POST failed - add it manually in the UI"
    fi
fi

# ---- 5. Restart agent so it re-reads BESZEL_AGENT_KEY -----------------------
# podman-compose re-parses the yml; ADMIN_PASSWORD must be in the shell env
# for the hub service's ${ADMIN_PASSWORD:?} substitution to resolve, even
# though we only want to (re)start the agent. The `set -a; . ; set +a` above
# already put it there, so this just works.
#
# XDG_RUNTIME_DIR: the compose mounts ${XDG_RUNTIME_DIR:-/run/user/1000}/podman/
# podman.sock. `su -` and bare shells don't always populate that variable
# (pam_systemd isn't in Ubuntu's default `su` PAM stack), so the compose
# falls back to UID 1000 - wrong on hosts where the dst user got UID 1001.
# Force-set it from the current effective UID before invoking compose.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
log "restarting agent to pick up new key"
( cd "$MONITOR_DIR" && podman-compose up -d agent >/dev/null )

log "done - hub should show '$SYSTEM_NAME' green within ~30s"
