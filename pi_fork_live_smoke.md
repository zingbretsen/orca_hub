# pi Session Forking — LIVE SMOKE against gb10 (2026-08-14)

> **⚠ THIS DOCUMENT HAS TWO PARTS.**
> **Part 1 (below) is the PRE-FIX run against `7d73b58` — verdict FAIL.** It is retained
> unedited as the evidence that motivated the §6 scope amendment.
> **Part 2 ("POST-FIX RE-MEASUREMENT", at the end) is the run against `56a18ba`, which
> contains the fix — verdict PASS.** If you want the current status of the feature, read
> Part 2. Part 1's FAIL verdict is **historical** and no longer describes shipped behaviour.

---

# PART 1 — PRE-FIX RUN (`7d73b58`)

**Verdict against `pi_fork_spec.md` §1.1 ("no caching, no forking"): FAIL.**

The gate requires that **every** forked child's first turn be a cache hit. It is not.
Across three independent parent sessions, the **first** fork taken off a freshly-built
parent context cold-prefilled its entire inherited history — `cache_read_input_tokens = 0`,
full prefill, 25.7–32.0 s — i.e. exactly the "strictly worse than a plain spawn" outcome
§1.1 was written to exclude. Every *subsequent* fork off the same parent hit cleanly
(~2 k fresh tokens, 3.2–8.2 s). The failure is **reproducible (3/3), structural, and has a
single identified root cause** (§"Root cause" below), confirmed against llama-server's own
slot logs.

Everything *else* in the feature worked exactly as specified: ForkGate serialization,
§6.1 miss detection, the pause-and-notify path, `fork_queue` status/resume, the §8 marker,
and `parent_context_tokens` / `first_response_usage` reporting. The feature is not broken
in general — it is broken on the one case the gate is about.

- Deployed SHA under test: `7d73b58` (contains all 12 pi-fork commits).
- No feature code was changed by this smoke.

---

## 0. Environment, verbatim

| Item | Value |
|---|---|
| llama-server | `192.168.1.77:8082`, container `llama-qwen3coder`, image `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| Build | `b10223-11924d4c1` (from `GET /props`) |
| Model | `/models/Qwen3-Coder-Next-UD-Q4_K_XL.gguf`, alias `qwen3-coder-next`, Q4_K_XL |
| Slots | `total_slots: 4`, `n_ctx` 262,144 per slot report, `kv_unified` (one shared pool) |
| Server args | `-m … -ngl 99 --host 0.0.0.0 --port 8080 -c 262144 --jinja -a qwen3-coder-next -fa on -b 2048 -ub 2048 --temp 1.0 --top-p 0.95 --top-k 40 --min-p 0.01 --metrics` (**no explicit `--cache-ram`** → default host prompt cache) |
| pi | 0.83.0, `/home/zach/.local/bin/pi`, provider `gb10-coder`, model id `gb10-coder/qwen3-coder-next` |
| OrcaHub node | `debian@192.168.1.177` (local systemd agent); all sessions same-node per §3 |

Health checks: `GET /health` → `{"status":"ok"}` at **13:34:49 UTC** (before) and
**13:56:26 UTC** (after).

**No interference from the sibling GPU-arbiter work.** `docker inspect llama-qwen3coder`
reported `StartedAt=2026-08-10T14:57:57.746318044Z Restarts=0` both before and after the
run — the server was not restarted or reconfigured at any point during the smoke, so no
result here is attributable to a `--cache-ram` change or a bounce. The box **did** carry
unrelated external traffic throughout (visible as `srv alloc: - making room for prompt
cache entry, removing oldest entry (size = 705–891 MiB)` lines), which is called out
where relevant below.

**Log clock note.** llama-server log timestamps are `<uptime-minutes>.<sec>.<ms>.<µs>`.
Anchor: child A's prefill finished at log `5690.55.872` ↔ DB wall clock `13:48:54.0 UTC`
(container start `2026-08-10T14:57:57Z` + 5690 min ≈ `13:47:58`, consistent). All log↔wall
mappings below use that anchor.

---

## 1. Cold baseline, measured on TODAY's box (not §1's ~26 s figure)

Two fresh pi sessions were given **novel, never-before-served content** (procedurally
generated prose, random UUID salts `de4be78a…` and `df94e12c…`, 4 files ≈ 105 KB each set,
in `/home/zach/pi_fork_smoke2` and `/home/zach/pi_fork_smoke3`) so the prefill could not
accidentally hit an existing cache entry.

**Server-side prompt eval, verbatim:**

```
# parent2 loading 4 novel files (task 85012, slot 1)
5695.01.114.007 I slot print_timing: id  1 | task 85012 | prompt eval time =   15450.42 ms / 20898 tokens (    0.74 ms per token,  1352.58 tokens per second)

