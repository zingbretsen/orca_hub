#!/usr/bin/env python3
"""Wire-size accounting for the two keyword spotters.

The number that matters is the MARGINAL cost. SPIKE 1 already puts
onnxruntime-web + silero_vad_v5.onnx on the page for voice activity detection
(5.56 MB gzip), so openWakeWord adds only three .onnx files and no new runtime,
while Porcupine adds an entire second wasm runtime plus its own model files.
Both totals are reported either way.
"""
import gzip, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
KWS = os.path.join(HERE, "..")
VOICE = os.path.join(KWS, "..")

SHARED = [                      # already shipped by SPIKE 1's VAD stack
    ("ort.wasm.min.js", os.path.join(VOICE, "vendor/ort/ort.wasm.min.js")),
    ("ort-wasm-simd-threaded.wasm", os.path.join(VOICE, "vendor/ort/ort-wasm-simd-threaded.wasm")),
    ("ort-wasm-simd-threaded.mjs", os.path.join(VOICE, "vendor/ort/ort-wasm-simd-threaded.mjs")),
    ("silero_vad_v5.onnx", os.path.join(VOICE, "vendor/vad/silero_vad_v5.onnx")),
]
OWW = [
    ("melspectrogram.onnx", os.path.join(KWS, "vendor/oww/melspectrogram.onnx")),
    ("embedding_model.onnx", os.path.join(KWS, "vendor/oww/embedding_model.onnx")),
    ("hey_jarvis_v0.1.onnx", os.path.join(KWS, "vendor/oww/hey_jarvis_v0.1.onnx")),
]
OWW_ALT = [
    ("alexa_v0.1.onnx", os.path.join(KWS, "vendor/oww/alexa_v0.1.onnx")),
    ("hey_mycroft_v0.1.onnx", os.path.join(KWS, "vendor/oww/hey_mycroft_v0.1.onnx")),
]
PV = [
    ("porcupine-web.iife.min.js", os.path.join(KWS, "vendor/porcupine/porcupine-web.iife.min.js")),
    ("porcupine_params.pv", os.path.join(KWS, "vendor/porcupine/porcupine_params.pv")),
    ("computer_wasm.ppn", os.path.join(KWS, "vendor/porcupine/computer_wasm.ppn")),
]
GLUE = [("kws.js (this spike's engine code)", os.path.join(KWS, "kws.js"))]


def measure(items):
    out = []
    for name, p in items:
        if not os.path.exists(p):
            out.append({"name": name, "missing": True}); continue
        b = open(p, "rb").read()
        out.append({"name": name, "raw": len(b), "gzip": len(gzip.compress(b, 9))})
    return out


def total(rows):
    return (sum(r.get("raw", 0) for r in rows), sum(r.get("gzip", 0) for r in rows))


def main():
    groups = {"shared_with_spike1_vad": measure(SHARED), "openwakeword": measure(OWW),
              "openwakeword_extra_classifiers": measure(OWW_ALT),
              "porcupine": measure(PV), "harness_glue": measure(GLUE)}
    rep = {"groups": groups, "totals": {}}
    for k, rows in groups.items():
        r, g = total(rows)
        rep["totals"][k] = {"raw": r, "gzip": g}
    sh = rep["totals"]["shared_with_spike1_vad"]
    ow = rep["totals"]["openwakeword"]
    pv = rep["totals"]["porcupine"]
    rep["verdict"] = {
        "oww_marginal_over_vad_stack": ow,
        "porcupine_marginal_over_vad_stack": pv,
        "oww_standalone_total": {"raw": sh["raw"] + ow["raw"], "gzip": sh["gzip"] + ow["gzip"]},
        "note": "Porcupine ships its own wasm runtime INLINED as base64 inside "
                "porcupine-web.iife.min.js, so it shares nothing with onnxruntime-web; "
                "openWakeWord reuses the ort runtime the VAD already needs.",
    }
    dest = os.path.join(KWS, "out", "asset-sizes.json")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as f:
        json.dump(rep, f, indent=2)
    for k, rows in groups.items():
        print("##", k)
        for r in rows:
            if r.get("missing"):
                print("   %-44s MISSING" % r["name"]); continue
            print("   %-44s %10d  %10d" % (r["name"], r["raw"], r["gzip"]))
        t = rep["totals"][k]
        print("   %-44s %10d  %10d  (total)" % ("", t["raw"], t["gzip"]))
    print(json.dumps(rep["verdict"], indent=2))


if __name__ == "__main__":
    main()
