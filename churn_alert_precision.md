# Churn alert precision — ORCAHUB3-66

Measurement of what the worker-alert path has actually produced in production:
every `[Worker alert]` ever delivered, what the receiving orchestrator did about
it, a hand-labelled sample, and an offline counterfactual for each proposed
discriminator. Companion to `churn_signal_mining.md` (which ranked candidate
SIGNALS before the detector shipped); this document measures the DETECTOR after
it shipped. No `lib/` or `test/` file was touched to produce it.

**Headline numbers, up front:**

| | |
|---|---:|
| `[Worker alert]` messages ever delivered | **237** (2026-08-23 → 2026-09-19) |
| …of which `churn` | **230** (97.0%) |
| …of which carry a file-surgery clause | **229** (99.6% of churn) |
| …`paired_with_failed_edit: true` | **0** |
| Precision **proxy** (orchestrator redirect ≤30 min), all alerts | **24.1%** (57/237) |
| Precision **proxy**, unpaired file-surgery subset | **23.6%** (54/229) |
| Precision **hand-labelled**, stratified sample of 39 | **7.7%** (3/39) |
| Hand-labelled "prompted a useful intervention it did not predict" | 2/39 |
| Alerts that cost a peek and produced nothing (30 min) | **53.2%** (126/237) |
| Hand-labelled true positives lost by the recommended discriminator | **0 of 3** |

The proxy and the hand labels **disagree by a factor of ~3** and that
disagreement is itself a finding — see §B.4. Where they disagree, the hand
labels govern.

---

## Step 0 — corpus and database

