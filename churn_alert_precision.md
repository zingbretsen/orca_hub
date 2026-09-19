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

**Every figure in this document is measured against alerts that were
DELIVERED, not against detections** — a detection that never became an alert
was recorded nowhere. See **§F.0**, which also explains why this comparison
cannot be repeated the same way on future data. **§F** is the post-change
closing pass: what shipped, what it dropped, and what it cost. **§G** is the
post-deploy addendum: a defect class caught in review, the production check that
the new columns are in the intended shape, and one anecdote kept labelled as one.

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

**Do not try to rebuild this corpus from `churn_samples` — it is not there.**
`ChurnSampler.run_sweep/1` calls `Churn.assess/3`, so both `now` and
`file_surgery` take their defaults and `file_surgery` is always `nil`: the
sampler never computes file surgery at all. Only `AlertEvaluator` passes
evidence, via `assess/5`. That is the mechanical reason
`churn_samples.churn_suspected` was true 0 times in 1,480 samples (the figure
ORCAHUB3-44 was closed on) over the same period in which 229 file-surgery alerts
were delivered. The two are measuring different things, and the delivered
messages are the only record of what the detector actually fired on.

**As of 2026-09-19 this is fixed going FORWARD but not backward.** The sampler
now computes file surgery and persists `file_surgery_suspected` /
`file_surgery_kind` / `file_surgery_path` / `surgery_alert_decision`, so a
suppressed detection leaves a durable trace from that date on — and a future
version of this analysis must be built on `churn_samples` rather than on
delivered messages (§F.0). Rows written BEFORE that date are unchanged and
their `churn_suspected` remains void; they are identified by
`file_surgery_suspected IS NULL`, not by a date filter.

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
ORCAHUB3-61 incident was written around, has fired twice.

> **Correction (2026-09-19, after the matcher fix was implemented and
> replayed).** This paragraph, and §A.6(2) below, originally said **both**
> `slice_and_redirect` alerts were matcher artefacts. Measured against the
> fixed matcher, only **one** is: sample #27, where the `>` came from the
> literal string `<redacted>` in a pure read. The other, sample #28
> (`sed -n '526,645p' assets/js/hooks/teleprompter.js > /tmp/del_a.txt && …`),
> is a **genuine** slice-and-redirect with a real redirect operator, and it
> still fires correctly after the fix. Note what that does and does not say:
> the matcher is right about what #28 wrote. §C.1 still labels it FALSE —
> "recon, not repair" — which is a judgement about whether the write was
> worth alerting on, not about whether the match was real. Those are
> different claims and this document conflated them here.

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

**Read the `no commit Nm` clause with §D.3 open**: it is a property of the
alerted session's *directory*, not of the session, so in a shared worktree it
reports someone else's commit. Every `no commit Nm` value parsed out of this
corpus is confounded that way.

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

2. **`real_output_redirect?/1` sees `>` inside ordinary text.** **One** of
   the two `slice_and_redirect` alerts is this — see the correction in §A.3;
   this sentence originally claimed both. Sample #27's command is
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

### C.5 Second live specimen — a false positive that SURVIVES the adopted rule

A second alert fired during ORCAHUB3-66's own stage 2, on the worker building
the `EditFailure` module. Its command:

```
python3 - <<'PY'
p='lib/orca_hub/sessions/edit_failure.ex'
s=open(p).read()
… two structured replace() operations …
open(p,'w').write(s)
print("ok")
PY
```

Alert: `programmatic_write`, unpaired, **21 calls/15m, 0% repeats**, "no commit
6m", with `Top edited files: …/edit_failure.ex (1), …/edit_failure_test.exs (1)`.

Unambiguously a false positive: a worker making a structured multi-site edit to
a file it is itself authoring. Scored against the adopted rule:

| clause | fires? | why |
|---|---|---|
| D6 (no corroborating detail) | **no** | `Top edited files:` is non-empty |
| D1 (path not in git) | yes | brand-new file, untracked |
| D2b (same command reads back or executes) | **no** | the command neither re-reads nor runs what it wrote |
| **U1b = D6 ∨ (D1 ∧ D2b)** | **no — the alert is KEPT** | |

