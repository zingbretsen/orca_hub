# OrcaHub Page-Load Performance Report — Round 2

Measurement-only. No source files were edited. All numbers below were captured
live against **production** (hub pod `orca-hub-7598c6d79f-fjx54`, namespace
`lab`) via `bin/orca_hub rpc` one-shot evals and pod-local `curl` (network-
latency-free, isolates server time). Every `:telemetry.attach/4` handler used
for measurement was detached immediately after use — verified live via
`:telemetry.list_handlers/1` at the end (see "Telemetry handlers"). No
Ecto/LiveView/endpoint code was modified.

Pages covered: **Projects Index** (`/projects`), **Project Show**
(`/projects/:id`), **Dashboard** (`/`), **Usage** (`/usage`), **Queue**
(`/queue`). This follows the same methodology and table format as
`perf_session_load.md` (Round 1: Session Show / Sessions Index / Nodes
Index) so the two reports compose.

## Methodology notes

- Mount-level numbers were captured by building a real
  `%Phoenix.LiveView.Socket{}` (`transport_pid: nil` disconnected,
  `transport_pid: self()` connected) with `node_filter: :all` pre-assigned
  (mirroring `NodeFilter.on_mount/4`) and calling each LiveView's real,
  public `mount/3` directly — exercising actual production code, not a
  simulation.
- Ecto query counts/timings used a temporary `[:orca_hub, :repo, :query]`
  handler. Note: unlike Round 1, this hub pod's `:erpc` console runs
  **inside the same live BEAM node as real user traffic**, so a
  process-unscoped handler also captures concurrent unrelated queries from
  other sessions (visible as stray `INSERT INTO messages` / unrelated
  `SELECT` rows in one trace below). Where that happened it's called out
  explicitly and the isolated `:timer.tc` wall-clock number (which only
  measures our own call) is what's reported as authoritative.
- One real end-to-end load was also driven per page via pod-local `curl`
  (`http://localhost:4000<path>`, no Authelia/network hop) to get a true
  server-side, disconnected-mount response time and payload size.
- **Prod-safety judgment call:** `/usage`'s `Claude.Usage.fetch()` shells
  out to `claude -p 'hi' --tools "" ...` (capped `timeout 60`, `--model
  haiku`, 16-token output cap) — this is the *exact* code path every real
  visitor to `/usage` already triggers on this hub (confirmed: the hub's
  stored OAuth token is permanently expired, `expiresAt: 0`, so this fires
  on literally every page load, not just a cold-start edge case). Measuring
  it once was judged equivalent in risk to a normal user visiting the page
  — same conclusion Round 1 reached about `ensure_runner_started`. No
  process was left running past the call; the CLI subprocess exits on its
  own (confirmed by the returned `{output, code}` and total wall time).
- **Cleanup:** all `rpc` invocations were one-shot, short-lived BEAM
  processes; any `Phoenix.PubSub.subscribe/2` calls made inside them (Queue
  measurement) died with the process automatically. Scratch HTML files
  written to the pod's `/tmp` by the curl measurements were removed at the
  end (`rm -f /tmp/out_*.html`).
- Prod state at test time: 180 projects (55 non-deleted/tagged), 2,917
  sessions total (57 idle, 5 running, 1 error, non-archived), 8 cluster
  node identities known to the DB (5 actually connected via `Node.list()`
  at test time: `gb10`, `orca-dell`, `orca-discord`, `orca@192.168.1.18`
  aka "mini", `debian`).

---

# 1. Usage — `/usage`

## 1a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`OrcaHub.Claude.Usage.fetch/0`** (full mount body) | **8,735.7ms** (direct call) / **8,281ms** (curl, full HTTP round trip) | **yes, synchronous in `mount/3`** | **yes — the CLI subprocess runs twice per call**, see below | ends in `{:error, {:http_error, 22, ""}}` — the page pays 8.7s and still shows an error |

**This single item is the entire page.** There is nothing else in
`UsageLive.mount/3` — no Ecto queries, no `Cluster` calls, nothing.

## 1b. Root cause, precisely

`fetch/0`'s control flow (`lib/orca_hub/claude/usage.ex`):

