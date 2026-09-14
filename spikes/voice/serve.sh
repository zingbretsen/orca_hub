#!/usr/bin/env bash
# Start the voice spike harness static server.
#   ./serve.sh              -> http://localhost:8777/
#   ./serve.sh 9001         -> http://localhost:9001/
#   ./serve.sh 8777 --coi   -> also send COOP/COEP (wasm threads / SharedArrayBuffer)
#
# getUserMedia requires a SECURE CONTEXT. http://localhost:<port> is secure;
# http://192.168.1.x:<port> is NOT (navigator.mediaDevices is undefined, no error).
# From another machine:  ssh -L 8777:127.0.0.1:8777 zach@192.168.1.177
set -euo pipefail
cd "$(dirname "$0")"
PORT="${1:-8777}"; shift || true
exec python3 tools/server.py --port "$PORT" "$@"