Same setup as `churn_signal_mining.md`: **`orca_hub_prod`** on the shared
Postgres host, reached with `.env`'s `DB_HOST`/`DB_USERNAME`/`DB_PASSWORD` but
with `database: "orca_hub_prod"` overridden explicitly in every script
(`.env`'s `DB_NAME=orca_hub_dev` is the wrong database). All queries were
read-only. `orca_hub_prod` currently holds 4,314 sessions and 1,163,256
messages spanning 2026-02-01 → 2026-09-19.

Every alert ever delivered is persisted, because `AlertEvaluator` hands its
alerts to `SessionHeartbeat.deliver_or_queue/2`, which writes them into the
ORCHESTRATOR's own message feed. So the corpus is exact, not sampled.

### Extraction rule, and what it excludes

```sql
select m.id, m.session_id, m.inserted_at, e->>'text'
from messages m, lateral jsonb_array_elements(m.data->'message'->'content') e
where m.data->>'type' = 'user'
  and jsonb_typeof(m.data->'message'->'content') = 'array'
  and e->>'text' like '%[Worker alert]%'
```

A naive `data::text like '%[Worker alert]%'` returns **590** rows and is wrong:
it also matches every `tool_result` in which some session PRINTED an alert while
investigating one, and every prompt (including this task's own brief) that
quotes the literal string. Restricting to `user`-role **text** blocks gives 251
blocks; parsing each with

```
\[Worker alert\] (?<cond>[a-z_]+) on (?<title>.*?) \((?<uuid>[0-9a-f-]{36}\)): 
```

yields **237 alerts**. The 15 blocks that fail to parse were all inspected
individually: every one is prose ABOUT alerts (issue briefs, worker reports,
orchestrator instructions), none is a delivery. A single message can carry more
than one alert (queued delivery batches them), so the parser splits each text
block at every header occurrence rather than taking the first.

**Delivery lag matters and is measured.** `messages.inserted_at` is when the
alert was DELIVERED, not when it was evaluated — `deliver_or_queue` holds it
while the orchestrator is mid-turn. Lag between the flagged Bash call and the
alert row: median **53 s**, p90 **332 s**, max **698 s**. Every window in §D is
therefore anchored on the flagged call's own timestamp (recovered by matching
the alert's quoted command back into the worker's transcript — located for
**229/229** file-surgery alerts), never on `inserted_at`.

---

## A. The alert corpus

**237 alerts, 38 distinct orchestrators, 135 distinct workers, 20 working
directories, 2026-08-23 20:08 → 2026-09-19 18:59.**

### A.1 By condition

| condition | alerts |
|---|---:|
| `churn` | 230 |
| `stall` | 6 |
| `no_commit_for` | 1 |
| `progress_stale` | 0 |
| `pending_question` | 0 |

`churn` is 97% of all alert traffic. `progress_stale` and `pending_question`
have never fired in production.

### A.2 `churn` is, in practice, the file-surgery detector

| | alerts |
|---|---:|
| churn alerts WITH a file-surgery clause | **229** |
| churn alerts from the volumetric gate alone | **1** |

This is the single most important structural fact in the corpus. `Churn.assess/5`
computes `churn_suspected = volumetric_churn or file_surgery_suspected`, and in
seven weeks of production the volumetric half has contributed **one** alert. The
`churn` condition an orchestrator subscribes to is, empirically, `FileSurgery.detect/1`
with a volumetric footnote attached.

### A.3 By family (`kind`) and confidence

| kind | alerts | share |
|---|---:|---:|
| `programmatic_write` | 130 | 56.8% |
| `write_to_tracked` | 80 | 34.9% |
| `in_place_edit` | 17 | 7.4% |
| `slice_and_redirect` | 2 | 0.9% |

| `paired_with_failed_edit` | alerts |
|---|---:|
| `false` (unpaired, "lower confidence") | **229** |
| `true` (paired, "high confidence") | **0** |

**No paired alert has ever been delivered.** `churn_signal_mining.md` measured
pairing as the strongest available confidence signal (P=0.92 paired vs P=0.72
unpaired) and the detector's message format still advertises the distinction —
but in production the high-confidence branch is dead code. The task brief asked
for "every `paired_with_failed_edit: true` alert you can find, since those are
rare and are the signal we must NOT damage"; there are none to protect. §D.3
quantifies why.

The distribution is also inverted relative to the mining run's predictions.
`programmatic_write` was measured at P=1.00 **R=0.02** — the rarest family — and
is now 57% of all alerts. `slice_and_redirect`, the family the original
ORCAHUB3-61 incident was written around, has fired twice, and **both** were
matcher artefacts rather than file surgery (§A.6).

### A.4 What is being written

| path class | alerts |
|---|---:|
| code (`.ex .exs .js .py .ts .heex .erl`) | 141 |
| markdown/docs (`.md`) | 50 |
| data/config (`.json .yaml .yml .toml`) | 21 |
| shell script (`.sh`) | 16 |
| `.html` | 1 |

**One alert in three is about a document, a config file, or a shell script** —
not source the worker is failing to edit.

### A.5 Volumetric numbers carried at alert time

Repetition ratio in the alert body (churn alerts, n=230):

| repeats | alerts |
|---:|---:|
| 0% | 117 |
| 1–4% | 57 |
| 5–9% | 32 |
| 10–19% | 21 |
| ≥20% | 2 |
| n/a | 1 |

**Every single alert is below `@churn_min_repetition` (0.5 = 50%).** The highest
repetition ratio ever carried by a delivered alert is 23%. Tool-call volume:
67 alerts under 25 calls/15m (below `@churn_min_calls`), 85 at 25–49, 77 at ≥50.

Other body fields: 80/229 (34.9%) carry no `Top edited files:` line at all (the
worker made no repo edits in the window); 54/229 (23.6%) carry **neither** a
`Top edited files:` nor a `Repeated calls:` line — the file-surgery sentence is
the entire evidence. 37/229 carry a `Failing tests:` block.

### A.6 Two matcher defects visible in the corpus

Found by reading the flagged commands, not by testing:

1. **Family (c) takes the path from anywhere in the command string.**
   `match_family_c/1` splits the whole command on whitespace/quotes and returns
   the first token that looks like a tracked path — so a `python3 - <<'PY'`
   script that READS `lib/foo/CLAUDE.md` and writes `/tmp/out.md` is reported as
   "worker rebuilding lib/foo/CLAUDE.md". Confirmed in sample #6, where the
   alert named `/home/zach/projects/tts/README.md` for a command whose only
   write was `open("/tmp/tts-arb-check/blocks.txt","w")`. With
   `programmatic_write` at 57% of the corpus this is not a corner case.

2. **`real_output_redirect?/1` sees `>` inside ordinary text.** Both
   `slice_and_redirect` alerts are this. Sample #27's command is
   `cat config/test.exs | head -40 && echo "=== env ===" && env | grep … | sed 's/PASSWORD=.*/PASSWORD=<redacted>/'`
   — a pure READ. The `>` that made `real_output_redirect?` true came from the
   literal string `<redacted>`.

Neither defect is what ORCAHUB3-66 is about, but both inflate the corpus, and
(1) in particular means a share of the `programmatic_write` bucket is naming the
wrong file.

### A.7 Re-fire tax

208 distinct (worker, path) pairs produced 229 alerts, so **21 alerts (9%) are a
cooldown re-fire of a pair that already alerted**; 6 re-fire on a byte-identical
command. The deploy-runner case (§E) is the clearest instance: 6 deploys × 2
alerts each.

---

## B. Precision proxy — did the alert change anything?

### B.1 The rule

For each alert `(orchestrator O, worker W, delivery time T)` and window N ∈
{15, 30} minutes, over O's own `tool_use` blocks in `(T, T+N]` that mention W's
UUID:

- **peek** — a call whose code contains `get_session_tail`.
- **any message** — a `send_message_to_session` call, or a
  `session_interactions` row `(sender=O, recipient=W, kind='message')`.
- **redirect** — a `send_message_to_session` whose body names the flagged PATH,
  or matches a word-bounded correction vocabulary (`sed -i`, `edit tool`,
  `heredoc`, `python3 - <<`, `shell fragment`, `in-place`, `churn`, `wedged`,
  `STOP` (uppercase), `stand down`, `abandon`, `stuck`, `spinning`, `unbounded`,
  `poll loop`, `nohup`, `disown`).

A methodology bug worth recording: an early pass matched `sed` as a bare
substring and scored 138 hits, because `sed` is inside `used`, `based`,
`supersedes` and `advised`. Word boundaries cut that to 27. Any keyword rule
here needs `\b`.

### B.2 Results, with placebo controls

Two placebo windows are reported alongside: one ENDING an hour before the alert,
one STARTING an hour after. If the alert causes nothing, the three columns match.

**N = 15 min**

| signal | post-alert | placebo before | placebo after |
|---|---:|---:|---:|
| peek naming the worker | **157 (66.2%)** | 3 (1.3%) | 3 (1.3%) |
| any message to the worker | 112 (47.3%) | 10 (4.2%) | 9 (3.8%) |
| **redirect** | **48 (20.3%)** | 1 (0.4%) | 2 (0.8%) |
| …message naming the flagged path | 27 (11.4%) | 0 (0.0%) | 1 (0.4%) |
| peek, no redirect | 116 (48.9%) | | |
| nothing at all | 51 (21.5%) | | |

**N = 30 min**

| signal | post-alert | placebo before | placebo after |
|---|---:|---:|---:|
| peek naming the worker | **174 (73.4%)** | 4 (1.7%) | 9 (3.8%) |
| any message to the worker | 129 (54.4%) | 11 (4.6%) | 8 (3.4%) |
| **redirect** | **57 (24.1%)** | 3 (1.3%) | 4 (1.7%) |
| …message naming the flagged path | 29 (12.2%) | 0 (0.0%) | 1 (0.4%) |
| peek, no redirect | **126 (53.2%)** | | |
| nothing at all | 34 (14.3%) | | |

The placebo columns are the load-bearing part: at 1.3–1.7% baseline, a 73% peek
rate is unambiguously caused by the alert. **An alert reliably buys a peek. It
buys a redirect about a quarter of the time. The modal outcome — 53% — is
"cost a peek, produced nothing."**

### B.3 Breakdowns (proxy, N=30)

| group | alerts | peek | redirect | peek-no-redirect | proxy precision |
|---|---:|---:|---:|---:|---:|
| **condition: churn** | 230 | 168 | 54 | 123 | **23.5%** |
| condition: stall | 6 | 5 | 3 | 2 | 50.0% |
| condition: no_commit_for | 1 | 1 | 0 | 1 | 0.0% |
| kind: programmatic_write | 130 | 97 | 29 | 74 | 22.3% |
| kind: write_to_tracked | 80 | 54 | 18 | 39 | 22.5% |
| kind: in_place_edit | 17 | 14 | 6 | 8 | 35.3% |
| kind: slice_and_redirect | 2 | 2 | 1 | 1 | 50.0% |
| **paired: false (all of them)** | 229 | 167 | 54 | 122 | **23.6%** |
| paired: true | 0 | — | — | — | — |
| repeats 0% | 117 | 86 | 22 | 65 | 18.8% |
| repeats 1–4% | 57 | 45 | 22 | 26 | 38.6% |
| repeats 5–9% | 32 | 20 | 5 | 18 | 15.6% |
| repeats 10–19% | 21 | 15 | 5 | 12 | 23.8% |
| repeats ≥20% | 2 | 1 | 0 | 1 | 0.0% |
| calls/15m <25 | 67 | 44 | 14 | 34 | 20.9% |
| calls/15m 25–49 | 85 | 62 | 20 | 45 | 23.5% |
| calls/15m ≥50 | 77 | 61 | 20 | 43 | 26.0% |
| no repo edits in window | 81 | 52 | 16 | 39 | 19.8% |
| has repo edits | 149 | 116 | 38 | 84 | 25.5% |

Nothing here separates cleanly. The spread across `kind` is 22–35% on samples
too small to distinguish (the 50% cells are n=2 and n=6). Volume barely moves it
(20.9% → 26.0% across a 2× change in call rate). This is the first sign that the
detector's own evidence fields do not carry the signal.

Worker outcome: 233/237 workers are now `idle`, 4 `running`; **none** of the
alerted workers ended in `error`. 145/237 alerts were followed by the worker
being archived within 30 min and 205/237 within 2 h — i.e. most alerts fire near
the END of a worker's life, when it is wrapping up, not when it is stuck.

### B.4 This proxy is biased in BOTH directions — read before using any number above

The proxy is a characterisation of the corpus at scale. It is **not** a
precision measurement, and it must never be blended with §C's hand labels.

**It over-counts false positives (via "ignored").** An orchestrator trained by
repeated noise stops peeking. Observed directly on 2026-09-19: the same
deploy-runner alert fired twice per deploy across six deploys, and only 6 of
those 12 drew a peek — the *first* alert of a pair was peeked for 4 of the 6
deploys, the cooldown re-fire for only 1, and the last deploy of the day drew
none at all. Those score "ignored" and happen to be genuinely false — but
**"ignored" is not evidence of falseness**; a fatigued orchestrator ignoring a
TRUE alert scores identically. Alert fatigue and correctness are confounded in
the same bucket, and the confound is *worst* for the most repetitive alerts,
which is exactly where the aggregate numbers look most decisive.

**It under-counts true positives (via "unpredicted interventions").** A peek can
surface a real problem the alert did not itself identify. That is neither a
clean true positive (the detector did not find it) nor a clean false one (the
alert paid for itself). §C gives these their own label.

**Measured disagreement.** On the same 39 alerts:

| | |
|---|---:|
| proxy says REDIRECT | 10 (25.6%) |
| hand label TRUE | 3 (7.7%) |
| hand label TRUE or AMBIGUOUS | 5 (12.8%) |

Confusion: of the 10 proxy-redirects, 3 are hand-labelled TRUE, 2 AMBIGUOUS, and
**5 are hand-labelled FALSE** — routine coordination that happened to land in
the window and use correcting language (e.g. sample #5, where the orchestrator
interrupted with an unrelated "the work is good, its location is wrong"
correction ~3 min after the alert, and *separately* filed an issue calling that
same alert a false positive). Proxy recall is 3/3 — it caught every hand-labelled
true positive — but **proxy precision is 3/10**. The proxy overstates real
precision by roughly 2.6×.

Two sub-signals survive the comparison better than the headline:
- **peek-then-nothing** was FALSE in **20/20** sampled cases. As a *negative*
  marker it is clean.
- **ignored entirely** was FALSE in 6/6 — but n=6, and per the fatigue confound
  above this must not be generalised.

Other failure modes, stated plainly: an orchestrator may act via a channel this
proxy cannot see (`archive_session`, or a decision recorded only in its own
reasoning); a redirect may be delivered outside the window; `get_session_tail`
called through a loop over several session ids counts as a peek for each; and
`session_interactions` has no message body, so redirect classification depends
on reconstructing the text from the orchestrator's `run_elixir` code.

---

## C. Hand-labelled sample

**39 churn alerts**, stratified random (seeded `{66, 2026, 919}`) over `kind`,
over-sampling the rare families, plus forced inclusion of both §E ground-truth
cases. Every `paired_with_failed_edit: true` alert was to be included — there
are none. For each, the worker's transcript was read from the `messages` rows
directly (±3/+5 tool calls around the flagged command, with `tool_result`
`is_error` flags), together with the orchestrator's reaction.

Labels, per the three-bucket definition:

- **TRUE** — the flagged behaviour was genuinely a problem and the orchestrator
  intervened *on it*.
- **FALSE** — the flagged behaviour was normal, deliberate, successful work.
- **AMBIGUOUS** — the alert prompted a useful intervention it did not itself
  predict, or produced a correction on a point where nothing was at risk.

| | count |
|---|---:|
| TRUE | **3** |
| FALSE | **34** |
| AMBIGUOUS | **2** |
| hand-labelled precision | **3/39 = 7.7%** |

### C.1 The labelled table

| # | when | worker | kind | path | label | reason |
|---:|---|---|---|---|---|---|
| 1 | 09-03 21:14 | b7343b91 | in_place_edit | `src/image_gen/engine.py` | FALSE | sandbox falsification harness copied to /tmp; clean commit 2 calls later |
| 2 | 09-03 21:56 | 12048e26 | write_to_tracked | `docs/DECISIONS-since-v1.md` | FALSE | `cat >>` appends a new decision entry, committed 50 s later |
| 3 | 09-04 01:52 | 2e5af9a4 | write_to_tracked | `docs/DECISIONS-since-v1.md` | FALSE | `cat >>` appends decision #103, committed |
| 4 | 09-04 11:15 | 2e5af9a4 | write_to_tracked | `tests/test_execution.py` | FALSE | `cat >>` appends a new test block, tests run, committed |
| 5 | 09-04 12:46 | f03580f0 | write_to_tracked | `vendor/chatterbox/compat.py` | FALSE | `cat >` CREATES a new vendored file; the orchestrator then filed an issue calling this exact alert a false positive |
| 6 | 09-04 13:23 | 49158859 | programmatic_write | `projects/tts/README.md` | FALSE | python3 heredoc READS the README and writes `/tmp/…`; detector took the path from the script body (§A.6.1) |
| 7 | 09-05 02:40 | 0a5e78b7 | write_to_tracked | `debug.js` | FALSE | writes a Playwright harness into `~/.cache/…`, outside any repo |
| 8 | 09-05 04:00 | a825ef88 | programmatic_write | `…/context_chat_component.ex` | FALSE | python3 anchored replace on a tracked `.ex`, screenshot-verified |
| **9** | **09-05 11:21** | **e39149f4** | **write_to_tracked** | **`test/debug_linked_notes_test.exs`** | **TRUE** | scratch test rewritten 3× in 90 s into the real `test/` tree; orchestrator ordered it deleted before finishing |
| 10 | 09-06 03:06 | 24fa2474 | programmatic_write | `…/agents/bootstrap.ex` | FALSE | python3 anchored doc-comment replace |
| 11 | 09-06 15:05 | 7692a865 | programmatic_write | `config/runtime.exs` | FALSE | python3 config edit, compile + test immediately |
| 12 | 09-06 15:19 | 5910c76f | programmatic_write | `deploy/README.md` | FALSE | python3 appends a deploy-log entry, committed 8 s later |
| 13 | 09-06 15:31 | f0818a25 | in_place_edit | `game/tests/test_agent_snapshot.py` | FALSE | `sed -i` bumps a query-count budget, grep-verified in the same command, pytest reruns |
| 14 | 09-06 22:52 | 797a85bb | write_to_tracked | `…/memory/MEMORY.md` | FALSE | `cat >>` one index line, `tail -3` verify in the same command |
| 15 | 09-07 00:26 | 797a85bb | programmatic_write | `lib/…/llm/README.md` | FALSE | python3 doc update; formatted and committed |
| 16 | 09-07 02:35 | 55d1656d | programmatic_write | `…/memory/MEMORY.md` | FALSE | memory-index update outside the repo |
| 17 | 09-07 02:44 | d1fab46f | programmatic_write | `loadcurve.py` | FALSE | python3 patch of a scratch benchmark script, run immediately |
| 18 | 09-07 03:10 | d1fab46f | in_place_edit | `MEMORY.md` | FALSE | edit of a Claude memory file outside the repo |
| 19 | 09-08 17:38 | 7b60986a | in_place_edit | `MEMORY.md` | FALSE | edit of a Claude memory file outside the repo |
| 20 | 09-08 22:57 | 90df68f5 | in_place_edit | `test/…/node_arg_test.exs` | FALSE | `sed -i` capitalisation fix, grep-verified same command, tests rerun, committed |
| 21 | 09-10 15:32 | ee17abe3 | programmatic_write | `config/dev.exs` | FALSE | python3 config edits scaffolding a new Phoenix app |
| **22** | **09-14 14:05** | **26654d55** | **write_to_tracked** | **`lib/orca_hub/postgrex_types.ex`** | **AMBIG** | STYLE-ONLY: `cat >` creates a new tracked `lib/` file; orchestrator nudged "use Write/Edit". The alert's own evidence was acted on, but no work was at risk |
| 23 | 09-14 14:35 | f17fa7b2 | programmatic_write | `voice_mode_spec.md` | FALSE | python3 spec edit with an explicit `ANCHOR FAIL` guard, committed |
| 24 | 09-14 15:49 | fb01e7c6 | programmatic_write | `README.md` | FALSE | README polish in a spike dir, committed |
| 25 | 09-17 10:45 | 967d19d5 | write_to_tracked | `docs/research/residency-authority.md` | FALSE | `cat >>` research addendum, verified, committed |
| 26 | 09-17 13:35 | f31a24e8 | in_place_edit | `lib/orca_hub/voice/intent.ex` | FALSE | `sed -i` one threshold constant, grep-verified same command, tests run |
| **27** | **09-18 15:29** | **6970d958** | **slice_and_redirect** | **`config/test.exs`** | **AMBIG** | UNPREDICTED: the surgery match is a parse artefact (`<redacted>` supplied the `>`; the command only reads). The peek it caused surfaced 70 calls of unrelated DB/env yak-shaving → "STOP the database/environment work" |
| 28 | 09-18 19:08 | c7b00508 | slice_and_redirect | `assets/js/hooks/teleprompter.js` | FALSE | `sed -n` slice into /tmp to inspect a region before an Edit — recon, not repair |
| 29 | 09-18 20:18 | a6ad8e0d | in_place_edit | `lib/voice_prompt/asr/job_lane.ex` | FALSE | `sed -i` multi-line arity fix, compile + test immediately after |
| **30** | **09-19 00:23** | **b5cf3756** | **programmatic_write** | **`build_clips.py`** | **TRUE** | GROUND TRUTH: `nohup … & disown` plus an unbounded `until …; sleep` poll loop; orchestrator: "STOP the `nohup … & disown` + `until grep -q …; sleep` pattern … now, before it costs you the run" |
| 31 | 09-19 01:07 | b5cf3756 | programmatic_write | `scenarios.json` | FALSE | python3 edit of an untracked scratch harness, run immediately |
| 32 | 09-19 01:33 | c0c2846a | write_to_tracked | `run-dc6d8cc.sh` | FALSE | GROUND TRUTH: deploy runner `sed … > run-<sha>.sh`, `chmod +x && diff` in the same command |
| 33 | 09-19 01:40 | c0c2846a | write_to_tracked | `run-dc6d8cc.sh` | FALSE | GROUND TRUTH: same alert re-fired after cooldown |
| 34 | 09-19 10:58 | f7c9bc0d | programmatic_write | `DESIGN.md` | FALSE | `cat >` creating new gradle scaffold files in a fresh project |
| 35 | 09-19 14:08 | df3e1047 | write_to_tracked | `run-9349254.sh` | FALSE | GROUND TRUTH: deploy runner |
| 36 | 09-19 16:50 | e574bddb | write_to_tracked | `run-a685f44.sh` | FALSE | GROUND TRUTH: deploy runner |
| 37 | 09-19 16:54 | e574bddb | write_to_tracked | `run-a685f44.sh` | FALSE | GROUND TRUTH: deploy runner, re-fired |
| **38** | **09-19 17:38** | **9a1b0869** | **in_place_edit** | **`test/…/voice_channel_test.exs`** | **TRUE** | `sed -i` across test files; orchestrator: "Do not `sed` test expectations that encode MEASURED values" |
| 39 | 09-19 18:52 | 265c4375 | write_to_tracked | `run-e62debf.sh` | FALSE | GROUND TRUTH: deploy runner, `bash -n` verified |

### C.2 What the false positives have in common

34 of 39 are the **same shape**: a deliberate, successful, one-shot shell edit —
`cat >>` appending a section to a document, `python3 - <<'PY'` doing an anchored
string replace, `sed -i` fixing one constant — followed within seconds by a
compile, a test run, a `git commit`, or all three. Nine of the 39 write to files
under `~/.claude/projects/*/memory/` or `~/.cache/`, i.e. outside any repository.
Six are the deploy-runner case. **None of the 34 shows a worker that could not
land an edit.**

### C.3 What the three true positives have in common — and it is not the file surgery

This is the finding that decides §D.

- **#30** — the flagged write (`python3 - <<'PY'` patching a scratch
  `build_clips.py` in `tmp/voice2c/`) is, on its own, indistinguishable from
  sample #17 or #31, both FALSE. What made the orchestrator act was the
  `Repeated calls: 2x Bash: … until grep -q "wrote clips.json" …; sleep 10; done`
  block carried *alongside* the surgery sentence.
