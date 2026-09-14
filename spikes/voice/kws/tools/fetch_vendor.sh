#!/usr/bin/env bash
# Fetch the two keyword-spotter runtimes under test. Binaries are deliberately
# NOT in git (~8 MB). Everything is pinned, so this is reproducible.
#
#   @picovoice/porcupine-web 4.0.1   Apache-2.0 (SDK) + Picovoice license (models)
#   porcupine_params.pv      master  Picovoice model file
#   openWakeWord models      v0.5.1  Apache-2.0 (dscripka/openWakeWord)
#
# onnxruntime-web is NOT re-fetched here: SPIKE 1 already vendored 1.29.0 at
# spikes/voice/vendor/ort and this harness loads it from there.
set -euo pipefail
cd "$(dirname "$0")/.."
PV=4.0.1
OWW=v0.5.1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p vendor/porcupine vendor/oww

echo "fetching @picovoice/porcupine-web@$PV ..."
curl -sSfL -o "$TMP/pv.tgz" "https://registry.npmjs.org/@picovoice/porcupine-web/-/porcupine-web-$PV.tgz"
tar xzf "$TMP/pv.tgz" -C "$TMP"
cp "$TMP/package/dist/iife/index.min.js" vendor/porcupine/porcupine-web.iife.min.js
cp "$TMP/package/README.md"              vendor/porcupine/README.upstream.md
# The language model is NOT in the npm package; it is fetched separately and is
# the single biggest Porcupine asset.
curl -sSfL -o vendor/porcupine/porcupine_params.pv \
  "https://raw.githubusercontent.com/Picovoice/porcupine/master/lib/common/porcupine_params.pv"
# One built-in keyword file, as an example of what a custom .ppn weighs.
curl -sSfL -o vendor/porcupine/computer_wasm.ppn \
  "https://raw.githubusercontent.com/Picovoice/porcupine/master/resources/keyword_files/wasm/computer_wasm.ppn"

echo "fetching openWakeWord models @$OWW ..."
for f in melspectrogram.onnx embedding_model.onnx \
         hey_jarvis_v0.1.onnx alexa_v0.1.onnx hey_mycroft_v0.1.onnx; do
  curl -sSfL -o "vendor/oww/$f" \
    "https://github.com/dscripka/openWakeWord/releases/download/$OWW/$f"
done
curl -sSfL -o vendor/oww/LICENSE.upstream \
  "https://raw.githubusercontent.com/dscripka/openWakeWord/main/LICENSE" || true

echo "done:"; find vendor -type f -printf '  %-52p %10s B\n' | sort
