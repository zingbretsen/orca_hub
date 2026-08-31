# Churn signal mining — ORCAHUB3-61(b)

Data-driven analysis of which tool-call patterns actually preceded orchestrator
intervention in real OrcaHub history, to rank candidate detection signals by
measured precision/recall rather than by anecdote. Companion to ORCAHUB3-61(a)
(the code change). This document is the analysis; no `lib/` or `test/` files
were touched to produce it.

## Step 0 — database sanity check

`.env`'s `DB_NAME=orca_hub_dev` is the WRONG database — it is empty of the five
known reference sessions and unrelated to production history. The real corpus
is **`orca_hub_prod`** on the same Postgres host (`192.168.1.177`), reached
with the same `DB_USERNAME`/`DB_PASSWORD` from `.env` but `database:
"orca_hub_prod"` overridden explicitly in each script. All five reference
session-id prefixes (`5e18c2f2`, `be7803aa`, `5d8d089f`, `6738fba4`,
`36d2e2d4`) matched real rows there. `orca_hub_prod` has 3556 sessions,
2026-02-28 through 2026-08-31.

**Every query in this document was run against `orca_hub_prod`, never
`orca_hub_dev`.** If you rerun any query below, set `database:
"orca_hub_prod"` explicitly — do not rely on `.env`.

A sibling session was mid-edit on `lib/orca_hub/sessions.ex` (and later
`lib/orca_hub/sessions/churn.ex`) for the whole duration of this analysis
(ORCAHUB3-61(a), landing the file-surgery detector this document's findings
feed). All DB scripts were run with `mix run --no-start --no-compile` against
the last-known-good build to avoid touching or waiting on that file.

## Corpus

**683 distinct positive sessions**, union of four label rules, out of 3556
total sessions (3159 non-orchestrator/worker sessions). Breakdown by which
rule(s) fired (a session can satisfy more than one):

| Rule | Fired (sessions) | Definition used |
|---|---:|---|
| Rule 1 — mid-task orchestrator message | 599 | See "Rule 1 operational definition" below |
| Rule 2 — child blocked on a question | 99 | `question`/`AskUserQuestion` tool_use by the worker (see note) |
| Rule 3 — archived, issue still open, no commit | 1 | archived worker session, `issues.status != 'closed'`, no `git commit` Bash call found |
| Rule 4 — superseded by a later session on the same issue | 6 (+1 manual) | not the chronologically-last worker session on its `issue_id`, and made no commit of its own (see fix-up below) |

Overlaps: rule1∩rule2 = 18, rule1∩rule3 = 1, rule1∩rule4 = 3, rule3∩rule4 = 1,
rule2∩rule3 = rule2∩rule4 = 0.

Backend/model breakdown of the full 683-session population:

| backend/model | positive sessions |
|---|---:|
| claude / claude-sonnet-5 | 273 |
| claude / (no model recorded) | 172 |
| claude / claude-opus-5 | 127 |
| pi / gb10-coder/qwen3-coder-next | 49 |
| claude / claude-opus-4-6 | 38 |
| claude / claude-fable-5 | 10 |
| codex / (no model recorded) | 5 |
| other claude models | 9 |

Base rates (positives ÷ total sessions of that backend, the number that
actually matters for the "don't just rediscover qwen needs help" caveat):
**pi+codex: 54/152 = 35.5%** vs **claude: 629/3007 = 20.9%**. pi/codex sessions
are labelled positive at ~1.7x the rate of claude sessions — real, but far
short of "almost all pi sessions are positive," so stratifying (below) is
necessary but the raw label counts are not simply an artifact of "there are
more claude sessions."

### Rule 1 operational definition ("mid-task, excluding spawn and routine ack")

A spawn prompt is structurally excluded already — `start_session` writes the
first message directly, it never creates a `SessionInteraction`. Only
`send_message_to_session` calls do, so every `session_interactions` row with
`kind = "message"` is already non-spawn by construction.

