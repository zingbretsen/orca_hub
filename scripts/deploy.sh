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
#   Step 1 — git push the deployed commit to origin
#   Step 2 — build local prod release
#   Step 3 — build + push image, roll k3s
#   Step 4 — restart local systemd
#
# The push runs FIRST so origin reflects exactly the commit being deployed,
# and (under `set -euo pipefail`) a rejected push halts the deploy before any
# build work. It must never come after the local systemd restart, which
# terminates this script's own host process.
#
# Flags:
#   --skip-push      skip pushing the current branch to origin (Step 1)
#   --skip-release   skip building the local prod OTP release (Step 2)
#   --skip-local     skip restarting the local systemd service (Step 4)
#                    NOTE: --skip-release does not imply --skip-local; the
#                    local service can be restarted on an existing release.
#   --skip-k3s       skip the Docker build/push + k3s rollout (Step 3)
#   -h, --help       show this help
#
# Examples:
#   scripts/deploy.sh                 # full deploy (push + both targets)
#   scripts/deploy.sh --skip-k3s      # push + local release + systemd only
#   scripts/deploy.sh --skip-local --skip-release   # push + k3s image roll only
#   scripts/deploy.sh --skip-push     # full deploy without pushing to origin
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
SKIP_PUSH=0
SKIP_RELEASE=0
SKIP_LOCAL=0
SKIP_K3S=0

usage() {
  sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-push)    SKIP_PUSH=1 ;;
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

# --- Step 1: Push the deployed commit to origin -----------------------------
if [[ "$SKIP_PUSH" -eq 0 ]]; then
  banner "Step 1/4 — Pushing current branch to origin"
  git push
  echo "Pushed to origin."
else
  step_skipped "Step 1/4 — git push to origin (--skip-push)"
fi

# --- Step 2: Build local prod OTP release ----------------------------------
if [[ "$SKIP_RELEASE" -eq 0 ]]; then
  banner "Step 2/4 — Building local prod OTP release"
  echo "Repo root: $REPO_ROOT"
  MIX_ENV=prod mix deps.get --only prod
  MIX_ENV=prod mix assets.deploy
  MIX_ENV=prod mix release --overwrite
  echo "Prod release built into _build/prod/rel/orca_hub"
else
  step_skipped "Step 2/4 — build local prod release (--skip-release)"
fi

# --- Step 3: Build + push image, roll k3s ----------------------------------
if [[ "$SKIP_K3S" -eq 0 ]]; then
  banner "Step 3/4 — Building image, pushing, and rolling k3s"
  echo "Image: $IMAGE"
  docker build -t "$IMAGE" .
  docker push "$IMAGE"
  echo "Rolling $K8S_DEPLOYMENT in namespace $K8S_NAMESPACE (kubeconfig: $KUBECONFIG_PATH)"
  KUBECONFIG="$KUBECONFIG_PATH" kubectl rollout restart "$K8S_DEPLOYMENT" -n "$K8S_NAMESPACE"
else
  step_skipped "Step 3/4 — Docker build/push + k3s rollout (--skip-k3s)"
fi

# --- Step 4: Restart local systemd service ---------------------------------
if [[ "$SKIP_LOCAL" -eq 0 ]]; then
  banner "Step 4/4 — Restarting local systemd service: $SYSTEMD_UNIT"
  sudo systemctl restart "$SYSTEMD_UNIT"
  echo "Service restarted. Recent status:"
  systemctl --no-pager --lines=0 status "$SYSTEMD_UNIT" || true
else
  step_skipped "Step 4/4 — restart local systemd service (--skip-local)"
fi

# --- Final summary ---------------------------------------------------------
banner "Deploy complete"
echo "Summary:"
[[ "$SKIP_PUSH"    -eq 0 ]] && echo "  [x] Pushed current branch to origin" || echo "  [ ] (skipped) git push to origin"
[[ "$SKIP_RELEASE" -eq 0 ]] && echo "  [x] Built local prod OTP release" || echo "  [ ] (skipped) local prod release"
[[ "$SKIP_K3S"     -eq 0 ]] && echo "  [x] Built + pushed image and rolled k3s deployment" || echo "  [ ] (skipped) Docker image + k3s rollout"
[[ "$SKIP_LOCAL"   -eq 0 ]] && echo "  [x] Restarted local systemd service ($SYSTEMD_UNIT)" || echo "  [ ] (skipped) local systemd restart"
echo ""
echo "Done."