# parent3 loading 4 novel files (task 85442, slot 1)
5696.48.972.455 I slot print_timing: id  1 | task 85442 | prompt eval time =   15500.55 ms / 20852 tokens (    0.74 ms per token,  1345.24 tokens per second)
```

**pi-side per-response usage for parent2 (verbatim from its JSONL):**

```
{'input': 5716,  'output': 128, 'cacheRead': 0,     'cacheWrite': 0, 'totalTokens': 5844}
{'input': 20898, 'output': 3,   'cacheRead': 5843,  'cacheWrite': 0, 'totalTokens': 26744}
{'input': 181,   'output': 88,  'cacheRead': 26743, 'cacheWrite': 0, 'totalTokens': 27012}
```

Cold-prefill rate today: **1,345–1,353 tok/s** for a clean ~21 k-token load, degrading to
**1,020–1,086 tok/s** when a co-tenant is decoding concurrently (the fork cases below).
This brackets §1's "~866–1,400 tok/s" — the box behaves as §1 measured it.

**Same-session warm resume** (the control that proves caching works at all here):
parent2's third response reprocessed **181 tokens** against `cacheRead 26,743`. Warm resume
is healthy.

---

## 2. §11.3 — single fork of an idled ~31 k-token parent → **MISS**

Parent `218a3d60-cef8-423a-9134-393adecbf909`, directory `/home/zach/pi_fork_smoke`,
built to a real working context by reading 4 files (`pi_fork_spec.md`,
`pi_fork_spike_findings.md`, `fork_gate.ex`, `CLAUDE.md`, 94,727 bytes).

Latest `pi_session_stats` before the fork: `context_usage.tokens = 31462`.
Parent went **idle at 13:47:30 UTC**; its last LLM response was 13:47:27 — cache maximally hot.
Fork instruction sent 13:48:17; child row created **13:48:20**.

**Spawn tool result, verbatim (as the parent saw it):**

```
=> %{
  "already_exists" => false,
  "backend" => "pi",
  "directory" => "/home/zach/pi_fork_smoke",
  "forked_from" => "218a3d60-cef8-423a-9134-393adecbf909",
  "issue_id" => nil,
  "model" => "gb10-coder/qwen3-coder-next",
  "node" => "debian",
  "orchestrator" => false,
  "parent_context_tokens" => 31462,
  "session_id" => "b153053c-97c7-4fa8-811a-4e7ba7ff85e2"
}
```

`parent_context_tokens = 31462` matches the parent's `pi_session_stats` exactly. ✅

**Child A first `result`, verbatim:**

```json
{"type": "result", "usage": {"input_tokens": 32254, "output_tokens": 4, "cache_read_input_tokens": 0}, "is_error": false, "timestamp": "2026-08-14T13:48:54.103679", "duration_ms": 32013, "total_cost_usd": 0.0, "first_response_usage": {"input_tokens": 32254, "cache_read_input_tokens": 0}}
```

**§8 marker, verbatim (annotated by §6.1 after the miss):**

```json
{"type": "system", "subtype": "forked_from", "cache_miss": true, "inherited_tokens": 31462, "parent_session_id": "218a3d60-cef8-423a-9134-393adecbf909", "parent_context_tokens": 31462, "first_turn_input_tokens": 32254, "first_turn_cache_read_tokens": 0}
```

**§6.1 miss event, verbatim:**

```json
{"type": "system", "paused": false, "message": "Fork cache MISS: child session b153053c-97c7-4fa8-811a-4e7ba7ff85e2's first turn reprocessed 32254 fresh input tokens against a parent context of 31462 (cache_read 0; threshold 25%). The inherited prefix was NOT served from the prompt cache — this fork cost a full cold prefill (pi_fork_spec.md §6.1).", "subtype": "fork_cache_miss", "input_tokens": 32254, "threshold_ratio": 0.25, "child_session_id": "b153053c-97c7-4fa8-811a-4e7ba7ff85e2", "parent_session_id": "218a3d60-cef8-423a-9134-393adecbf909", "parent_context_tokens": 31462, "cache_read_input_tokens": 0}
```

**Expected vs actual:**

| §11.3 expectation | Actual |
|---|---|
| ~2 s first turn | **32.0 s** |
| `cache_read_input_tokens` ≈ 31,462 | **0** |
| fresh first-response `input_tokens` in the tens | **32,254** |

**llama-server cross-check, verbatim** — pi's counters match the server's exactly (32,254):

```
5690.22.542.874 I slot get_availabl: id  1 | task -1 | selected slot by LCP similarity, f_sim_best = 0.994 (> 0.100 thold), f_keep = 1.000
5690.22.542.874 I slot launch_slot_: id  1 | task 84015 | processing task, is_child = 0      <-- PARENT's own next turn takes slot 1 (13:48:20.6)
5690.24.127.765 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = 1101356388876   <-- CHILD A: no LCP match available (13:48:22.2)
5690.24.129.090 I slot launch_slot_: id  2 | task 84057 | processing task, is_child = 0
5690.55.872.806 I slot print_timing: id  2 | task 84057 | prompt eval time =   31604.77 ms / 32254 tokens (    0.98 ms per token,  1020.54 tokens per second)
5690.55.874.866 I slot      release: id  2 | task 84057 | stop processing: n_tokens = 32257, truncated = 0
5690.59.803.384 I slot print_timing: id  1 | task 84015 | prompt eval time =     429.68 ms /   186 tokens (    2.31 ms per token,   432.88 tokens per second)
5690.59.803.388 I slot print_timing: id  1 | task 84015 |        eval time =   36830.43 ms /   173 tokens (  212.89 ms per token,     4.70 tokens per second)
5690.59.804.236 I slot      release: id  1 | task 84015 | stop processing: n_tokens = 32089, truncated = 0   <-- slot 1 frees at 13:48:57.9, 4 s AFTER the child already finished cold-prefilling
```

Note also `eval time … 4.70 tokens per second` on slot 1: the parent's own decode was
dragged from ~30 t/s to 4.7 t/s by the child's concurrent cold prefill — §1's
"cold-prefill contention craters the box" reproduced, on the parent that caused it.

---

## 3. Root cause

**The forked child's first request races the parent's own still-open turn for the only
slot that holds the matching prefix.**

`fork_from_parent: true` forks the **caller**. The caller is, by construction, **mid-turn**
at the instant it calls `start_session` — it has emitted a tool call and must still consume
the tool result and produce a final message. So at fork time the parent is *always*
occupying the slot whose prefix the child needs. Sequence, from the logs above:

1. `13:48:20.5` parent emits the `run_elixir`→`start_session` tool call.
2. `13:48:20.6` tool result lands; the parent immediately issues its **next** LLM call,
   which llama-server routes to **slot 1** by LCP similarity (`f_sim_best = 0.994`) — the
   slot holding the 31 k prefix. Slot 1 is now busy for the next ~37 s.
3. `13:48:22.2` the child's first request arrives. Slot 1 is busy, so llama-server falls
   back to **`selected slot by LRU`** → slot 2, which holds nothing relevant.
4. Slot 2 pays a full 32,254-token prefill (31.6 s).
5. `13:48:57.9` slot 1 finally frees — 4 seconds *after* the child was already done.

§6 serializes fork children **against each other**. Nothing serializes a fork child
**against its parent's in-flight turn** — and that in-flight turn is not an edge case, it
is guaranteed by the API shape. §1 had already measured this exact pathology ("firing while
a sibling is still GENERATING cold-prefills"); the spec simply never applied it to the
parent, because §4's guidance frames the target as "a *just-idled* parent" — which the
caller-initiated fork API makes structurally impossible to achieve.

**Why later siblings hit anyway.** Once the first child has cold-prefilled, a **second**
copy of the prefix exists (in the slot it landed on, and as a host-memory prompt-cache entry
saved when slot 1 later switched tasks). Subsequent children are still LRU-routed away from
the busy parent slot, but the prefix is now restorable into whatever slot they get — so they
hit. Evidence: child B was **also** `selected slot by LRU` (slot 3) yet evaluated only 1,985
tokens:

```
5692.45.244.882 I slot get_availabl: id  3 | task -1 | selected slot by LRU, t_last = 1101402606854
5692.53.102.216 I slot print_timing: id  3 | task 84341 | prompt eval time =    3204.43 ms /  1985 tokens (    1.61 ms per token,   619.46 tokens per second)
```

So the first fork of a given parent context effectively **pays a one-time cold prefill to
seed a second slot**, and every fork after that rides it for free. That is precisely the
economics §1.1 rejects: a fork that cold-prefills is strictly worse than a plain spawn.

**Ruled out as causes:**

- **Byte-divergent prefix (§5).** Ruled out. Children B/C/D/G/H hit at `cache_read` 31,367 /
  26,689 against parent contexts of 32,152 / 26,688 — i.e. ~97–100 % of the inherited
  history matched byte-for-byte from the cache. If the §5.1 flags-only system prompt or the
  `orca-identity` entry diverged before the inherited history, *no* child could ever hit.
  The parent's JSONL confirms the identity entry lands where §5.1 designs it to
  (`custom_message orca-identity` as a child of the first user message, after the inherited
  chain).
- **Serialization not firing.** Ruled out — see §4, it fires precisely.
- **Eviction by external traffic.** Ruled out as the *cause*, though the box was busy.
  The parent's prefix was demonstrably resident and hot at fork time: slot 1 was being
  selected for the parent's own turns at `f_sim_best = 0.994–0.998` immediately before,
  during, and after each failed fork. The child didn't miss because the prefix was gone —
  it missed because it couldn't get the slot the prefix was in.

---

## 4. §11.4 — 3-child fan-out → serialization ✅, all three hit ✅

Same parent, fanned out to children B/C/D in one `run_elixir` call (children created
`13:50:41`). ForkGate held C and D in `ready` (created, un-prompted) while B ran.

**First-prompt release vs prior sibling's first `result` — the §6 rule, verbatim:**

| Child | first prompt released | first `result` | gap after prior sibling's result |
|---|---|---|---|
| B | `13:50:41.490` | `13:50:51.337` | — (first) |
| C | `13:50:51.345` | `13:50:56.122` | **+8 ms** after B's result |
| D | `13:50:56.151` | `13:51:00.894` | **+6 ms** after C's result |

Strictly serialized at full-turn granularity, with no think time between children — exactly
§6's "releases children back-to-back with zero think time" posture.

**Usage, verbatim:**

```json
B: {"input_tokens": 1985, "output_tokens": 4, "cache_read_input_tokens": 31367}  duration_ms 8181   first_response_usage {"input_tokens": 1985, "cache_read_input_tokens": 31367}
C: {"input_tokens": 1980, "output_tokens": 4, "cache_read_input_tokens": 31367}  duration_ms 3250   first_response_usage {"input_tokens": 1980, "cache_read_input_tokens": 31367}
D: {"input_tokens": 1981, "output_tokens": 4, "cache_read_input_tokens": 31367}  duration_ms 3200   first_response_usage {"input_tokens": 1981, "cache_read_input_tokens": 31367}
```

None cold-prefilled; no `fork_cache_miss` events. **§8 marker present on all three**, e.g.

```json
{"type": "system", "subtype": "forked_from", "inherited_tokens": 32152, "parent_session_id": "218a3d60-cef8-423a-9134-393adecbf909"}
```

and `MessageComponents` renders it (`lib/orca_hub_web/components/message_components.ex:744-747`,
`"Forked from session #{msg["parent_session_id"]}…"`, session-id linkified).

**Caveat that makes this result weaker than it looks:** B/C/D hit only because child A had
already paid the cold prefill that seeded a second slot. This fan-out is the *second* fork
operation on that parent, not a clean test of "a fan-out hits".

---

## 5. The miss is reproducible — 3 independent parents, 3/3

To test whether A was a fluke of external traffic, two more parents were built from
**novel** content and forked **immediately** after going idle.

| # | Parent | Parent ctx (`context_usage.tokens`) | Parent idle → child's first LLM call | First fork | fresh `input_tokens` | `cache_read_input_tokens` | `duration_ms` |
|---|---|---|---|---|---|---|---|
| 1 | `218a3d60` (31 k, repo docs) | 31,462 | 13:47:30 → 13:48:22 (52 s) | **A** | **32,254** | **0** | **32,013** |
| 2 | `581aad15` (27 k, novel salt `de4be78a`) | 26,744 | 13:52:59 → 13:53:12 (13 s) | **E** | **27,534** | **0** | **25,734** |
| 3 | `d031a8eb` (27 k, novel salt `df94e12c`) | 26,688 | 13:54:48 → 13:55:00 (12 s) | **F** | **27,906** | **0** | **26,752** |

Server-side confirmation for E and F — same LRU fallback, same full prefill, pi's counters
matching the server's token-for-token (27,534 / 27,906):

```
# E — parent's turn on slot 1 (task 85121), child forced to slot 0
5695.12.369.576 I slot launch_slot_: id  1 | task 85121 | processing task, is_child = 0
5695.14.386.805 I slot get_availabl: id  0 | task -1 | selected slot by LRU, t_last = 1109784403103
5695.39.861.096 I slot print_timing: id  0 | task 85176 | prompt eval time =   25342.84 ms / 27534 tokens (    0.92 ms per token,  1086.46 tokens per second)
5695.43.445.584 I slot      release: id  1 | task 85121 | stop processing: n_tokens = 27373, truncated = 0

