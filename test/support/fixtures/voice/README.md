# Voice intent corpus — reference output for `OrcaHub.Voice.Intent`

`intent_corpus.json` is the acceptance fixture for
`test/orca_hub/voice/intent_test.exs`. It is not a hand-written expectation
set: every `ref_intent` / `ref_score` in it was produced by **actually running
the normative Python reference**, so the Elixir port is checked for PARITY
rather than for "roughly the right accuracy".

## Provenance

| | |
|---|---|
| reference | `spike-asr/intent_ref.py` |
| repo | `/home/zach/transcription`, commit `4675905` — **on gb10 (`192.168.1.77`)**, not on the OrcaHub host |
| spec | `voice_mode_spec.md` section 5.1.1 |
| inputs | `spike-asr/results/wakeword_transcripts.json`, `spike-asr/audio/wakeword_manifest.json` |
| threshold | `0.85` |

The upstream corpus is SPIKE 2b's: 26 command phrases x 4 placements x 5-9
renderings through one synthetic Chatterbox voice, plus 32 decoy dictation
sentences and the SPIKE 2 negatives.

## Shape

```jsonc
{
  "source":    { /* the provenance table above, machine-readable */ },
  "aggregate": {"positives": 190, "tp": 184, "wrong_intent": 0,
                "miss": 6, "negatives": 154, "fp": 0},
  "observations": [
    {"clip": "c_orca_send__iso__v1",   // upstream clip name
     "rep": 0,                         // which transcription rep of that clip
     "text": "or Cascend,",            // what the ASR returned
     "label": "positive",              // "positive" | "negative"
     "expected_intent": "send",        // ground truth; null for negatives
     "ref_intent": "send",             // what intent_ref.py RETURNED at 0.85
     "ref_score": 0.9411764705882353}  // ...and the score it returned with
  ]
}
```

344 observations: **190 positives + 154 negatives**, the exact counts behind
the spec's headline. `ref_intent` is what the reference actually produced, so
it differs from `expected_intent` on the 6 misses — the port must reproduce the
misses too, not just the hits.

## Regenerating it

`intent_ref.py` only prints aggregates from its `__main__`, so the fixture was
produced by a throwaway driver that reuses the module's own `_verify()` loop
(same positive/negative selection, same TTS-ramble skip) and emits one record
per observation instead of a tally. Nothing was written into
`/home/zach/transcription` — the driver ran from `/tmp` on gb10.

```bash
scp driver.py zach@192.168.1.77:/tmp/dump_corpus.py
ssh zach@192.168.1.77 'python3 /tmp/dump_corpus.py' > intent_corpus.json
```

`driver.py`, verbatim:

```python
#!/usr/bin/env python3
"""Dump per-observation reference output for OrcaHub.Voice.Intent."""
import json, sys
from pathlib import Path

sys.path.insert(0, "/home/zach/transcription/spike-asr")
import intent_ref as R

here = Path("/home/zach/transcription/spike-asr")
cache = json.loads((here / "results/wakeword_transcripts.json").read_text())
man = {r["name"]: r for r in json.loads((here / "audio/wakeword_manifest.json").read_text())}
want = {f"orca_{i}": i for i in R.VOCAB}

obs = []
hit = wrong = miss = fp = npos = nneg = 0
for name, e in cache.items():
    r = man.get(name)
    if r is None:                      # SPIKE-2 negatives (s2_*)
        r = {"kind": "decoy"}
    for rep, text in enumerate(e["texts"]):
        got, sc = R.intent(text, threshold=0.85)
        if r.get("kind") == "command" and r["cmd"] in want:
            exp = max(0.8, len(r["text"]) / 13.5)   # skip TTS-ramble takes
            if (r["duration"] > exp * 1.25
                    and len(R._PUNCT.sub(" ", text.lower()).split())
                    > len(R._PUNCT.sub(" ", r["text"].lower()).split()) + 3):
                continue
            npos += 1
            hit += got == want[r["cmd"]]
            wrong += got is not None and got != want[r["cmd"]]
            miss += got is None
            obs.append({"clip": name, "rep": rep, "text": text, "label": "positive",
                        "expected_intent": want[r["cmd"]],
                        "ref_intent": got, "ref_score": sc})
        elif r.get("kind") in ("decoy", "spike2_neg"):
            nneg += 1
            fp += got is not None
            obs.append({"clip": name, "rep": rep, "text": text, "label": "negative",
                        "expected_intent": None,
                        "ref_intent": got, "ref_score": sc})

out = {
    "source": {
        "repo": "/home/zach/transcription (on gb10, 192.168.1.77)",
        "commit": "4675905",
        "reference": "spike-asr/intent_ref.py",
        "inputs": ["spike-asr/results/wakeword_transcripts.json",
                   "spike-asr/audio/wakeword_manifest.json"],
        "threshold": R.THRESHOLD,
        "vocab": R.VOCAB,
    },
    "aggregate": {"positives": npos, "tp": hit, "wrong_intent": wrong,
                  "miss": miss, "negatives": nneg, "fp": fp},
    "observations": obs,
}
print(json.dumps(out, indent=1))
print(f"# thr=0.85 TP {hit}/{npos} wrong {wrong} miss {miss} FP {fp}/{nneg}", file=sys.stderr)
```

It printed `# thr=0.85 TP 184/190 wrong 0 miss 6 FP 0/154`, which agrees with
`python3 intent_ref.py`'s own 0.85 row.

The committed JSON is that stdout re-dumped with `ensure_ascii=False`, which
only affects how non-ASCII transcript characters are escaped, never a value.