- **#38** — the `sed -i` is real and is what the orchestrator corrected, but the
  correction was about *which* strings were being sed'd (measured values), a
  judgement the detector cannot make. The alert also carried
  `Repeated calls: 5x Bash: python3 - <<'PY' …`.
- **#9** — genuinely the flagged behaviour: the same path rewritten from the
  shell three times in 90 seconds, into the real `test/` tree.

So **one of three** true positives was true *because of* the file-surgery
evidence. The other two were true because of the `ChurnDetail` block riding
along with it — evidence the alert already carries but formats as a footnote,
under a headline sentence that leads with the least informative field.

### C.4 Live specimen — an alert fired on this measurement session

While this document was being produced, the detector fired on the session
writing it. Verbatim:

```
[Worker alert] churn on <this session>:
worker rebuilding /home/zach/orca-hub-churn-analysis/probe1.exs from shell fragments:
cat > /home/zach/orca-hub-churn-analysis/probe1.exs <<'EOF' ... EOF
export $(grep -E '^DB_' .env | xargs) && mix run --no-start --no-compile \
  /home/zach/orca-hub-churn-analysis/probe1.exs 2>&1 | head -80
(write_to_tracked, unpaired (lower confidence)) | 11 calls/15m, 18% repeats, no commit 18m
Repeated calls: 3x Bash: Bash {"command":"cat > /home/zach/orca-hub-churn-analysis/probe1.exs ...
```

