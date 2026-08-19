# Tool-Use Anti-Pattern Audit (Behavior Side)

**Scope:** read-only analysis of production tool-call behavior. Companion to a sibling
audit of unused tool *parameters*; this one starts from wasteful call *sequences* and
works backwards to a fix.

**Window:** 30 days (2026-07-19 → 2026-08-19).

**Database:** `orca_hub_prod` on `192.168.1.177:5432`, reached directly via
`docker exec -i postgres psql -U orca_hub -d orca_hub_prod` (the shared Postgres runs
as plain Docker Compose on this host, outside k3s). Confirmed NOT the stale
`orca_hub_dev` pointed to by this repo's `.env`: `select count(*) from sessions` → 3273,
`select count(*) from messages` → 760,991, matching the prod scale cited in the task
brief (dev has 436 sessions). All queries were `SELECT`-only.

In the 30-day window: 1091 sessions created, 1074 with any message activity, 1036 with
at least one tool call. My own analysis session (`6ba1a8a4-…`) is excluded from every
number below — it's an OrcaHub session itself and would have polluted the sample with
this audit's own Bash/Read calls.

## Methodology — extraction coverage

Sessions run in code-exec mode by default, so most OrcaHub-tool calls are NOT direct
`tool_use` blocks — they're `Tools.<name>(%{...})` invocations inside the `code` string
argument of a `run_elixir` tool call. Confirmed the scale of this undercount directly:

| tool | direct `tool_use` blocks (30d) | embedded `Tools.*` calls found in `run_elixir` code |
|---|---:|---:|
| `send_message_to_session` | 25 (+8 `mcp__orca__…` variant) | **2035** (82×) |
| `get_session_tail` | 83 (+3) | **2013** (24×) |
| `start_session` | 8 | **843** (105×) |
| `schedule_heartbeat` | 6 | **804** (134×) |
| `archive_session` | 8 | **741** (93×) |

Confirms the prior audit's "18x undercount" finding generalizes — for several tools
it's far worse. **All numbers in this report use the combined (direct + embedded)
count** unless stated otherwise.

Extraction was done with a string-literal-aware paren/brace balancer (not a JSON
parser, since embedded args are Elixir map literals) over 6,927 `run_elixir` calls in
the window:

- 98.5% of `run_elixir` calls contain ≥1 recognizable `Tools.<name>(` call.
- 9,125 embedded calls extracted total.
- Of those, **90.9%** had args that parsed cleanly as a literal `%{...}` map (usable for
  parameter inspection); **7.7%** passed a variable/pipe instead of a literal (args
  content unknown — NOT counted as "param absent," just unknown); **1.4%** hit an
  unbalanced-paren scan failure (truncated/heredoc edge cases).
- Target-session-id extraction (regex on `"session_id" => "<uuid>"`) succeeded for
  1991/2096 `get_session_tail` calls (95%) and 1340/2067 `send_message_to_session`
  calls (65% — the rest pass a bound variable like `id`, target genuinely unknown).

Where a metric depends on literal-arg extraction, the caveat above applies — treat
gaps as "unknown," not "flag unused."

---

## Ranked findings

### 1. `report_progress`'s `note` field crashes the whole turn — no length cap, unlike `title`

**What:** `progress_note` is `field :progress_note, :string` (Postgres
`varchar(255)`), and — unlike `title`, which `do_report_progress!` runs through
`normalize_title/1` (trim + slice to 80 chars) before persisting — **nothing** truncates
or validates `note`. `Session.changeset/2` has zero `validate_length` calls anywhere in
the schema. A `note` over 255 bytes reaches Postgres raw and raises
`Postgrex.Error{code: :string_data_right_truncation}` inside `Ecto.Repo.Schema.apply/4`,
called from `OrcaHub.Sessions.update_session/2`.

**Volume:** 71 of 318 `run_elixir` errors in the window (**22.3% of ALL `run_elixir`
errors**, 1.0% of all `run_elixir` calls) are this exact Postgrex error — confirmed by
fetching full (untruncated) error content for six sampled occurrences, all showing the
identical stack (`Ecto.Repo.Schema, :apply, 4` ← `OrcaHub.Sessions, :update_session, 2`).
Single root cause, no other `update_session` call site takes agent-supplied free text of
unbounded length.

**Cost per occurrence:** the whole `run_elixir` script aborts at the `report_progress`
line — any `Tools.*` calls made earlier in that same code block already took effect
(e.g. a `start_session` a few lines up), but the agent gets an opaque Erlang stack trace
instead of confirmation, and has to notice, shorten the note, and retry the entire
block. This is a plausible contributor to the duplicate-spawn failure mode documented in
project memory (`project-duplicate-child-spawns-rca.md`).

**Fix — changed default / bug fix (not prompt guidance):** truncate `note` the same way
`title` already is (`normalize_title`-style slice before persisting in
`do_report_progress!`), or add `validate_length(:note, max: 255)`-equivalent handling to
the changeset so an oversized note degrades to a clear validation error instead of a raw
`Postgrex.Error`. Cheapest fix: mirror the existing `title` truncation pattern that's
three lines away in the same file.