```
with {:ok, token} <- resolve_token() do      # (1) may itself call refresh_via_cli/0
  case fetch_with_token(token) do
    {:error, {:http_error, 22, _}} = err ->  # 401 from the usage endpoint
      case refresh_via_cli() do              # (2) calls refresh_via_cli/0 AGAIN
        ...
```

On this hub, `~/.claude/.credentials.json`'s `expiresAt` is **`0`**
(confirmed live) — i.e. permanently "expired" by the code's own check. That
means:

1. `resolve_token/0` → `token_from_file_or_keychain/0` → `expired?/1` is
   always `true` → calls `refresh_via_cli/0` **once** — which shells out
   `timeout 60 claude -p 'hi' --tools "" --system-prompt "" --model haiku`.
   On this hub, that CLI invocation itself fails fast (`Failed to
   authenticate: OAuth session expired and could not be refreshed`, ~4.3s
   including a "no stdin data received in 3s" CLI startup delay) and falls
   back to the (still-expired) token in the file.
2. `fetch_with_token/1` calls the real Anthropic usage endpoint with that
   known-bad token → 401 → curl exit code 22.
3. The `{:error, {:http_error, 22, _}}` branch calls `refresh_via_cli/0` **a
   second time** (same ~4.3s cost) as a retry, which also fails, and the
   original error is returned.

**Net effect: every single `/usage` page load shells out to the `claude`
CLI twice, ~4.3s apiece, for a guaranteed ~8.7s page freeze, and the page
still renders an error state at the end.** This is not a slow-path edge
case — it is the *only* path this hub currently has, verified three
independent ways (direct `:timer.tc` on `fetch/0`: 8,735.7ms; pod-local
curl on `/usage`: 8,281ms wall clock; and the `[warning]` log lines showing
the CLI subprocess actually ran, twice, ~4.3s apart).

`fetch_usage/1` is called identically, synchronously, from both `mount/3`
and the `"refresh"` `handle_event` — clicking the Refresh button re-pays
the full 8.7s and freezes that LiveView process again.

## 1c. Top fix — Usage

1. **Move `Claude.Usage.fetch/0` off the synchronous mount/event path** via
   `start_async/3`, showing a loading state while it runs. This alone would
   turn an 8.7s frozen page into an instant page + a background spinner —
   trivial LiveView-pattern change, no change to `Usage.fetch/0` itself
   needed.
2. **Separately (real bug, not just a perf issue): the retry-refresh
   couples two full CLI subprocess invocations into one request, and both
   are known-doomed once the *first* `refresh_via_cli/0` inside
   `resolve_token/0` has already failed** — `fetch_with_token/1` is then
   called with a token already known to be stale, guaranteeing the 401, which
   triggers the *second*, identical, doomed refresh. Short-circuiting to
   return the original error immediately after `refresh_via_cli/0` fails
   once (instead of proceeding to call the API anyway) would halve the cost
   in this failure mode (~4.3s instead of ~8.7s) even before async-ifying it.
3. This is orthogonal to whether the hub can ever have valid credentials —
   that's a login/ops question, not a perf one. But note for whoever owns
   that: a hub with a permanently-expired token is presumably not a rare
   edge case in this deployment (headless/infra node, never interactively
   `claude login`'d), so #1 has real, ongoing user-facing impact, not just
   theoretical value.

---

# 2. Queue — `/queue`

Prod state at test time: 49 idle/waiting sessions in the queue (`show_all`
default off, so only 1 rendered by default).

## 2a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`Sessions.list_idle_sessions_with_last_assistant_message/0`** (the "last assistant message per idle session" query) | **3,489–3,545ms** | yes, synchronous in `mount/3` | re-run on `archive`/`undo_archive`/`defer`/`set_filter`/every idle-or-waiting status-change PubSub event too | full unindexed scan + disk-spilled sort over the *entire* `messages` table — see 2b |
| 2 | `reset_front_of_queue_priority/0` (2 small queries, part of the same function) | ~5–8ms | yes | same as above | cheap, not the issue |
| 3 | `OrcaHub.Cluster.node_name/1` (template, per visible entry) | 0ms today (default view renders only 1 entry) | yes, but only if that entry's node is unresolvable | only when "Show all" is toggled | **same ghost-node hazard as §3/§4 below** — if a visible entry's session happens to be on `ymir@192.168.1.19` (4 of the 49 idle sessions currently are), each such row costs ~3s independently, uncached, and "Show all" makes this unbounded by session count |
| — | `Phoenix.PubSub.subscribe/2` loop (once per idle/waiting session, connected mount only) | 0.75ms for 48 | yes | no | **cleared suspicion** — looks like an N+1 fan-out but is a purely local ETS-backed registry op, negligible even at today's scale |

**Full page load (curl, disconnected mount):** `time_total = 4.14s`,
29,009 bytes. Matches item #1 almost exactly (server time is ~100% one
query).

