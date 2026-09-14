#!/usr/bin/env python3
"""Name every false accept instead of just counting it.

neg_speech records which sentence sits at which offset, so a detection can be
attributed to the utterance it fired on. "26 false accepts per hour" is a
number; "it fires on 'Alexandra said she would look at it on Monday'" is the
finding.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
KWS = os.path.join(HERE, "..")

fx = json.load(open(os.path.join(KWS, "assets", "kws_fixtures.json")))
rep = json.load(open(os.path.join(KWS, "out", sys.argv[1] if len(sys.argv) > 1 else "kws-report.json")))
utts = fx["fixtures"]["neg_speech"]["utterances"]

out = {}
for key, run in rep["runs"].items():
    if not key.startswith("fa_") or "neg_speech" not in key:
        continue
    rows = []
    for th, d in (run.get("byThreshold") or {}).items():
        for hit in d.get("at", []):
            at = hit["atMs"]
            # the spotter decides at the END of the chunk, and its receptive
            # field reaches ~2 s back, so attribute to the utterance whose span
            # contains the decision point, else the most recent one before it
            cand = [u for u in utts if u["onset_ms"] <= at <= u["offset_ms"] + 400]
            if not cand:
                cand = [u for u in utts if u["offset_ms"] <= at]
                cand = cand[-1:] if cand else []
            rows.append({"threshold": float(th), "atMs": at, "score": hit["score"],
                         "utterance": cand[0]["text"] if cand else None,
                         "slug": cand[0]["slug"] if cand else None})
    out[key] = {"durationMs": run["fixtureDurationMs"], "hits": rows}

dest = os.path.join(KWS, "out", "false-accepts.json")
json.dump(out, open(dest, "w"), indent=2)
for k, v in out.items():
    print("##", k, "(%.1f s)" % (v["durationMs"] / 1000))
    for h in v["hits"]:
        print("   th=%.1f  %7.0f ms  score=%.3f  [%s] %s"
              % (h["threshold"], h["atMs"], h["score"], h["slug"], h["utterance"]))