Ground truth is absolute here: the orchestrator wrote the brief that caused the
behaviour. It is a false positive, and it sharpens four things.

1. **Volume is not a gate on this branch.** 11 calls/15m and 18% repeats are both
   below `@churn_min_calls` (25) and `@churn_min_repetition` (0.5). Every
   volumetric gate was false. This fired purely through
   `file_surgery_suspected` in the `or`.
2. **Discriminator 1 is load-bearing.** `probe1.exs` is a scratch script in
   `/home/zach/orca-hub-churn-analysis/`, which is not merely untracked but
   outside any git repository. It matched family (a) for exactly one reason:
   `tracked_source_path?/1` saw `.exs` and the path hit none of the hardcoded
   `@excluded_substrings`.
3. **It refutes discriminator 4 outright.** The proposed rule was "one write per
   path = style, ≥2 writes to the same path = repair loop". This specimen is
   **three** writes to the same path (`Repeated calls: 3x Bash`) and is an
   unambiguous false positive — iterating on a scratch script is the single most
   normal thing anyone does with a scratch script. Same-path repeat count is
   confounded with ordinary iterative development on throwaway files. D4 scores
   *superbly* in the aggregate (§D, 81.2% suppression) and is *wrong in kind*;
   if the corpus makes it look good, that is a statement about how few
   scratch-script sessions the corpus contains, not about the discriminator.
