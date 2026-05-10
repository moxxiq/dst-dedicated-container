#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  DST dedicated server - Vultr Startup Script
#
#  HOW TO USE:
#    1. Fill in every value in the "FILL IN THESE VARS" section below.
#    2. Vultr dashboard -> Startup Scripts -> Add Script.
#       Paste this whole file -> Save -> attach the script to your VPS on create.
#       Runs automatically as root on first boot. No SSH session needed.
#
#       - OR - SSH in as root and paste the filled-in script straight into the
#       terminal for immediate execution.
#
#  SECURITY NOTE:
#    This file contains secrets (token, password, R2 keys). Do NOT commit it
#    to git. Vultr stores it in your account; rotate credentials afterward if
#    that concerns you.
# -----------------------------------------------------------------------------

# -- FILL IN THESE VARS -------------------------------------------------------

CLUSTER_NAME="qkation-cooperative"    # Shown in the DST server browser
CLUSTER_TOKEN=""                       # https://accounts.klei.com/account/game/servers -> Add New Server
ADMIN_PASSWORD=""                      # Web admin + dst Linux user password (min 8 chars)
                                       # Web admin login is always "dst"
R2_ACCOUNT_ID=""                       # Cloudflare -> R2 -> Account ID (top-right of overview)
R2_BUCKET=""                           # Your R2 bucket name
R2_ACCESS_KEY_ID=""                    # R2 -> Manage API tokens -> Create token -> Access Key ID
R2_SECRET_ACCESS_KEY=""                # Same token dialog -> Secret Access Key
INSTALL_BESZEL="n"                     # "y" to also install Beszel monitoring on :8090

# -----------------------------------------------------------------------------
# Everything below this line is boilerplate - do not edit.
# -----------------------------------------------------------------------------

set -euo pipefail

# Validate before downloading anything - catch empty vars immediately.
_require() {
    local var="$1"
    [[ -n "${!var:-}" ]] || {
        printf '\033[1;31mERROR: %s is empty - fill it in above this line.\033[0m\n' "$var" >&2
        exit 1
    }
}
_require CLUSTER_TOKEN
_require ADMIN_PASSWORD
_require R2_ACCOUNT_ID
_require R2_BUCKET
_require R2_ACCESS_KEY_ID
_require R2_SECRET_ACCESS_KEY

[[ ${#ADMIN_PASSWORD} -ge 8 ]] || {
    echo "ERROR: ADMIN_PASSWORD must be at least 8 characters." >&2
    exit 1
}

# Export so vultr-bootstrap.sh detects non-interactive mode automatically
# (it checks whether all required vars are already set and skips prompts).
export CLUSTER_NAME CLUSTER_TOKEN ADMIN_PASSWORD \
       R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY \
       INSTALL_BESZEL

# Pull and run the full bootstrap from the repo.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL \
    "https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh" \
    -o "$WORK/vultr-bootstrap.sh"
chmod +x "$WORK/vultr-bootstrap.sh"
exec "$WORK/vultr-bootstrap.sh"
