#!/bin/bash
#
# Render and install the orca-hub systemd unit. Nothing else.
#
# Usage: ./install.sh [--user USER] [--dry-run]
#
# What it does:
#   - Renders systemd/orca-hub.service.template ({{USER}}, {{HOME}}) into
#     /etc/systemd/system/orca-hub.service as a REAL file. If the existing
#     destination is a symlink (e.g. into a checkout), it is replaced, never
#     written through.
#   - Pre-flights the env file the unit actually reads,
#     $HOME/orca-hub-releases/.env (SECRET_KEY_BASE; DATABASE_URL unless
#     ORCA_MODE=agent; PHX_HOST warning). Values are never printed.
#   - Warns if $HOME/orca-hub-releases/current/bin/orca_hub is not executable.
#   - Runs `sudo systemctl daemon-reload`.
#
# What it does NOT do:
#   - Build or compile anything. Releases and the .env file are installed by
#     ~/homelab/scripts/deploy-orca-hub.sh (not in this repo).
#   - Restart, start, or enable the service. Next-step commands are printed.
#
# --dry-run prints the rendered unit and a diff against the installed unit,
# changes nothing, and never calls sudo.
#
# sudo: the NOPASSWD rule in scripts/orca-hub.sudoers covers only
# start/stop/status/restart, NOT daemon-reload or install/rm, so this is an
# interactive-sudo script.
#
# Options:
#   --user USER   User to run the service as (default: current user)
#   --dry-run     Show what would be installed; change nothing
#   -h, --help    Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER="$(whoami)"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            USER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--user USER] [--dry-run]"
            echo ""
            echo "Render and install the orca-hub systemd unit (no build)."
            echo ""
            echo "Options:"
            echo "  --user USER     User to run the service as (default: current user)"
            echo "  --dry-run       Print the rendered unit and diff vs installed; change nothing"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

HOME_DIR="$(eval echo ~"$USER")"
TEMPLATE="$SCRIPT_DIR/orca-hub.service.template"
DEST="/etc/systemd/system/orca-hub.service"
RELEASES_DIR="$HOME_DIR/orca-hub-releases"
RELEASE_BIN="$RELEASES_DIR/current/bin/orca_hub"
ENV_FILE="$RELEASES_DIR/.env"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template file not found: $TEMPLATE"
    exit 1
fi

# Read a single KEY's value from the .env file without sourcing it.
# Returns the last assignment for KEY (tolerates a leading `export` and indentation).
env_value() {
    local key="$1"
    grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" 2>/dev/null \
        | tail -n1 \
        | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${key}=//" || true
}

# True if KEY is assigned a non-empty value in the .env file.
# Only used to detect presence — never echoes the value (secrets stay hidden).
has_env() {
    local key="$1"
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=[^[:space:]]" "$ENV_FILE" 2>/dev/null
}

# Validate the env file the unit reads (EnvironmentFile in the template).
# These are RUNTIME requirements from config/runtime.exs (prod):
#   - SECRET_KEY_BASE: always required
#   - DATABASE_URL:    required unless ORCA_MODE=agent
#   - PHX_HOST:        recommended (otherwise host defaults to example.com)
preflight_env() {
    echo ""
    echo "Pre-flight: validating runtime environment..."
    echo "  Env file: $ENV_FILE"

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Error: env file not found at: $ENV_FILE" >&2
        echo "  The deploy script's env step (~/homelab/scripts/deploy-orca-hub.sh) writes it." >&2
        echo "  Run the deploy script, then re-run this installer." >&2
        exit 1
    fi

    local orca_mode missing=0
    orca_mode="$(env_value ORCA_MODE)"
    orca_mode="${orca_mode:-hub}"
    echo "  ORCA_MODE: $orca_mode"

    # SECRET_KEY_BASE — always required.
    if has_env SECRET_KEY_BASE; then
        echo "  SECRET_KEY_BASE: present"
    else
        echo "Error: SECRET_KEY_BASE is missing or empty in $ENV_FILE" >&2
        missing=1
    fi

    # DATABASE_URL — required unless running as an agent (agents proxy DB ops to the hub).
    if [[ "$orca_mode" == "agent" ]]; then
        echo "  DATABASE_URL: not required (agent mode)"
    elif has_env DATABASE_URL; then
        echo "  DATABASE_URL: present"
    else
        echo "Error: DATABASE_URL is missing or empty in $ENV_FILE (required in hub mode)" >&2
        missing=1
    fi

    # PHX_HOST — recommended but optional.
    if has_env PHX_HOST; then
        echo "  PHX_HOST: present"
    else
        echo "  WARNING: PHX_HOST is unset; the host URL will default to example.com" >&2
    fi

    if [[ "$missing" -ne 0 ]]; then
        echo "" >&2
        echo "Pre-flight failed: fix the missing variable(s) above (via the deploy script's env step) and re-run." >&2
        exit 1
    fi

    echo "  Pre-flight OK."
}

# Render the template.
render() {
    sed \
        -e "s|{{USER}}|$USER|g" \
        -e "s|{{HOME}}|$HOME_DIR|g" \
        "$TEMPLATE"
}

echo "Installing orca-hub.service..."
echo "  User: $USER"
echo "  Home: $HOME_DIR"
echo "  Dest: $DEST"

# Validate runtime env up front so a misconfigured host fails here rather than
# in a systemd crash-loop after install.
preflight_env

if [[ ! -x "$RELEASE_BIN" ]]; then
    echo ""
    echo "WARNING: release binary is not executable / not found at:"
    echo "  $RELEASE_BIN"
    echo "  Run ~/homelab/scripts/deploy-orca-hub.sh to install a release."
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
render > "$TMP"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "=== Rendered unit (dry run) ==="
    cat "$TMP"
    echo "=== End rendered unit ==="
    echo ""
    if [[ -L "$DEST" ]]; then
        echo "Note: $DEST is a symlink -> $(readlink -f "$DEST"); a real install would replace it with a real file."
    fi
    if [[ -e "$DEST" ]]; then
        echo "Diff vs currently installed ($DEST), installed -> rendered:"
        diff -u "$DEST" "$TMP" && echo "  (no differences)" || true
    else
        echo "No unit currently installed at $DEST."
    fi
    echo ""
    echo "Dry run: no changes made."
    exit 0
fi

# Replace any symlink with a real file: writing through it would clobber its
# target (e.g. a file in a git checkout).
if [[ -L "$DEST" ]]; then
    echo ""
    echo "Replacing symlink $DEST -> $(readlink "$DEST") with a real file."
    sudo rm -f "$DEST"
fi

sudo install -m 0644 -o root -g root "$TMP" "$DEST"

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo ""
echo "Done. The service was NOT restarted or enabled. Next steps:"
echo "  sudo systemctl restart orca-hub  # Pick up the new unit"
echo "  sudo systemctl enable orca-hub   # Enable on boot"
echo "  sudo systemctl status orca-hub   # Check status"