# F — parent's turn on slot 1 (task 85576), child forced to slot 2
5696.59.074.424 I slot launch_slot_: id  1 | task 85576 | processing task, is_child = 0
5697.00.772.894 I slot get_availabl: id  2 | task -1 | selected slot by LRU, t_last = 1187748383178
5697.27.168.647 I slot print_timing: id  2 | task 85612 | prompt eval time =   26261.41 ms / 27906 tokens (    0.94 ms per token,  1062.62 tokens per second)
5697.43.513.694 I slot      release: id  1 | task 85576 | stop processing: n_tokens = 28089, truncated = 0
```

Shortening the parent-idle→fork window from 52 s to 12 s changed nothing. Using content the
box had never seen changed nothing. `cache_read_input_tokens` was **exactly 0** all three
times.

---

## 6. §6.1 pause-and-notify — verified live ✅

Parent 3's fan-out (F/G/H) produced the real-world case §6.1 exists for: the first child
missed, with two siblings still queued.

**Miss event, verbatim — note `"paused": true`:**

```json
{"type": "system", "paused": true, "message": "Fork cache MISS: child session 896dbd35-5c55-4c2c-9999-0f663f6180b4's first turn reprocessed 27906 fresh input tokens against a parent context of 26688 (cache_read 0; threshold 25%). The inherited prefix was NOT served from the prompt cache — this fork cost a full cold prefill (pi_fork_spec.md §6.1). Remaining forked siblings are PAUSED.", "subtype": "fork_cache_miss", "input_tokens": 27906, "threshold_ratio": 0.25, "child_session_id": "896dbd35-5c55-4c2c-9999-0f663f6180b4", "parent_session_id": "d031a8eb-6b37-412a-86f0-1991ea7eefb6", "parent_context_tokens": 26688, "cache_read_input_tokens": 0}
```

**Orchestrator notification delivered to the parent, verbatim (13:55:25.453):**

```
[Session lifecycle] Fork fan-out PAUSED for parent session d031a8eb-6b37-412a-86f0-1991ea7eefb6:
child 896dbd35-5c55-4c2c-9999-0f663f6180b4's first turn was a prompt-cache MISS (27906 fresh
input tokens against a 26688-token parent context), so the inherited prefix is no longer cached
and every remaining sibling would pay a full cold prefill (pi_fork_spec.md §6.1). 2 forked child
session(s) are cr…
```

**`fork_queue` status, verbatim:**

```elixir
%{
  "active_child_session_id" => nil,
  "parent_session_id" => "d031a8eb-6b37-412a-86f0-1991ea7eefb6",
  "paused" => true,
  "paused_reason" => "cache_miss",
  "pending_child_session_ids" => ["81fe7a2a-3742-41d2-b117-00acb294fe26",
   "35409400-2665-4c0e-a7e8-31e9926dd92f"]
}
```

G and H sat in status `ready` — created, linked, visible, un-prompted. The miss was **not**
silently absorbed.

**`fork_queue` resume, verbatim:**

```elixir
%{
  "active_child_session_id" => "81fe7a2a-3742-41d2-b117-00acb294fe26",
  "parent_session_id" => "d031a8eb-6b37-412a-86f0-1991ea7eefb6",
  "paused" => false, "paused_reason" => nil,
  "pending_child_session_ids" => ["35409400-2665-4c0e-a7e8-31e9926dd92f"],
  "resumed" => "Released the next forked child's first prompt; the rest follow one turn at a time."
}
```

After resume, G and H both **hit** and remained serialized (H released 8 ms after G's result):

```json
G: {"input_tokens": 1798, "output_tokens": 3, "cache_read_input_tokens": 26689}  duration_ms 7236   released 13:55:40.391  result 13:55:49.362
H: {"input_tokens": 2097, "output_tokens": 8, "cache_read_input_tokens": 26689}  duration_ms 7839   released 13:55:49.370  result 13:55:59.091
```

The §11.5 *live* half ("force an eviction … confirm the miss is detected and surfaced") was
satisfied without needing to flood or restart the shared box: the structural bug produced
three genuine misses on its own, and detection fired on all three. **No llama-server restart
was requested or performed.**

---

## 7. Cold vs forked — the headline comparison

| Case | Fresh `input_tokens` (first response) | `cache_read_input_tokens` | Wall duration | Server prompt-eval |
|---|---|---|---|---|
| **Cold baseline** — novel 21 k load, parent2 | 20,898 | 5,843 | (25.9 s turn) | 15,450 ms @ 1,353 t/s |
| **Cold baseline** — novel 21 k load, parent3 | 20,852 | — | — | 15,501 ms @ 1,345 t/s |
| **Fork, 1st off a parent — A** | **32,254** | **0** | **32.0 s** | 31,605 ms @ 1,021 t/s |
| **Fork, 1st off a parent — E** | **27,534** | **0** | **25.7 s** | 25,343 ms @ 1,086 t/s |
| **Fork, 1st off a parent — F** | **27,906** | **0** | **26.8 s** | 26,261 ms @ 1,063 t/s |
| Fork, later sibling — B | 1,985 | 31,367 | 8.2 s | 3,204 ms |
| Fork, later sibling — C | 1,980 | 31,367 | 3.3 s | 2,913 ms |
| Fork, later sibling — D | 1,981 | 31,367 | 3.2 s | 2,882 ms |
| Fork, later sibling — G | 1,798 | 26,689 | 7.2 s | — |
| Fork, later sibling — H | 2,097 | 26,689 | 7.8 s | — |
| (control) same-session warm resume | 181 | 26,743 | — | 436 ms |

A first fork is **indistinguishable from a cold spawn**: it reprocesses ~100 % of the
inherited context at full cold-prefill cost, and additionally craters the parent's own
concurrent decode (30 → 4.7 t/s). A later fork is 3–10× faster than cold and reprocesses
~6–7 % — the intended regime.

---

## 8. Secondary findings (not blocking, but worth recording)

1. **Warm forks reprocess ~2 k tokens, not "tens."** §6.1 predicts "fresh `input_tokens` in
   the TENS" on a hit; every observed hit reprocessed **1,798–2,097**. Consistent with §1's
   hybrid/DeltaNet checkpoint granularity (reuse lands at a checkpoint boundary, not at the
   exact divergence point), and comfortably inside the 25 % threshold — so the threshold
   choice is vindicated, but the spec's stated expectation is optimistic by ~2 orders of
   magnitude. Worth correcting in §6.1 so a future reader doesn't treat 2 k as a partial miss.
2. **§4's "fork a just-idled parent" is unachievable through this API.** Because
   `fork_from_parent` forks the caller, the parent is by construction mid-turn. The guidance
   should either be removed or the mechanism changed (see §9).
3. **A `pi_ui_request` can strand a parent for the full 10-minute dialog timeout.** The first
   parent ended its context-building turn with an `extension_ui_request` (`method: "input"`,
   "Have you reviewed my summary?"). `send_message_to_session` does **not** answer a pending
   UI request — the message queued behind it and the session sat in `running` from 13:38:29
   until the dialog timed out at 13:47:26 (`tool_result`: "The user did not answer in time."),
   only then consuming the queued message. From MCP there is no way to answer a pending pi UI
   request (`SessionRunner.answer_ui_request/3` is LiveView-driven), so an agent-driven pi
   session that asks a question is stuck for 10 minutes. Relevant to §12 Q2's "refuse to fork
   while a UI request is pending" — but also a general pi-backend ergonomics gap.
4. **`parent_context_tokens` and `first_response_usage` are accurate.** `parent_context_tokens`
   matched the parent's `pi_session_stats.context_usage.tokens` exactly in all three spawns
   (31462 / 26744 / 26688), and `first_response_usage` correctly isolated the first response
   (identical to the summed `usage` here only because these first turns had no tool loop).
5. **pi's counters exactly match llama-server's**, re-confirming §1: 32,254 / 27,534 / 27,906
   fresh tokens reported by pi appear verbatim as the server's `prompt eval time … / N tokens`.

---

## 9. What a fix would have to address (diagnosis only — not implemented here)

The gate's serialization scope is incomplete. §6 serializes child *N+1* against child *N*'s
first `result`; it must **also** serialize the *first* child against **the parent's own
in-flight turn** — i.e. ForkGate should hold the first fork child's first prompt until the
parent session's current turn produces its `result` (parent transitions out of `:running`),
not release it immediately at spawn time. The parent's slot then frees, and llama-server's
LCP selection can route the child onto the warm prefix instead of falling back to LRU.

That is a hypothesis, not a verified fix — but it is directly supported by the observed
contrast: every fork that ran while the parent's turn was *finished or superseded* hit, and
every fork that ran while the parent held the matching slot and no second copy of the prefix
existed, missed. Cost of the fix is one parent-turn's latency (a few seconds) per fan-out,
versus a full cold prefill (25–32 s) plus co-tenant decode collapse today.

Two follow-on questions a fix worker should settle:
- Does waiting for the parent's `result` actually get the child onto slot 1, or does
  llama-server's LRU-vs-LCP selection need the prefix to have been written to the host prompt
  cache first (which appears to happen when the slot switches tasks)? Verify by measuring,
  not by reasoning.
- Should the §7 KV-budget guard also account for the fact that N forks of a P-token parent can
  end up resident on N distinct slots (N×P cells), which is what the LRU fallback produces?

---

## 10. Verdict

**§1.1: FAIL.** The feature does not meet "every forked child's first turn is a cache hit."
The very first fork off any given parent context reliably cold-prefills its entire inherited
history (3/3 parents, `cache_read_input_tokens = 0`, 25.7–32.0 s), which is exactly the
"strictly worse than a plain spawn" outcome the gate exists to prevent.

The three v1 prerequisites §1.1 names, judged individually:

| Prerequisite | Status |
|---|---|
| Byte-identical prefixes (§5) | ✅ **Holds** — later siblings hit at 97–100 % of parent context |
| Mandatory first-turn gate (§6) | ⚠️ **Works as written, but its scope is wrong** — serializes sibling-vs-sibling, not child-vs-parent's-in-flight-turn |
| Per-fork cache-miss detection (§6.1) | ✅ **Works, live-verified** — detected 3/3, warned, annotated the §8 marker, paused the fan-out, notified the orchestrator, `fork_queue` status/resume both correct |

The detection half of the gate did its job perfectly: it caught its own feature failing. Ship
blocked on the §6 scope gap.

---

## Appendix — artifacts

Sessions created and **archived** at end of run (11 total; nothing pre-existing was touched):

```
218a3d60-cef8-423a-9134-393adecbf909  SMOKE parent (pi fork §11.3)
  b153053c-97c7-4fa8-811a-4e7ba7ff85e2  child A (MISS)
  fb364fc7-8e58-41c5-8180-33d0578509e7  child B (hit)
  a30527da-c5a5-43d1-817d-d1e561448942  child C (hit)
  ff083bb1-7202-4405-88b3-118e3a32cbb5  child D (hit)
