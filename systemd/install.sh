#!/bin/bash
#
# Render and install the orca-hub systemd unit. Nothing else.
#
# Usage: ./install.sh [--user USER] [--memory-max SIZE] [--memory-high SIZE]
#                     [--memory-swap-max SIZE] [--private-devices yes|no]
#                     [--dry-run]
#
# What it does:
#   - Renders systemd/orca-hub.service.template ({{USER}}, {{HOME}},
#     {{MEMORY_HIGH}}, {{MEMORY_MAX}}, {{MEMORY_SWAP_MAX}},
#     {{PRIVATE_DEVICES}}) into
#     /etc/systemd/system/orca-hub.service as a REAL file. If the existing
#     destination is a symlink (e.g. into a checkout), it is replaced, never
#     written through.
#   - Resolves each memory limit, highest precedence first, from: its flag;
#     the ORCA_UNIT_MEMORY_HIGH / ORCA_UNIT_MEMORY_MAX /
#     ORCA_UNIT_MEMORY_SWAP_MAX environment variable; the value in the unit
#     that is installed now; the default (MemoryHigh=infinity, MemoryMax=6G,
#     MemorySwapMax=1G). Because the installed value wins over the default, a
#     reinstall never silently reverts a host's tuning. The source of every
#     value is printed.
#
#     These cap the WHOLE unit (BEAM + agent CLIs). Each agent CLI spawn also
#     gets its own cgroup limits inside it (Delegate=yes + DelegateSubgroup=
#     beam; ORCA_AGENT*_ in the .env, see config/runtime.exs). Suggested per
#     host (ORCAHUB3-145): debian and mini (16G, shared with k3s/Postgres)
#     --memory-max 6G --memory-swap-max 1G; gb10 (128G unified memory, most
#     of it held by GPU models) --memory-max 30G --memory-swap-max 2G. Keep
#     --memory-high at infinity: a MemoryHigh far below MemoryMax stalls the
#     whole service instead of OOM-killing the runaway.
#   - Resolves PrivateDevices= the same way (--private-devices,
#     ORCA_UNIT_PRIVATE_DEVICES, installed unit, default yes). An installed
#     unit WITHOUT the line counts as `no`: gb10's unit has always run
#     without it, and `yes` would hide /dev/nvidia* from its agents.
#   - Checks systemd >= 254 (DelegateSubgroup=).
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
#   --user USER             User to run the service as (default: current user)
#   --memory-max SIZE       Unit MemoryMax= (e.g. 6G, 30G)
#   --memory-high SIZE      Unit MemoryHigh= (default infinity; see above)
#   --memory-swap-max SIZE  Unit MemorySwapMax= (e.g. 1G)
#   --private-devices B     Unit PrivateDevices= (yes|no)
#   --dry-run               Show what would be installed; change nothing
#   -h, --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER="$(whoami)"
DRY_RUN=false
FLAG_MEMORY_HIGH=""
FLAG_MEMORY_MAX=""
FLAG_MEMORY_SWAP_MAX=""
FLAG_PRIVATE_DEVICES=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            USER="$2"
            shift 2
            ;;
        --memory-high)
            FLAG_MEMORY_HIGH="$2"
            shift 2
            ;;
        --memory-max)
            FLAG_MEMORY_MAX="$2"
            shift 2
            ;;
        --memory-swap-max)
            FLAG_MEMORY_SWAP_MAX="$2"
            shift 2
            ;;
        --private-devices)
            FLAG_PRIVATE_DEVICES="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--user USER] [--memory-max SIZE] [--memory-high SIZE] [--memory-swap-max SIZE] [--private-devices yes|no] [--dry-run]"
            echo ""
            echo "Render and install the orca-hub systemd unit (no build)."
            echo ""
            echo "Options:"
            echo "  --user USER             User to run the service as (default: current user)"
            echo "  --memory-max SIZE       Unit MemoryMax= (e.g. 6G; gb10 30G)"
            echo "  --memory-high SIZE      Unit MemoryHigh= (default infinity: kill, don't stall)"
            echo "  --memory-swap-max SIZE  Unit MemorySwapMax= (e.g. 1G; gb10 2G)"
            echo "  --private-devices B     Unit PrivateDevices= yes|no (gb10: no, for /dev/nvidia*)"
            echo "  --dry-run               Print the rendered unit and diff vs installed; change nothing"
            echo ""
            echo "A value comes from its flag, else ORCA_UNIT_MEMORY_HIGH/_MAX/_SWAP_MAX or"
            echo "ORCA_UNIT_PRIVATE_DEVICES, else the installed unit, else the default"
            echo "(infinity / 6G / 1G / yes)."
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

# DelegateSubgroup= (the BEAM starts in orca-hub.service/beam) needs systemd
# >= 254. Older systemd would refuse the unit outright.
check_systemd_version() {
    local version
    version="$(systemctl --version | head -n1 | awk '{print $2}')"
    version="${version%%[!0-9]*}"
    if [[ -z "$version" || "$version" -lt 254 ]]; then
        echo "Error: systemd ${version:-?} is too old for DelegateSubgroup= (needs >= 254)." >&2
        exit 1
    fi
    echo "  systemd: $version (DelegateSubgroup= supported)"
}

