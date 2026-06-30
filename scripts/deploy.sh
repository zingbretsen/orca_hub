#!/usr/bin/env bash
#
# deploy.sh — Canonical OrcaHub production deploy.
#
# Updates BOTH prod instances:
#   1. Local systemd service `orca-hub` (runs an OTP release from
#      _build/prod/rel/orca_hub) — updated by building a prod release and
#      restarting the service.
#   2. k3s deployment `orca-hub` in namespace `lab` — updated by building and
#      pushing the Docker image, then rolling the deployment.
#
# Flow (matches the intended deploy order):
#   Step 1 — build local prod release
#   Step 2 — build + push image, roll k3s
#   Step 3 — restart local systemd
#
# Flags:
#   --skip-release   skip building the local prod OTP release (Step 1)
#   --skip-local     skip restarting the local systemd service (Step 3)
#                    NOTE: --skip-release does not imply --skip-local; the
#                    local service can be restarted on an existing release.
#   --skip-k3s       skip the Docker build/push + k3s rollout (Step 2)
#   -h, --help       show this help
#
# Examples:
#   scripts/deploy.sh                 # full deploy (both targets)
#   scripts/deploy.sh --skip-k3s      # local release + systemd only
#   scripts/deploy.sh --skip-local --skip-release   # k3s image roll only
#
set -euo pipefail

# --- Configuration ---------------------------------------------------------
IMAGE="registry.lab.ingbretsenhome.com/orca-hub:latest"
K8S_DEPLOYMENT="deployment/orca-hub"
K8S_NAMESPACE="lab"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/k3s.yaml}"
SYSTEMD_UNIT="orca-hub"

# --- Resolve repo root from this script's location -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- Flags -----------------------------------------------------------------
SKIP_RELEASE=0
SKIP_LOCAL=0
SKIP_K3S=0

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-release) SKIP_RELEASE=1 ;;
    --skip-local)   SKIP_LOCAL=1 ;;
    --skip-k3s)     SKIP_K3S=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; echo "Try --help." >&2; exit 2 ;;
  esac
  shift
done

# --- Helpers ---------------------------------------------------------------
banner() {
  echo ""
  echo "=============================================================="
  echo ">>> $*"
  echo "=============================================================="
}

step_skipped() {
  echo ""
  echo "--- SKIPPED: $* ---"
}

# --- Step 1: Build local prod OTP release ----------------------------------
if [[ "$SKIP_RELEASE" -eq 0 ]]; then
  banner "Step 1/3 — Building local prod OTP release"
  echo "Repo root: $REPO_ROOT"
  MIX_ENV=prod mix deps.get --only prod
  MIX_ENV=prod mix assets.deploy
  MIX_ENV=prod mix release --overwrite
  echo "Prod release built into _build/prod/rel/orca_hub"
else
  step_skipped "Step 1/3 — build local prod release (--skip-release)"
fi

# --- Step 2: Build + push image, roll k3s ----------------------------------
if [[ "$SKIP_K3S" -eq 0 ]]; then
  banner "Step 2/3 — Building image, pushing, and rolling k3s"
  echo "Image: $IMAGE"
  docker build -t "$IMAGE" .
  docker push "$IMAGE"
  echo "Rolling $K8S_DEPLOYMENT in namespace $K8S_NAMESPACE (kubeconfig: $KUBECONFIG_PATH)"
  KUBECONFIG="$KUBECONFIG_PATH" kubectl rollout restart "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE"
else
  step_skipped "Step 2/3 — Docker build/push + k3s rollout (--skip-k3s)"
fi

# --- Step 3: Restart local systemd service ---------------------------------
if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  banner "Step 3/3 — Restarting local systemd service: $SYSTEMD_UNIT"
  sudo systemctl restart "$SYSTEMD_UNIT"
  echo "Service restarted. Recent status:"
  systemctl --no-pager --lines=0 status "$SYSTEMD_UNIT" || true
else
  step_skipped "Step 3/3 — restart local systemd service (--skip-local)"
fi

# --- Final summary ---------------------------------------------------------
banner "Deploy complete"
echo "Summary:"
[[ "$SKIP_RELEASE" -eq 0 ]] && echo "  [x] Built local prod OTP release" || echo "  [ ] (skipped) local prod release"
[[ "$SKIP_K3S"     -eq 0 ]] && echo "  [x] Built + pushed image and rolled k3s deployment" || echo "  [ ] (skipped) Docker image + k3s rollout"
[[ "$SKIP_LOCAL"   -eq 0 ]] && echo "  [x] Restarted local systemd service ($SYSTEMD_UNIT)" || echo "  [ ] (skipped) local systemd restart"
echo ""
echo "Done."