581aad15-81b2-4743-9e9a-3b305d38a318  SMOKE parent2 (cold baseline + reproduction)
  f27e07b3-c289-4b91-afea-7c7fb55f2bbf  child E (MISS)
d031a8eb-6b37-412a-86f0-1991ea7eefb6  SMOKE parent3 (§6.1 pause path)
  896dbd35-5c55-4c2c-9999-0f663f6180b4  child F (MISS -> paused fan-out)
  81fe7a2a-3742-41d2-b117-00acb294fe26  child G (hit, after resume)
  35409400-2665-4c0e-a7e8-31e9926dd92f  child H (hit)
```

Scratch corpora left in place for reproduction (outside the repo):
`/home/zach/pi_fork_smoke`, `/home/zach/pi_fork_smoke2` (salt `de4be78a57994a35b9376a545588d2d1`),
`/home/zach/pi_fork_smoke3` (salt `df94e12c141c4e70a24126ce482aa84b`) — each also holds the pi
JSONLs under `.pi_sessions/<orca-session-id>/`.

Measurements sourced from: the `orca_hub_prod` `messages` table (event JSON verbatim), pi's
own session JSONLs, and `docker logs llama-qwen3coder` on `192.168.1.77`.

---
---

# PART 2 — POST-FIX RE-MEASUREMENT (`56a18ba`), 2026-08-14 18:43–18:47 UTC

**Verdict against `pi_fork_spec.md` §1.1 ("no caching, no forking"): PASS.**

First-forks now hit **3/3 on three independent parents**, each forked immediately after
idling, each against content the box had never served. Every one was routed by
**`selected slot by LCP similarity` onto the parent's own slot** — the LRU fallback that
caused the pre-fix failure did not occur once for any fork child. `cache_read_input_tokens`
went from **0 / 0 / 0** to **27,292 / 27,353 / 28,147**; first-turn duration went from
**32.0 / 25.7 / 26.8 s** to **1.03 / 1.07 / 0.97 s**. Zero `fork_cache_miss` events were
emitted across the entire post-fix run.

## Setup deltas from Part 1

| | Part 1 (pre-fix) | Part 2 (post-fix) |
|---|---|---|
| SHA under test | `7d73b58` | **`56a18ba`** (`GET /api/version` on local agent: `{"sha":"56a18ba","built_at":"2026-08-14T15:57:29.906620Z"}`) |
| llama-server | b10223, 4 slots, `Restarts=0` | **unchanged** — `StartedAt=2026-08-10T14:57:57.746318044Z Restarts=0`, `GET /health` → `{"status":"ok"}` at 18:43:33 UTC |
| Corpora | smoke / smoke2 / smoke3 | **NEW: smoke4 / smoke5 / smoke6, fresh salts** |

**Why fresh corpora rather than reusing smoke2/smoke3 as suggested.** Those prefixes were
served ~5 h earlier. A residual host-cache entry would have produced a hit *independent of
the fix* — a false PASS, the one error direction that matters here. New salts guarantee the
prefill is genuinely novel. The Part 1 directories were left in place untouched.

- `/home/zach/pi_fork_smoke4` — salt `cad09512fbf84b2e86d465d7bfb2f15a`, 105,309 bytes
- `/home/zach/pi_fork_smoke5` — salt `b70a7438819c4ffc9dd7a8e5efd10786`, 105,417 bytes
- `/home/zach/pi_fork_smoke6` — salt `32a8d5d4264c48f7bd8f24e4142b405b`, 105,851 bytes

Log-clock anchor re-derived for this run (it does not carry over): container start
`2026-08-10T14:57:57.746Z` + 5986 min ⇒ **log minute `5986` sec `0` ↔ `18:43:57.7 UTC`**,
cross-checked against child P4's prompt-eval completion (`5986.52.776` ↔ DB `18:44:51.006`,
~0.5 s of pipeline lag). Same `<uptime-min>.<sec>.<ms>.<µs>` format as Part 1.

## 1. The three first-forks — the §1.1 gate

| Parent | ctx (`context_usage.tokens`) | first-fork child | `first_response_usage.input_tokens` | `cache_read_input_tokens` | `duration_ms` | slot selection |
|---|---|---|---|---|---|---|
| `18912c73` parent4 | 26,653 | `86fe76fb` P4 | **343** | **27,292** | **1,029** | slot 2, **LCP** `f_sim_best = 0.988` |
| `ea8f32af` parent5 | 26,726 | `6d9b3880` P5 | **351** | **27,353** | **1,073** | slot 2, **LCP** `f_sim_best = 0.987` |
| `7ff38d63` parent6 | 26,758 | `d288c7f9` J | **343** | **28,147** | **973** | slot 2, **LCP** `f_sim_best = 0.988` |

Result events, verbatim:

```json
P4: {"type": "result", "usage": {"input_tokens": 343, "output_tokens": 5, "cache_read_input_tokens": 27292}, "is_error": false, "timestamp": "2026-08-14T18:44:51.006065", "duration_ms": 1029, "total_cost_usd": 0.0, "first_response_usage": {"input_tokens": 343, "cache_read_input_tokens": 27292}}
P5: {"type": "result", "usage": {"input_tokens": 351, "output_tokens": 5, "cache_read_input_tokens": 27353}, "is_error": false, "timestamp": "2026-08-14T18:46:13.785476", "duration_ms": 1073, "total_cost_usd": 0.0, "first_response_usage": {"input_tokens": 351, "cache_read_input_tokens": 27353}}
J:  {"type": "result", "usage": {"input_tokens": 343, "output_tokens": 3, "cache_read_input_tokens": 28147}, "is_error": false, "timestamp": "2026-08-14T18:47:22.252386", "duration_ms": 973, "total_cost_usd": 0.0, "first_response_usage": {"input_tokens": 343, "cache_read_input_tokens": 28147}}
```

**llama-server slot logs — the LCP-vs-LRU signal, verbatim.** In every case the child is
selected onto **slot 2, the parent's own slot**, by LCP similarity, and evaluates only its
own divergence:

```
# child P4 (task 88946)
5986.52.065.305 I slot get_availabl: id  2 | task -1 | selected slot by LCP similarity, f_sim_best = 0.988 (> 0.100 thold), f_keep = 1.000
5986.52.065.678 I slot launch_slot_: id  2 | task 88946 | processing task, is_child = 0
5986.52.776.491 I slot print_timing: id  2 | task 88946 | prompt eval time =     581.69 ms /   343 tokens (    1.70 ms per token,   589.66 tokens per second)

