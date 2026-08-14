# pi Session Forking Spec — Shared KV-Cache Reuse on a Self-Hosted llama-server

**Status:** Proposed — design only, nothing implemented. Companion to
`backend_abstraction_spec.md` (whose §12.2–§12.8 describe the pi adapter this
builds on); reads best after that spec's pi sections.
**Goal:** Let an orchestrator fork a pi session — spawn a child whose LLM
context starts as a byte-identical copy of the parent's — so the serving
layer's prompt cache turns the child's first turn from a ~26s cold prefill
into a ~2s warm resume. Forking is a pi-native primitive
(`pi --fork`); the work here is OrcaHub plumbing plus one prompt-determinism
refactor that makes the inherited prefix actually byte-identical.
**Hard requirement (operator, 2026-08-13): no caching, no forking.** Cache
reuse across EVERY fork is the feature's admission criterion, not an
optimization — see the go/no-go gate (§1.1).
**Non-goal:** general cross-backend forking. Claude/Codex have no equivalent
file-level fork primitive; this is pi-only (§10).

**Scope note:** everything here targets the hub's self-hosted serving path —
pi provider `gb10-coder` → llama-server on the GB10 box — where prompt-cache
economics are ours to reason about. Forking also *works* against hosted
providers (pi doesn't care), but the KV-budget guard (§7) and fan-out
protocol (§6) are motivated by the llama-server numbers in §1 and are
harmless elsewhere.

> The pi-side mechanics below are **Verified** where marked — ground-truthed
> 2026-08-13 via three worker investigations plus two live experiments
> against the GB10 llama-server (local pi → `192.168.1.77:8082`). The pi
> extension-API claims (`pi.sendMessage`, `custom_message` entries,
> `parentSession` headers, RPC `fork`/`clone`/`switch_session`) are verified
> against the bundled docs of the locally-installed pi **0.83.0**
> (`docs/extensions.md`, `docs/session-format.md`, `docs/rpc.md`); the
> adapter itself was live-verified against 0.80.3 (see
> `backend_abstraction_spec.md` §12.2) — the version-skew risk is Q5.

---

## 1. Motivation & measured baseline (Verified, 2026-08-13)

All numbers measured live and kept verbatim.

**pi session model.** pi (0.80.x) sessions are entry trees (id/parentId
JSONL). `pi --fork <path|id>` + `-p --mode json` compose; forks land in
`--session-dir` with a `parentSession` header field. RPC mode also has
fork/clone/switch_session commands. pi replays parent history
BYTE-IDENTICALLY on fork (verified — no nondeterministic injection).

**Serving layer.** llama-server b10223 on gb10 (`192.168.1.77:8082`,
qwen3-coder-next Q4_K_XL, pi provider `gb10-coder`), 4 slots,
`kv_unified=true` meaning 262,144 KV cells TOTAL shared across slots (NOT
per slot), host-memory prompt cache on (`--cache-ram` 8 GiB default, fills
to cap under traffic; a 100k-token session state ≈ 3.2 GiB, 200k ≈ 6.5 GiB,
so only 2-3 long-session states fit).

**Measured** (local pi → gb10, ~22.5k-token prefix):

- Cold prefill: 22,507 tok @ ~866-1,400 tok/s.
- Same-session resume: reprocesses ~16 tok.
- Serial fork's first turn: reprocesses ~18 tok (~2s vs ~26s cold).
- N CONCURRENT same-prefix first turns: 1 warm + N−1 full cold prefills
  (slot-local checkpoints; upstream fix PR #24190 is in b10223 but does NOT
  deliver cross-slot warm hits while the origin slot is busy — also
  verified: firing while a sibling is still GENERATING cold-prefills).
- Cache survives a fan-out; each slot that served a fork acquires the
  prefix.
- Hybrid (DeltaNet) arch → reuse at checkpoint granularity
  (`--checkpoint-min-step 8192`, ≤8k tok worst-case reprocess ≈ ~2-6s);
  `--cache-reuse` inapplicable.
- Cold-prefill contention craters the box: prefill drops to 520-830 tok/s
  and co-tenant decode falls ~38 → ~6 tok/s. A 4-child fan-out at 100k ≈
  4-5 wasted GPU-minutes. The server also carries external traffic (public
  endpoint).

The punchline: forking is nearly free **iff** (a) the inherited prefix is
byte-identical (§5) and (b) forked first turns are serialized (§6). Get
either wrong and a fork costs a full cold prefill *plus* degrades every
co-tenant on a shared public endpoint.

### 1.1 Go/no-go gate: no caching, no forking

Operator framing, adopted as the ship criterion: a fork that cold-prefills
its inherited history is strictly worse than a plain spawn — it pays full
prefill for tokens that may not even be useful to the child, while
degrading every co-tenant. So the feature ships **only** with a mechanism
that makes every forked child's first turn a cache hit, plus detection
when one isn't (§6.1). The measured data says this IS achievable on
llama.cpp today: serialized forks all hit at ~2s, and each slot that
serves a fork acquires the prefix (§1's fan-out-survival observation) —
so the gate is about *enforcing* the serialized regime mechanically, not
hoping orchestrators follow guidance. Concretely, v1 does not ship
without all three of: byte-identical prefixes (§5, pinned by §11.1's
tests), the mandatory first-turn gate (§6), and per-fork cache-miss
detection (§6.1). If serving moves to vLLM (§9), the serialization half
of the gate relaxes; the requirement itself does not.

---

## 2. Current state (inventory)

What exists today at each seam this spec touches — verified by reading the
files, line numbers as of `master` @ 173f1a1:

| # | Surface | File | Relevant today |
|---|---------|------|----------------|
| 1 | Spawn tool schema | `lib/orca_hub/mcp/tools/sessions.ex` ~127 | `start_session` args: prompt, directory, project_id, node, title, backend, model, notify_on_completion, idempotency_key, orchestrator, issue_id. **No fork arg, no code_exec arg** — a child's `code_exec` comes from the schema default (`true`), not the caller. |
| 2 | Spawn implementation | same, `do_start_session/3` ~619, `create_and_start_session/7` ~643 | Validates backend/model against the target node, creates the row, `Cluster.start_session` + `Cluster.send_message(…, :queue)` for the initial prompt. |
| 3 | Parent linking | same, `maybe_link_parent/4` ~1137 | Normal spawn: `parent_session_id = caller`, `notify_parent`. Orchestrator handoff: caller's own parent + `kind: "handoff"` `SessionInteraction` (~684). |
| 4 | pi spawn args | `lib/orca_hub/backend/pi.ex` `common_args/1` ~329 | `--session-dir <dir>/.pi_sessions/<orca-session-id>` (`pi_session_dir/1` ~423), `--session-id <claude_session_id>` when resuming (`maybe_add_session_id_arg/2` ~401 — a no-op on first spawn, when the column is nil), `--append-system-prompt`, four `-e` extensions, `--approve`. |
| 5 | Session-id capture | `lib/orca_hub/session_runner.ex` ~2083-2150 | pi announces no id unprompted in RPC mode; `Backend.Pi.on_open/1` writes `get_state`, `normalize/2` turns the response into a `system`/`init` event, the runner persists `claude_session_id` from it. |
| 6 | System prompt | `lib/orca_hub/backend/pi.ex` `system_prompt/1` ~983 | Per-session-divergent fragments enumerated in §5. |
| 7 | Context telemetry | same, `session_stats_event/1` ~638 | `pi_session_stats` message events with `context_usage` (`tokens`/`contextWindow`/`percent`, from pi's `get_session_stats`) persisted after every turn — the parent-size signal §7 reads. |
| 8 | Lifecycle | `session_runner.ex` `@idle_timeout_ms` ~440 (15 min idle teardown), `Streaming.WarmPool` eviction; `cleanup_session/1` `pi.ex` ~959 removes only the session's own `--session-dir`. |
| 9 | pi extensions | `priv/pi/orca.ts`, `orca-mcp.ts`, `orca-plan.ts`, `orca-guard.ts` | Load via `-e`; `orca-mcp.ts` reads `ORCA_MCP_URL` at `session_start` — the precedent for §5's env-fed identity extension. |
| 10 | Session schema | `lib/orca_hub/sessions/session.ex` | `parent_session_id` (~33), `code_exec` default `true` (~32), `claude_session_id` (~13). |

**Post-implementation addition — `fork_queue` MCP tool** (not in the table
above, since it didn't exist at the pre-implementation baseline; added by
`ForkGate`, `lib/orca_hub/mcp/tools/fork_queue.ex`): the orchestrator-facing
half of §6.1. It only matters in one situation — the gate detected a fork
child's first turn was a prompt-cache miss and PAUSED the remaining fan-out
(§6.1) — and without it that pause's `[Session lifecycle]` notification
would name an unreachable action. Minimal surface by design, one tool with
an `action` enum:

- `"status"` (default) — reports the parent's queue: `active_child_session_id`,
  `pending_child_session_ids`, whether it's `paused` and why. Defaults
  `parent_session_id` to the caller's own session (the queue is keyed by the
  parent), so a paused orchestrator can call it with no args.
- `"resume"` — releases the next pending child's first prompt and clears the
  pause, accepting that it (and every remaining sibling) may pay a cold
  prefill.
- `"abort"` — drops every pending first prompt for that parent without
  touching the child sessions themselves; they stay created and un-prompted
  so the orchestrator can message or archive them by hand.

Dispatches locally, no cross-node routing: a fork child always runs on its
parent's node (§3's same-node restriction), which is also the node serving
this MCP connection, and `ForkGate` is itself a per-node process.

---

## 3. API surface

`start_session` (`lib/orca_hub/mcp/tools/sessions.ex`) gains one argument:

```
"fork_from_parent" => %{
  "type" => "boolean",
  "description" => "pi-backend only. Fork the CALLER's session: the new
    child starts with a byte-identical copy of your full conversation
    context (cheap on a prompt-cached provider) instead of a blank
    context. The child is a normal child session in every other respect.
    Default: false."
}
```

v1 validation (clear tool errors, checked in `create_and_start_session/7`
before the row is created):

- Caller must itself be a **pi-backend** session (the fork source is the
  caller — v1 has no "fork some third session" form).
- Child **inherits, and may not override**: `backend`, `model`,
  `directory`, `project_id`, runner node (same-node only — the parent's
  JSONL must be readable at spawn time), `orchestrator`, and `code_exec`.
  Passing a conflicting `backend`/`model`/`directory`/`project_id`/`node`/
  `orchestrator` arg is an error, not a silent override. `orchestrator`
  and `code_exec` matter because they change the rendered prompt prefix
  (system-prompt fragments *and* the MCP tool list `orca-mcp.ts` registers,
  which serializes into the model-side prompt) — a flag-changing fork
  diverges at byte 0 and inherits nothing (§10).
  - ⚠ Deviation from a naive reading of the code: since `start_session`
    has no `code_exec` arg (inventory #1), "inherit" here means the
    creation path must **explicitly copy the parent's `code_exec` value**
    into the child row — relying on the schema default silently breaks
    forking from a `code_exec: false` parent.
- `issue_id` is allowed (the issue trailer rides the identity payload,
  §5.2 — it does not touch the shared prefix).

**Result additions:** alongside the existing
`session_id/node/model/backend/directory/already_exists/orchestrator`
fields, a fork spawn's result includes `forked_from` (the parent id) and
`parent_context_tokens` — the parent's last known context size, read from
its most recent `pi_session_stats` message event (`context_usage.tokens`,
inventory #7; `null` if the parent has none yet) — so orchestrators can
reason about the KV budget (§7) without a separate lookup.

**Persistence:** a new nullable `forked_from_session_id` binary_id column
on `sessions`. `parent_session_id` alone cannot serve as the fork
discriminant: it's set for *every* child spawn (inventory #3), and the
runner needs an unambiguous spawn-time signal for §4's `--fork` path plus a
durable record that survives re-parenting semantics. Lineage/notification
plumbing (`parent_session_id`, `notify_parent`, `[Session lifecycle]`
callbacks) is unchanged — a fork child is also a normal child.

---

## 4. Fork mechanics (adapter layer)

All in `lib/orca_hub/backend/pi.ex`; `SessionRunner` stays backend-agnostic.

**First spawn only.** The existing first-spawn discriminant is already
exactly right: `ctx[:claude_session_id]` is nil until the runner captures
the id (inventory #5). `common_args/1` changes from

```
|> maybe_add_session_id_arg(ctx[:claude_session_id])
```

to: when `claude_session_id` is nil **and** `ctx.forked_from_session_id` is
set, emit `--fork <parent-session-file>` (child keeps its **own**
`--session-dir` as today); otherwise the current behavior. The
`forked_from_session_id` and the resolved parent-file path ride the runner
`data` map the same way `plan_mode_pending` does (ctx IS `data` at every
`spawn_spec/2` call site).

**Session-id capture is unchanged.** After `--fork`, the active session IS
the new fork (pi assigns it a fresh id and writes a `parentSession` header
— `docs/session-format.md`). `on_open/1`'s `get_state` → `system`/`init` →
persist-as-`claude_session_id` path needs zero changes; every later cold
reopen resumes via `--session-id` exactly as today, and the `--fork` flag is
structurally unreachable from then on (the nil check).

**Locating the parent file.** Parent's dir is deterministic:
`<parent.directory>/.pi_sessions/<parent.orca_session_id>/` (same
`pi_session_dir/1` computation, keyed by the *OrcaHub* id). Inside it, pick
the `*.jsonl` whose header `id` equals the parent's `claude_session_id`
(defensive against pi ever writing siblings into one dir). Resolved at
spawn time on the runner node — hence §3's same-node restriction.

**Every fork is a mid-turn fork.** The JSONL is append-only, so forking
while the parent is mid-turn still yields a well-formed (just possibly
turn-truncated) prefix — which is fortunate, because it is the ONLY case
that exists. `fork_from_parent` forks the CALLER, and the caller is by
construction mid-turn at the instant `start_session` runs: it has emitted a
tool call and still has to consume the tool result and produce a final
message.

> **Amendment (live smoke, 2026-08-14).** This paragraph previously said
> "guidance + the §6 gate both push toward forking a *just-idled* parent."
> That is unachievable through this API — there is no way for a caller to
> fork itself while idle — and the advice was actively misleading, because
> it implied a *state* the orchestrator could reach rather than a *race*
> the gate has to own. Correctness therefore does not rest on parent
> idleness at spawn time at all: §6's gate holds the first child until the
> parent's in-flight turn ENDS, which is what actually frees the slot
> caching the prefix. What the orchestrator still controls is the eviction
> exposure window, and that window runs **parent-turn-end → last child's
> first turn**, not "parent-idle → last fork" — so the guidance that
> survives is: make fork spawns the last action of your turn and end the
> turn promptly (§6).

**Fallback if `--fork` rejects an absolute path outside the child's
`--session-dir`** (Q1 — plausible, since `--session <path|id>`'s id lookup
is dir-scoped): copy the parent file into the child's session dir, rewrite
the header `id` (fresh uuid) + `parentSession` (absolute parent path), and
spawn with plain `--session-id <fresh-uuid>`. Byte-identical history either
way; verify before building it (§11.0).

> **Q1 RESOLVED (spike, 2026-08-13):** the absolute-path form of `--fork`
> IS accepted with no rejection (`pi_fork_spike_findings.md` Q1) — the flag
> alone is what shipped in §4's adapter code. This copy + rewrite-header
> fallback was **not built**.

**`cleanup_session/1` unchanged.** Forks share no mutable files — the child
copied nothing and its `--session-dir` is its own; removing it can never
touch the parent's (inventory #8).

---

## 5. Prompt determinism — the crux

Any byte difference *before* the inherited history invalidates prompt-cache
reuse of the ENTIRE prefix (the serving layer matches longest-common-prefix
from byte 0). Today `Backend.Pi.system_prompt/1` (~983) diverges per
session in exactly these fragments (verified against
`lib/orca_hub/backend/shared_prompts.ex`):

1. The literal `"Your OrcaHub session ID is #{ctx.session_id}."` line.
2. `SharedPrompts.commit_trailer_prompt(session_id)` (~467) — embeds the id
   in the required git trailer.
3. `SharedPrompts.issue_commit_trailer_prompt(issue_key)` — when
   issue-linked; varies per issue. (Not in the original exploration's list;
   found reading the adapter.)
4. `SharedPrompts.open_issues_prompt(session_id)` (~352) — a **live DB
   query** at spawn time: varies per session *and* per moment, so it
   already busts same-session prefix caching on every cold reopen today.

`orchestrator_prompt/3` and `worker_practices_prompt/2` take the session id
but ignore it (`_session_id` — verified ~160-209): they're functions of
flags only and are NOT divergence sources.

### 5.1 Proposal: flags-only `--append-system-prompt`, identity as a session entry

For the pi backend only, `system_prompt/1` becomes a pure function of
`(orchestrator, code_exec, commit_trailer-enabled)` — fragments 1–4 are
removed from the flag entirely. Two pi sessions with the same flags then
render byte-identical system prompts (§11.1 pins this with a unit test).

Identity instead becomes a pi **`custom_message`** session entry — these
participate in LLM context (`docs/extensions.md`: "Custom messages
participate in LLM context"; NOT `pi.appendEntry`, which is explicitly
TUI-only and never reaches the model). A new extension —
`priv/pi/orca-identity.ts`, loaded via `-e` alongside `orca.ts` (inventory
#9) — reads an `ORCA_IDENTITY` env payload (JSON: session id, commit-trailer
instruction, issue trailer if any, open-issues text) injected by
`pi_env/1`, and at `session_start` appends it via
`pi.sendMessage({customType: "orca-identity", content: …}, {deliverAs:
"nextTurn"})` — mirroring how `orca-mcp.ts` already consumes
`ORCA_MCP_URL` at `session_start`.

**Idempotence rule** (drives both cold reopens and forks): at
`session_start`, walk the session's existing entries; only append when the
latest `orca-identity` entry names a **different** session id.

- Cold reopen of the same session → latest entry names *this* id → no-op →
  the prefix stays stable across reopens.
- Fork child's first spawn → the inherited history's latest identity entry
  names the *parent* → the extension appends an identity **update** ("you
  are now session `<child>`, forked from `<parent>`; use trailer `<child>`
  from now on") exactly at the divergence point — the entire inherited
  prefix above it is untouched. The right fork behavior falls out of the
  reopen rule automatically; no fork-special-casing in the extension.

**Identity in prompt matters less than it looks.** MCP tools already act as
the child regardless of prompt text — `ORCA_MCP_URL`'s `orca_session_id`
query param binds the connection (env differs per child; env is invisible
to the KV cache). The commit trailer is the main *text-level* identity, and
the update entry carries it.

**This helps ALL pi sessions, not just forks:** moving `open_issues_prompt`
(time-varying, fragment 4) out of the system prompt means an ordinary
long-lived pi session's cold reopen stops paying a full re-prefill against
a prompt-cached provider. Fresh open-issue state can ride the same identity
entry (appended only when changed) or simply be dropped from pi (it's
advisory).

### 5.2 What still varies, deliberately

The identity entry itself, `ORCA_MCP_URL`, the issue trailer, and the
child's own turns — all *at or after* the divergence point, where variance
is free. The invariant to protect is: **no per-session byte before the
inherited history.** §11.1's tests are the regression fence.

---

## 6. First-turn serialization (mandatory, mechanical)

Measured (§1): concurrent same-prefix first turns get 1 warm + N−1 full
cold prefills — checkpoints are slot-local, and firing while a sibling is
still *generating* also cold-prefills. Under §1.1's gate, serialization is
therefore a correctness mechanism, not an optimization:

**Rule: forked children's FIRST turns are serialized at full-turn
granularity** — child N+1's first prompt goes out only after child N's
first `result` event lands ("prefill finished" is NOT sufficient —
verified). After its first turn, each child has its own slot-resident
state and needs no further coordination.

Enforcement is MECHANICAL and mandatory. Prompt guidance to orchestrators
("fork serially, wait for each child's first reply") is not a shippable
version of this rule — at most a dev-mode stopgap behind a config flag
while the gate is built, never the production posture. The enforcement
point: for a fork child, `create_and_start_session/7` (inventory #2)
never calls `Cluster.send_message` with the initial prompt directly. The
child is *created* immediately (ids/links/UI exist), but its first prompt
is handed to a per-runner-node coordinator — `OrcaHub.ForkGate`, a
GenServer holding one FIFO per parent id — that owns delivery. The gate
releases the next child's first prompt when the previous child's first
turn completes, observed via the sibling's `session:<id>` PubSub topic
(the same events `SessionLive.Show` consumes). Non-fork spawns are
untouched.

#### Amendment (live smoke, 2026-08-14): the parent is child zero

Sibling-vs-sibling serialization as written above is **necessary but not
sufficient**, and the case it misses is not an edge case — it is every
fan-out's first child. Measured live on gb10 across 3 independent parents,
3/3: the FIRST fork off a parent context cold-prefilled its entire
inherited history (`cache_read_input_tokens` **exactly 0**, 25.7-32.0 s),
i.e. precisely the outcome §1.1 exists to exclude. Every *later* sibling
hit cleanly.

Root cause, confirmed against llama-server's own slot logs. Because
`fork_from_parent` forks the caller (§4), the parent is mid-turn at spawn
time by construction. Its next LLM call — consuming the very tool result
that created the child — is routed straight back onto the slot holding the
prefix (`selected slot by LCP similarity, f_sim_best = 0.994`) and holds it
for the rest of the turn. The child's request arrives ~1.6 s later, finds
that slot busy, falls back to `selected slot by LRU` onto a slot holding
nothing relevant, and pays a full prefill. The parent's slot freed ~4 s
*after* the child had already finished cold-prefilling. Later siblings hit
only because the first child's cold prefill seeded a second copy of the
prefix — i.e. the first fork pays a full cold prefill to subsidize the rest
of the fan-out, which is exactly the economics §1.1 rejects.

**Rule (widened):** the first child of a fan-out has one ADDITIONAL
precondition — the parent's own in-flight turn must have ended. Mechanically
the parent is just **child zero** in the same serialization chain: same
`session:<id>` observation, same four turn-ending signals, same
`release_timeout_ms` backstop. Everything above about sibling-vs-sibling
serialization is unchanged; this is a precondition on the FIRST release,
not a replacement for it.

Verified before implementing (same box, same model, ~32 k-token parent,
parent process NOT mid-turn): the child's first turn reprocessed **20 fresh
tokens against `cacheRead` 31,813 in 4.97 s**, and llama-server chose
`selected slot by LCP similarity, f_sim_best = 0.999` — the parent's own
slot — with no intervening task switch. That also settles the open question
the smoke report raised: the prefix does **not** need to be written to the
host prompt cache before LCP can route to it; still being slot-resident is
enough.

**A parent that is idle, `ready`, `error`, torn down, cold, or simply gone
clears this check immediately** and adds zero latency. File-level fork needs
no live parent runner (§12 Q4), and a non-running parent is not holding a
slot.

**Honest cost.** "One parent-turn's latency" is the BEST case, not the
typical one. The gate waits for the parent's ENTIRE current turn to end, not
just the tool call that spawned the fork — so an orchestrator that forks and
then runs five more minutes of tool calls holds every one of its children
for five minutes. That is inherent to the API shape (the caller is always
mid-turn), not a bug in the gate, and it is still strictly better than the
25-32 s guaranteed cold prefill plus co-tenant decode collapse (30 → 4.7
t/s) it replaces. It is also cheap to avoid, which is the one piece of
orchestrator guidance this feature does carry (in the **pi** system prompt
only — forking is pi-native and Claude/Codex prompts are byte-pinned):
*make fork spawns the LAST action of your turn and end the turn promptly;
the gate releases on your result.* Following it converts the worst case into
the best case.

**Residual race (accepted, documented rather than fixed).** When the
parent's turn ends, the parent may immediately consume a queued follow-up
(heartbeat, operator message, `[Session lifecycle]` ping) and start a NEW
turn that re-grabs the slot. The gate releases off the turn-ending EVENT,
not off a status poll, so it is on the same +6-8 ms footing as the measured
sibling releases — it should win that race essentially always. If it ever
loses, the outcome is not corruption but a cold prefill, which §6.1 detects
and reports like any other miss.

Failure handling:

- **Child errors mid-first-turn:** an error event ends the turn — release
  the next child immediately. A later re-prompt of the errored child goes
  back through the gate only if its first turn never completed.
- **Parent's turn errors, or never ends:** the parent-as-child-zero wait
  honours the same turn-ending signals, so a CRASHING parent (`cli_error` /
  `{:status, :error}`) releases the first child immediately rather than
  stranding the whole fan-out behind a dead turn. A parent that merely hangs
  is covered by the SAME per-child `release_timeout_ms` knob — deliberately
  not a second timeout mechanism — which releases anyway and emits a
  `fork_gate_parent_timeout` warning on both the parent's and the held
  child's session topics.
- **Child hangs mid-first-turn:** per-child release timeout (default
  ~10 min, roughly one worst-case long first turn) releases the next and
  emits a warning on both the parent's and child's session topics.
- **Node restart:** gate state is per-node and in-memory — the queue
  drops, and `SessionResumer`-recovered children send their pending
  prompts unserialized. §6.1's miss detection turns that from a silent
  regression into a visible one.

Also mandatory posture, not guidance: **a fork fan-out is a prompt,
contiguous operation.** The window between the parent going idle and the
LAST fork's first turn must stay bounded — the host-memory prompt cache
holds only 2-3 long-session states (§1), and unrelated (public-endpoint)
traffic can evict the parent's prefix mid-fan-out. The gate provides the
bound structurally: it releases children back-to-back with zero think
time between them, so the exposure window is (fan-out width × first-turn
duration), a function of the work itself rather than of orchestrator
diligence.

### 6.1 Cache-miss detection (eviction is a correctness concern)

> **Amendment (post-ship):** the original text below said "fresh
> `input_tokens`" without qualifying which response's `input_tokens` — as
> written it read as the synthesized `result` event's accumulated,
> turn-SUMMED `input_tokens` (`accumulate_usage/1`). That is wrong for a
> forked child's first turn that runs a tool loop: `input_tokens` is
> summed across every assistant response in the turn, and later responses'
> inputs legitimately grow (each tool result appends to the prompt) —
> nothing to do with whether the inherited prefix hit the cache. A long
> first-turn tool loop could therefore inflate the sum past the 25%
> threshold and false-positive a pause even on a clean cache hit. The
> comparison is now **FIRST-RESPONSE-ONLY**: only the turn's first LLM
> response has a prompt prefix that is exactly `[shared system prompt +
> inherited history + identity entry + first prompt]` — the one prefix
> this check is actually testing. `Backend.Pi.agent_end_result/2` now also
> surfaces a `first_response_usage` field (`input_tokens` /
> `cache_read_input_tokens` from just the first assistant response of the
> turn) alongside the unchanged, still-summed `usage` field (other code
> and the UI keep reading `usage`). `ForkGate` reads `first_response_usage`
> when present, falling back to `usage` otherwise. See
> `lib/orca_hub/fork_gate.ex`'s §6.1 moduledoc section for the
> implementation-level detail. The rest of this section (threshold,
> hit/miss framing, pause-and-notify behavior) is unchanged by the
> amendment — only the definition of "fresh input tokens" changed.

Eviction cannot be *prevented* from OrcaHub — the box serves external
traffic — so it must be *detected*, per fork. The signal already flows:
pi reports per-response `usage.cacheRead` and `usage.input`, and the
adapter already folds both into the synthesized `result` event
(`accumulate_usage/1`, `pi.ex` ~768 — `cache_read_input_tokens` /
`input_tokens`); in the §1 experiments these exactly matched the server's
own counters. A forked child's first `result` is therefore self-reporting
(per the amendment above, "first `result`" here means the FIRST assistant
response inside that result, not the turn-summed total):

- **Hit:** `cache_read_input_tokens` ≈ parent context size (same
  `pi_session_stats` read as §3's `parent_context_tokens`), with fresh
  `input_tokens` a small fraction of it — see the amendment just below for
  what "small" actually measures at.
- **Miss:** `input_tokens` ≈ parent context size — the child just paid
  full prefill.

> **Amendment (live smoke, 2026-08-14): "in the tens" was optimistic by
> ~2 orders of magnitude, and there are TWO hit regimes, not one.** Every
> real hit observed through OrcaHub reprocessed **1,798-2,097 fresh tokens**
> (children B/C/D/G/H, against parent contexts of 26,688-32,152) — not
> "tens". Those children were LRU-routed onto a slot that did *not* already
> hold the prefix, so the hit came from RESTORING it, and restore lands at
> hybrid/DeltaNet checkpoint granularity (§1) rather than at the exact
> divergence point. The "tens" figure describes the *other* regime: when the
> child lands by LCP similarity on the slot still holding the prefix, no
> restore is needed and the reprocess is genuinely tiny — the §6 verification
> run measured **20 fresh tokens against `cacheRead` 31,813**. Both are
> clean hits. A future maintainer reading "tens" and seeing 2,000 would
> reasonably conclude a partial miss; they should not. The 25% threshold is
> **vindicated by exactly this**: it was chosen so checkpoint-granularity
> partial hits don't false-positive, and at ~6-7% of the parent context the
> observed hits sit comfortably inside it while the observed misses sat at
> ~100%. No threshold change is warranted — only this expectation is
> corrected.

**Field note (live smoke, 2026-08-14): this half of the gate worked
perfectly, and caught its own feature failing.** Against all three
structurally-caused misses above it detected 3/3, emitted the warning on
both topics, annotated the child's §8 marker, paused the remaining fan-out,
notified the orchestrator with an actionable `[Session lifecycle]` message,
and reported correct `fork_queue` status/resume. The feature failed exactly
as it was designed to fail — visibly, with the fan-out stopped rather than
silently paying full prefill for every remaining sibling.

`ForkGate` performs this check on each first `result` before releasing
the next child. Miss threshold: fresh `input_tokens` > ~25% of
`parent_context_tokens` — chosen so checkpoint-granularity partial hits
(≤8k-token reprocess on this hybrid arch, §1) don't false-positive. On a
detected miss: emit a warning event on the parent's and child's session
topics (and annotate the child's synthetic fork marker, §8), and —
configurable, default ON for the gb10 profile — **pause the remaining
fan-out** and notify the orchestrator (a `[Session lifecycle]`-style
message) rather than serially paying full prefill for every remaining
sibling against an evicted prefix. The orchestrator resumes the queue
(accepting cold cost) or aborts it.

---

## 7. KV/context budget guard

Unified KV means fan-out width × context depth is a single shared budget:
262,144 cells ≈ 4×65k, 2×130k, or 1×260k concurrently-resident contexts.
A 4-wide fan-out of a 100k-token parent physically cannot be
simultaneously slot-resident.

v1 is a **soft guard**: `start_session` computes
`(concurrent fork-children of this parent + 1) × parent_context_tokens`
(from the same `pi_session_stats` read as §3's result field) and, above a
threshold (default: the 262,144 total, configurable), *appends a warning to
the tool result* — it does not refuse. Rationale for soft: the numbers are
provider-specific (a hosted-provider fork has no such budget), OrcaHub
can't see the llama-server's other tenants anyway, and the failure mode
(slot thrash → slow, not wrong) matches a warning's severity. Hard
enforcement, and whether the threshold should live in per-node policy, is
Q6. This guard is distinct from §6.1's miss detection: the guard
*predicts* slot-residency pressure at spawn time; miss detection
*observes* actual cache behavior at first-turn time.

---

## 8. UI / DB

- **The child's feed starts empty while its LLM context is full** — the
  fork copies pi-side history, not OrcaHub `messages` rows. Bridge the gap
  with one synthetic system message created at fork-spawn time (via the
  same `create_message` path the runner persists events through):
  `%{"type" => "system", "subtype" => "forked_from", "parent_session_id" =>
  …, "inherited_tokens" => …}`, rendered by `MessageComponents`' system
  path as "Forked from session `<parent>` (`<tokens>` tokens inherited)",
  ideally linking to the parent session.
- **Lineage:** `parent_session_id` (already set — a fork child is a normal
  child) + the new `forked_from_session_id` column (§3). Additionally
  record a `kind: "fork"` `SessionInteraction` via the existing
  best-effort `maybe_record_interaction/3` (~498) — same posture as
  `"handoff"`: the session-graph edge survives even if parentage is later
  re-examined.
- **No copying of parent message rows in v1.** Duplicating a 100k-token
  history into `messages` bloats the DB and lies about what the child
  *displayed*; the synthetic marker + a link to the parent is honest and
  cheap. Revisit only if users demand inline inherited history.

---

## 9. Alternative: vLLM serving backend (open decision)

vLLM's automatic prefix caching shares KV blocks across CONCURRENT
requests — cached prefix blocks are global to the engine, not slot-local —
so §1's 1-warm + N−1-cold pathology does not exist there and §6's
serialization would be unnecessary (miss detection, §6.1, stays useful as
a cheap assertion). The catch for this stack: qwen3-coder-next is a
hybrid (GatedDeltaNet) architecture, and hybrid-model prefix caching only
landed in vLLM ~2026-07-12 (PR #46384, "support partial prefix cache hit
for hybrid model", building on the hybrid KV cache manager) — recent
enough that its maturity on this model class is unproven here.

A parallel serving-engine evaluation is underway in the llm-serving
project. This spec treats the engine choice as an **open decision** and
layers the feature so it works over either:

- **Engine-agnostic (the bulk):** the `fork_from_parent` surface (§3),
  file-level fork mechanics (§4), prompt determinism + identity injection
  (§5), and the UI/DB treatment (§8). None of it knows what serves the
  tokens.
- **llama.cpp-specific (isolated):** the mandatory `ForkGate`
  serialization, the miss-detection threshold (§6/§6.1), and the
  unified-KV budget guard (§7). These live behind a per-node/per-provider
  serving profile (where §7's threshold already wanted to live — Q6), so
  a vLLM cutover disables serialization by configuration without touching
  the fork feature itself.

Decision rule: if vLLM's hybrid prefix caching proves out on
qwen3-coder-next before this ships, §6 collapses to miss-detection-only
and §1.1's gate is satisfied by the engine instead of by OrcaHub
scheduling. No caching, no forking — on either engine.

---

## 10. Out of scope (v1)

- **Cross-node forks** — needs parent-file transfer; same-node covers the
  motivating single-GB10 topology.
- **Non-pi backends** — no file-level fork primitive to build on.
- **Flag-changing forks** (orchestrator→worker, code_exec flips) — diverge
  at byte 0, inherit no cache; a fork that costs a full cold prefill is
  strictly worse than a plain spawn plus a written handoff.
- **Fork-from-arbitrary-session** (a third session, not the caller) and
  fork-from-entry (pi's RPC `fork` forks from a chosen user message —
  powerful, later).
- **Explicit llama-server slot save/restore** (`/slots` API) — heavier
  operational coupling for marginal gain over checkpoints.
- **llama-server config changes** — a separate track: gpu-arbiter
  coordination on `--cache-ram` 8→12 GiB, conditional on image-gen models
  moving to on-demand residency; a companion effort, decision pending, and
  this design must not depend on it.

---

## 11. Verification plan

0. **Pre-implementation spike (gates §4's shape):** Q1 — does `--fork`
   accept an absolute path outside the child's `--session-dir`? Five
   minutes with two temp dirs; decides flag-vs-copy before any Elixir is
   written. **RESOLVED, 2026-08-13:** yes — see `pi_fork_spike_findings.md`
   Q1; §4 ships flag-only. The same spike also resolved Q7 (§12) as LAZY
   materialization.
1. **Unit:** two pi sessions, same flags, different ids → byte-identical
   `system_prompt/1` output (pins §5.1; `test/orca_hub/backend/pi_test.exs`
   is where prompt-content assertions already live). Identity-extension
   idempotence: reopen appends nothing; fork appends exactly one update
   entry.
2. **Stub-level:** extend the existing
   `test/support/fixtures/pi_stub_rpc.py` + `PiStubIntegrationTest`
   pattern — assert first-spawn args carry `--fork <parent file>` (and no
   `--session-id`), the captured new id lands in `claude_session_id`, and
   the second spawn resumes via `--session-id` with no `--fork`.
3. **Live smoke on gb10:** replicate the §1 experiment through OrcaHub
   proper — fork an idle ~20k-token pi session, expect the child's first
   turn ≈ ~2s / ~tens of tokens reprocessed (vs ~26s cold), confirmed via
   llama-server slot logs.
4. **Fan-out serialization:** 3-child fork through the §6 gate — assert
   first prompts are released strictly after the prior sibling's first
   `result`, including the error-release and timeout-release paths (stub
   level), plus one live 2-child run confirming no cold prefill on either.
5. **Miss detection (§6.1):** stub-level — a first `result` whose usage
   reports full-prefill-sized `input_tokens` triggers the warning event
   and pauses the remaining queue; a checkpoint-partial hit (≈8k fresh
   tokens against a large parent) does not. Live — force an eviction
   (restart llama-server, or flood `--cache-ram` with unrelated traffic)
   between parent-idle and fork, and confirm the miss is detected and
   surfaced rather than silently absorbed.

---

## 12. Open questions

- **Q1 — RESOLVED (spike, 2026-08-13):** Does `--fork` accept an absolute
  path outside the child's `--session-dir`? **Yes, no rejection** — see
  `pi_fork_spike_findings.md` Q1. §4 ships the plain `--fork <absolute-path>`
  flag; the copy + rewrite-header `id`/`parentSession` fallback was
  **not built** (not needed).
- **Q2:** Forking a parent whose history contains compaction entries
  (`branch_summary`), or captured mid-plan-mode / with pending
  extension-UI state — does replay reconstruct all of it cleanly, and does
  the child inherit plan-mode-on? Needs a targeted experiment; possibly
  "refuse to fork while a UI request is pending."
- **Q3:** Should fork also be exposed via the RPC `fork`/`clone` commands
  of a WARM parent port instead of file-level? Probably not v1 — cold-file
  fork is simpler and node-local. Note the semantics differ: RPC `fork`
  rewinds to a chosen prior user message *within* the live session, and
  `clone` duplicates the current branch into a new session
  (`docs/rpc.md`) — `clone` on a warm port is the closer future analogue,
  not `fork`.
- **Q4:** Interaction with warm-pool eviction and idle teardown
  (`@idle_timeout_ms`, 15 min): forking reads the parent's JSONL from disk,
  so a torn-down parent is *fine* — but confirm pi flushes entries to the
  file as they land (not on exit), so a fork taken while the parent is
  warm-but-idle sees the full history. Also: does a fork fan-out's worth of
  new children pressure `ORCA_MAX_WARM_SESSIONS` (default 6) into evicting
  the parent mid-fan-out, and does that matter? (It shouldn't — file-level
  — but the §6 gate holds references to the parent id and should not
  assume a live parent runner.)
- **Q5:** Does the identity `custom_message` approach need a pi version
  pin? `pi.sendMessage` and the `custom_message` entry type are verified
  in 0.83.0's docs; the adapter was live-verified against 0.80.3; nodes
  may skew. Decide: minimum-version check in the extension (degrade to
  today's per-session system prompt?) vs pinning pi via BackendInstaller.
- **Q6:** Hard enforcement for the §7 KV budget (refuse vs warn), and
  whether the threshold belongs in per-node policy (`nodes` table) since
  it's a property of the serving box, not of OrcaHub.
- **Q7 — RESOLVED (spike, 2026-08-13):** Does `pi.sendMessage(…, {deliverAs:
  "nextTurn"})` at `session_start` write the `custom_message` entry to the
  JSONL immediately, or only when the next prompt arrives? **LAZY** —
  materialized only when the next prompt/turn actually arrives, confirmed
  empirically not written yet even within the same `session_start` handler
  invocation that queued it (see `pi_fork_spike_findings.md` Q7). §5.1's
  idempotence check (walk entries at `session_start`, compare the latest
  `orca-identity` entry's session id) remains correct and sufficient for the
  steady-state case; the spike also found the one gap this implies (a
  process torn down before its first prompt loses the queued entry) is
  self-healing on the next reopen, so no extra "already queued" flag was
  needed.

---

## 13. Known limitations (v1, accepted)

Distinct from §12's open questions above — these are not undecided, they
are shipped-with-eyes-open tradeoffs `ForkGate` (§6/§6.1) makes, recorded
here so they don't get rediscovered as surprise bugs later.

- **The per-child release timeout is an unmeasured guess.**
  `ServingProfile.release_timeout_ms/0` defaults to ~10 minutes, documented
  in §6 and in `lib/orca_hub/fork_gate.ex`'s moduledoc as "roughly one
  worst-case long first turn." That figure was never measured against a
  real worst-case forked first turn on the gb10 box — it's a round-number
  guess, not a number derived from §1's timing data. If it turns out too
  short, a legitimately-long first turn (a large tool loop) gets its
  sibling released early, possibly cold-prefilling for no reason; too long,
  and a genuinely hung child holds up the whole fan-out longer than
  necessary. Revisit once there's real distribution data on forked
  first-turn durations.
- **§7's KV budget models one resident copy of the prefix; a fan-out can
  produce N.** The soft guard computes
  `(concurrent fork-children + 1) × parent_context_tokens` as if the shared
  prefix were resident once. The 2026-08-14 smoke shows it need not be:
  llama-server routes a child by LCP similarity only when the matching slot
  is FREE, and otherwise falls back to `selected slot by LRU` — so N forks
  of a P-token parent can end up spread across N distinct slots, each
  holding its own copy, for N×P cells against the 262,144-cell unified pool
  rather than the ~P the guard implicitly assumes. The §6 parent-turn wait
  makes the *first* child likely to land back on the parent's own slot
  (verified: `f_sim_best = 0.999`), which helps, but nothing forces siblings
  2..N onto it — B/C/D were each LRU-routed to different slots and still hit
  (from restore), which is fine for latency and invisible to the guard's
  arithmetic. Consequence: the guard under-predicts residency pressure for
  wide fan-outs of deep parents, in the direction of warning too little. Not
  fixed in v1 — it is a soft warning either way, and modelling slot
  placement would mean modelling a scheduler OrcaHub cannot see (it also
  cannot see the box's other tenants at all, §7). Fold into Q6 if the guard
  is ever made hard.
- **A node restart mid-fan-out silently unserializes the remaining
  children.** `ForkGate`'s queue is per-node and in-memory by explicit §6
  design (see "Node restart" under Failure handling, both in §6 and in the
  module's moduledoc) — a restart drops the queue, and
  `SessionResumer`-recovered children send their pending first prompts
  unserialized, with no gate left to pause them. §6.1's cache-miss
  detection is the only remaining signal at that point: it will flag and
  warn on whichever of those children happens to miss, but by then there is
  no queue to pause — the "pause the remaining fan-out" recovery path in
  §6.1 requires a live gate holding pending siblings, which a restart has
  already lost. This is deliberate (a queue resurrected minutes after a
  restart is fanning out against a prefix the host-memory cache has very
  likely already evicted anyway, so serializing it further buys little),
  but it means a restart during a fan-out is observably worse than a
  restart between fan-outs, and there is no v1 mechanism to detect "a fork
  fan-out was in flight when this node went down" after the fact beyond
  reading the miss warnings the resumed children happen to produce.