# The value KEY= has in the unit installed now (through a symlink, too), if any.
installed_value() {
    local key="$1"
    [[ -e "$DEST" ]] || return 0
    grep -E "^[[:space:]]*${key}=" "$DEST" 2>/dev/null | tail -n1 \
        | sed -E "s/^[[:space:]]*${key}=//; s/[[:space:]]+$//" || true
}

# systemd's own size syntax: bytes with an optional K/M/G/T suffix, a
# percentage of physical memory, or infinity.
valid_size() {
    [[ "$1" =~ ^([0-9]+(\.[0-9]+)?[KMGT]?|[0-9]+(\.[0-9]+)?%|infinity)$ ]]
}

# resolve_size NAME FLAG_VALUE ENV_VAR DEFAULT -> sets RESOLVED + RESOLVED_FROM
resolve_size() {
    local key="$1" flag="$2" env_var="$3" default="$4" installed
    installed="$(installed_value "$key")"
    if [[ -n "$flag" ]]; then
        RESOLVED="$flag"; RESOLVED_FROM="flag"
    elif [[ -n "${!env_var:-}" ]]; then
        RESOLVED="${!env_var}"; RESOLVED_FROM="\$$env_var"
    elif [[ -n "$installed" ]]; then
        RESOLVED="$installed"; RESOLVED_FROM="installed unit"
    else
        RESOLVED="$default"; RESOLVED_FROM="default"
    fi
    if ! valid_size "$RESOLVED"; then
        echo "Error: $key=$RESOLVED (from $RESOLVED_FROM) is not a systemd size (e.g. 6G, 512M, 50%, infinity)." >&2
        exit 1
    fi
    echo "  $key: $RESOLVED ($RESOLVED_FROM)"
}

resolve_memory_limits() {
    echo ""
    echo "Per-host settings (memory limits cover the whole unit):"
    resolve_size MemoryHigh "$FLAG_MEMORY_HIGH" ORCA_UNIT_MEMORY_HIGH infinity
    MEMORY_HIGH="$RESOLVED"
    resolve_size MemoryMax "$FLAG_MEMORY_MAX" ORCA_UNIT_MEMORY_MAX 6G
    MEMORY_MAX="$RESOLVED"
    resolve_size MemorySwapMax "$FLAG_MEMORY_SWAP_MAX" ORCA_UNIT_MEMORY_SWAP_MAX 1G
    MEMORY_SWAP_MAX="$RESOLVED"
    if [[ "$MEMORY_HIGH" != "infinity" ]]; then
        echo "  WARNING: MemoryHigh=$MEMORY_HIGH throttles the whole service (BEAM included) once" >&2
        echo "           it is crossed, instead of OOM-killing the runaway: that is the 11-hour" >&2
        echo "           stall of ORCAHUB3-145. Pass --memory-high infinity unless you mean it." >&2
    fi
}

# PrivateDevices=: flag, env, installed unit (no line there = systemd's
# default, `no`), default yes.
resolve_private_devices() {
    local installed
    if [[ -n "$FLAG_PRIVATE_DEVICES" ]]; then
        PRIVATE_DEVICES="$FLAG_PRIVATE_DEVICES"; RESOLVED_FROM="flag"
    elif [[ -n "${ORCA_UNIT_PRIVATE_DEVICES:-}" ]]; then
        PRIVATE_DEVICES="$ORCA_UNIT_PRIVATE_DEVICES"; RESOLVED_FROM="\$ORCA_UNIT_PRIVATE_DEVICES"
    elif [[ -e "$DEST" ]]; then
        installed="$(installed_value PrivateDevices)"
        if [[ -n "$installed" ]]; then
            PRIVATE_DEVICES="$installed"; RESOLVED_FROM="installed unit"
        else
            PRIVATE_DEVICES="no"; RESOLVED_FROM="installed unit has none"
        fi
    else
        PRIVATE_DEVICES="yes"; RESOLVED_FROM="default"
    fi
    case "$PRIVATE_DEVICES" in
        yes|no|true|false) ;;
        *) echo "Error: PrivateDevices=$PRIVATE_DEVICES (from $RESOLVED_FROM) must be yes or no." >&2; exit 1 ;;
    esac
    echo "  PrivateDevices: $PRIVATE_DEVICES ($RESOLVED_FROM)"
}

# Render the template.
render() {
    sed \
        -e "s|{{USER}}|$USER|g" \
        -e "s|{{HOME}}|$HOME_DIR|g" \
        -e "s|{{MEMORY_HIGH}}|$MEMORY_HIGH|g" \
        -e "s|{{MEMORY_MAX}}|$MEMORY_MAX|g" \
        -e "s|{{MEMORY_SWAP_MAX}}|$MEMORY_SWAP_MAX|g" \
        -e "s|{{PRIVATE_DEVICES}}|$PRIVATE_DEVICES|g" \
        "$TEMPLATE"
}

echo "Installing orca-hub.service..."
echo "  User: $USER"
echo "  Home: $HOME_DIR"
echo "  Dest: $DEST"
check_systemd_version
resolve_memory_limits
resolve_private_devices

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
