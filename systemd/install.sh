#!/bin/bash
#
# Install the orca-hub systemd service
#
# Usage: ./install.sh [--user USER] [--dir DIR] [--no-build]
#
# Defaults:
#   USER: current user
#   DIR:  parent directory of this script's location (i.e., the orca_hub repo root)
#   BUILD: on (build the prod release); pass --no-build to skip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_HUB_DIR="$(dirname "$SCRIPT_DIR")"
USER="$(whoami)"
HOME_DIR="$(eval echo ~"$USER")"
BUILD=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            USER="$2"
            shift 2
            ;;
        --dir)
            ORCA_HUB_DIR="$2"
            shift 2
            ;;
        --no-build)
            BUILD=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--user USER] [--dir DIR] [--no-build]"
            echo ""
            echo "Install the orca-hub systemd service."
            echo ""
            echo "Options:"
            echo "  --user USER     User to run the service as (default: current user)"
            echo "  --dir DIR       OrcaHub directory (default: repo root)"
            echo "  --no-build      Skip building the prod release (build is on by default)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

TEMPLATE="$SCRIPT_DIR/orca-hub.service.template"
DEST="/etc/systemd/system/orca-hub.service"
RELEASE_BIN="$ORCA_HUB_DIR/_build/prod/rel/orca_hub/bin/orca_hub"
ENV_FILE="$ORCA_HUB_DIR/.env"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template file not found: $TEMPLATE"
    exit 1
fi

if [[ ! -d "$ORCA_HUB_DIR" ]]; then
    echo "Error: OrcaHub directory not found: $ORCA_HUB_DIR"
    exit 1
fi

# Read a single KEY's value from the .env file without sourcing it.
# Returns the last assignment for KEY (tolerates a leading `export` and indentation).
env_value() {
    local key="$1"
    grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" 2>/dev/null \
        | tail -n1 \
        | sed -E "s/^[[:space:]]*(export[[:space:]]+)?${key}=//"
}

# True if KEY is assigned a non-empty value in the .env file.
# Only used to detect presence — never echoes the value (secrets stay hidden).
has_env() {
    local key="$1"
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=[^[:space:]]" "$ENV_FILE" 2>/dev/null
}

# Validate the runtime environment (.env) before touching system state or building.
# These are RUNTIME requirements from config/runtime.exs (prod):
#   - SECRET_KEY_BASE: always required
#   - DATABASE_URL:    required unless ORCA_MODE=agent
#   - PHX_HOST:        recommended (otherwise host defaults to example.com)
preflight_env() {
    echo ""
    echo "Pre-flight: validating runtime environment..."
    echo "  Env file: $ENV_FILE"

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Error: .env file not found at: $ENV_FILE" >&2
        echo "" >&2
        echo "Create it with at least the production runtime variables:" >&2
        echo "  SECRET_KEY_BASE=<generate via: mix phx.gen.secret>" >&2
        echo "  DATABASE_URL=ecto://USER:PASS@HOST/DATABASE   # hub mode only" >&2
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
        echo "  Generate one with: (cd \"$ORCA_HUB_DIR\" && mix phx.gen.secret)" >&2
        missing=1
    fi

    # DATABASE_URL — required unless running as an agent (agents proxy DB ops to the hub).
    if [[ "$orca_mode" == "agent" ]]; then
        echo "  DATABASE_URL: not required (agent mode)"
    elif has_env DATABASE_URL; then
        echo "  DATABASE_URL: present"
    else
        echo "Error: DATABASE_URL is missing or empty in $ENV_FILE (required in hub mode)" >&2
        echo "  Expected format: ecto://USER:PASS@HOST/DATABASE" >&2
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
        echo "Pre-flight failed: fix the missing variable(s) above and re-run." >&2
        exit 1
    fi

    echo "  Pre-flight OK."
}

# Ensure the Elixir/Erlang toolchain is available before attempting a build.
check_build_tools() {
    local tool missing=0
    for tool in mix elixir erl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: '$tool' was not found on PATH." >&2
            missing=1
        fi
    done
    if [[ "$missing" -ne 0 ]]; then
        echo "" >&2
        echo "Elixir/Erlang must be installed and on PATH to build the release." >&2
        echo "If you manage versions with asdf, make sure its shims are on PATH" >&2
        echo "(e.g. add \`. \"\$HOME/.asdf/asdf.sh\"\` to your shell profile)," >&2
        echo "or re-run with --no-build to skip building." >&2
        exit 1
    fi
}

# Build the production OTP release (MIX_ENV=prod).
build_release() {
    check_build_tools
    echo ""
    echo "Building production release (MIX_ENV=prod)..."
    echo "  Directory: $ORCA_HUB_DIR"
    (
        cd "$ORCA_HUB_DIR"
        MIX_ENV=prod mix deps.get --only prod
        MIX_ENV=prod mix assets.deploy
        MIX_ENV=prod mix release --overwrite
    )
    echo "  Build complete."
}

echo "Installing orca-hub.service..."
echo "  User: $USER"
echo "  Directory: $ORCA_HUB_DIR"
echo "  Home: $HOME_DIR"

# Validate runtime env up front so a misconfigured deploy fails here rather than
# in a systemd crash-loop after install.
preflight_env

# Build the prod release (default on; --no-build to skip).
if [[ "$BUILD" == "true" ]]; then
    build_release
else
    echo ""
    echo "Skipping build (--no-build)."
fi

# Generate the service file from template
SERVICE_CONTENT=$(sed \
    -e "s|{{USER}}|$USER|g" \
    -e "s|{{ORCA_HUB_DIR}}|$ORCA_HUB_DIR|g" \
    -e "s|{{HOME}}|$HOME_DIR|g" \
    "$TEMPLATE")

# Install to systemd (requires sudo)
echo "$SERVICE_CONTENT" | sudo tee "$DEST" > /dev/null

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo ""
if [[ ! -x "$RELEASE_BIN" ]]; then
    echo "WARNING: release binary not found at:"
    echo "  $RELEASE_BIN"
    echo ""
    if [[ "$BUILD" == "true" ]]; then
        echo "The build step ran but the binary is still missing — review the build output above."
    else
        echo "Build was skipped (--no-build). Build it before starting the service:"
        echo "  cd $ORCA_HUB_DIR"
        echo "  MIX_ENV=prod mix deps.get --only prod"
        echo "  MIX_ENV=prod mix assets.deploy"
        echo "  MIX_ENV=prod mix release --overwrite"
    fi
    echo ""
fi

echo "Done! You can now:"
echo "  sudo systemctl enable orca-hub   # Enable on boot"
echo "  sudo systemctl start orca-hub    # Start the service"
echo "  sudo systemctl status orca-hub   # Check status"
echo ""
echo "After rebuilding the release, restart with:"
echo "  sudo systemctl restart orca-hub"