---

### 2. Hand-rolled polling of `get_session_tail` instead of trusting `schedule_heartbeat`'s watch mechanism

**What:** 410 distinct (caller session, target session) pairs were peeked with
`get_session_tail` more than once in the window; 1552 calls total in those groups,
**1142 "redundant" calls** (beyond the first peek per pair).

**Timing breakdown** (inter-peek gap within a group, median):
- 144 groups (35%) are **busy-polling**: median gap <60s — 587 calls, 443 redundant.
- 124 groups: median gap 60s–5min.
- 142 groups: median gap ≥5min (closer to legitimate spaced check-ins).

**Token cost:** direct `get_session_tail` results average 3734 bytes (p50 3651, p90
5927) — roughly 900-1000 tokens. 1142 redundant calls × ~900 tokens ≈ **~1M tokens** of
pure repeat-output in 30 days, before counting the tool-call overhead itself.

**Root cause, confirmed via the actual code:** 31 `run_elixir` turns across 31 sessions
attempt `Process.sleep(...)` inside the sandbox to pace a wait-then-peek loop. The
sandbox's `@denied_modules` list (`sandbox.ex`) includes `Process` outright — **28 of 31
attempts (90%) error immediately** with `module Process is denied`; the remaining 3
"successes" are false positives (a `start_session` prompt whose TEXT happened to contain
the string "Process.sleep", not an actual sleep call). Net: genuine `Process.sleep`
calls have a **~100% failure rate**. Traced one example end-to-end: session
`ba41b860…` scheduled `Tools.schedule_heartbeat(watch_children: true, interval_seconds:
600)` for target `78760f83…`, then 3 seconds later tried
`Enum.each(1..3, fn _ -> Process.sleep(20_000) end)` immediately followed by
`get_session_tail` — the *next* call landed 2 seconds later (not ~60s later), confirming
the sleep was denied and the agent fell straight into a tight loop instead of the paced
one it intended. Broader check: of the 23 turns combining `Process.sleep` +
`get_session_tail` in one block, 9 occurred within 5 minutes of that same session
scheduling a `watch_children`/`watch_session_ids` heartbeat — i.e. the agent set up the
push mechanism and then didn't trust it enough to just end its turn.

Of the 122 sessions that repeat-peeked at all, 101 (83%) DID use
`watch_children`/`watch_session_ids` heartbeats somewhere in the session — so this is
mostly "belt-and-suspenders on top of a mechanism that's already in use," not "never
heard of heartbeats."

**Fix — two parts:**
- **Prompt guidance** (`shared_prompts.ex`): after `schedule_heartbeat` with
  `watch_children`/`watch_session_ids`, end the turn — don't also hand-poll
  `get_session_tail` (with or without a sleep) in the same or next turn. The heartbeat
  message *is* the notification; polling defeats its purpose and, because `Process.sleep`
  is denied, ends up strictly worse than not pacing at all.
- **New/changed sandbox allowlist entry** (not prompt guidance — this needs a code
  change to `sandbox.ex`, out of scope to implement here, sibling-owned per repo
  convention besides): consider allowlisting `Process.sleep/1` specifically. It has no
  filesystem/OS/process-control capability, unlike the rest of `Process` — a narrow,
  safe exception that would at least make agents' paced-polling attempts work as
  intended instead of silently degrading into a busy loop, IF the prompt-guidance fix
  above doesn't fully eliminate this pattern.

---

### 3. `TaskCreate` has no batch form — 96.5% of its calls already arrive in same-session bursts

**What:** `TaskCreate` (Claude Code CLI-native, not an OrcaHub tool) creates exactly one
task per call — no `tasks`/`todos` array parameter. Of 836 `TaskCreate` calls in the
window, **807 (96.5%) occur in same-session bursts of ≥2 calls within 60 seconds**
(124 such bursts, avg ~6.5 calls/burst) — i.e. nearly every use of this tool is really
"set up an N-item task list," expressed as N sequential single-item calls.

19 of 21 `TaskCreate` errors in the window are agents explicitly trying to pass a
`tasks` array and getting rejected with `InputValidationError: … An unexpected
parameter 'tasks' was provided` before falling back to N individual calls anyway (I hit
this exact error myself, live, while starting this audit).

**Fix — mixed, be honest about what's OrcaHub's to fix:**
- The N-calls-per-burst volume itself (807 calls) is **not OrcaHub-actionable** —
  `TaskCreate` is a Claude Code CLI built-in, its schema isn't something
  `shared_prompts.ex` or any OrcaHub flag can change.
- The 19 failed-batch-attempt round trips ARE avoidable: **prompt guidance** in
  `shared_prompts.ex` telling agents up front that `TaskCreate` is strictly one-task-
  per-call with no array form, so they don't burn a call finding that out empirically.
  Small win (19 calls/30d) but free.

---

### 4. Hand-rolled Bash polling for deploy/service status instead of `Monitor`/`Jobs`