4. **It argues for a wider discriminator 2.** Here the write and its
   verification are one Bash call: `cat > script <<EOF … EOF` then
   `&& mix run … script`. **Executing** what you just wrote is the same class of
   evidence as reading it back — a repair loop does neither. §D therefore scores
   read-back-only (D2a) and read-back-or-execute (D2b) separately. D2a misses
   this specimen; D2b catches it.

Also for §D.5: the `no commit 18m` clause fired on a worker whose brief
*forbids* touching `lib/` or `test/` and which will commit exactly once, at the
end. Another instance of the non-committing-role defect, self-documenting.

One caution on how this specimen is used: the orchestrator dismissed it in
seconds, but only because it already knew the mechanism. "The orchestrator
ignored it instantly" is the §B.4 fatigue confound appearing inside the
measurement run itself, and is evidence of nothing.

---

## D. Counterfactual — what each discriminator would have suppressed

Computed offline over all **229** file-surgery alerts. Nothing was implemented
in `lib/`. `FileSurgery`'s private matcher was ported verbatim into an
analysis-only module so every match in a window could be enumerated (the real
`detect/1` returns only the most recent).

**"True positives lost" is scored against the HAND LABELS only** (§C, n=3
TRUE). The proxy characterises the corpus; it may not decide this column.