**This is the honest limit of the recommendation, and it belongs in the
headline, not a footnote.** U1b cuts ~31% of alert volume at no measured cost to
true positives, but it does **not** touch the largest remaining false-positive
class: the structured programmatic edit to a file the worker is authoring —
low repeat rate, no preceding failed edit, ORCAHUB3-66's own "pattern 2". That
class is most of the 34 false positives in §C.1 (samples #8, #10, #11, #15, #21,
#23 and #24 are all the same shape), and it is precisely why sample precision
only moves **7.7% → 12.0%**. That modest number was always the tell; this
specimen is what the tell looks like in the wild.

#### A third specimen, leaking through the OTHER clause

A third alert fired the same day, on worker B — editing
`lib/orca_hub/churn_sampler/alert_evaluator.ex`, and therefore alerted *by the
alert evaluator*. Same idiom (`python3 - <<'PY' … open(p,'w') … PY`), but with a
same-command `grep -n … alert_evaluator.ex` after it. 35 calls/15m, **0%
repeats**, "no commit 1m" — and that 1 minute was sibling worker C's commit
`e144743`, not anything this worker did (see §D.3).

It survives U1b too, but **for a different reason than §C.5's does**: here the
path IS tracked, so D1 is false and the `D1 ∧ D2b` conjunct never engages;
§C.5's path is untracked and it survives because D2b is false instead. Between
them the two specimens show the recommended rule leaking on **each of its two
clauses independently**, not on one weak spot.

#### A tightening considered and REJECTED

D6 currently requires `top_edited_files` **and** `top_repeated_signatures` to
both be empty. This specimen has a `Top edited files:` line whose every entry
has a count of **(1)** — each file touched exactly once. The tempting tightening
is therefore "no repeated signatures AND no file edited more than once", which
would suppress it.

**Not shipping it.** It would be tuned against a single specimen, which is
exactly the failure mode §D.1 documents: D4 looked superb in aggregate (81.2%
suppression) and destroyed 3 of 3 hand-labelled true positives. A rule invented
to explain one anecdote has no *measured* true-positive cost, and "no measured
cost" and "no cost" are different claims. It is recorded here as a **candidate
for ORCAHUB3-111 to measure against a fresh hand-labelled sample**, not a change
to make now. The next person should inherit the reasoning, not the temptation.

**And the third specimen settles it, having arrived unprompted rather than been
constructed to make the point.** Its `Top edited files:` line is
`alert_evaluator.ex (5)` — five edits to one file — where §C.5's has every file
at (1). So the rejected tightening would suppress the first of these two false
positives and would **not** suppress the second; they sit on opposite sides of
the very threshold it proposes. **No single tightening covers both.**
That is a stronger argument than "it would be tuned on one anecdote", and it is
stronger precisely because nobody went looking for it.

One further datum for §D.3: this alert's `no commit 6m` clause fired on a worker
roughly **20 minutes** into a task that commits once, at the end, by design. The
clause is not measuring staleness there; on a single-commit role, until that one
commit lands, the age it prints is the age of somebody else's.

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
  detector actually fires on. Stage 2 is deleting the field rather than keeping
  it, which is the right call for a reason this measurement makes concrete: a
  boolean that has only ever taken one value still *advertises* that the other
  value exists, so every alert's "unpaired (lower confidence)" reads as a
  meaningful downgrade from a higher tier no orchestrator has ever seen.
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
because the file-surgery clause itself is nearly uninformative. **§C.5 is what
U1b leaves standing** — a structured programmatic edit to a file the worker is
authoring passes every clause of the rule, and that class is most of the
remaining false positives.

### D.3 D5 / `no_commit_for` — alerts on sessions that never edit the repo

80/229 (34.9%) of file-surgery alerts carry an empty `Top edited files:` line —
the worker made no repo edits at all in the window. These are deploy workers,
gate workers, cleanup workers and measurement workers (this one included),
operating outside the repo by design. The `no commit Nm` clause in the metric
line fires on them mechanically: the role does not commit. D5 alone loses TP
#30, so it must not be used alone, but it is a component of U1b via D6. The
clause also misfires on single-commit roles that DO edit the repo — see §C.5,
where it reported "no commit 6m" against a worker 20 minutes into a task that
commits once at the end.

#### `no commit Nm` is a property of the DIRECTORY, not of the session

The mechanism is more general than the single-commit-role case above, and the
source says so plainly:

- **`OrcaHub.Sessions.git_head_info/1`** (`lib/orca_hub/sessions.ex:1732`) runs
  `git log -1 --format=%H%n%h%n%cI%n%s` with `cd: directory`. No author filter,
  no session attribution — it is the **directory's HEAD, whoever made it**.
- **`AlertEvaluator.fetch_commit_info_for/1`** dedupes by
  `{runner_node, directory}` *explicitly*, so every session sharing a working
  directory is handed the identical number. `ChurnSampler` and
  `SessionHeartbeat.Digest` do the same.

In a shared worktree the clause therefore reports a fact about **someone else's
work** while reading as a fact about the alerted worker. That is not merely
uninformative, it is misattributing: §C.5's third specimen was told "no commit
1m" about a sibling's commit `e144743`.

**Consequence for this corpus, stated explicitly: every `no commit Nm` value
parsed here is confounded.** 20 working directories, several carrying multiple
concurrent workers, means the field cannot be read as session-level anywhere in
§A–§E, and no future analysis should treat it as such.

**Checked, and nothing in this document's conclusions rests on it.** The field is
parsed in `parse_alerts.exs:24` and then never consumed: no breakdown groups by
it, no discriminator reads it, and D5 keys off `top_edited_files` being empty,
not off commit age. The §A.5 distribution tables are over `repeats` and
`calls/15m`; §B's proxy is over orchestrator actions; §D's counterfactual is over
git-tracking, verification, same-path matches and detail-block emptiness. The
confound is real and it is inert here — but it would not have been inert had D5
been defined the obvious other way, on commit age, which is worth noticing.

One forward pointer, not developed here because it is not this issue's: the
volumetric gate also requires `minutes_since_last_commit > 30`, so the same
directory-level confound plausibly explains why the volumetric half of
`churn_suspected` fired exactly **once** in seven weeks (§A.2). The full
argument is filed as **ORCAHUB3-111**.

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

## Conclusions

### The must-keep case and the must-kill case are the same shape

The most transferable result here is not a number, it is a collision. The
deploy-runner false positive (§E) and the wedged `nohup`/`until`-loop true
positive (§E) are **structurally identical under D1, the discriminator proposed
to kill the first of them.** Both workers wrote to a file outside git, and they
did so for the same ordinary reason: a deploy runner belongs in
`orca-hub-deploy-logs/`, a browser harness belongs in `tmp/voice2c/`, and
neither is repository source. "Path not in git" separates repo work from
scaffolding. It does not separate distress from competence, because distress and
competence both produce scaffolding.

That is a general property, not an accident of this corpus. **A discriminator
chosen by staring at false positives will reliably also match true positives
that happen to share the false positives' incidental properties** — and it will
look excellent right up until someone scores it against hand-labelled TRUE
cases, which is the only step that can expose it. Every candidate in this
issue's brief failed exactly this way (§D.1): D1 on outside-git-ness, D2 on
self-verification, D4 on same-path repeat count, D3 on a field that is always
false. Each is a real regularity among the false positives; none of them is
*about* the thing being detected.

The practical consequence is that the fix is a CONJUNCTION, not a signal. D1 is
**adopted, not rejected** — as a conjunct with same-command verification (D2b),
gated by the corroborating-evidence clause (D6). D1 alone suppresses 101 alerts
and costs 2 of 3 true positives; inside `D6 ∨ (D1 ∧ D2b)` it contributes to
suppressing 72 and costs none. The extra conjunct is what encodes "outside git
AND the worker exercised what it wrote", which is a statement about the
worker's behaviour rather than about where the file lives.

Anyone proposing a further discriminator for this detector should expect to
score it against §C's labelled table before it is taken seriously, and should
expect the aggregate suppression figure to be misleading in its favour.

### Out of scope, filed separately

§C.3 and the D6 result both point the same way: two of three true positives were
true because of the `Repeated calls:` block, and the clause that loses nothing
is the one demanding corroborating repetition. The stronger hypothesis that
follows — *repetition is the real signal and the file-surgery match is
decoration* — is filed as **ORCAHUB3-111** and is explicitly **out of scope for
ORCAHUB3-66**. Nothing in this document's recommendation depends on it.

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

---

## F. Closing pass — what actually shipped, and what it cost

Written 2026-09-19, after ORCAHUB3-66's four implementation workers landed.
Everything above this line is the measurement as it stood BEFORE any code
changed; this section is the post-change accounting. Where a number here
disagrees with one above, this section is the later one.

### F.0 LABEL THE DENOMINATOR — read this before quoting any figure below

Every percentage in this section, and every percentage above it, is measured
against **alerts that were DELIVERED**. It is not measured against detections.

There is no denominator of detections available, and never was: a detection
that did not become an alert was **recorded nowhere at all**. `ChurnSampler`
called `Churn.assess/3` and so never computed file surgery (§0), and the only
persistent record of the detector firing has always been the message
`SessionHeartbeat.deliver_or_queue/2` wrote into an orchestrator's feed. So the
corpus is exact — but it is exactly the set of alerts that got sent.

Phrase results accordingly. **"Of the alerts that WERE delivered historically,
N would not have been"** is supportable. *"N% of detections are suppressed"* and
*"measured in production"* are not; the first invents a denominator that does
not exist, the second implies a live A/B that never ran. This is an OFFLINE
replay against stored transcripts.

**And the comparison cannot be repeated this way on future data.** Once
suppression ships, a suppressed alert does not enter the delivered corpus
either — so re-running this analysis in a month would measure only the alerts
that survived the policy, and would silently report the suppressed population
as though it had never been detected. That is precisely the gap item 1 of this
issue closes: `churn_samples` now carries `file_surgery_suspected`,
`file_surgery_kind`, `file_surgery_path` and `surgery_alert_decision`, so the
suppressed set is durably recorded going forward. **Any future version of this
analysis must be built on `churn_samples`, not on delivered messages.**

Corollary, and it is the one most likely to be forgotten: **every
`churn_samples` row written before 2026-09-19 has a void `churn_suspected`** —
uniformly `false` for reasons that have nothing to do with churn. Those rows
are identified by `file_surgery_suspected IS NULL`, not by a date. 1,480 falses
are not 1,480 clean sessions; they are 1,480 rows on which the question was
never asked.

### F.1 The matcher fixes: 20/229 stop firing, 5 fire on a corrected path

Worker A implemented the two §A.6 defects' fixes and replayed the corpus. The
old matcher reproduces the delivered path AND kind on **229/229** alerts —
zero nils, zero mismatches — so the before/after comparison is **exact rather
than estimated**; there is no replay error to net out and no need to qualify
any figure below with a reproduction-rate caveat. Re-verified independently
against `parsed.bin` rather than carried over from a report, since every
number in this section rests on it. The replay is reproducible:
`/home/zach/orca-hub-churn-analysis/fixed_matcher_replay.exs`.

| outcome under the fixed matcher | alerts | share of delivered |
|---|---:|---:|
| stops firing outright | **20** | **8.7%** |
| — defect 1 (family (c) took the path from anywhere in the command) | 17 | 7.4% |
|   · real write target is not a tracked source path | 11 | 4.8% |
|   · genuinely indeterminate | 6 | 2.6% |
| — defect 2 (`real_output_redirect?/1` saw `>` in ordinary text) | 3 | 1.3% |
| still fires, on a CORRECTED path or family | **5**\* | **2.2%** |
| — corrected PATH | 4 | 1.7% |
| — corrected FAMILY, path unchanged | 1 | 0.4% |
| wholly unchanged (path AND family) | 204 | 89.1% |

**0 of the 3 hand-labelled true positives is lost.**

\* **Read the 4/1 split before comparing this table to any other figure.**
The related headline — **24/229 (10.5%) of delivered alerts NAMED THE WRONG
FILE** — is `20 + 4`, not `20 + 5`, because the fifth correction is a FAMILY
change on an *unchanged* path: `tools/label_false_accepts.py`, reclassified
`programmatic_write` -> `write_to_tracked` (the command both writes it from
the shell and patches another file programmatically, and a `=>` arrow
function inside a heredoc used to shadow the real redirect, so family (a)
never got a look). Same file named, more accurate family — it never misled
anyone, which is why it is outside the wrong-file count. A reader who sees
"5" here and "4 re-paths" in the implementing worker's report is looking at
two correct answers to two different questions.

Defect 2's 3 drops break down as 1 `slice_and_redirect` + 2
`write_to_tracked` — **exactly one `slice_and_redirect`**, which independently
confirms the §A.3 correction above: the other one is a genuine match and
survives the fix.

### F.2 The policy is the bigger lever; the corrected paths matter anyway

Stated plainly, because the two changes are easy to mix up:

- **U1b (the suppression policy) suppresses 72/229 — 31.4%.**
- **The matcher fixes drop 20/229 — 8.7%.**

**The policy change is the bigger lever, by roughly 3.6x.** If only one of the
two had shipped, it should have been that one. Neither loses a hand-labelled
true positive.

**That is not what either change FELT like, and the gap is the lesson.** The
matcher defects felt like the main event, because the most vivid specimen in
the whole corpus was a worker being alerted by the very defect it was
repairing (§F.4). The replay says otherwise: 31.4% against 8.7%. **A memorable
specimen is evidence of EXISTENCE, never of FREQUENCY.** A vivid case proves a
failure mode is real and tells you nothing whatever about how often it occurs
— and vividness correlates with how *recently and personally* a reader met the
case, which is not a property of the data at all.

This is §D.1's lesson wearing different clothes. There, a discriminator chosen
by staring at false positives looked excellent until it was scored against
labelled true positives; here, a defect chosen by staring at one striking
alert looked like the main event until it was scored against the corpus. Both
are the same instruction: **the specimen tells you what to go and count; it is
never itself the count.** Worth stating plainly because it caught two
experienced readers of this document in the same week — it is not a beginner's
error, and noticing it required the replay, not more careful reading.

But volume is the wrong yardstick for the **5** alerts that now fire on a
corrected path, and they matter out of proportion to their count. An alert that
suppresses costs a reader nothing. An alert that names the WRONG FILE does not
merely waste a peek — **it misleads**. §A.6(1)'s confirmed instance is sample
#6, where the alert said `/home/zach/projects/tts/README.md` for a command
whose only write was `open("/tmp/tts-arb-check/blocks.txt","w")`. An
orchestrator acting on that alert would have gone and looked at a README that
nothing had touched. Suppression makes the detector quieter; this makes it
*honest*, and only one of those two failure modes can send a reader somewhere
that does not exist.

### F.3 The honest cost — what these fixes take away

Neither fix is free, and neither cost is visible in the aggregate tables.

**The fix deletes the corpus's luckiest alert.** Defect 2's fix removes AMBIG
#27 from the corpus — the alert §B and §C identify as the single most
serendipitously valuable one ever delivered, whose peek surfaced a genuine
70-call DB/env yak-shave and produced a "STOP the database/environment work"
redirect. It was a parse artefact: the `>` came from the literal string
`<redacted>`, and the command only ever read. Removing it is exactly what
§A.6(2) asks for and the right call. It is also true that the change deletes
the luckiest alert in the record, and that belongs on the record rather than
being quietly netted out of a suppression percentage.

**The 6 "indeterminate" drops are probably real writes now missed.** These are
`open(path, "w")` inside a loop, and destinations computed at runtime — cases
where the fixed matcher declines to name a path because it cannot determine one
rather than because there was no write. That is the sanctioned trade: a missed
detection is better than an alert naming the wrong file, for the reason §F.2
gives. It is still a cost, not a free win, and the correct summary is "8.7% of
delivered alerts stop firing, of which about a third are writes we can no
longer resolve" — not "8.7% of delivered alerts were noise".

### F.4 The irony, placed after the numbers rather than ahead of them

The third live specimen (§C.5) is the **alert evaluator alerting on the worker
who was editing the alert evaluator**. It arrived unprompted, mid-measurement,
in the file the measurement was about.

It is also the specimen that exposed the directory-attribution bug: its "no
commit 1m" clause was reporting sibling worker C's commit `e144743`, not
anything the alerted worker had done — which is how the confound in §D.3 got
noticed at all, and which then turned out to affect a second rendering site
(`metric_line("no_commit_for", …)`, still saying "last commit Nm ago") that no
amount of reading the counterfactual tables had surfaced.

**Self-application found what the measurement pass did not.** Four sections of
offline replay over 229 alerts and a hand-labelled sample of 39 did not surface
the misattribution; one alert fired at the author did, within minutes, because
the author could check the claim against what they knew they had done. That is
a cheap technique and it is underused: run the detector on the work of building
the detector. The numbers above are the substance and this is a footnote to
them — but it is a footnote that changed the code twice.

### F.5 What shipped

| item | where |
|---|---|
| U1b suppression policy (`D6 ∨ (D1 ∧ D2b)`), reason-returning | `lib/orca_hub/sessions/surgery_alert_policy.ex` |
| §A.6 matcher defects 1 and 2 | `lib/orca_hub/sessions/file_surgery.ex` |
| message reorder; `paired_with_failed_edit` deleted | `lib/orca_hub/churn_sampler/alert_evaluator.ex`, `file_surgery.ex` |
| `no commit Nm` → `directory HEAD Nm old`, BOTH render sites | `alert_evaluator.ex` (`commit_clause/2`, `metric_line/5`) |
| "worker cannot land an edit" detector, wired ungated | `lib/orca_hub/sessions/edit_failure.ex`, `alert_evaluator.ex` |
| sampler computes file surgery + persists the policy decision | `lib/orca_hub/churn_sampler.ex`, migration `20260919160000` |

Not shipped, deliberately: the §C.5 tightening ("no repeated signatures AND no
file edited more than once"), which two live specimens sit on opposite sides
of; and the "repetition is the real signal" hypothesis — both are
**ORCAHUB3-111**, to be measured against a fresh hand-labelled sample rather
than argued.

**ORCAHUB3-63 §1 is NOT a component of any of this.** It ships alongside U1b,
ungated by volume or by `SurgeryAlertPolicy`, because it covers a population
the surgery detector does not find (§D.4: failed editor calls number 0 in 223
of the 229 alert windows, 1 in 5, 2 in 1; none of the three true positives has
one). The two populations are disjoint. **No suppression anywhere in this
issue may be justified with "63 §1 will catch it" — measurably, it will not.**

---

## G. Post-deploy addenda

Three items that arrived after §F was written: a defect caught in review whose
SHAPE matters more than the defect, the production check that the new columns
are in the shape they were designed to be in, and five alerts that are an
anecdote and are labelled as one. The code is deployed at `2925d44` on all six
instances; every figure below was measured against `orca_hub_prod` on
2026-09-19 at 20:12 UTC.

### G.1 The `insert_all` atom bug — a class, not a changelog entry

Worker D caught this in review, before it shipped. `FileSurgery` evidence
carries `:kind` as an ATOM (`:write_to_tracked`, `:programmatic_write`, …), and
`Sessions.insert_churn_samples/1` uses `insert_all`, which dumps values straight
through the schema's field types with **no casting** — a changeset would have
cast the atom; `insert_all` does not. An atom in a `:string` column raises
`Ecto.ChangeError`. That raise lands inside `run_sweep/1`, whose outer rescue
logs and returns — discarding **the entire sweep**: every session's sample, not
merely the offending row, every 120 seconds, with one `Logger` line as the only
trace.

**The point is not the bug, it is the shape: the fix's failure mode would have
been indistinguishable from the bug it was fixing.** This document exists
because file surgery was never recorded — `churn_suspected` true 0 times in
1,480 samples (§0), because the sampler called `Churn.assess/3` and never
computed it. Had the atom shipped, the sampler would have begun computing file
surgery and stopped persisting anything at all. Symptom before: a column that is
uniformly void. Symptom after: a table that stops growing. Both present to an
analyst as *"there is no file-surgery data in `churn_samples`"* — which is the
sentence §0 already had to write. The gap would have been closed and replaced by
a total sampling OUTAGE, and the evidence for "fixed" and the evidence for
"worse than before" would have been the same evidence. Nobody would have
noticed, because nobody had noticed for seven weeks while the table was already
empty for the other reason.

**The structural answer adopted is containment, not just the corrected atom.**
`Atom.to_string/1` at the boundary (`file_surgery_kind/1`) is the one-line
correction and it is the smaller half. The larger half is that each new
computation which can raise is contained PER SESSION rather than per sweep:
`surgery_alert_decision/2` rescues and fails closed to `nil` for that session
only, and `FileSurgery.fetch_many/2` rescues internally and guarantees a key per
requested id, so a DB failure degrades to "no evidence anywhere" rather than to
no sweep. One bad row now costs one row. `run_sweep/1`'s outer rescue stays, but
nothing added by this issue is allowed to reach it. The asymmetry is what makes
this the right trade: `surgery_alert_decision` is an observability field — losing
it for one session loses one datum, while losing the sweep loses every session's
core churn metrics for that tick.

**Generalised: a fix whose failure mode reproduces the symptom of the thing it
fixes cannot be validated by absence.** "The table is empty" could not
distinguish success from failure here in *either* direction — before, empty meant
"never computed"; after a botched fix, empty would mean "never written"; after a
good fix, empty means "nothing detected yet", and all three look identical for
as long as nothing is detected. A change of that shape needs an independent
POSITIVE check: a row that EXISTS, in production, carrying the value the fix was
supposed to produce. It has to be run after the deploy, not in the suite — the
suite writes its own rows and proves only that the code CAN write one. §G.2 is
that check, performed, which is why it reports row counts and a live detection
rather than "the migration is up".

### G.2 Production confirmation — nullable-no-default, checked at the schema level

Measured against **`orca_hub_prod`** (§0's corpus database; `.env`'s
`DB_NAME=orca_hub_dev` is a different database and answers a different
question), read-only, with `2925d44` deployed on all six instances.

**Deliberately at the schema level.** `mix ecto.migrations` reporting "up" is a
claim about the `schema_migrations` table, not about the shape of the deployed
database; the question is what the columns actually are.

| column | type | nullable | default |
|---|---|---|---|
| `file_surgery_suspected` | boolean | YES | **none** |
| `file_surgery_kind` | varchar | YES | none |
| `file_surgery_path` | text | YES | none |
| `surgery_alert_decision` | varchar | YES | none |
| `churn_suspected` *(for contrast)* | boolean | **NO** | **false** |

`churn_samples_surgery_alert_decision_idx` on
`(surgery_alert_decision, sampled_at) WHERE surgery_alert_decision IS NOT NULL`
is present.

| rows, 2026-09-19 20:12 UTC | |
|---|---:|
| `churn_samples` total | 5,171 |
| **`file_surgery_suspected IS NULL`** — never computed | **5,168** |
| non-null — written by the deployed sampler | 3 |

The 5,168 void rows span 2026-09-05 22:42 → 2026-09-19 20:05 (the table's own
prune window is why the corpus starts there; §0's 1,480 is an earlier window of
the same table); the first non-null row is at 20:08:48, the deploy restart. The
dev database holds **95 rows, 95 of them NULL** — same conclusion on a smaller,
non-authoritative corpus. A report quoting "95 rows" is quoting that database,
not the deployed one.

**What this confirms: the discontinuity is now QUERYABLE, not merely documented
in prose.** `where file_surgery_suspected is null` selects exactly the rows on
which the question was never asked — in the table itself, with no date filter and
no access to this document. `default: false` would have backfilled all 5,168 of
them into the same value the sampler writes when it looks and finds nothing,
merging "never asked" with "asked, answer no" permanently; no date filter could
undo it, because the six instances restart at different moments and the prune
window rolls rows out on its own schedule.

This is what makes §0's "**Do not try to rebuild this corpus from
`churn_samples`**" self-enforcing rather than advisory. The warning now lives in
the data: an analyst who never reads this document gets a NULL, which is not a
number they can average.

**And it is the independent positive check §G.1 demands.** The table is not
empty and the three post-deploy rows carry the intended shapes: two `false`
(no evidence, decision `nil`) and one genuine detection —
`file_surgery_suspected = true`, `file_surgery_kind = "write_to_tracked"`,
`file_surgery_path = "run-2925d44.sh"`, `surgery_alert_decision =
"suppress:untracked_and_verified"`. That is the §E deploy-runner false positive:
detected, suppressed by U1b, and **recorded** — precisely the population §F.0
says was recorded nowhere before. The same session had, 3.5 minutes earlier at
20:05:15 UTC, delivered an old-style `[Worker alert]` on the same file to
another orchestrator: same worker, same write, an alert before the restart and a
durable `suppress:` row after it. One row in four minutes proves the
detection → policy → persistence path works end to end. It proves nothing
whatever about rates — §G.3 is about not pretending otherwise. (It is also §F.4's
technique once more: the first detection the new observability ever recorded was
the deploy of the change that added it.)

### G.3 Five alerts in 44 minutes — an anecdote, and labelled as one

While this issue was being built, the PRE-change detector fired five
`[Worker alert]` churn alerts into the orchestrating session's feed — one on
each of the five workers, 18:59:22 → 19:43:12 UTC on 2026-09-19.

| delivered (UTC) | worker | named path | family | metric line | write-up |
|---|---|---|---|---|---|
| 18:59:22 | measurement (this document) | `…/probe1.exs` | `write_to_tracked` | 11 calls/15m, 18% repeats | §C.4 |
| 19:27:35 | `EditFailure` | `…/edit_failure.ex` | `programmatic_write` | 21 calls/15m, 0% repeats | §C.5 |
| 19:29:17 | `SurgeryAlertPolicy` + message rewrite | `…/alert_evaluator.ex` | `programmatic_write` | 35 calls/15m, 0% repeats | §C.5, third specimen |
| 19:31:23 | matcher defects | `…/matcher.exs` | `programmatic_write` | 34 calls/15m, 0% repeats | below |
| 19:43:12 | observability + `EditFailure` wiring | `…/churn_sample.ex` | `programmatic_write` | 31 calls/15m, 0% repeats | below |

**All five were false positives. None was true.** Every one fired on a worker
doing exactly what its brief instructed, and every one fired through the
file-surgery branch alone — four carry 0% repeats and all five sit far below
`@churn_min_repetition` (0.5), exactly as §C.4 describes.

The two not yet written up:

- **The matcher worker was alerted BY the defect it was actively repairing.**
  The alert named `/home/zach/orca-hub-churn-analysis/matcher.exs` — a file the
  command only `Code.require_file`'d — while the real writes went to
  `cat > /tmp/wa66/corpus.exs` and `File.write!("/tmp/wa66/rows.bin", …)`, both
  under an excluded `/tmp` path. That is §A.6(1) exactly: family (c) taking the
  path from anywhere in the command. It is the second time that defect
  demonstrated itself on its own repair; §F.4 is the other.
- **The observability worker was alerted for a `python3` heredoc edit to
  `churn_sample.ex`** — a tracked path, and the genuine write target, so the
  matcher was right about the file here. Its `Top edited files:` line is
  non-empty (the migration), so D6 is false, and D1 is false because the path is
  tracked; it therefore **survives U1b**, for the same reason §C.5's third
  specimen does.

**Five is an anecdote, not a measurement, and no rate may be derived from it.**
Deriving one would be self-refuting in a document that spends §D.1 showing a
vivid small sample getting it exactly backwards — D4 looked superb in aggregate
(81.2% suppression) and destroyed 3 of 3 hand-labelled true positives — and
§F.2 stating the rule outright: a memorable specimen is evidence of EXISTENCE,
never of FREQUENCY. The population here would poison any rate anyway: all five
workers were editing or measuring the detector itself, using heredocs and
`python3` one-liners, which is the precise idiom the detector matches on. And
four of the five arrived AFTER the 237-alert corpus was frozen — its last alert
is the 18:59:22 row above — so none of them is inside any figure in §A–§F.

What it IS: the lived cost of the pre-change detector across one stage of one
ordinary multi-worker issue — five interruptions into a single orchestrator's
feed inside 44 minutes, each an invitation to peek at a worker that was fine.
§B's corpus-wide "cost a peek and produced nothing" figure is 53.2%; this is
what that number feels like from the receiving end, on one afternoon.

**The provenance is the only reason it is worth recording at all.** These alerts
were not gathered to argue for fixing the detector; they arrived as a BYPRODUCT
of fixing it, at an orchestrator already committed to the change, and they are a
complete enumeration of that orchestrator's alerts for the window rather than a
selection of the vivid ones. Evidence that arrives while you are looking
elsewhere cannot have been constructed to fit the case — the same argument
§C.5's third specimen rests on. That protects against one bias, not all of them:
it is still five, still self-observed, still one unusual kind of work. Record it
as an anecdote with good provenance, and use it for nothing else.
