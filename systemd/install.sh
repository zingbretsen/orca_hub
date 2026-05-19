#!/bin/bash
#
# Install the orca-hub systemd service
#
# Usage: ./install.sh [--user USER] [--dir DIR]
#
# Defaults:
#   USER: current user
#   DIR:  parent directory of this script's location (i.e., the orca_hub repo root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_HUB_DIR="$(dirname "$SCRIPT_DIR")"
USER="$(whoami)"
HOME_DIR="$(eval echo ~$USER)"

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
        -h|--help)
            echo "Usage: $0 [--user USER] [--dir DIR]"
            echo ""
            echo "Install the orca-hub systemd service."
            echo ""
            echo "Options:"
            echo "  --user USER     User to run the service as (default: current user)"
            echo "  --dir DIR       OrcaHub directory (default: repo root)"
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

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template file not found: $TEMPLATE"
    exit 1
fi

if [[ ! -d "$ORCA_HUB_DIR" ]]; then
    echo "Error: OrcaHub directory not found: $ORCA_HUB_DIR"
    exit 1
fi

echo "Installing orca-hub.service..."
echo "  User: $USER"
echo "  Directory: $ORCA_HUB_DIR"
echo "  Home: $HOME_DIR"

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
    echo "Build it before starting the service:"
    echo "  cd $ORCA_HUB_DIR"
    echo "  MIX_ENV=prod mix deps.get --only prod"
    echo "  MIX_ENV=prod mix assets.deploy"
    echo "  MIX_ENV=prod mix release"
    echo ""
fi

echo "Done! You can now:"
echo "  sudo systemctl enable orca-hub   # Enable on boot"
echo "  sudo systemctl start orca-hub    # Start the service"
echo "  sudo systemctl status orca-hub   # Check status"
echo ""
echo "After rebuilding the release, restart with:"
echo "  sudo systemctl restart orca-hub"