Operational definitions:

- **D1 path not in git** — `git log --oneline -1 -- <path>` in the enclosing
  repo. `tracked` never suppresses. Where the directory does not exist on this
  host (68/229 — `/home/zach/projects/*` sessions ran on other nodes), the
  fallback is "no prior `Read`/`Edit`/`Grep` of that path anywhere earlier in
  the session". Corpus: tracked 109, untracked-in-repo 44, outside-any-repo 8,
  directory-unavailable 68.
- **D2a write-then-verify (same command, read-back)** — the flagged command
  itself continues into `diff`/`grep`/`cat`/`head`/`tail`/`wc`/`ls`/`md5sum`.
- **D2b write-then-verify (same command, read-back OR executes)** — D2a, or the
  command runs what it wrote (`mix run`, `mix test`, `node`, `python3 <file>`,
  `uv run`, `pytest`, `bash -n`, `./<file>`).
- **D2 write-then-verify (wide)** — D2a, or one of the next **2** tool calls
  reads the same path back (`Read`, `Grep`, or a Bash read verb naming it).
- **D3 require `paired_with_failed_edit`**.
- **D4 only ONE surgery match on that path** in the 10-minute window.
- **D5 no repo edits in window** — `top_edited_files` empty.
- **D6 no corroborating detail** — `top_edited_files` AND
  `top_repeated_signatures` both empty; the file-surgery sentence is the whole
  alert.

| discriminator | corpus suppressed | % | labelled FP suppressed | **labelled TP LOST** | of those, recoverable by 63 §1 | sample precision after |
|---|---:|---:|---:|---:|---:|---:|
| D1 path not tracked by git | 101 | 44.1% | 14/34 | **2/3** | 0 | 4.3% |
| D2 write-then-verify (wide) | 126 | 55.0% | 23/34 | **2/3** | 0 | 7.1% |
| D2a same-command read-back | 52 | 22.7% | 13/34 | **1/3** | 0 | 8.0% |
| D2b same-command read-back or execute | 63 | 27.5% | 14/34 | **1/3** | 0 | 8.3% |
| D3 require paired | 229 | **100.0%** | 34/34 | **3/3** | 0 | 0.0% |
| D4 only one match on that path | 186 | 81.2% | 31/34 | **3/3** | 0 | 0.0% |
| D5 no repo edits in window | 80 | 34.9% | 12/34 | **1/3** | 0 | 8.0% |
| **D6 no corroborating detail** | 54 | 23.6% | 11/34 | **0/3** | — | 11.1% |
| C1 D1 ∧ D2 | 54 | 23.6% | 10/34 | **1/3** | 0 | 7.1% |
| C2 D1 ∧ D2a | 34 | 14.8% | 8/34 | **0/3** | — | 9.7% |
| C2b D1 ∧ D2b | 43 | 18.8% | 9/34 | **0/3** | — | 10.0% |
| C3 D1 ∧ D5 | 50 | 21.8% | 7/34 | **1/3** | 0 | 6.5% |
| C4 D1 ∧ D6 | 35 | 15.3% | 7/34 | **0/3** | — | 9.4% |
| C5 D2 ∧ D4 | 105 | 45.9% | 22/34 | **2/3** | 0 | 6.7% |
| C6 D1 ∧ D2 ∧ D5 | 31 | 13.5% | 6/34 | **0/3** | — | 9.1% |
| C7 D6 ∨ (D1 ∧ D2) | 84 | 36.7% | 15/34 | **1/3** | 0 | 9.1% |
| U1 D6 ∨ (D1 ∧ D2a) | 66 | 28.8% | 13/34 | **0/3** | — | 12.0% |
| **U1b D6 ∨ (D1 ∧ D2b)** | **72** | **31.4%** | **13/34** | **0/3** | — | **12.0%** |
| U2 D6 ∨ (D1 ∧ D2) | 84 | 36.7% | 15/34 | **1/3** | 0 | 9.1% |
| U3 D6 ∨ D2a | 80 | 34.9% | 17/34 | **1/3** | 0 | 10.0% |
| U4 D6 ∨ D1 | 120 | 52.4% | 18/34 | **2/3** | 0 | 5.6% |

