#!/usr/bin/env bash
# Static server for the SPIKE 3 harness.
# Root is spikes/voice/ (the PARENT), not spikes/voice/kws/, so the page can
# reuse SPIKE 1's /vendor/ort/ and /capture-worklet.js read-only while all of
# this spike's own files stay under /kws/.
set -euo pipefail
cd "$(dirname "$0")/../.."          # spikes/voice
PORT="${1:-8791}"                   # 8777 is SPIKE 1's; 4000/4001 are the app's
exec python3 kws/tools/server.py --port "$PORT"
