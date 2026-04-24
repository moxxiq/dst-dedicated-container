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
#   - A `dst` Linux user owning ~/steamCMD, with its Linux password set to
#     the admin panel password you chose (one credential for both).
#   - The DST container running under rootless podman (restart=unless-stopped)
#   - The FastAPI admin panel on :8080 (HTTP Basic, user: `dst`)
#   - UFW (host firewall) configured with rules for SSH, admin, and DST ports.
#   - Optionally the Beszel monitoring stack (:8090) if you opt in.
#
# Re-running is idempotent: existing users/clones/containers are reused, the
# dst Linux password is rotated to whatever ADMIN_PASSWORD you supply.

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
    INSTALL_BESZEL="${INSTALL_BESZEL:-n}"
    INSTALL_BESZEL="${INSTALL_BESZEL,,}"

    # Validate what we can without a TTY.
    [[ ${#ADMIN_PASSWORD} -ge 8 ]] || die "ADMIN_PASSWORD must be at least 8 characters."
    [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "n" \
       || "$INSTALL_BESZEL" == "yes" || "$INSTALL_BESZEL" == "no" ]] \
        || warn "INSTALL_BESZEL='${INSTALL_BESZEL}' unexpected - expected y/n; treating as n."

    printf '  CLUSTER_NAME  : %s\n'  "$CLUSTER_NAME"
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

    # Admin panel username is always the DST Linux user (default: "dst").
    # Same value is used for both the web admin login and the Linux user
    # password, so you have one credential to remember for this VPS.
    echo "  Admin panel username will be: ${DST_USER}"
    echo "  (same name as the Linux user that owns ~/steamCMD)"

    while :; do
        read -r -u3 -s -p "Password for ${DST_USER} (web admin + Linux user, min 8 chars): " ADMIN_PASSWORD; echo
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

# Admin panel login is always the DST Linux user. One credential for both.
ADMIN_USER="$DST_USER"

# ---- 2. System packages ------------------------------------------------------
say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    podman podman-compose git rsync ca-certificates curl jq uidmap ufw \
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

# Put dst in the sudo group so the operator can `sudo <cmd>` from an SSH
# session as dst (e.g. re-run this bootstrap, install packages, edit UFW).
# They'll authenticate with ADMIN_PASSWORD (set below). Idempotent; adding
# a user to a group they're already in is a no-op.
usermod -aG sudo "$DST_USER"

# Unify credentials: ADMIN_PASSWORD is the web admin password AND the Linux
# password for the dst user. Re-running rotates the password to match.
# Use usermod -p with a pre-hashed password to bypass PAM quality checks
# (pam_pwquality rejects "simple" passwords via chpasswd on Ubuntu). The
# operator is provisioning their own server and can choose their own password.
usermod -p "$(openssl passwd -6 "${ADMIN_PASSWORD}")" "${DST_USER}"

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
# env_file: in a compose service injects vars into the CONTAINER, not into
# the shell that podman-compose runs in - so parse-time `${ADMIN_PASSWORD}`
# substitutions in the yml need the vars in the caller's shell. Sourcing
# ../.env into the subshell takes care of that for every compose invocation.
as_dst bash -c "set -a; . '$TARGET/.env'; set +a; cd '$TARGET/admin' && podman-compose up -d"

# ---- 9. Optional Beszel monitoring ------------------------------------------
if [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]]; then
    say "Starting Beszel monitoring"
    # First compose-up: hub seeds its admin user from ADMIN_PASSWORD on the
    # empty DB; agent boots without a key and waits. Source ../.env first so
    # ${ADMIN_PASSWORD:?} substitution resolves in podman-compose's own env.
    as_dst bash -c "set -a; . '$TARGET/.env'; set +a; cd '$TARGET/monitoring' && podman-compose up -d"

    # autowire.sh fetches the hub's SSH pubkey, creates the system record via
    # the hub API, writes the key to monitoring/.env, and restarts the agent
    # so it picks the key up. After this the hub shows this host green in the
    # "Systems" list with full CPU/RAM/disk/net metrics + container stats for
    # dst / dst-admin / beszel-agent. Idempotent; fine to re-run.
    if ! as_dst bash -c "cd '$TARGET/monitoring' && ./autowire.sh"; then
        warn "Beszel autowire failed - log in at http://<vps-ip>:8090 and add the system manually."
        warn "  email    = admin@dst.local"
        warn "  password = <your ADMIN_PASSWORD>"
    fi
fi

# ---- 10. Host firewall (UFW) ------------------------------------------------
# Ubuntu Vultr images sometimes ship with UFW active (default deny incoming),
# silently blocking ports we've just bound. Rather than tell the operator to
# do this by hand after the fact, open the ports we need here and make sure
# UFW is enabled. SSH goes first so `ufw enable` can't lock you out.
say "Configuring host firewall (ufw)"
ufw allow 22/tcp     comment 'SSH'                          >/dev/null
ufw allow 8080/tcp   comment 'DST admin panel'              >/dev/null
ufw allow 10999/udp  comment 'DST Master shard (overworld)' >/dev/null
ufw allow 10998/udp  comment 'DST Caves shard (underground)' >/dev/null
ufw allow 8766/udp   comment 'Steam auth (Master)'          >/dev/null
ufw allow 8768/udp   comment 'Steam auth (Caves)'           >/dev/null
ufw allow 27016/udp  comment 'Steam master server (Master)' >/dev/null
ufw allow 27018/udp  comment 'Steam master server (Caves)'  >/dev/null
if [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]]; then
    ufw allow 8090/tcp comment 'Beszel UI' >/dev/null
fi
# --force skips the "this will disrupt existing SSH connections" prompt.
if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw --force enable >/dev/null
else
    ufw reload >/dev/null
fi

# ---- 11. Summary -------------------------------------------------------------
VPS_IP="$(hostname -I | awk '{print $1}')"
say "Bootstrap complete"
cat <<EOF

  DST container     : podman logs -f dst        (as ${DST_USER})
  Admin panel       : http://${VPS_IP}:8080     (user: ${ADMIN_USER})
$( [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]] && echo "  Beszel monitoring : http://${VPS_IP}:8090" )

  Credentials (unified):
    Web admin login         : ${ADMIN_USER} / <your admin password>
    Linux user on this VPS  : ${ADMIN_USER} / <same password, sudoer>
    SSH example             : ssh ${ADMIN_USER}@${VPS_IP}$( [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]] && echo "
    Beszel login            : admin@dst.local / <same password>" )

  Host firewall (UFW) already configured by this script:
       TCP  22      SSH
       TCP  8080    admin panel
       UDP  10999   DST Master shard (overworld)
       UDP  10998   DST Caves shard (underground)
       UDP  8766    Steam auth (Master)
       UDP  8768    Steam auth (Caves)
       UDP  27016   Steam master server (Master)
       UDP  27018   Steam master server (Caves)$( [[ "$INSTALL_BESZEL" == "y" || "$INSTALL_BESZEL" == "yes" ]] && echo "
       TCP  8090    Beszel UI" )
    (Caves UDP rules are required - missing them silently breaks
     surface<->caves teleports.)

  Next steps:
    1. Open http://${VPS_IP}:8080 (user: ${ADMIN_USER}) and either:
         - upload an existing cluster zip, or
         - use the template wizard to create a new world.
    2. DST is currently waiting for a cluster - it will pick up the files
       within 5 seconds of the admin panel writing them.

  To re-run this bootstrap on a new VPS, download the pre-filled startup
  script from the admin panel ("Download bootstrap.sh") - it bakes in all
  secrets so the next paste needs zero extra typing.
EOF