### D.1 Which discriminator kills which true positive

| TP | path | git | D2b | same-path matches | repo edits | killed by |
|---|---|---|---|---:|---|---|
| #9 | `test/debug_linked_notes_test.exs` | untracked | no | 1 | yes | D1, D2, D3, D4, C1, C5, C7 |
| #30 | `build_clips.py` | untracked | no | 1 | **no** | D1, D3, D4, D5, C3 |
| #38 | `test/…/voice_channel_test.exs` | tracked | **yes** | 1 | yes | D2, D2a, D2b, D3, D4, C5 |
| AMBIG #22 | `lib/orca_hub/postgrex_types.ex` | tracked | no | 1 | no | D3, D4, D5, D6, C7 |
| AMBIG #27 | `config/test.exs` | tracked | no | 1 | yes | D3, D4 |

**Every single discriminator proposed in the brief loses at least one
hand-labelled true positive when applied alone.** Loudly:

- **D3 (require paired) suppresses 100% of the corpus and loses 3/3.** It is not
  a discriminator, it is an off switch — and it quantifies why the corpus has no
  paired alerts: pairing requires a *failed* `Edit`/`Write`/`MultiEdit` on the
  same path within 10 calls, and across all 229 alert windows there are **6**
  alerts with even one failed editor call and **1** with two. The behaviour the
  pairing signal was built to catch does not co-occur with the behaviour the
  detector actually fires on.
- **D4 (zero repeats on the same path) loses 3/3 while suppressing 81% of the
  corpus.** 186/229 alerts fire on a path matched exactly once in the window.
  This is the most dangerous entry in the table: it looks like a near-total
  cleanup and it deletes every true positive. §C.4 refutes it in the wild from
  the other side too (three same-path writes, unambiguously false).
- **D1 (path not in git) loses 2/3**, including the §E must-keep case, because
  the `nohup`/`until`-loop worker was writing to a scratch harness under
  `tmp/voice2c/`. The discriminator that best kills the deploy-runner false
  positives also kills the ground-truth true positive, for the same reason: both
  write outside git.
- **D2 (wide, next-2-calls) loses 2/3.** Narrowed to the same command (D2a/D2b)
  it loses 1/3 — #38, where `sed -i … && grep -n …` self-verifies and the
  problem was semantic.

### D.2 What does work: require corroborating evidence