# child P5 (task 89439)
5988.14.723.495 I slot get_availabl: id  2 | task -1 | selected slot by LCP similarity, f_sim_best = 0.987 (> 0.100 thold), f_keep = 1.000
5988.15.558.508 I slot print_timing: id  2 | task 89439 | prompt eval time =     700.55 ms /   351 tokens (    2.00 ms per token,   501.03 tokens per second)

# child J (task 90253)
5989.23.250.688 I slot get_availabl: id  2 | task -1 | selected slot by LCP similarity, f_sim_best = 0.988 (> 0.100 thold), f_keep = 1.000
5989.23.251.079 I slot launch_slot_: id  2 | task 90253 | processing task, is_child = 0
5989.24.029.743 I slot print_timing: id  2 | task 90253 | prompt eval time =     707.03 ms /   343 tokens (    2.06 ms per token,   485.13 tokens per second)
```

**Audit of every slot selection in the post-fix window** (log minutes 5986–5990, 22
selections): **21 by LCP similarity, 1 by LRU.** The single LRU selection was
`5986.02.395.179 … task 88523` — **parent4's very first LLM call**, a brand-new session with
no prior context anywhere on the box (5,719 tokens = system prompt + first prompt). That is
correct behaviour for a cold non-fork spawn, not a fork miss. **No fork child was
LRU-selected.**

## 2. The parent-as-child-zero hold, measured

ForkGate held each first child from creation until the parent's own turn emitted `result`,
then released within single-digit milliseconds:

| Parent | child row created | parent `result` | child first prompt released | hold | release latency |
|---|---|---|---|---|---|
| parent4 | 18:44:42.437 | 18:44:48.199 | 18:44:48.207 | **5.77 s** | **+8 ms** |
| parent5 | 18:46:05.495 | 18:46:11.190 | 18:46:11.193 | **5.70 s** | **+3 ms** |
| parent6 (J) | 18:47:02.391 | 18:47:19.797 | 18:47:19.800 | **17.41 s** | **+3 ms** |

This is the mechanism working exactly as the amendment describes: the parent is child zero,
release is driven by the `result` **event** (not a status poll — a 3 ms latency is not
pollable), and the cost is honest (the gate waits out the parent's whole turn — 17.4 s for
parent6, whose fan-out turn was long).

## 3. §11.4 fan-out — serialization intact, first child no longer pays

Parent6 fanned out to J/K/L in one `run_elixir` call (all three created 18:47:02.39–.44).

| Child | first prompt released | first `result` | gap after prior sibling's `result` | fresh `input_tokens` | `cache_read` | `duration_ms` |
|---|---|---|---|---|---|---|
| J | 18:47:19.800 | 18:47:22.252 | +3 ms after **parent's** result | 343 | 28,147 | 973 |
| K | 18:47:22.256 | 18:47:24.722 | **+4 ms** after J's result | 344 | 28,212 | 977 |
| L | 18:47:24.726 | 18:47:27.178 | **+4 ms** after K's result | 351 | 28,271 | 972 |

Serialization is unchanged from Part 1 (there it was +6–8 ms; here +3–4 ms). The material
difference is **J**: pre-fix the first fan-out child cold-prefilled 32,254 tokens in 32 s and
that cold prefill was what seeded a second slot so B/C/D could hit. Post-fix **J costs 343
tokens / 0.97 s**, and K and L are no longer riding a sacrifice — all three simply share the
parent's slot. The Part 1 caveat ("B/C/D only hit because A paid") no longer applies.

§8 markers rendered on all five post-fix children, none carrying a `cache_miss` annotation:

```json
{"type": "system", "subtype": "forked_from", "inherited_tokens": 26653, "parent_session_id": "18912c73-534b-4747-ae9c-85d06f429e46"}
{"type": "system", "subtype": "forked_from", "inherited_tokens": 26726, "parent_session_id": "ea8f32af-bffa-4684-b274-01f23b2757f5"}
{"type": "system", "subtype": "forked_from", "inherited_tokens": 26758, "parent_session_id": "7ff38d63-e873-48cf-9bde-e50d9b4e71fd"}   (×3, J/K/L)
```

`fork_cache_miss` events emitted in the entire post-fix run: **0**.

## 4. The release race — it FIRED three times and LOST three times

The spec author's concern was real and did materialize: fork children carry `notify_parent`,
so each child going idle sends its parent a `[Session lifecycle]` message, which starts a
**new parent turn** that can re-grab the slot. During parent6's fan-out this happened after
every child:

```
18:47:22.252  J  result
18:47:22.256  K  first prompt released   <-- ForkGate, +4 ms
18:47:22.280  PARENT  user               <-- J-idle notification, +24 ms (LOST by 24 ms)
18:47:22.807  PARENT  result
18:47:24.722  K  result
18:47:24.726  L  first prompt released   <-- ForkGate, +4 ms
18:47:24.749  PARENT  user               <-- K-idle notification, +23 ms (LOST by 23 ms)
```

**ForkGate won all three times, by 20–24 ms.** But the more interesting finding is that the
race is **benign even in the losing case here**, because the parent and its children share
~99 % of one prefix and therefore trade the *same* slot rather than contending for different
ones. The slot log shows a strict alternation on slot 2, every hop LCP-selected:

```
5989.23.250  LCP 0.988  task 90253  child J   343 tok / 707 ms
5989.24.213  LCP 0.998  task 90259  PARENT     63 tok / 296 ms   (f_keep 0.988)
5989.25.679  LCP 0.988  task 90266  child K   344 tok / 717 ms
5989.26.650  LCP 0.998  task 90273  PARENT     63 tok / 297 ms   (f_keep 0.988)
5989.28.139  LCP 0.988  task 90279  child L   351 tok / 718 ms
5989.29.051  LCP 0.998  task 90286  PARENT     70 tok / 341 ms   (f_keep 0.988)
```

The parent's interleaved turns cost **63–70 tokens each**, kept 98.8 % of slot state, and
evicted nothing. K and L hit identically to J (344 / 351 vs 343 fresh) despite running with
the parent interleaving, which is the empirical answer: the race did not bite.

**Bounded claim, stated deliberately.** What was measured is a race against a *short* queued
follow-up (a lifecycle notification producing a 63–70-token turn). A queued message that
starts *real* work — an operator ping or a heartbeat that triggers a tool loop — would hold
the slot far longer, and that case remains **unmeasured**. The 20–24 ms margin is a property
of ForkGate's event-driven release, not of the follow-up's size, so the ordering should still
hold; but "ForkGate wins the release" and "a lost race would be harmless" are two different
claims, and only the first is established for arbitrary follow-ups.

## 5. Pre-fix vs post-fix, side by side

| | pre-fix (`7d73b58`) | post-fix (`56a18ba`) |
|---|---|---|
| first-fork #1 | A: **32,254** fresh, cache_read **0**, **32,013 ms**, LRU→slot 2 | P4: **343** fresh, cache_read **27,292**, **1,029 ms**, LCP→slot 2 |
| first-fork #2 | E: **27,534** fresh, cache_read **0**, **25,734 ms**, LRU→slot 0 | P5: **351** fresh, cache_read **27,353**, **1,073 ms**, LCP→slot 2 |
| first-fork #3 | F: **27,906** fresh, cache_read **0**, **26,752 ms**, LRU→slot 2 | J: **343** fresh, cache_read **28,147**, **973 ms**, LCP→slot 2 |
| first-forks that hit | **0 / 3** | **3 / 3** |
| `fork_cache_miss` events | 3 | **0** |
| fan-out 1st child | cold prefill, seeded the slot for its siblings | 343 tok / 0.97 s, no sacrifice |
| co-tenant decode during fork | parent dragged 30 → **4.7 t/s** | no measurable degradation |

A first fork went from **indistinguishable from a cold spawn** (~100 % of context reprocessed,
25–32 s) to **~1.3 % reprocessed, ~1 s** — better than the ~2 s §1 predicted, and better than
the 1,798–2,100-token cross-slot-restore band, because same-slot LCP reuse avoids the
checkpoint-granularity penalty entirely.

## 6. Notes on the corrections that landed

- **§6.1's "tens" → checkpoint granularity.** Confirmed with more resolution now that both
  regimes are observable in one run: **same-slot LCP reuse costs 343–351 fresh tokens**
  (the child's identity entry + first prompt + divergence), while **cross-slot restore costs
  1,798–2,100** (Part 1's B/C/D/G/H). Both are hits; neither is "tens". The spec's revised
  two-band framing matches the data.
- **§9 open question, settled — and my Part 1 prediction was correct.** I predicted the child
  would land on the parent's own slot via LCP, with a small prompt eval, and that the prefix
  would *not* need writing to the host prompt cache first. That is exactly what happened
  (`f_sim_best 0.987–0.988`, slot 2, 343–351 tokens), matching the fix worker's pre-implementation
  experiment (`f_sim_best = 0.999`, cacheRead 31,813 / fresh 20). Slot residency alone is
  sufficient for LCP routing. No disagreement to report.
- **§4's "just-idled parent" framing.** Now achievable in practice, but only because ForkGate
  manufactures the condition — the API still forks a mid-turn caller; the gate is what makes
  the parent idle by the time the child's prompt goes out.

## 7. Verdict

**§1.1: PASS.** Every forked child's first turn in this run was a prompt-cache hit — 3/3
first-forks on independent parents, plus 2 further fan-out siblings, 5/5 children total, 0
misses. The three v1 prerequisites:

| Prerequisite | Status |
|---|---|
| Byte-identical prefixes (§5) | ✅ Holds — 343–351 fresh tokens against ~27 k inherited |
| Mandatory first-turn gate (§6, widened) | ✅ **Now correct in scope** — parent-as-child-zero hold measured at 5.7 / 5.7 / 17.4 s, release at +3–8 ms; sibling serialization intact at +3–4 ms |
| Per-fork cache-miss detection (§6.1) | ✅ Still armed — 0 false positives across 5 children; its true-positive behaviour was proven live in Part 1 |

Caveats a future reader should carry: the release race was measured only against short
queued follow-ups (§4 above); and this run, like Part 1, is a single-node, single-box,
~27 k-token-parent sample — nothing here speaks to 100 k-token parents or to the §7 KV-budget
regime, where N children resident on N slots was the pre-fix failure mode and is no longer
what happens (they now share one slot, which is *better* for the budget but changes the §7
arithmetic and may deserve a re-read).

## Appendix — post-fix artifacts

Sessions created and **archived** (8 total; nothing pre-existing touched):

```
18912c73-534b-4747-ae9c-85d06f429e46  SMOKE2 parent4 (post-fix §11.3)
  86fe76fb-82f4-4ab0-9957-815abd8776ce  child P4 (HIT)
ea8f32af-bffa-4684-b274-01f23b2757f5  SMOKE2 parent5 (post-fix §11.3)
  6d9b3880-682c-43c7-b05f-7b242b963630  child P5 (HIT)
7ff38d63-e873-48cf-9bde-e50d9b4e71fd  SMOKE2 parent6 (post-fix §11.4 fan-out)
  d288c7f9-58ad-4425-991a-7b8f850ce154  child J (HIT)
  d3740841-3287-482d-870e-351cc822ec34  child K (HIT)
  82d08429-a47b-4f57-a00d-f0810f5852f6  child L (HIT)
```

Corpora retained for reproduction: `/home/zach/pi_fork_smoke` … `smoke6` (Part 1 salts
`de4be78a…`, `df94e12c…`; Part 2 salts `cad09512…`, `b70a7438…`, `32a8d5d4…`), each with pi
JSONLs under `.pi_sessions/<orca-session-id>/`.
