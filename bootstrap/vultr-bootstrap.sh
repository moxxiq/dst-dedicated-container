#!/usr/bin/env bash
# DST dedicated server - Vultr VPS one-shot bootstrap.
#
# INTERACTIVE (SSH - prompts for all values):
#   curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh -o bootstrap.sh
#   chmod +x bootstrap.sh
#   sudo ./bootstrap.sh
#
# NON-INTERACTIVE - download script + vars template, fill in, run
# (works on a FRESH VPS with no repo checkout yet):
#   curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh    -o bootstrap.sh
#   curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/bootstrap.vars.example -o bootstrap.vars
#   # edit bootstrap.vars - fill in every value
#   chmod +x bootstrap.sh
#   sudo ./bootstrap.sh --vars bootstrap.vars
#
# NON-INTERACTIVE - pre-export vars, then run:
#   export CLUSTER_TOKEN="..." ADMIN_PASSWORD="..." R2_ACCOUNT_ID="..." ...
#   sudo ./bootstrap.sh
#
# NON-INTERACTIVE - Vultr Startup Script (zero SSH needed):
#   See bootstrap/vultr-startup-script.sh - fill in vars at top, paste into
#   Vultr dashboard -> Startup Scripts -> Add Script -> attach to VPS on create.
#
# After it finishes you'll have:
#   - A `dst` Linux user owning ~/steamCMD
#   - The DST container running under rootless podman (restart=unless-stopped)
#   - The FastAPI admin panel on :8080 (HTTP Basic)
#   - Optionally the Beszel monitoring stack (:8090) if you opt in
#
# Re-running is idempotent: existing users/clones/containers are reused.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/moxxiq/dst-dedicated-container.git}"
DST_USER="${DST_USER:-dst}"
DST_HOME="/home/${DST_USER}"
TARGET="${TARGET:-${DST_HOME}/steamCMD}"
CLUSTER_NAME_DEFAULT="qkation-cooperative"

say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo ./bootstrap.sh)."

# ---- 0. Parse flags ----------------------------------------------------------
VARS_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vars|-v)
            VARS_FILE="${2:?--vars requires a file argument}"
            shift 2
            ;;
        *)
            die "Unknown argument: $1  (usage: $0 [--vars FILE])"
            ;;
    esac
done

# Source a vars file if given - runs before the interactive/non-interactive check.
if [[ -n "$VARS_FILE" ]]; then
    [[ -f "$VARS_FILE" ]] || die "--vars: file not found: $VARS_FILE"
    # shellcheck source=/dev/null
    source "$VARS_FILE"
fi

# ---- 1. Interactive vs non-interactive ---------------------------------------
# Non-interactive mode activates when all required vars are already set
# (via --vars, via pre-exported env vars, or from vultr-startup-script.sh).
_required_vars_set() {
    [[ -n "${CLUSTER_TOKEN:-}"        &&
       -n "${ADMIN_PASSWORD:-}"       &&
       -n "${R2_ACCOUNT_ID:-}"        &&
       -n "${R2_BUCKET:-}"            &&
       -n "${R2_ACCESS_KEY_ID:-}"     &&
       -n "${R2_SECRET_ACCESS_KEY:-}" ]]
}

