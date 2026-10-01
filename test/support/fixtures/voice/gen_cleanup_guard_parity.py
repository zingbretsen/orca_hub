#!/usr/bin/env python3
"""Dump the reference acceptance-guard decision for every recorded bench output.

Produces `cleanup_guard_parity.json`, the fixture behind
`test/orca_hub/voice/cleanup/guard_test.exs`. The guard is NOT re-implemented
here: the features and the decision come from the bench's own code, loaded by
path —

  * `guard.py`  — `content`/`STOP`, `protected_ok`/`PROTECT`, `GLOSS`,
                  `guard_features`, `FINAL = mk(0.1, 1)`
  * `score.py`  — `norm_tokens`, `FILLERS`, `GLOSSARY_TOKENS`, and the
                  `g_novel`/`g_len` formulas (copied from `score_row`, the only
                  two lines not callable on their own)

`guard.py` runs its whole analysis at import (it prints tables), so it is run
with stdout swallowed and its globals are lifted out afterwards.

Usage (from anywhere; the bench lives outside the repo):

    python3 test/support/fixtures/voice/gen_cleanup_guard_parity.py \
        > test/support/fixtures/voice/cleanup_guard_parity.json
"""
import contextlib
import io
import json
import runpy
import sys
from collections import defaultdict
from pathlib import Path

BENCH = Path.home() / "voice-cleanup-bench"
sys.path.insert(0, str(BENCH))

import score as S  # noqa: E402

with contextlib.redirect_stdout(io.StringIO()):
    G = runpy.run_path(str(BENCH / "guard.py"))

FINAL = G["FINAL"]
RESULT_FILES = ["qwen2.5-3b-instruct.jsonl", "gemma-4-26B-A4B.jsonl", "nemotron-3.5-lightning.jsonl", "holdout.jsonl"]

raws = {json.loads(l)["id"]: json.loads(l)["raw"] for l in (BENCH / "cases.jsonl").open()}
raws.update({json.loads(l)["id"]: json.loads(l)["raw"] for l in (BENCH / "holdout.jsonl").open()})


def features(raw, out):
    n, miss, intro = G["guard_features"](raw, out)
    out_t, raw_t = S.norm_tokens(out), S.norm_tokens(raw)
    raw_nf = [t for t in raw_t if t not in S.FILLERS]
    r = {
        "g_n": n,
        "g_miss": miss,
        "g_intro": intro,
        "g_miss_adj": max(0, miss - 2 * intro),
        # score.py score_row, verbatim:
        "g_novel": sum(t not in set(raw_t) | S.GLOSSARY_TOKENS for t in out_t) / max(1, len(out_t)),
        "g_len": len(out_t) / max(1, len(raw_nf)),
        "g_prot": G["protected_ok"](raw, out),
    }
    reason = None
    if r["g_miss_adj"] > max(1, int(0.1 * r["g_n"])):
        reason = "missing_content"
    elif r["g_novel"] > 0.25:
        reason = "novel"
    elif r["g_len"] > 1.6:
        reason = "too_long"
    elif not r["g_prot"]:
        reason = "protected"
    accept = FINAL(r)
    assert accept == (reason is None), (raw, out, r)
    return r, accept, reason


# Manual good/bad verdicts exist only for guard.py's own population (tag
# "main", usable). Count them per unique (case, output) so the Elixir side can
# reproduce the report's headline false-reject / catch numbers.
verdicts = defaultdict(lambda: {"good": 0, "bad": 0})
for r in G["rows"]:
    verdicts[(r["case"], r["text"])]["good" if r["kind"] == "good" else "bad"] += 1
    # Cross-check: our recomputation agrees with guard.py's own FINAL on its rows.
    assert features(raws[r["case"]], r["text"])[1] == FINAL(r), r["case"]

pairs = {}
runs = defaultdict(int)
for name in RESULT_FILES:
    for line in (BENCH / "results" / name).open():
        rec = json.loads(line)
        text = rec.get("text")
        if text is None:  # structural failure / HTTP error: nothing to guard
            continue
        key = (rec["case"], text)
        runs[key] += 1
        pairs.setdefault(key, rec["model"])

rows = []
for (case, text) in sorted(pairs, key=lambda k: (k[0], k[1])):
    f, accept, reason = features(raws[case], text)
    v = verdicts.get((case, text))
    rows.append({
        "case": case,
        "output": text,
        "runs": runs[(case, text)],
        "n": f["g_n"], "miss": f["g_miss"], "intro": f["g_intro"], "miss_adj": f["g_miss_adj"],
        "novel": f["g_novel"], "len": f["g_len"], "prot": f["g_prot"],
        "accept": accept, "reason": reason,
        "good": v["good"] if v else 0, "bad": v["bad"] if v else 0,
    })

good = [r for r in G["rows"] if r["kind"] == "good"]
bad = [r for r in G["rows"] if r["kind"] != "good"]
aggregate = {
    "unique_pairs": len(rows),
    "recorded_outputs": sum(runs.values()),
    "accepted_pairs": sum(r["accept"] for r in rows),
    "rejected_pairs": sum(not r["accept"] for r in rows),
    "verdict_good": len(good),
    "verdict_bad": len(bad),
    "good_rejected": sum(not FINAL(r) for r in good),
    "bad_caught": sum(not FINAL(r) for r in bad),
}

out = {
    "source": {
        "bench": "~/voice-cleanup-bench (outside the repo)",
        "rule": "guard.py FINAL = mk(0.1, 1): miss_adj <= max(1, int(0.1 * n)) and novel <= 0.25 "
                "and len <= 1.6 and protected tokens verbatim",
        "reason_order": ["missing_content", "novel", "too_long", "protected"],
        "inputs": ["cases.jsonl", "holdout.jsonl"] + [f"results/{f}" for f in RESULT_FILES],
        "credit_glossary": G["GLOSS"],
        "novelty_glossary": sorted(S.GLOSSARY_TOKENS),
        "output_strip": "lib.py extract(): str.strip() only; no recorded output was quoted or fenced",
    },
    "aggregate": aggregate,
    "cases": {k: raws[k] for k in sorted({r["case"] for r in rows})},
    "rows": rows,
}
# One row per line: diffable, and a third the size of indent=1.
head = json.dumps({k: v for k, v in out.items() if k != "rows"}, indent=1, ensure_ascii=False)
body = ",\n".join("  " + json.dumps(r, ensure_ascii=False) for r in rows)
print(head[:-2] + ',\n "rows": [\n' + body + "\n ]\n}")
print(f"# {aggregate}", file=sys.stderr)