## 2b. Root cause of the 3.5s query — confirmed via `EXPLAIN (ANALYZE, BUFFERS)`

The query joins every idle/waiting session against a subquery selecting
each session's most recent assistant message:

```elixir
last_messages =
  from m in Message,
    where: fragment("? ->> 'type' = 'assistant'", m.data),
    distinct: m.session_id,
    order_by: [asc: m.session_id, desc: m.inserted_at]
```

`EXPLAIN ANALYZE` on the real query (with the join columns actually
selected, matching production's `select: {s, m}` — a shortened variant
that drops the `m` columns gets silently optimized away by Postgres and is
**not representative**, a trap worth flagging explicitly) shows:

```
Execution Time: 3545.116 ms
  -> Parallel Seq Scan on messages m0
       Filter: ((data ->> 'type'::text) = 'assistant'::text)
       Rows Removed by Filter: 131437   (×3 workers)
  -> Sort Method: external merge  Disk: 80056kB  (+ 2 workers, ~80MB each)
  Buffers: shared read=164833   (~1.3GB read)
```

This is a **full parallel sequential scan of the entire `messages`
table**, because `data ->> 'type' = 'assistant'` is a JSONB text-extraction
predicate with no supporting index — Postgres cannot use an index for it.
The subsequent `DISTINCT ON (session_id) ORDER BY session_id,
inserted_at DESC` then has to sort essentially all matching rows
(hundreds of thousands), which doesn't fit in `work_mem` and **spills to
disk** (`external merge`, ~80MB per worker). All of this work is done to
answer a question that only needs **49 rows** (the current idle/waiting
sessions) out of **2,917** total sessions — this is the "anything
unbounded loaded" pattern the audit brief called out, and it will get
linearly worse as the `messages` table grows (it's already scanning
>300K rows across all history, not just recent messages).

## 2c. Top fix — Queue

1. **Needs restructuring, but is the highest-value fix in this whole
   report by a wide margin:** replace the whole-table `DISTINCT ON`
   subquery with a `LATERAL` join scoped to just the (bounded, ~50) idle/
   waiting sessions — `SELECT ... FROM sessions s, LATERAL (SELECT * FROM
   messages WHERE session_id = s.id AND data->>'type'='assistant' ORDER BY
   inserted_at DESC LIMIT 1) m`. Combined with an index on
   `(session_id, inserted_at DESC)` (probably already covered by an
   existing `session_id` index — worth checking before adding a new one),
   this turns an O(all messages ever) scan into O(idle sessions × log(their
   own history)). This single change should take the page from ~3.5s to
   comparable-to-the-rest-of-the-page (~single-digit ms).
2. Once #1 is in place, **also move it off the synchronous mount path**
   with `start_async/3` as a defense-in-depth — the query is re-run on
   several `handle_event`s too (archive/undo/defer/filter), so even a fast
   query still means every one of those interactions blocks the LiveView
   process. Lower priority than #1 since #1 alone removes ~99.9% of the
   cost.