if _required_vars_set; then
    say "Non-interactive mode - using pre-set variables"

    # Apply defaults for optional vars.
    CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
    ADMIN_USER="${ADMIN_USER:-admin}"
    INSTALL_BESZEL="${INSTALL_BESZEL:-n}"
    INSTALL_BESZEL="${INSTALL_BESZEL,,}"

    # Validate what we can without a TTY.
    [[ ${#ADMIN_PASSWORD} -ge 8 ]] || die "ADMIN_PASSWORD must be at least 8 characters."
    [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "n" \
       || "$INSTALL_BESZEL" == "yes" || "$INSTALL_BESZEL" == "no" ]] \
        || warn "INSTALL_BESZEL='${INSTALL_BESZEL}' unexpected - expected y/n; treating as n."

    printf '  CLUSTER_NAME  : %s\n'  "$CLUSTER_NAME"
    printf '  ADMIN_USER    : %s\n'  "$ADMIN_USER"
    printf '  R2_BUCKET     : %s\n'  "$R2_BUCKET"
    printf '  INSTALL_BESZEL: %s\n'  "$INSTALL_BESZEL"
    printf '  (secrets omitted from log)\n'

else
    # ---- Interactive path ----------------------------------------------------
    say "Interactive setup"
    # Use /dev/tty so prompts work even when the script is piped.
    exec 3</dev/tty 4>/dev/tty || die "No controlling TTY. SSH in interactively first, or pre-set variables - see bootstrap/bootstrap.vars.example or bootstrap/vultr-startup-script.sh."

    read -r -u3 -p "Cluster name [${CLUSTER_NAME_DEFAULT}]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"

    read -r -u3 -p "Klei cluster token (paste from accounts.klei.com): " CLUSTER_TOKEN
    [[ -n "$CLUSTER_TOKEN" ]] || warn "Empty cluster token - DST will not start until you set it."

    read -r -u3 -p "Admin panel username [admin]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-admin}"

    while :; do
        read -r -u3 -s -p "Admin panel password (required, min 8 chars): " ADMIN_PASSWORD; echo
        read -r -u3 -s -p "Repeat: " ADMIN_PASSWORD2; echo
        if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]]; then warn "Mismatch, try again."; continue; fi
        if [[ ${#ADMIN_PASSWORD} -lt 8 ]];               then warn "Too short."; continue; fi
        break
    done

    say "Cloudflare R2 backup (REQUIRED - DST refuses to launch without it)"
    cat >&2 <<'R2NOTE'
  Create a bucket + API token at https://dash.cloudflare.com/?to=/:account/r2
  The token needs Object Read & Write scope on your bucket.
R2NOTE
    while :; do read -r -u3 -p    "R2 account ID:    " R2_ACCOUNT_ID;          [[ -n "$R2_ACCOUNT_ID"        ]] && break; warn "required."; done
    while :; do read -r -u3 -p    "R2 bucket:        " R2_BUCKET;              [[ -n "$R2_BUCKET"            ]] && break; warn "required."; done
    while :; do read -r -u3 -p    "R2 access key ID: " R2_ACCESS_KEY_ID;       [[ -n "$R2_ACCESS_KEY_ID"     ]] && break; warn "required."; done
    while :; do read -r -u3 -s -p "R2 secret key:    " R2_SECRET_ACCESS_KEY; echo
                [[ -n "$R2_SECRET_ACCESS_KEY" ]] && break; warn "required."; done

    read -r -u3 -p "Also install Beszel monitoring (:8090)? [y/N]: " INSTALL_BESZEL
    INSTALL_BESZEL="${INSTALL_BESZEL,,}"  # lowercase
fi

# ---- 2. System packages ------------------------------------------------------
say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    podman podman-compose git rsync ca-certificates curl uidmap \
    slirp4netns fuse-overlayfs dbus-user-session systemd-container

# Sanity-check podman-compose is reachable - on Ubuntu 22.04 the `podman`
# package has no compose subcommand at all, and on 24.04 the subcommand
# only works if an external provider like podman-compose is installed.
command -v podman-compose >/dev/null \
    || die "podman-compose not found after apt install - try: pip3 install --break-system-packages podman-compose"

# ---- 3. User + rootless runtime ---------------------------------------------
say "Creating ${DST_USER} user"
if ! id "$DST_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$DST_USER"
fi
loginctl enable-linger "$DST_USER"

as_dst() { sudo -u "$DST_USER" -H XDG_RUNTIME_DIR="/run/user/$(id -u "$DST_USER")" "$@"; }

# ---- 4. Clone the repo -------------------------------------------------------
say "Fetching repo at ${TARGET}"
if [[ -d "$TARGET/.git" ]]; then
    as_dst git -C "$TARGET" pull --ff-only || warn "git pull failed; keeping existing checkout."
else
    sudo -u "$DST_USER" -H git clone "$REPO_URL" "$TARGET"
fi

# ---- 5. Write .env (DST + admin) --------------------------------------------
say "Writing ${TARGET}/.env"
umask 077
cat > "$TARGET/.env" <<EOF
# Generated by vultr-bootstrap.sh on $(date -Is)
CLUSTER_NAME=${CLUSTER_NAME}
CLUSTER_TOKEN=${CLUSTER_TOKEN}

R2_ACCOUNT_ID=${R2_ACCOUNT_ID}
R2_BUCKET=${R2_BUCKET}
R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID}
R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY}

AUTO_UPDATE=1

ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
chown "$DST_USER:$DST_USER" "$TARGET/.env"
chmod 0600 "$TARGET/.env"
umask 022

# ---- 6. Bind-mount ownership ------------------------------------------------
mkdir -p "$TARGET/saves" "$TARGET/mods" "$TARGET/parked"
chown -R "$DST_USER:$DST_USER" "$TARGET"

# ---- 7. Build & start DST ---------------------------------------------------
say "Building DST image"
as_dst bash -c "cd '$TARGET' && podman build --platform=linux/amd64 -t local/steamcmd:latest ."

say "Starting DST container"
as_dst bash -c "cd '$TARGET' && ./run-dst.sh start"

# ---- 8. Build & start admin panel -------------------------------------------
say "Building admin panel image"
as_dst bash -c "cd '$TARGET/admin' && podman build --platform=linux/amd64 -t local/dst-admin:latest ."

say "Starting admin panel"
as_dst bash -c "cd '$TARGET/admin' && podman-compose up -d"

# ---- 9. Optional Beszel monitoring ------------------------------------------
if [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]]; then
    say "Starting Beszel monitoring"
    as_dst bash -c "cd '$TARGET/monitoring' && podman-compose up -d"
fi

# ---- 10. Summary -------------------------------------------------------------
VPS_IP="$(hostname -I | awk '{print $1}')"
say "Bootstrap complete"
cat <<EOF

  DST container     : podman logs -f dst        (as ${DST_USER})
  Admin panel       : http://${VPS_IP}:8080     (user: ${ADMIN_USER})
$( [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]] && echo "  Beszel monitoring : http://${VPS_IP}:8090" )

  Next steps:
    1. Open Vultr Cloud Firewall and allow:
         UDP  10999       from anywhere   (DST Master shard - overworld)
         UDP  8766        from anywhere   (Steam auth - Master)
         UDP  27016       from anywhere   (Steam master server - Master)
         UDP  10998       from anywhere   (DST Caves shard - underground)
         UDP  8768        from anywhere   (Steam auth - Caves)
         UDP  27018       from anywhere   (Steam master server - Caves)
         TCP  22          from your IP    (SSH)
         TCP  8080        from your IP    (admin panel)$( [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]] && echo "
         TCP  8090        from your IP    (Beszel UI)" )
       (Missing caves UDP rules silently break surface<->caves teleports.)
    2. Open http://${VPS_IP}:8080 and either:
         - upload an existing cluster zip, or
         - use the template wizard to create a new world.
    3. DST is currently waiting for a cluster - it will pick up the files
       within 5 seconds of the admin panel writing them.

  To re-run this bootstrap on a new VPS, download the pre-filled startup
  script from the admin panel ("Download bootstrap.sh") - it bakes in all
  secrets so the next paste needs zero extra typing.
EOF