**"Routine completion ack" was operationalized as: the child performs fewer
than 2 more `tool_use` calls after receiving the message.** Manual reading of
~15 random sampled message bodies confirmed this is a heterogeneous bucket —
genuine distress corrections ("STOP the file-reconstruction approach..."),
routing/coordination directives ("the cluster half goes to session X, do NOT
spawn your own"), truncation-recovery requests ("resend just the remainder"),
and code-review feedback with minor asks, are ALL "mid-task, non-ack, tca≥2"
messages under this definition. **This is intentional per the issue's own
framing (weak supervision) but means Rule 1's 599 raw positives are the
noisiest of the four rules by a wide margin** — see Caveat 1 below.

**A methodology bug found and fixed while building this**: a session can
receive multiple qualifying messages; the first pass collapsed a session's
label to a single timestamp (originally the *earliest* qualifying message).
For `6738fba4` (the reference cat/head session) this picked "STOP calling the
`question` tool" at 22:57 instead of the actual file-surgery rescue message at
23:02:55 — a different intervention entirely, minutes before the real one.
Fixed by (a) using each session's individual qualifying interactions as
**separate events** rather than collapsing to one row per session for the
deep-extraction sample (below), and (b) for the corpus-level union/backend
counts, using the session's *latest* qualifying interaction rather than the
earliest.

### Rule 2: `answer_session_question` was never actually called

The issue's literal spec ("an `answer_session_question` call against that
child") produced **zero hits** — `Tools.answer_session_question` exists in the
tool surface but has never been invoked in this corpus's history. Substituted
the structurally-equivalent, directly observable proxy: **the child itself
calling `question` (pi) or `AskUserQuestion` (Claude)** — this is exactly the
event that puts a session into `"waiting"` status per
`.context/session-lifecycle.md`, i.e. it is definitionally "blocked" whether
or not anyone ever formally answers it. See the dedicated ORCAHUB3-60 section
below for a full breakdown of this tool's behavior.

### Rule 3 was nearly empty

Only 23 archived worker sessions have any `issue_id` at all (issue-linked work
is a small fraction of total activity), and after requiring a not-closed issue
and no own commit, exactly **one** row survived. This rule contributed almost
nothing to the corpus — see "what I could not determine."

### Rule 4 fix-up: commit-but-later-reverted

The naive rule ("no `git commit` Bash call from this session") initially
EXCLUDED `6738fba4` — the headline reference incident — from Rule 4, because
it did successfully commit (`f170060`, "Preserve managed config..."). Checking
`git log --all --grep="^Revert "` (only 3 revert commits exist in this repo's
entire history) found that `f170060` was reverted by `8c40442`, authored by
the very next session on that issue (`36d2e2d4`), whose revert commit message
states the original fix was root-cause wrong. The other two reverts in history
are unrelated self-corrections (an accidental `git add` pathspec mistake, a
design revert), not "worker's committed work needed correcting" — I did not
generalize this into an automated rule given n=1 confirmed case; `6738fba4`
was added to Rule 4 by this specific, documented manual check, not a query.

Also fixed: Rule 4's window cutoff was initially the superseded session's own
**start** time (`inserted_at`) instead of when it stopped being worked
(`archived_at`) — this produced empty/near-empty windows for `5e18c2f2` and
`be7803aa` in an earlier pass. Fixed to `archived_at` (falling back to
`inserted_at` only if never archived).

### Controls

Archived worker sessions with a **verified successful** commit (`is_error =
false` on the paired `tool_result`, not merely a `git commit` Bash
invocation), not in the positive union, with ≥5 messages. 1298 candidates in
the full population.

## Deep-extraction sample

Processing all 683 positives' full message histories was not attempted — Rule
1 alone is 599 sessions and multiple of them run to hundreds of tool calls.
Sampled: **ALL** non-Rule-1-only positives (Rules 2/3/4, 105 sessions — small
enough to use in full) + **ALL** pi/codex Rule-1-only positives (47) +  a
systematic (evenly-spaced-by-time) sample of 40 claude Rule-1-only positives =
**176 positive sessions**. Controls: all 32 pi/codex candidates + a systematic
sample of 60 claude candidates = **92 controls**. Total 268 distinct sessions,
85–86k messages fetched.

**For Rule-1 sessions, each qualifying interaction was expanded into its own
labelled event** (not collapsed to one per session), since a session can
receive several distinct interventions for different reasons at different
times (see the `6738fba4` example above, which has 3). This produced **295
positive events** across 176 sessions. Rule 2/3/4 remain one event per
session (their cutoff is an unambiguous single moment: first blocking call,
archival, or supersession). Controls remain one event per session (cutoff =
`archived_at`).

Windows tested: **15 and 30 minutes** before the event, matching the existing
`OrcaHub.Sessions.Churn` module's own two buckets, so results are directly
comparable to the thresholds already in production.

## A load-bearing bug I found and fixed in my own reconstruction

`OrcaHub.Sessions.activity_metadata/1`'s `distinct_tools_15m` counts DISTINCT
**`tool_name || ':' || left(input::text, 120)`** — i.e. distinct
(name+arguments) *signatures* — not distinct tool names. My first pass
mistakenly counted distinct tool NAMES only (Bash/Read/Edit/... — at most a
handful of buckets), which made a burst of many DIFFERENT Bash commands look
artificially repetitive and inflated the reconstructed volumetric flag far
above reality (it made `volumetric_30` fire 3x more often, at P=0.76, in an
early pass — completely inconsistent with `churn_samples`, see below). Fixed
to match the real SQL fragment exactly; the corrected numbers for `6738fba4`
now match its actual recorded `churn_samples` rows to two decimal places
(`repetition_ratio_15m = 0.08` reconstructed vs `0.08` recorded at the closest
sample). **All precision/recall numbers below use the corrected formula.**
This is exactly the kind of error the issue warned about ("an analysis of the
wrong corpus is worse than no analysis") — it wasn't the wrong corpus, but it
would have produced a confidently wrong headline number if not caught.

## Ranked candidate signals

Pooled = all 295 positive events / 92 controls. Stratified splits claude
(n_pos=170, n_ctrl=60) from pi+codex (n_pos=125, n_ctrl=32).

| Rank | Signal | Pooled P / R | claude P / R | pi/codex P / R | Confidence & caveats |
|---|---|---|---|---|---|
| 1 | **`question`/`AskUserQuestion` call in window** (30m) | 1.00 / 0.10 | 1.00 / 0.011 | 1.00 / 0.17 | **HIGH.** Zero false positives across all 92 controls — a pending dialog genuinely never occurs in a clean-completion session in this corpus. Tested against labels *excluding* pure-Rule-2 events to avoid tautology (a session is only counted positive here if it ALSO independently satisfies Rule 1/3/4). Low recall is inherent — it only catches sessions that stall specifically this way. See full ORCAHUB3-60 section below. |
| 2 | **Failed `Edit`/`Write`/`MultiEdit` → `Bash` cat/head/tail/sed/awk fragment-read-and-redirect on the same file within 5 calls** (30m) | 0.92 / 0.08 | 1.00 / 0.012 | 0.91 / 0.17 | **HIGH precision, LOW but non-circular recall.** This is the issue's headline pattern. Whole-session scan (not window-limited) found 20 genuine instances; **19/20 (95%) occurred while the real 30-minute volumetric flag was FALSE at that exact moment** — this is the strongest direct confirmation of the issue's core claim, measured at the actual instant of the dangerous action rather than at intervention time (see "instant-of-action" check below). Adds coverage the existing heuristic does not have: of the 23 window-level true positives, only 2 also had the volumetric flag on. Nearly exclusive to pi/qwen (2 TPs total in 170 claude events vs 21 in 125 pi/codex events) but recall stays meaningful (17%) *within* the pi/codex stratum alone — not just an artifact of pi having more raw positives. 2 false positives, both pi controls that exhibited the pattern once and then recovered and committed successfully — see caveat below about false positives with no bad outcome. |
| 3 | **Repeated `Edit`/`Write`/`MultiEdit` failures on the same file, no successful edit on that file in between (≥2, 30m)** | 0.89 / 0.08 | 1.00 / 0.006 | 0.88 / 0.18 | **HIGH precision, overlapping-but-not-redundant with #2.** Session-level overlap with signal #2: 6/8 sig-2 sessions also fire this; 7 additional sessions fire this WITHOUT the fragment-read pattern (still worth alerting on — "the model can't land an edit" is dangerous on its own even absent a cat/head escape hatch). Essentially pi-only in this corpus (1 claude TP out of 170). |
| 4 | **ANY Bash cat/head/tail/sed/awk-to-redirect on a tracked source path, without requiring a prior failed edit** (30m, the issue's "generalize beyond cat/head" ask) | 0.72 / 0.16 | 0.58 / 0.11 | 0.88 / 0.22 | **MEDIUM.** Higher recall than the strict failed-edit-gated version (#2) but noticeably lower precision, driven almost entirely by claude false positives (14 FP in claude vs 4 in pi/codex) — claude sessions legitimately `cat`/`head` tracked files into `/tmp` scratch outputs more often than pi does. Recommend keeping the failed-edit gate (#2) as the auto-alert trigger and this looser version as a lower-severity/log-only signal. |
| 5 | **10+ (15m window) / 15+ (30m window) consecutive `Read`/`Bash`/`Grep`/`Glob` calls with zero `Edit`/`Write`/`MultiEdit` interleaved** ("investigation that stopped converging") | 0.79 / 0.48 | 0.73 / 0.40 | 0.86 / 0.59 | **MEDIUM-LOW confidence — substantially confounded with elapsed time (Caveat 3).** Of 139 30m-window true positives, 88 (63%) also satisfy the crude "elapsed > 10 minutes since session start" test, which by itself gets P=0.71/R=0.51 pooled — nearly the same operating point. 51 TPs (37%) fire this signal despite elapsed ≤ 10 min, so it is not PURELY a time proxy, but a meaningful share of its apparent power is "the session has been running a while," which is not itself evidence of distress. Recommend NOT shipping this alone; if used, report elapsed time alongside it so an orchestrator can discount the "just a long session" case. |
| 6 | **Oversized commit** (`git commit --stat` lines-changed above the control-population's own p75 = 578) | 0.72 / 0.37 | — | — | **LOW-MEDIUM, exploratory, no stratification (only 235 sessions in this sample ever committed at all — see note).** Positive-population commit sizes ARE larger at every percentile than control commits (p50 281 vs 194, p90 2314 vs 1341), directionally confirming the app.js-reformat anecdote, but the distributions overlap heavily and a session must have already committed for this to apply at all — useless as an early-warning signal, only a post-hoc "was this commit suspicious" check. Not recommended as a live alert condition. |
| — | **Existing volumetric heuristic** (`tool_calls_15m≥25 AND repetition_ratio_15m≥0.5`, both 15m and 30m) | 1.00 / 0.01 (30m) | 0 fires at all | 0.01 fires | Included for direct comparison, not a candidate. **Recall is essentially zero against this labelled set** — 1 fire out of 295 at 15m, 3 at 30m. This matches ground truth exactly: `churn_samples.churn_suspected` has fired **zero times ever** in 1480 real samples across 187 sessions since 2026-08-22 (see ORCAHUB3-44 section). The issue's premise — that the volumetric gate is structurally blind to distress that doesn't also look like "spinning fast in circles" — is not just true for the one observed anecdote, it is true almost everywhere in this corpus. |

### The "instant of action" check (why signal #2's numbers differ from a naive window read)

A window ending at the orchestrator's RESPONSE timestamp is not the same
question as "was the heuristic blind at the moment of the dangerous action" —
by the time a human notices and reacts, several more minutes of (possibly
unrelated) activity have often already pushed cumulative counts up. To test
the issue's actual claim, I additionally scanned each session's FULL history
(not window-limited) for genuine failed-edit→fragment-read instances and
computed the real 15m/30m volumetric state **at the exact timestamp of the
Bash fragment call itself**, using the corrected signature-based formula:

- 20 genuine instances found across the whole corpus (17 unique sessions;
  `6738fba4`, `d5d67dfa`, and `e6925479` each have 2–3).
- **19/20 (95%) had `volumetric_15` FALSE at that exact instant; 20/20 (100%)
  had `volumetric_30` FALSE.**
- 3 of the 20 instances occurred in CONTROL sessions that went on to commit
  successfully — i.e. the pattern fired, an orchestrator either didn't
  notice or the model self-corrected, and the outcome was fine. This is
  important: **the pattern is a strong distress SIGNAL, not a guaranteed-bad
  outcome** — false positives at the session level exist and should be sized
  into any auto-block-vs-alert-only decision (ORCAHUB3-61(a)'s scope, not
  this document's).

Exact reproduction: query in "Reproducibility" below (`true_instant_check.exs`
logic).

### Killed / demoted

- **"10-minutes-elapsed" as a standalone timing heuristic** — not explicitly
  in the candidate list, but tested directly as the sharpest form of Caveat 3
  ("beware learning the orchestrator's habits"). At `elapsed > 10 min`, pooled
  P=0.71/R=0.52 — genuinely close to signal #5's operating point, and within
  the pi/codex stratum alone (P=0.87/R=0.70) it is nearly as strong as any
  qualitative signal tested. **This is the single most important caveat
  finding in this document**: several of the "qualitative" signals above
  (especially #5) partially reduce to "the session has been running a while,"
  and any live implementation should report/condition on elapsed time
  explicitly rather than let a correlated qualitative signal quietly stand in
  for it.
- **Oversized commit as a live gate** — demoted (see #6 above), not killed
  outright (direction is right, magnitude is not useful for gating).
- **Nothing else on the candidate list was fully killed** — every pattern the
  issue and its note explicitly asked about (failed-edit→fragment,
  repeated-edit-failure, question-tool, investigation-without-convergence,
  generalized shell-reconstruction) showed a real, non-zero, above-baseline
  precision/recall footprint in this data. The two that most needed a
  confidence downgrade rather than outright death are #5 (confounded with
  time) and #6 (too coarse to gate on).

### New signal candidates the data suggested (not on the original list)

- **`Agent` (subagent-delegation) tool immediately followed by `Read` or
  `Bash`** — lift 4.05x and 2.49x respectively over controls in a bigram scan
  (30m windows, tool-name bigrams only, no argument normalization). Absolute
  counts are small (13/295 and 8/295 positive events) — this is **exploratory,
  low-confidence**, not validated the way the ranked signals above are. The
  plausible interpretation is a worker delegating to a subagent and then
  redundantly re-doing or re-checking that work itself, which would itself be
  a mild distress signal (not trusting delegated output), but I did not have
  budget to manually verify a sample of these 13 cases and am not
  recommending it for implementation without that check.
- No other bigram cleared a meaningful lift threshold at ≥8 positive
  occurrences; most of the tool-adjacency structure (Read↔Bash, Bash↔Bash,
  Read↔Edit) is near-identical between positives and controls — the
  discriminating signal in this corpus lives in specific tool NAMES firing
  and specific FAILURE outcomes, not in generic sequencing, which is
  consistent with why the volumetric/repetition-only heuristic (which is
  sequence-blind) misses it.

## The three required caveats, addressed directly

**1. Label noise, both directions, per signal.** Rule 1 (599/683 = 88% of the
raw positive population) is the noisiest — manual reading of sampled message
bodies found routing directives, truncation-recovery requests, and code-review
nits mixed in with genuine distress corrections. Rules 2 and 4 are the
cleanest (mechanically unambiguous: a blocking tool call; a
commit-then-reverted or never-committed-and-superseded outcome). Because
signal #2 (question-tool) and #1 in the ranked table above draw most of their
recall from Rule 2 and pi-heavy Rule-1/4 events respectively, their measured
precision is closer to "true positive w.r.t. genuine distress" than signals
whose recall comes mostly from bulk Rule-1 events. Conversely, **false
negatives are undercounted everywhere**: the issue's own framing (the
reference incident "was caught by luck") means an unknown number of equally
dangerous sessions in the 1298-candidate control pool never got looked at and
are sitting in my "control" bucket mislabeled as clean. I have no way to
bound this from the data alone — see "what I could not determine."

**2. Stratification.** Every number in the ranked table is reported both
pooled and split claude vs pi+codex. The base-rate check above (pi+codex
35.5% vs claude 20.9% positive) confirms pi genuinely fails more often, but
signals #2 and #3 (edit-failure patterns) remain meaningfully predictive
*within* the pi/codex stratum alone (P≈0.88-0.91, R≈0.17-0.18) — not simply
"pi has more raw positives so anything correlates." Signal #1
(question-tool) is nearly claude-absent (1 TP / 170 claude events) not
because claude never calls `AskUserQuestion` (it does, 141 times across 81
sessions — see next section) but because those calls rarely coincide with a
Rule-1/3/4-independent positive window in this specific sample.

**3. Orchestrator-habit confound.** Directly tested and reported above
("Killed / demoted" — elapsed-time-alone). This is real and load-bearing:
signal #5 in particular should not be shipped without reporting elapsed time
alongside it, and any live alert built from this document's signals should be
spot-checked against "does this fire mostly on long-running sessions
regardless of content" before being trusted.

## ORCAHUB3-44 side-request: has a genuine alert ever fired in prod?

Direct answers, from `orca_hub_prod`:

1. **`churn_samples.churn_suspected = true`: 0 rows, ever.** The table has
   1480 rows across 187 distinct sessions, 2026-08-22 through 2026-08-31 (it
   samples every 120s for running sessions, per the module doc), and not one
   has `churn_suspected = true`. ORCAHUB3-44's own stated close criterion
   ("closes after the first genuine alert fires in prod") **has never been
   met**.
2. **`[Worker alert]` deliveries: 3 real, not 4.** A precise regex match on
   the actual template (`"[Worker alert] #{condition} on #{title}
   (#{session.id}):"` from `alert_evaluator.ex`) found 4 hits; one
   (`6aa7cb42`, 2026-08-22) is inside a ` ``` ` code fence in what reads as
   the ORCAHUB3-44 implementation session's own example/documentation output,
   not a live delivery — excluded. The 3 genuine deliveries: `stall` on
   `5ef9bd04` (2026-08-23, targeting `47ee43cb` — the actual ORCAHUB3-50a
   session in THIS document's own Rule-4 corpus, a nice cross-validation),
   `no_commit_for` on `b48414ae` (2026-08-24), and `stall` on `1687296e`
   (2026-08-27). **`churn` has never fired as a delivered alert, consistent
   with (1).** `stall` and `no_commit_for` are the only two conditions
   observed to fire at all; `progress_stale` never fired either.
3. Given (1) and (2): **any positive in this document's labelled corpus whose
   window included a real `[Worker alert]` delivery is flagged.** Only
   `47ee43cb` qualifies (the `stall` alert above), and it is a single Rule-4
   session, not a Rule-1/2 bulk contributor. **None of the ranked signals in
   this document are contaminated by "echoing the existing detector"** — the
   existing detector essentially never fires in this window, so it cannot be
   a hidden explanatory variable for why the orchestrator intervened.

## ORCAHUB3-60 side-request: `question`/`AskUserQuestion` deep dive

**1. Rate.** 180 total calls across the whole corpus: 141 `AskUserQuestion`
(claude) across 81 distinct sessions, 39 `question` (pi) across 18 distinct
sessions.

**2. Split by backend (absolute counts, not just rate).** claude:
**141 calls / 81 sessions**, out of 3007 claude worker sessions (2.7% of
claude sessions ever call it — not "3% of stalls," 81 REAL sessions). pi: 39
calls / 18 sessions out of 126 pi worker sessions (14.3% of pi sessions).
Per-session rate is ~5.3x higher for pi, but claude's absolute count is far
from negligible — 81 real sessions asked a blocking question, some of them
multiple times.

**3. Resolved vs timed out (pi's `pi_ui_request`/`pi_ui_response` pair, the
mechanism that actually blocks a turn — Claude's `AskUserQuestion` tool_result
is recorded synchronously and does not carry real wait-time information, so
this breakdown is pi-only).** 63 `pi_ui_request` events total:
- **28 (44%) resolved via a matching `pi_ui_response`** — median 0.8 minutes,
  p90 6.6 minutes, max 7.85 minutes. These are real, timely answers.
- **22 (35%) hit the ~10-minute self-timeout exactly** (gap to the next event
  measured at 10.00–10.02 minutes, next event type `user`) — confirms the
  orchestrator's stated ~10-minute self-timeout mechanism precisely.
- **13 (21%) resolved via some other, faster path** (gaps 0.0–7.9 min, next
  event `user`) not captured by a matching `pi_ui_response` row — most likely
  an orchestrator replying with a plain `send_message_to_session` text answer
  rather than going through the structured response channel.
- **0 sessions were ever abandoned while blocked** (no case where a
  `pi_ui_request` had no further events at all) — every stall eventually
  resolved one way or another, so this specific failure mode ("stuck forever,
  nobody ever comes back") did not occur in this corpus, though 22/63 (35%)
  did burn the full 10 minutes before self-resolving.

**4. Where in the session.** Measured as tool-call index ÷ total tool calls in
the session (0 = very start, 1 = very end) — chosen over
time-since-last-commit because most of these sessions never commit before
their first question call, making a commit-relative metric undefined for the
majority of cases. **The "clusters at wrap-up" hypothesis is only partially
supported**: median position is 0.31 (31% of the way through the session's
work, not near the end), p75 = 0.63, p90 = 0.98. There is a real tail of
late-session "should I do more?" stalls (the p90 case), but the *typical*
question call happens mid-task, not at a commit boundary — this should temper
"default-on because it's purely a wrap-up nuisance" framing; a meaningful
share of these are mid-implementation blocks, not just end-of-task hesitation.

**Bottom line for ORCAHUB3-60's decision**: the "a pending dialog is a fact,
not a heuristic" framing is well-supported by the precision data (0 false
positives across 92 controls, ranked signal #1 above) — that part of the
argument is now backed by data, not intuition. The "it's basically free
because it clusters at low-stakes wrap-up moments" part is only half true:
median position is mid-session, and 35% of pi's blocking questions eat the
full ~10-minute timeout before self-resolving, which is real elapsed-time
cost on a live session even though the code-correctness cost is zero.

## What I could not determine, and why

- **The true false-negative rate is unknowable from this data.** By the
  issue's own framing, the reference incident was caught by luck, meaning an
  unknown number of the 1298 control candidates (and the 92 sampled controls
  drawn from them) may contain equally dangerous unnoticed patterns that never
  triggered any of the four label rules. I could not distinguish "genuinely
  clean" from "dangerous but nobody looked" from message data alone — this
  would require either manually auditing a large control sample by hand
  (out of scope/budget here) or a much stronger structural proxy than any of
  the four rules provide.
- **Whether Rule 1's noisiest cases (routing directives, truncation-recovery
  asks) systematically differ in tool-call pattern from genuine distress
  corrections.** I did not have budget to hand-label a sample of the 599
  Rule-1 sessions by INTENT (distress-correction vs routine coordination) and
  re-run precision/recall against that finer label; the signals above are
  measured against the coarser "tca≥2, non-ack" definition throughout.
- **Rule 3 is nearly unusable as-is** (n=1 in the whole corpus) because
  issue-linked work is still a small fraction of total session activity in
  this hub. Any future re-run of this analysis once more work routes through
  `Issue`/`issue_id` should revisit it — the current single data point is not
  enough to say anything about it as a signal source.
- **The 13 "fast-but-not-via-`pi_ui_response`" question resolutions** (ORCAHUB3-60
  section) are inferred from timing + next-event-type only; I did not
  individually read all 13 messages to confirm they are genuinely answers
  rather than some other coincidental event, though a handful of spot-checked
  samples were consistent with plain text replies.
- **The "Agent→Read/Bash" bigram lead** is unverified beyond the frequency
  count — see "New signal candidates" above.
- **Commit-but-later-reverted as a systematic label source** — only checked
  by hand for the 3 revert commits that exist in this repo's entire history,
  found exactly 1 genuine case. Too small a sample to know whether this
  pattern is a rich vein or a one-off; a repo with a larger revert history
  might behave differently.

## Reproducibility

All scripts run against `orca_hub_prod` via
`mix run --no-start --no-compile <script>.exs` with
`export $(grep -E '^DB_' .env | xargs)` first (the DB host/user/password come
from `.env`; the DATABASE NAME must be overridden to `orca_hub_prod` in the
script itself, `.env`'s `DB_NAME=orca_hub_dev` is wrong for this purpose).
Scripts (kept at `/tmp/churn_scripts/`, not part of this repo — recreate from
the queries below if that directory is gone):

- **`master_labels.exs`** — builds the 4 label rules; the core queries:
  - Rule 1: `session_interactions` joined to `sessions` (sender=orchestrator,
    recipient=worker), `kind='message'`, filtered by a correlated subquery
    counting `tool_use` blocks in the recipient's `messages` after the
    interaction timestamp (`>= 2` required); aggregated `max(inserted_at)`
    per recipient.
  - Rule 2: `messages` × `jsonb_array_elements(message->content)` where
    `elem->>'name' in ('question','AskUserQuestion')` and
    `elem->>'type'='tool_use'`, joined to non-orchestrator `sessions`.
  - Rule 3: archived worker sessions joined to `issues` where
    `issues.status != 'closed'`, minus sessions with a `Bash` tool_use whose
    `input->>'command' ~* 'git commit'`.
  - Rule 4: worker sessions grouped by `issue_id`, all but the
    `max(inserted_at)` per group, minus sessions with a git-commit Bash call;
    cutoff timestamp is `archived_at` (fallback `inserted_at`).
  - Commit detection: `elem->>'name'='Bash' and elem->'input'->>'command' ~*
    'git commit'` — best-effort, does not verify success for the union-level
    counts (the deep-extraction sample's `committed_ids`/`commit_stat` DO
    check `is_error=false` on the paired `tool_result`).
- **`build_sample.exs`** / **`build_sample_v2.exs`** — stratified sampling
  (keep-all-non-claude + systematic claude sample) and the rule-1
  per-interaction event expansion described above.
- **`extract_features.exs`** — bulk-fetches `messages.data`/`inserted_at` for
  the sampled session set, caches to `/tmp/churn_scripts/*.bin`.
- **`compute_features.exs`** — pure-Elixir (no DB) pattern detectors over the
  cached data; the volumetric formula matches
  `OrcaHub.Sessions.activity_metadata/1` exactly:
  `distinct = count(uniq(name <> ":" <> String.slice(Jason.encode!(input), 0, 120)))`.
- **`analyze.exs`** / **`analyze2.exs`** — precision/recall tables, overlap
  checks, elapsed-time confound checks.
- **`true_instant_check.exs`** — whole-session (not window-limited) scan for
  genuine failed-edit→fragment instances, volumetric state computed at the
  exact instant of the Bash call.
- **`orcahub44_alerts2.exs`** — precise `[Worker alert]` delivery search:
  `elem->>'text' ~ '\[Worker alert\] [a-z_]+ on .+ \([0-9a-f-]{36}\):'` on
  array-typed message content.
- **`pi_ui_timing.exs`** / **`pi_ui_unresolved_full.exs`** — `pi_ui_request`
  left-joined to matching `pi_ui_response` (same `id`, same session,
  `resp.inserted_at >= req.inserted_at`) for the ORCAHUB3-60 timing
  breakdown.
- **`bigrams.exs`** — tool-name bigram frequency/lift over 30-minute windows.

The Bash-command dump (`tmp_bash_corpus.txt`, see final report):

```sql
select distinct elem->>'command' as cmd
from messages m
join sessions s on s.id = m.session_id
, jsonb_array_elements(
    case when jsonb_typeof(m.data->'message'->'content') = 'array'
      then m.data->'message'->'content' else '[]'::jsonb end
  ) elem
where elem->>'type' = 'tool_use' and elem->>'name' = 'Bash'
  and (s.orchestrator = false or s.orchestrator is null)
  and (elem->'input'->>'command' like '%>%')
```