3. The `Cluster.node_name/1` ghost-node hazard (item #3 in the table) is
   the same underlying issue as §3 and §4 below — fixing it there (a
   shared `Cluster` function) fixes it here too. Not a separate code change
   needed on this page.

---

# 3. Dashboard — `/`

## 3a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`Cluster.node_name(:"ymir@192.168.1.19")`** (inside `node_session_counts`) | **1,468–3,098ms** (variable — see 3b) | yes, synchronous in `mount/3` | **yes — re-paid on every `handle_info` from the "sessions" PubSub topic**, i.e. on every session status change *anywhere in the cluster*, for every open Dashboard tab | see 3b for root cause |
| 2 | `Cluster.list_sessions(:all)` | ~2–5ms | yes | yes (same handle_info re-run) | single `HubRPC` query, **unbounded** — loads literally every non-archived session (currently 63) with no `LIMIT`; cheap today, will grow linearly with total session count since nothing here paginates |
| 3 | `Cluster.list_projects()` + `Cluster.list_triggers()` | ~2–3ms combined | yes | yes | single queries each, cheap |
| — | `node_session_counts` build (`group_by` then one `node_name` call per **distinct** node) | included in #1 | yes | yes | **this code already does the Round-1-recommended dedup pattern** (group first, resolve once per node) — see 3b for why that isn't enough here |

**Full page load (curl, disconnected mount):** `time_total = 3.095s`,
28,786 bytes — almost entirely item #1; the page's actual content is tiny.

## 3b. Root cause: not a classic N+1 — a single always-slow ghost node, uncached

`node_session_counts` in `dashboard_live.ex` already groups sessions by
node **before** resolving names (`Enum.group_by` then `Enum.map`), which is
exactly the dedup fix Round 1 recommended for Sessions Index's identical-
looking bug. I confirmed by direct measurement that deduping doesn't help
here: calling `Cluster.node_name/1` once per **row** across 55 tagged
projects (Projects Index's version of the same call) took 3,043ms; calling
it once per **distinct node** (8 nodes) took 3,050ms — statistically the
same. The cost isn't proportional to call count; it's dominated entirely by
one specific node atom.

Isolating each of the 8 known node identities individually:

```
orca@orca-hub.lab.svc.cluster.local: 0.01ms -> "k3s-hub"
ymir@192.168.1.19:                   3073.94ms -> "192.168.1.19"   (fallback string, not a real name)
gb10@192.168.1.77:                   0.56ms -> "gb10"
orca@192.168.1.18:                   0.58ms -> "mini"
debian@192.168.1.177:                0.27ms -> "debian"
orca-dell@orca-agent-dell.lab:       0.6ms  -> "dell-agent"
orca-discord@orca-agent-discord.lab: 0.51ms -> "discord-agent"
mini@192.168.1.18:                   1.13ms -> "192.168.1.18"      (also not connected, but fails FAST)
```

**`ymir@192.168.1.19` is a stale node reference** (has a `nodes` table row,
is assigned as `runner_node` on 5 live non-archived sessions and `node` on
1 live project, but is not in `Node.list()` — not actually connected) that
costs **~3 seconds per resolution attempt**, every time, with **no
caching**. This is not simply "a disconnected node" in the generic sense —
`mini@192.168.1.18`, also disconnected, fails in ~1ms (fast TCP refusal).
`ymir` is reachable enough at the network level that Erlang's distribution
handshake actually attempts and hangs for several seconds before giving up
(consistent with a host that's up but not answering the distribution
protocol/EPMD correctly — a firewall-blackholed port rather than a closed
one). `Cluster.node_name/1`'s own documented timeout for this path is 5s,
so today's 1.5–3.1s already sits well within — and could, on a worse day
for that specific host, reach — that ceiling.

Because Dashboard subscribes to the global `"sessions"` PubSub topic and
`handle_info(_msg, socket) -> load_data(socket)` unconditionally re-runs
`load_data/1` (including this same node resolution) on **every** session
status change anywhere in the cluster — not just this viewer's own
sessions — **every open Dashboard tab re-pays this ~1.5-3s stall on every
unrelated session event system-wide**, not just once at page load.

## 3c. Top fix — Dashboard

1. **Fix (or decommission) the stale `ymir@192.168.1.19` node reference** —
   this is a data-hygiene issue (5 live sessions + 1 live project still
   point at it), not purely a code bug, but it is *actively* costing ~3s on
   every Dashboard/Projects-Index page load and repeated Dashboard
   re-renders right now, in production, today. Highest-value single action
   in this report after the Usage/Queue backend fixes.
2. **Trivial, addresses the code-level hazard regardless of #1:** add a
   short-TTL cache (e.g. `:persistent_term` or an ETS table refreshed every
   N seconds) to `Cluster.node_name/1`/`display_name/1` for remote nodes.
   A node's display name changes essentially never; caching removes both
   the redundant-but-cheap resolution cost for healthy nodes *and* turns a
   permanently-broken node like `ymir` from "pay ~3s on every single
   render" into "pay ~3s once until the cache invalidates or the node
   reconnects." This is the same recommendation Round 1 made for Sessions
   Index (§2c #2 there), but this investigation shows caching matters more
   than deduping — dedup alone (already present here) does nothing for a
   single always-slow node.
3. **`handle_info(_msg, socket)` re-running full `load_data/1` on every
   unrelated cluster-wide session event** is a separate amplification
   worth narrowing — e.g. only reload on status transitions that actually
   change one of the displayed counts, or debounce — but this is
   secondary to #1/#2: once node-name resolution is fast/cached, the
   re-render cost itself (list_sessions/list_projects/list_triggers, all
   sub-5ms combined) is no longer worth optimizing further at today's
   scale.

---

# 4. Projects Index — `/projects`

Prod state at test time: 55 tagged (non-deleted) projects across 8 node
identities (see §3b table).

## 4a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`OrcaHub.Cluster.node_name/1`** (template, `<:col>` badge, once per **row**, unconditionally, not gated) | **~3,043ms** for 55 rows (today, entirely the `ymir` ghost node — see §3b) | yes | no (Index mount runs once per navigation, no equivalent "double mount" cost like Session Show) | **confirmed N+1-shaped call site** (per-project, not deduped) though today's cost is 100% attributable to the single ghost node, not row-count multiplication — see note below |
| 2 | `Cluster.list_projects()` (mount) | 0.77–0.85ms | yes | no | single `HubRPC` query, cheap |
| — | `mount/3` total, DB only | 1.0–1.1ms, 1 query | yes | no | **cleared suspicion**: mount itself is fast; all the cost lives in the template, not `mount/3` |

**Full page load (curl, disconnected mount):** `time_total = 0.083s`,
188,391 bytes. **This number is surprisingly fast relative to the isolated
`node_name` loop measurement (3s) — see note below; treat it as the more
representative real-world number for this specific run.**

## 4b. A genuine surprise: curl showed 83ms, not ~3s — investigated

The isolated per-row `node_name` loop (run via `rpc`, same technique used
throughout this report) measured ~3,043ms for 55 projects. But the
pod-local `curl GET /projects` immediately after measured only 83ms total.
Both are real, on the same pod, minutes apart. The most likely explanation,
consistent with §3b's finding that `ymir`'s failure mode is a **slow TCP-
level handshake attempt rather than an instant refusal**: Erlang's
distribution layer appears to cache a short-lived "this node is currently
unreachable, don't retry the handshake" state after a failed connection
attempt (a well-known `net_kernel`/`dist_util` behavior — a recent failed
`:erpc.call`/connect attempt to the same node can fail fast for some
window afterward rather than re-attempting the full handshake timeout).
The isolated loop measurement ran a fresh `Node.connect`-triggering call to
`ymir` cold; the curl request landed inside the "recently failed, fail
fast" window opened by that same prior attempt (and by the earlier
Dashboard/`node_info` measurements run moments before it in this session).
**This means the ~3s stall is not necessarily paid on literally every
single page load — it's paid whenever the last failed-connection-attempt
cache to `ymir` has expired**, which based on the gap between our
Dashboard test (3.1s, cold) and this curl test (83ms, warm) is more than
the ~10-30s between those two commands, but the exact TTL wasn't
independently isolated in this pass. **Practical takeaway: this is a real,
currently-active intermittent multi-second stall on `/projects`, not a
guaranteed-every-load one** — worth flagging precisely as such rather than
overstating it as "always 3s," per the audit brief's instruction to
measure before blaming.

## 4c. Top fix — Projects Index

1. Same as Dashboard §3c #1/#2: **fix/decommission the stale `ymir` node
   reference**, and/or **cache `Cluster.node_name/1`** — this page and
   Dashboard share the identical root cause and the identical fix.
2. **Trivial, independent of the ghost-node issue:** dedupe the template's
   per-row `Cluster.node_name/1` call in `index.html.heex`'s `<:col>` the
   same way Round 1 recommended for Sessions Index — build a
   `%{node => name}` map once in `mount/3` (or `reload_for_node_filter/1`)
   over the distinct nodes in `tagged_projects`, and look up from that map
   in the template instead of calling `Cluster.node_name/1` live per row.
   This doesn't fix the ghost-node stall by itself (as demonstrated in
   §3b, dedup alone doesn't help when the cost is dominated by one
   uncached slow node) but it *is* still correct practice and becomes
   meaningfully valuable in combination with #1/#2 once the node lookup is
   fast again — at that point this page's node badge cost genuinely does
   scale with row count, not node count, exactly like Round 1's Sessions
   Index finding.
3. Everything else on this page is already fast and non-N+1 — `mount/3`
   itself: 1 query, ~1ms. No further action needed there.

---

# 5. Project Show — `/projects/:id`

Measured against the `orca_hub` project itself (an actively-developed,
non-trivial repo — 606KB rendered page, chosen deliberately as a
larger-than-typical case).

## 5a. Ranked table (mount-time RPC calls, individually timed)

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`AgentMemory.list_claude_memories/1`** | 99.5ms | yes | no | returns **~284KB** — full content of every Claude memory file for this project, unconditionally, regardless of whether any memory panel is expanded |
| 2 | **`AgentMemory.list_codex_memories/0`** | 56.0ms | yes | no | returns **~963KB** — and is **not project-scoped at all** (called with `[]`, no directory arg): every project's Show page fetches the exact same global, node-wide Codex memory set (252 files) |
| 3 | `Projects.git_log/2` (shells to `git log`, capped at 20 entries) | 20.3ms | yes | no | **cleared suspicion** — the "shells out synchronously" pattern IS present (all 4 git_* calls use `System.cmd`) but measured cost is small on this repo; see 5b |
| 4 | `Projects.git_worktree_list/1` | 5.2ms | yes | no | |
| 5 | `HubRPC.list_triggers_for_project/1` | 5.3ms | yes | no | |
| 6 | `Projects.git_branch/1` | 4.5ms | yes | no | |
| 7 | `HubRPC.list_artifacts_for_project/1` | 4.5ms | yes | no | **unbounded** — no `LIMIT`, 34KB today; will grow per-project over time as artifacts accumulate (item 7 from the audit brief) |
| 8 | `Projects.git_branches/1` | 3.3ms | yes | no | |
| 9 | `Cluster.session_alive?`-adjacent / `HubRPC.list_servers_for_project` | 2.3ms | yes | no | |
| 10 | `AgentMemory.list_agents_md_memories/1` | 0.5ms | yes | no | |
| 11 | `AgentMemory.codex_memories_enabled?/0` | 1.1ms | yes | no | |
| 12 | `HubRPC.list_upstream_servers/0` | 0.4ms | yes | no | |
| — | **All 8 `Cluster.rpc` calls run sequentially, not concurrently** | sum ≈ 203ms | yes | — | none individually slow today, but see 5c #1 |

**Ecto (mount):** the git/AgentMemory calls are all non-DB (shell/file I/O
on the remote node); the DB-backed calls (`triggers`, `artifacts`,
`servers`, `upstream_servers`) are 4 small single-table queries, all
sub-6ms.

**Full page load (curl, disconnected mount):** `time_total = 0.109s`,
606,163 bytes — consistent with the ~203ms server-side sum above (some
overlap/caching between the isolated-call measurement and the full request
is expected and not concerning).

## 5b. Cleared suspicion: git shellouts are NOT slow today

The audit brief specifically calls out "anything shelling out (git, etc.)
synchronously" as a risk. All four `Projects.git_*` functions do exactly
that (`System.cmd("git", ...)`), and they run **sequentially** in
`mount/3`, not concurrently. On the `orca_hub` project (a real,
actively-committed-to repo, not a toy fixture) this measured at
20.3+4.5+5.2+3.3 ≈ **33ms total** — genuinely cheap. **Measured, not
assumed: this is a cleared suspicion at today's repo sizes**, not a live
bug. It remains a latent risk shape (sequential blocking shellouts scale
with repo size — many refs/branches, or a `git log` against a repo with an
enormous history, would cost more, and a hung/stuck git process on a
network filesystem has no timeout at all here) — worth remembering if a
much larger repo is ever added, but not something to fix speculatively
today.

## 5c. Confirmed: a real, moderate rendering cost from the global Codex memory list

`AgentMemory.list_codex_memories/0` is called with `[]` (no project
directory argument) — it returns **every Codex memory file on that node's
user**, not anything scoped to the viewed project. This means:

- **Every one of the 180 projects' Show pages fetches and renders the
  identical 252-file, ~963KB payload**, redundantly, on every visit —
  confirmed via `curl`'s DOM output: **756 `codex-memory-*` id'd divs**
  (252 files × 3 divs/row) out of 1,598 total `<div>`s on the page, and
  606KB of rendered HTML for a page whose actual project-specific content
  (git log, triggers, MCP servers) is tiny by comparison.
- The template also unconditionally computes
  `split_body_blocks("codex_memory", file.content)` (markdown block
  splitting) for **every** file on every render, regardless of whether
  that file's `<div>` is actually expanded (`MapSet.member?(@codex_expanded,
  ...)`) — the same "eagerly-evaluated regardless of whether it's used"
  shape the audit brief warned to watch for. Measured directly: this costs
  **18.6ms** across all 252 files today — real, but modest, not the
  dominant cost (the dominant cost is payload size / DOM node count, not
  CPU).
- Not remotely as severe as Round 1's 27k-node/6.6MB/5.8s Session Show
  freeze, but the same *shape* of problem at 1/40th the scale: a large,
  effectively-static collection sent and rendered in full on every page
  view of something that shows it collapsed by default.

## 5d. Top 3 to fix — Project Show

1. **Scope `list_codex_memories` to the project, or at minimum stop
   re-fetching/re-rendering the identical global list on every project's
   page** — e.g. cache it once per node (it's genuinely node-global, not
   project-specific, so per-project caching doesn't even make sense;
   node-level or session-level caching does), or defer loading it until the
   Codex memory section is actually expanded/visited. Trivial-to-moderate:
   no data model change needed, just move the fetch behind a lazy trigger
   (`phx-click` load, or `start_async` gated on first expand) instead of
   unconditional `mount/3` inclusion.
2. **Gate `split_body_blocks/2`'s eager per-file computation behind the
   same `MapSet.member?(@codex_expanded, ...)` check the rendering itself
   already uses** — trivial, single-line-ish change, removes 100% of the
   18.6ms wasted-computation cost (small in isolation, but it's pure waste
   today: computed for all 252 files, used for however many happen to be
   expanded, typically 0).
3. **Parallelize the 8 sequential `Cluster.rpc`/git calls in `mount/3`**
   (e.g. `Task.async_stream` or a few `Task.async`/`await` pairs) — not
   urgent at today's per-call costs (sum ≈203ms, sub-6ms per DB call), but
   since every one of these is an independent cross-node round trip with
   its own timeout, sequential execution means the page's worst-case mount
   time is the *sum* of all 8 timeouts if the project's node is degraded,
   not the *max* of one. Moderate effort (needs to preserve error handling
   per call), lower priority than #1/#2 given current measured costs are
   small.

---

# Telemetry handlers (proof of cleanup)

Every `:telemetry.attach/4` call made during this investigation was
`:telemetry.detach/1`'d inside the same atomic `rpc` invocation
immediately after use, and final state was confirmed live:

```
repo:query handlers: []
mount:stop handlers: [only Phoenix.LiveView.Logger's own built-in handler]
```

Handlers used, all temporary, one attach+measure+detach per invocation:

- `[:orca_hub, :repo, :query]` — attached/detached for ProjectLive.Index
  mount (×1), DashboardLive mount (×1), QueueLive mount (×1),
  `list_idle_sessions_with_last_assistant_message/0` isolation (×1).
- No handler was attached for ProjectLive.Show or UsageLive measurements —
  those used plain `:timer.tc/1` around individually-called context
  functions (no telemetry needed since the goal was per-call timing, not
  query counting).

No `:fprof`/`:eprof` or other whole-VM profiling was used. No process was
left running, no PubSub subscription outlived its one-shot `rpc` process,
and no scratch files were left on the pod's filesystem
(`rm -f /tmp/out_*.html` at the end).

# Overall top 3 (across my five pages)

1. **`/usage`'s 8.7s synchronous double CLI-shellout (§1)** — every single
   page load, guaranteed on this hub, ends in an error anyway. Trivial fix
   (`start_async/3`) for the perf half; a real logic bug for the
   double-refresh half. Larger than every other finding in this report
   combined.
2. **`/queue`'s 3.5s full-`messages`-table scan (§2)** — the single most
   architecturally serious finding (an actual `EXPLAIN ANALYZE`-confirmed
   unindexed sequential scan + disk-spilled sort over the entire messages
   table, to answer a question about 49 rows), and the one item in this
   report that "needs restructuring" rather than a one-line fix. Will only
   get worse as the messages table grows.
3. **The `ymir@192.168.1.19` ghost node (§3/§4)** — a single stale
   `runner_node`/project `node` reference that currently costs ~1.5–3.1s,
   uncached, on Dashboard and (intermittently — see §4b) Projects Index.
   Distinct from Round 1's Sessions Index N+1 in an important way: dedup
   alone (already present in Dashboard's code) does **not** fix it,
   because the cost isn't proportional to call count — it's one specific
   node with no cache and a slow (not instant) failure mode. Fixing the
   stale data (or adding a short-TTL cache to `Cluster.node_name/1`) fixes
   both pages at once.

## Cleared suspicions

- **Projects Index / Project Show's `mount/3` DB cost** — genuinely fast
  (1 query, ~1ms for Index; a handful of sub-6ms queries for Show). All of
  Projects Index's real cost lives in the template's per-row `node_name`
  call, not in `mount/3` itself — worth remembering when reading table #1's
  headline number for that page.
- **Project Show's four sequential `git_*` shellouts** — the audit brief
  specifically asked to check for synchronous shellouts, and this page has
  four of them, run sequentially. Measured (not assumed) at 33ms combined
  on a real, actively-used repo. A real risk *shape* worth remembering for
  a much larger repo, but not a live bug today.
- **Queue's per-idle-session `Phoenix.PubSub.subscribe/2` loop** — looks
  exactly like the fan-out N+1 shape the audit brief warns about, but
  measured at 0.75ms for 48 subscriptions — a local ETS-backed registry
  op, not a network call. Cleared.
- **Dashboard's `node_session_counts` dedup pattern** — already implements
  the exact "group by node, resolve once per distinct node" fix Round 1
  recommended for Sessions Index's analogous bug. Confirmed by direct
  measurement that this pattern, correctly applied, still doesn't help
  when the underlying cost is one always-slow node rather than call-count
  multiplication (§3b) — noted here so the dedup fix isn't mistakenly
  re-recommended for this page without also flagging that it won't be
  sufficient alone.

## Fixes, split by effort

**Trivial** (single aggregate/cache, `start_async`, hoist a per-row call,
gate an eager computation):
- `/usage`: wrap `fetch_usage/1` in `start_async/3` (§1c #1).
- `/usage`: short-circuit the double CLI-refresh-and-retry (§1c #2).
- `/`, `/projects`: add a short-TTL cache to `Cluster.node_name/1`/
  `display_name/1` (§3c #2, fixes both pages).
- `/projects`: dedupe the template's per-row `node_name` call to a
  precomputed `%{node => name}` map (§4c #2).
- `/projects/:id`: gate `split_body_blocks/2`'s eager per-file computation
  behind the `codex_expanded` check already used for rendering (§5d #2).

**Needs restructuring** (schema/query change, real architectural work):
- `/queue`: replace the whole-`messages`-table `DISTINCT ON` subquery with
  a `LATERAL` join scoped to the idle/waiting sessions (§2c #1) — by far
  the most involved fix in this report, and the highest-value one after
  the Usage fix.
- `/projects/:id`: scope or cache `list_codex_memories/0` so 180 project
  pages stop each independently fetching+rendering the same global 963KB/
  252-file list (§5d #1).
- Data hygiene (not a code change, but blocking full resolution of §3/§4):
  decommission or reconnect the stale `ymir@192.168.1.19` node reference
  (5 live sessions + 1 live project still point at it).
