#!/usr/bin/env python3
"""Wire-size accounting for the two VAD options, raw / gzip / brotli."""
import gzip, json, os, sys
try:
    import brotli; HAVE_BR = True
except ImportError:
    HAVE_BR = False

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

# What each option actually has to download at runtime.
OPTIONS = {
    "@ricky0123/vad-web 0.0.31 (+ onnxruntime-web 1.29.0)": [
        "vendor/ort/ort.wasm.min.js",
        "vendor/ort/ort-wasm-simd-threaded.mjs",
        "vendor/ort/ort-wasm-simd-threaded.wasm",
        "vendor/vad/vad-bundle.min.js",
        "vendor/vad/vad.worklet.bundle.min.js",
        "vendor/vad/silero_vad_v5.onnx",
    ],
    "direct Silero on onnxruntime-web 1.29.0": [
        "vendor/ort/ort.wasm.min.js",
        "vendor/ort/ort-wasm-simd-threaded.mjs",
        "vendor/ort/ort-wasm-simd-threaded.wasm",
        "vendor/vad/silero_vad_v5.onnx",
        # our own state machine, which replaces the vad-web bundle
        "silero-direct.js",
        "capture-worklet.js",
    ],
}


def sizes(p):
    b = open(os.path.join(ROOT, p), "rb").read()
    row = {"raw": len(b), "gzip": len(gzip.compress(b, 9))}
    if HAVE_BR:
        row["brotli"] = len(brotli.compress(b, quality=11))
    return row


out = {"brotli_available": HAVE_BR, "options": {}}
for name, files in OPTIONS.items():
    rows = {f: sizes(f) for f in files}
    tot = {k: sum(r[k] for r in rows.values()) for k in next(iter(rows.values()))}
    out["options"][name] = {"files": rows, "total": tot}
print(json.dumps(out, indent=2))