**What:** 544 (session, exact-command) groups had the identical `Bash` command run ≥2
times in one session — 907 redundant calls total (Bash's own error rate is a separate,
smaller issue, see below). Classifying by content: **514 of those 907 redundant calls
(57%) are poll-flavored** — commands matching `tail|ps -p|journalctl|kubectl get|docker
ps|status|log|watch`. Top example: one session ran
`ssh localhost 'tail -30 /tmp/deploy-5af9da8.log'` **42 times** verbatim in a session;
another ran `tail -5 gpu-watch.log; ps -p <pid> -o pid,etime,cmd` 17 times.

OrcaHub already ships purpose-built alternatives for exactly this: the `Monitor` tool
(poll-until-condition with a notification, not a hand-rolled loop) and the `Jobs`
subsystem (`Tools.check_job`, used only **50 times** in the whole window against 907
redundant polling Bash calls).

**Fix — prompt guidance** (`shared_prompts.ex`): for "wait for this background thing to
finish/change," point agents at `Monitor`/`Jobs.check_job` instead of a repeated
identical `Bash` status-check call. This is squarely the "existing tool nobody reaches
for" category the brief asked to watch for.

---

### 5. Smaller / informational findings (real, but lower volume or lower confidence)

- **`start_session` `idempotency_key` adoption is low (12.1%)**, and 14 confirmed exact
  duplicate `(directory, title)` spawns by the same caller session were found in the
  window (e.g. `a4895f89…` spawned "Correct the GB10 fake: over-long duration-less
  input returns" twice). Low *count*, but each duplicate is a whole wasted child
  session (many turns), not one wasted call — disproportionately expensive per
  incident. **Fix:** prompt guidance to default to passing `idempotency_key` on
  `start_session`, especially on any retry where the caller isn't sure the first call
  landed (the tool description already explains this; adoption is just low).
- **`Read` fails with `InputValidationError: … could not be parsed as JSON` 57 times**
  (55% of all 104 `Read` errors) — this is a CLI/tool-call-encoding issue at the
  Read-tool-argument level, not something routed through OrcaHub's MCP layer, so it's
  flagged as informational only; no clear OrcaHub-side lever identified.
- **Exact-duplicate `Read` calls:** 194 (session, file_path) groups repeated, 244
  redundant reads — smaller than the polling patterns above, mention only.
- **Exact-duplicate `Edit` calls (same file + same `old_string`)**: 80 groups, 85
  redundant — mostly consistent with "File has been modified since read" errors (132
  total, dominant `Edit` error) forcing a re-read-then-reedit cycle; not obviously
  fixable beyond existing tool behavior.
- **Bash retry-after-error is mostly *good* behavior, not an anti-pattern:** of the
  1220 cases where the same session called `Bash` again within 120s of a `Bash` error,
  only 45 (3.7%) were a **blind** retry of the identical failing command — the other
  96.3% changed the command (diagnosed fix). Included for completeness since "error
  retry loops" was explicitly asked about, but this one doesn't clear the bar as waste.
- **`run_elixir` overall error rate is 4.6%** (318/6927). Breakdown of causes beyond
  the #1 finding above: `Tools.Error`/tool-call failures 91 (mostly transient cross-node
  `{:not_started, {:erpc, :noconnection}}`), `CompileError`/syntax 19+18, sandbox
  `module X is denied` hits 42 (`Process` 29, `System` 5, `File` 6, `Code` 1, `Node` 1 —
  `Process` dominates, tying back to finding #2).

---

## Summary table (ranked by estimated waste)

| # | Pattern | Volume (30d) | Est. waste | Fix type |
|---|---|---|---|---|
| 1 | `report_progress` note crashes run_elixir | 71 crashes (22% of all run_elixir errors) | 71 aborted turns + silent progress loss | **Bug fix** — add length cap/validation, mirror `title`'s `normalize_title` |
| 2 | Hand-rolled `get_session_tail` polling vs heartbeat watch | 1142 redundant calls (144 busy-loop groups) | ~1M tokens + defeats the push mechanism | **Prompt guidance** (+ consider allowlisting `Process.sleep/1`) |
| 3 | `TaskCreate` no batch form | 807/836 calls in bursts; 19 failed batch attempts | 19 avoidable error round trips (807 itself not OrcaHub-fixable) | **Prompt guidance** (schema not OrcaHub's) |
| 4 | Hand-rolled Bash status polling vs Monitor/Jobs | 514 redundant poll-flavored Bash calls vs 50 `check_job` uses | ~500 avoidable Bash round trips | **Prompt guidance** (existing tools underused) |
| 5 | Low `idempotency_key` adoption / duplicate spawns | 14 confirmed duplicate spawns, 12.1% key adoption | 14 wasted full child sessions | **Prompt guidance** |

## What I did not find

No evidence of `search_sessions` → N×`get_session_tail` fan-out (the pattern explicitly
named in the brief) — searched for `search_sessions` without `include_activity`
followed in the same turn by ≥2 `get_session_tail` calls and found **zero** instances;
agents already reach for `include_activity: true` when they need per-child status
(200 embedded `search_sessions` calls sampled, `include_activity` present in a
majority). Worth confirming this stays true as usage grows, but it's a genuine
non-finding, not a gap in the analysis.
