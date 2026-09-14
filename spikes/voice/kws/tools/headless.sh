#!/usr/bin/env bash
# Drive the SPIKE 3 harness headlessly. Requires tools/serve.sh already running.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SPIKE_PORT:=8791}"
if [ -z "${PLAYWRIGHT_DIR:-}" ]; then
  PLAYWRIGHT_DIR="$(ls -d /home/zach/.npm/_npx/*/node_modules 2>/dev/null \
    | while read d; do [ -f "$d/playwright/package.json" ] && echo "$d"; done | tail -1)"
fi
[ -n "$PLAYWRIGHT_DIR" ] || { echo "playwright not found; npx playwright --version once" >&2; exit 1; }
export PLAYWRIGHT_DIR SPIKE_PORT
echo "using playwright at $PLAYWRIGHT_DIR (port $SPIKE_PORT)" >&2
exec node tools/headless.mjs "$@"
