#!/usr/bin/env bash
# Re-download the vendored VAD runtime. The binaries are deliberately NOT in
# git: ~19 MB of wasm/onnx would bloat every clone AND this app's Docker build
# context. Everything here is pinned, so this is reproducible.
#
#   onnxruntime-web    1.29.0   MIT
#   @ricky0123/vad-web 0.0.31   ISC
set -euo pipefail
cd "$(dirname "$0")/.."
ORT=1.29.0
VAD=0.0.31
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p vendor/ort vendor/vad

echo "fetching onnxruntime-web@$ORT ..."
curl -sSfL -o "$TMP/ort.tgz" "https://registry.npmjs.org/onnxruntime-web/-/onnxruntime-web-$ORT.tgz"
tar xzf "$TMP/ort.tgz" -C "$TMP"
for f in ort.wasm.min.js ort-wasm-simd-threaded.wasm ort-wasm-simd-threaded.mjs; do
  cp "$TMP/package/dist/$f" vendor/ort/
done

echo "fetching @ricky0123/vad-web@$VAD ..."
rm -rf "$TMP/package"
curl -sSfL -o "$TMP/vad.tgz" "https://registry.npmjs.org/@ricky0123/vad-web/-/vad-web-$VAD.tgz"
tar xzf "$TMP/vad.tgz" -C "$TMP"
cp "$TMP/package/dist/bundle.min.js"             vendor/vad/vad-bundle.min.js
cp "$TMP/package/dist/vad.worklet.bundle.min.js" vendor/vad/
cp "$TMP/package/dist/silero_vad_v5.onnx"        vendor/vad/
cp "$TMP/package/dist/silero_vad_v6.onnx"        vendor/vad/
cp "$TMP/package/dist/bundle.min.js.LICENSE.txt" vendor/vad/ 2>/dev/null || true
cp "$TMP/package/README.md"                      vendor/vad/README.upstream.md

echo "done:"; find vendor -type f -printf '  %-46p %10s B\n' | sort