**D6 — suppress when the alert carries neither `Top edited files:` nor
`Repeated calls:`** — suppresses 54/229 (23.6%) and loses **0 of 3**
hand-labelled true positives. It encodes exactly the §C.3 finding: two of three
true positives were true because of the corroborating block, and the third (#9)
carries one too. An alert whose entire content is one shell write, with no repo
edits and no repeated signatures behind it, has never been a true positive in
this corpus.

**U1b — D6 ∨ (D1 ∧ D2b)** — suppresses **72/229 (31.4%)**, loses **0 of 3**, and:

- suppresses **12/12** deploy-runner alerts (§E FALSE case);
- **preserves** the `nohup`/`until`-loop alert (§E TRUE case) and its 00:35
  follow-up, while suppressing the three *earlier* benign scratch-write alerts
  from the same worker (23:43, 23:59, 00:11) — noise removed ahead of the real
  one;
- suppresses the §C.4 live specimen (via D1 ∧ D2b; D2a alone misses it, which is
  the measured argument for the widened form).

Sample precision after U1b: 3/25 = **12.0%**, up from 7.7%. That is the honest
number: a ~31% cut in volume with no measured loss, and precision still poor,
because the file-surgery clause itself is nearly uninformative.

### D.3 D5 / `no_commit_for` — alerts on sessions that never edit the repo

80/229 (34.9%) of file-surgery alerts carry an empty `Top edited files:` line —
the worker made no repo edits at all in the window. These are deploy workers,
gate workers, cleanup workers and measurement workers (this one included),
operating outside the repo by design. The `no commit Nm` clause in the metric
line fires on them mechanically: the role does not commit. D5 alone loses TP
#30, so it must not be used alone, but it is a component of U1b via D6.

### D.4 The ORCAHUB3-63 §1 check — no recommendation becomes "alert only at high volume"

U1b keeps **157** alerts, of which **25** are below 25 calls/15m (volumetrically
invisible) and **59** carry 0% repeats. The rule never consults volume or
repetition; it consults corroborating evidence and same-command verification,
both of which are orthogonal to rate. The low-volume-and-low-repetition
population is preserved.

The **suppress-plus-add** bar deserves a blunt number, though: **ORCAHUB3-63 §1
would not recover anything lost here, because there is nothing to recover and
almost nothing to detect.** Across all 229 alert windows, failed
`Edit`/`Write`/`MultiEdit` calls number 0 in 223 windows, 1 in 5, and 2 in 1.
None of the three hand-labelled true positives has a single failed editor call.
"Worker cannot land an edit" and "worker writes a file from the shell" are, in
this corpus, **disjoint populations**. That strengthens rather than weakens the
suppress-plus-add argument — 63 §1 is additive coverage of a population 66's
detector is not currently finding — but it means the two cannot be traded off
against each other, and no discriminator here should be justified by "63 §1 will
catch it".

---

## E. The two ground-truth cases

**FALSE — the deploy runner.** `cd /home/zach/orca-hub-deploy-logs && sed -e
's/^SHA=<old>$/SHA=<new>/' … run-<old>.sh > run-<new>.sh && chmod +x && diff`.
Found: **12 alerts** across **6 deploy workers** on 2026-09-19 (two per deploy —
the second is a cooldown re-fire ~5 min later). All `write_to_tracked`,
unpaired, 0% repeats (one at 5%), 12–25 calls/15m, empty `Top edited files:`,
empty `Repeated calls:`. Target did not exist, is outside any repo, and is
verified in the same command. **Suppressed by U1b: 12/12** (11 via D6, all 12
via D1 ∧ D2b). Orchestrator response decays across the sequence, which is the
§B.4 fatigue confound in situ.

**TRUE — the wedged poll loop.** Worker `b5cf3756`, orchestrator
`8de2a559-2785-4a2f-bde8-f848fe624226`, 2026-09-19 00:23:27, 15 calls/15m, **7%
repeats**, `programmatic_write` on `build_clips.py`, with
`Repeated calls: 2x Bash: … until grep -q "wrote clips.json…"; sleep 10; done`.
The orchestrator replied at 00:23:46: *"STOP the `nohup … & disown` +
`until grep -q …; sleep` pattern — that one I do need you to change, now, before
it costs you the run."* Both volumetric gates were false. **Survives U1b**, and
survives D2a/D2b/D6/C2/C2b/C4/C6/U1/U1b. It is killed by D1, D3, D4, D5, C3 and
U4 — which is why those are rejected.

---

## What I could not measure

- **Whether an orchestrator acted without leaving a trace.** A decision to do
  nothing, or to act through `archive_session`, is indistinguishable in the data
  from not noticing.
- **Alert fatigue as a quantity.** It is visible anecdotally (§E) but cannot be
  separated from correctness with this data, and it is the dominant bias in §B.
- **Git state at alert time.** D1 is evaluated against the checkout as it is
  *today*. A file created by the flagged write and committed minutes later reads
  as `tracked` now, which biases D1 toward under-suppressing. 68/229 paths live
  in directories that do not exist on this host at all (sessions on `mini`/
  `gb10`/other nodes); those fall back to a transcript-based proxy.
- **The 2 `slice_and_redirect` and 1 volumetric-only alerts** are too few to say
  anything about as classes.
- **Sample precision after a discriminator** is computed over the labelled 39
  only; its confidence interval is wide (3 true positives). The *loss* column is
  the reliable part, because a discriminator either kills a specific labelled
  true positive or it does not.
- **`progress_stale` and `pending_question`** have never fired, so nothing here
  bears on them.

---

## Reproducibility

Scripts live at **`/home/zach/orca-hub-churn-analysis/`** (deliberately outside
this repo — untracked files in the working tree trip the deploy dirty-checkout
guard). Run each with `export $(grep -E '^DB_' .env | xargs)` then
`mix run --no-start --no-compile <script>.exs` from `/home/zach/orca_hub`.

| script | what it does |
|---|---|
| `db.exs` | opens a read-only `Postgrex` connection with `database: "orca_hub_prod"` hard-coded |
| `extract_alerts.exs` | the §0 extraction query + header split → `alerts.bin` |
| `parse_alerts.exs` | parses each body into path/command/kind/paired/calls/repeats/detail blocks → `parsed.bin` |
| `fetch_context.exs` | orchestrator `tool_use` blocks, `session_interactions`, session metadata → `context.bin` |
| `section_b3.exs` | §B proxy with the two placebo windows → `actions.bin` |
| `section_b4.exs` | §B.3 breakdowns |
| `fetch_worker_tools.exs` | every alerted worker's tool stream ±(150, 30) min → `worker_tools.bin` |
| `matcher.exs` | verbatim port of `FileSurgery`'s private matcher, enumerating ALL matches in a window |
| `discriminators.exs` | per-alert D1–D6 flags, flagged-call relocation, failed-edit density → `enriched.bin`, `gitcheck.tsv` |
| `gitcheck.sh` | resolves each path to its repo and runs `git log -1 -- <path>` → `gitstatus.tsv` |
| `sample.exs` / `render_sample.exs` | the seeded stratified sample and its transcript renderer |
| `labels.exs` | the §C hand labels |
| `counterfactual.exs` | the §D table, ground-truth checks, live specimen |
| `proxy_vs_hand.exs` | the §B.4 proxy-vs-hand-label confusion |

---

## Recommendation

**Adopt D6 ∨ (D1 ∧ D2b) — "suppress when the alert carries no corroborating
evidence at all, or when the write is to a path outside git AND the same command
reads it back or executes it."** It removes 31.4% of file-surgery alerts
including all twelve deploy-runner firings and this document's own live
specimen, loses none of the three hand-labelled true positives, and preserves
the low-volume/low-repetition population ORCAHUB3-63 §1 warns about. **Reject
D3, D4, D1-alone and D5-alone outright**: D3 suppresses 100% of the corpus, D4
suppresses 81% and destroys all three true positives while looking excellent in
aggregate, and D1 alone kills the one case ORCAHUB3-66 must keep — the wedged
poll loop wrote to a scratch file outside git, exactly like the deploy runner
did. Also fix the two matcher defects in §A.6 independently of any
discriminator; family (c) naming a path it merely read is corrupting the largest
bucket in the corpus.

**And yes — a real part of this is working as intended, and belongs in the
orchestrator's reading rather than the detector.** Two of the three true
positives were true because of the `Repeated calls:` block the alert already
carries, not because of the file-surgery sentence it leads with; and the most
valuable alert in the whole corpus (§C.1 #27) was a *parse artefact* whose peek
surfaced a genuine 70-call yak-shave. An advisory that buys a peek 73% of the
time for a 24%-proxy / 8%-hand-labelled hit rate is not obviously mispriced —
what is mispriced is the message, which puts the weakest evidence in the
headline and labels a signal "high confidence" that has never once fired.
Reorder `metric_line/4` so the corroborating `ChurnDetail` leads and the shell
command follows; say "unpaired — advisory, judge from the detail below" instead
of "worker rebuilding X from shell fragments"; and drop the paired/unpaired
confidence language until pairing can actually fire. The detector change is
worth shipping; the message change is probably worth more.
