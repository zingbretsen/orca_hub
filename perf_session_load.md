# OrcaHub Page-Load Performance Report

Measurement-only. No source files were edited. All numbers below were captured
live against **production** (hub pod `orca-hub-7d9f64b95b-7v2gw`, namespace
`lab`) via `bin/orca_hub rpc` one-shot evals and one real Chromium session
(via `playwright-mcp`, origin `http://orca-hub.lab.svc.cluster.local:4000`).
Every `:telemetry.attach/4` handler used for measurement was detached
immediately after use — see "Telemetry handlers" at the end for proof. No
Ecto/LiveView/endpoint code was modified; the app's own built-in
`Phoenix.Logger`/`Phoenix.LiveView.Logger` telemetry handlers were left
untouched throughout.

Pages covered: **Session Show** (`/sessions/:id`), **Sessions Index**
(`/sessions`), **Nodes Index** (`/nodes`).

## Methodology notes

- Component-level numbers were captured with `:timer.tc/1` around the exact
  functions `show.ex` / `index.ex` call, using real prod data.
- Mount-level numbers were captured by calling the real, public
  `Show.mount/3`, `Index.mount/3` (both modules) directly against a
  hand-built `%Phoenix.LiveView.Socket{}` (`transport_pid: nil` for the
  disconnected pass, `transport_pid: self()` for the connected pass) — this
  exercises the actual production mount code, not a simulation, without
  needing `Phoenix.LiveViewTest`/Floki (not present in the prod release).
- Ecto query counts/timings used a temporary `[:orca_hub, :repo, :query]`
  handler accumulating into the calling process's dictionary (isolated to
  exactly the one mount call being measured, no cross-request noise).
- One real end-to-end load was also driven per page: `curl` from inside the
  hub pod (network-latency-free, isolates server time) and a real Chromium
  tab via `playwright-mcp` (full client-visible timeline, hooks, DOM,
  long tasks, WS/long-poll payload sizes).
- **Prod-safety judgment call:** `ensure_runner_started` (Show mount) can
  call `Cluster.start_session`, which is cheap and side-effect-free for an
  idle/archived session — reading `session_runner.ex` confirms `init/1`
  never opens a port or CLI subprocess for a session with no live turn in
  progress (`:ready`/cold-`:idle` "has never opened a port"). This was
  verified by inspection before exercising it live, and every runner our
  testing started was explicitly stopped again afterward (see cleanup note
  below) to leave prod in its original state.
- Three real sessions were used for Session Show, picked by message count
  from the prod DB (2,788 sessions with messages):

  | label | messages | directory | runner_node |
  |---|---|---|---|
  | small | 20 | `/home/zach/transcription` | `gb10@192.168.1.77` (remote) |
  | medium | 200 | `/home/zach/circus-of-puffins/voice_prompt` | `debian@192.168.1.177` (remote) |
  | large | 4,179 (largest in prod; #2 was 3,514) | `/home/zach/dataloop-bridge` | `gb10@192.168.1.77` (remote) |

  All three are archived, `status: idle`. No hub-local (`runner_node ==`
  the hub's own node) session was found alive at test time, so the
  local-vs-remote comparison for `Cluster.get_state`/`session_alive?` is
  based on: remote-alive (small, pre-existing), remote-cold-then-warm
  (medium/large), and code inspection for the local case (a same-node
  `:gen_statem.call` has no `:erpc` hop — expected sub-100µs, not
  independently prod-measured since no local-alive candidate existed).
- **Cleanup:** visiting an archived session's page starts its runner
  (harmless — see above). Sessions "medium" and "large" were dead before we
  touched them; both were explicitly `Cluster.stop_session`'d back to dead
  after testing. "small" was *already alive* before any of our testing (an
  existing warm-pool resident) and was left untouched.

---

# 1. Session Show — `/sessions/:id`

## 1a. Server-side component timing (ranked, slowest first, **large** session)

| # | item | small (20) | medium (200) | large (4,179) | critical path? | runs 2×? | note |
|---|---|---|---|---|---|---|---|
| 1 | **`message_feed` render → iodata** (incl. markdown) | 16.1ms | 37.2ms | **1.86–2.23s** (2 runs, high variance) | yes | yes (dead+connected) | dominant cost at scale; see 1b |
| 1a | — of which `Markdown.render` alone | 8.8ms | 20.6ms | **942–978ms (~50%)** | yes | yes | no caching — re-parsed from scratch on every mount, see below |
| 2 | `load_runner_state` (list_messages fallback, session cold) | 11.2ms† | 12.1ms | **325.6ms** | yes | only on the 1st mount if cold (see #3) | `HubRPC.list_messages/1` fetch + `Map.put(timestamp)` decode over every row |
| 3 | `ensure_runner_started` cold path (`Cluster.start_session`, isolated) | n/a (already warm) | not isolated | **264ms** | yes, blocking | 1st mount only | pays the *exact same* `list_messages` cost again, cross-node, inside `SessionRunner.init/1` — see 1c |
| 4 | `Cluster.get_state` after warm start (cross-node state transfer) | 11.2ms (already warm) | n/a | 88ms | yes | 2nd mount uses this path once warm | transfers the full in-memory message list back over `:erpc` |
| 5 | `pi_plan_mode_from_messages` scan (`Enum.reverse` + `find`) | 0.2ms | 0.5ms | **25.5ms** | yes | yes | O(n), allocates a full reversed copy every mount |
| 6 | `AskUserQuestion.pending_questions/1` | 0.05ms | 0.09ms | **7.0ms** | yes | yes | |
| 7 | `Todos.from_messages/1` | 0.03ms | 0.04ms | 2.0ms | yes | yes | |
| 8 | `PlanMode.detect/1` | 0.03ms | 0.11ms | 1.5ms | yes | yes | |
| 9 | `Cluster.node_info()` | 0.17ms | 2.1ms | 3.1ms | yes | yes | pings/reads cluster node state |
| 10 | `HubRPC.get_adjacent_session_ids/1` | 0.36ms | 0.43ms | 0.37ms | yes | yes | flat, not size-dependent |
| 11 | `HubRPC.list_artifacts_for_session/1` | 1.1ms | 0.44ms | 0.36ms | yes | yes | |
| 12 | `HubRPC.list_servers_for_session/1` | 1.0ms | 0.34ms | 0.36ms | yes | yes | |
| 13 | `HubRPC.list_upstream_servers/0` | 0.95ms | 0.28ms | 0.29ms | yes | yes | |
| 14 | `Cluster.session_alive?/2` check | 1.1ms | 0.3ms | 1.7ms | yes | yes | itself a cross-node `:erpc` call every time |
| 15 | `HubRPC.get_heartbeat/1` | 0.08ms | 0.02ms | 0.02ms | yes | yes | |
| — | `handle_params/3` (default `:conversation` view) | ~0.02ms | ~0.02ms | ~0.02ms | yes | yes | negligible — no DB work unless `?view=tree` |

† small's `load_runner_state` used the `Cluster.get_state` path since it was
already warm (was alive before we started testing), not the cold
`list_messages` fallback — not directly comparable to medium/large's number
on that row.

**Ecto (item 4 of the task):** exactly **12 queries / ~7–12ms total** for
*both* mounts combined, and — importantly — **constant regardless of message
count** (12 queries at 20 msgs, 12 at 200, 12 at 4,179). No N+1 inside
`Show.mount/3` itself. Query breakdown per full page load (disconnected +
connected, 2× each): `sessions` ×4, `upstream_servers` ×4, `artifacts` ×2,
`projects` ×2 — all doubled by the disconnected/connected mount pair, none
scaling with `messages`.

## 1b. Mount runs twice — confirmed, but NOT symmetric

`mount/3` genuinely runs twice (Phoenix LiveView's disconnected dead-render +
connected join), confirmed directly via the `[:phoenix, :live_view, :mount,
:stop]` telemetry event firing twice per page load. But the two passes are
**not equal cost** — the first one pays a hidden one-time tax if the
session's runner was cold:

| session | disconnected mount | connected mount | total_double_mount |
|---|---|---|---|
| small (already warm) | 21.0ms | 9.7ms | 30.7ms |
| medium (cold → warm) | 62.9ms | 11.5ms | 74.4ms |
| large (cold → warm) | **440.9ms** | 121.5ms | 562.5ms |

For a **cold** archived session, the *first* mount's `ensure_runner_started`
silently starts the runner, whose `init/1` does its own
`db_call(init_data, :list_messages, [session_id])` (`session_runner.ex:210`)
— paying the exact same expensive decode cost `load_runner_state`'s fallback
would have paid, just hidden one level down and blocking mount either way.
The *second* mount then hits the fast `Cluster.get_state` path since the
runner is now warm, which is still not free (88ms for large — transferring
4,179 messages back over `:erpc`) but far cheaper than redoing the DB
decode. **A naive mental model of "cost X runs twice" is wrong here — the
large session's real cost profile is "~264–330ms cold-start tax, paid once,
then ~120ms/mount steady-state."**

Real end-to-end numbers (own telemetry, warm runner, HTTP round trip via
`[:phoenix, :endpoint, :stop]` / `[:phoenix, :live_view, :mount, :stop]`):

| session | `mount_stop` (LiveView mount alone) | `endpoint_stop` (full server response incl. template render) | curl `time_total` (pod-local) |
|---|---|---|---|
| small | 9.4ms | 32.7ms | 34–39ms |
| medium | 16.7ms | 64.0ms | 59–65ms |
| large | 115.0ms | **1,286ms** | 1.29–1.41s |

`endpoint_stop − mount_stop` ≈ full-page template render (message_feed +
surrounding chrome), consistent with the isolated message_feed render number
in 1a (same order of magnitude; the isolated re-runs showed real run-to-run
variance of 1.4–2.3s on the same 4,179-message input — see "surprising"
notes below).

## 1c. Client-side timeline (large session, real Chromium via playwright-mcp)

This directly investigates the reported symptom: **"messages appear, then
the page still sits unresponsive for a while."** Confirmed and precisely
quantified — it is a client-side main-thread block, not (only) a server
render problem.

| stage | time (from navigation start) | note |
|---|---|---|
| Server TTFB (`responseStart`) | ~1.9s | browser-measured incl. network; pod-local curl shows server-render-alone at 1.3–1.4s |
| Dead-render response fully received (`responseEnd`) | ~2.2s | 723KB compressed / gzip transfer |
| **First Paint / First Contentful Paint** | **~2.27s** | content becomes *visible* here — matches "messages appear" |
| `DOMContentLoaded` | 2.8–3.9s | parsing/building **27,557 DOM nodes** from ~3.7MB decompressed HTML |
| `load` event | 2.8–4.0s | |
| Long-poll join (`WS` fallback in this browser context) round-trips | — | this env fell back to LiveView's long-poll transport, not a raw WebSocket |
| **Connected-mount join payload** | delivered right after connect | **2,927,948 bytes (~2.9MB)** — the entire message feed, sent a *second* time as the LiveView diff, on top of the ~723KB (compressed) dead-render HTML |
| **Main-thread long tasks after paint** | 10 tasks, **~7.2s total**, one single task = **5,838ms** | applying the connected-mount diff + mounting hooks against the 27k-node DOM; the page is visually painted but **not interactive** for several more seconds |
| `phx-hook` elements mounted | **302 total, 294 are `TTSPlayer`** | confirmed: `message_components.ex:255` puts `phx-hook="TTSPlayer" id={"tts-#{@msg_id}"}` on every assistant text message, unconditionally |

So for the large session: visible content at ~2.3s, but the page is
effectively frozen for ~6 more seconds (one dominant 5.8s long task) before
it can respond to a click/scroll/keypress — roughly **8–9 seconds from
navigation to actually interactive**. The 294 `TTSPlayer` hook mounts
themselves are individually cheap (`mounted()` just does a few property
inits + one `addEventListener`, confirmed by reading `app.js:692-713` — no
per-hook network/heavy work, no autoplay unless explicitly flagged), so the
cost is not "294 hooks are each slow" — it's LiveView's connected-mount
patch application processing a ~2.9MB diff against a 27k-node DOM,
mounting 302 hooks along the way, all as one synchronous JS task.

**Total bytes for one large-session page view: ~3.7MB (dead render) + ~2.9MB
(connected-mount payload) ≈ 6.6MB of essentially duplicate message content**,
transferred and parsed/diffed twice.

## 1d. Top 3 to fix — Session Show

1. **Stop sending the full message feed twice.** The connected-mount join
   payload (2.9MB) duplicates almost all of the dead-render HTML (3.7MB).
   This is the single biggest win available and is *the* direct cause of
   the 5.8s main-thread freeze after paint. Needs real restructuring
   (temporal/virtualized rendering, or suppressing/deferring the
   full-feed connected re-render), not a one-line fix.
2. **Cache markdown render output.** `Markdown.render/1` has no caching and
   re-parses every text block from scratch on *every* mount (both dead and
   connected) — ~50% of large-session render time (942–978ms). Persisted
   messages never change their markdown content after being written, so
   this is an ideal candidate for a per-message cache (even a simple
   `:persistent_term`/ETS keyed by message id+content hash would eliminate
   nearly half the render cost on repeat views). Trivially fixable
   relative to #1.
3. **Gate the 294 `TTSPlayer` hooks.** One hook per assistant text message
   is what makes the connected-mount diff/patch this expensive to apply on
   a big DOM. Consider mounting the hook lazily (e.g. only when its
   message scrolls into view, or only for the most recent N messages) —
   moderate restructuring, but directly cuts into the 5.8s long task
   independent of fix #1.

Smaller/cheaper wins also worth doing: the `ensure_runner_started` cold-start
tax (~264–330ms, one-time per cold session) and the `pi_plan_mode_from_messages`
full-list `Enum.reverse` scan (25.5ms on 4,179 messages, easily replaced
with a single backward `Enum.find` via `Enum.reduce_while` from the tail, or
cached alongside `plan_mode` state) are both small, isolated, low-risk fixes.

---

# 2. Sessions Index — `/sessions`

Prod state at test time: **38 sessions** (filter `:manual`, the mount's
default), **54 projects**, sessions spread across **5 distinct connected
runner nodes**.

## 2a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`Cluster.node_name/1` resolution loop** (`group_sessions`'s `session_node_names` map) | **33.5ms** | yes | no (index mount only fires once meaningfully — see below) | **confirmed N+1**: calls `Cluster.node_name/1` once **per session** (38 calls) instead of once **per distinct runner node** (5) — a ~7.6× multiplier. For a remote node, `node_name/1` does a blocking `:erpc.call(n, Cluster, :display_name, [], 5_000)` (5s timeout) per call |
| 2 | `Cluster.node_info()` (via `NodeFilter.on_mount`, runs before Index's own mount) | 6.3ms | yes | no | shared cross-page on_mount hook |
| 3 | `Cluster.list_sessions(:manual)` | 3.3ms | yes | no | single `HubRPC` query + in-memory tag/sort, does NOT scale badly |
| 4 | `Cluster.list_projects()` | 1.8ms | yes | no | |
| 5 | `project_node_map` build | 0.43ms | yes | no | |
| 6 | `get_heartbeat_session_ids` | 0.07ms | yes | no | |
| 7 | `filter_by_heartbeat` | 0.05ms | yes | no | |
| 8 | `Cluster.build_node_map/1` | 0.02ms | yes | no | pure/local, **not** an N+1 despite the name — see below |
| 9 | `NodeFilter.filter_tagged(..., :all)` ×2 | ~0 | yes | no | default filter is `:all`, a no-op pass-through |

**Ecto:** 2 queries, ~3.0ms total, for the whole mount — no DB-level N+1.

## 2b. Corrections to the stated hypothesis

- `Cluster.nodes()` (`index.ex` around line 83) is **not** called on the
  default `:index` route mount — it's only called inside `apply_action(...,
  :new, ...)`, i.e. only when opening the "New Session" form. **Not** on the
  default page-load critical path.
- `Cluster.runner_node_for/1` (used inside `list_sessions/1`) and
  `Cluster.build_node_map/2` are both **pure, local, in-memory functions** —
  `runner_node_for/1` just pattern-matches/`String.to_atom`s the
  already-loaded `session.runner_node` string, no query, no `:erpc`. They
  are *not* the N+1. The real N+1 is one level up: `Cluster.node_name/1`,
  called from `group_sessions/3`'s `session_node_names` map (index.ex
  ~452-455), which *is* a per-call `:erpc.call/4` for any node that isn't
  the hub itself.
- Archived sessions are **not** loaded and discarded — `Sessions.list_sessions/1`
  filters `is_nil(s.archived_at)` at the SQL level, and also joins/preloads
  `project` in the same query (no separate project N+1).
- Nothing in this mount is repeated on the connected pass in a way that adds
  cost — `mount/3` runs once total for a normal navigation to this page (no
  separate expensive disconnected-vs-connected split like Session Show has,
  since there's no equivalent "cold runner" concept here).

## 2c. Top 3 to fix — Sessions Index

1. **Deduplicate the `Cluster.node_name/1` calls by node, not by session** —
   trivially fixable: build a `%{node => name}` map once over
   `Enum.uniq(distinct nodes)` (5 calls instead of 38) before building
   `session_node_names`, then look up from that map per session. This alone
   should cut the dominant cost here by ~7×, and importantly caps the
   damage if a node is offline/slow (bounded by node count, not session
   count).
2. **Consider caching `display_name/1` results with a short TTL** (or
   pushing it into `Cluster.node_info()`, which is already called once per
   mount and already resolves per-node info) — a node's display name
   changes essentially never; there's no reason to re-resolve it via
   `:erpc` on every single page load.
3. Everything else on this page is already cheap and non-N+1 at today's
   scale (38 sessions/54 projects) — no further action needed there. Watch
   `Cluster.node_name/1`'s exposure grow linearly with total session count
   if it isn't fixed, though: at 10× today's session count this loop alone
   would be >300ms.

---

# 3. Nodes Index — `/nodes`

Prod state at test time: **14 rows** in the `nodes` table (mix of connected
and offline).

## 3a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`load_nodes/0`** (`HubRPC.list_nodes` + per-node counts) | **28.4ms** | yes | no | **confirmed N+1**: 1 query for `nodes`, then `Enum.map` over all 14 rows calling `HubRPC.count_sessions_for_node/1` **and** `HubRPC.count_projects_for_node/1` per row = **29 total queries** for a 14-node page |
| 2 | `restore_running_sweep/1` (connected mount only) | ~24.5ms total connected mount (see below) | **yes — but concurrent, not serial** | connected pass only | fans out `Task.async_stream` over every *connected* node calling `Cluster.rpc(atom, BackendInstaller, :running_backends, [], 6_000)`, but the **whole batch is still `await`ed inside `mount/3` before the connected socket returns** — see 3b |
| — | disconnected mount total | 28.4ms | yes | — | ≈ `load_nodes/0` alone (no `restore_running_sweep` on disconnected pass) |
| — | connected mount total | 24.5ms | yes | — | `load_nodes/0` + `restore_running_sweep/1`; nearly identical to disconnected today because all 14 nodes happened to be healthy/responsive during this test |

**Ecto:** 29 queries / ~24.6ms total on the disconnected mount alone (all of
it is the N+1 above — 1× `nodes`, 14× `sessions` COUNT, 14× `projects`
COUNT). Individually each COUNT query is cheap (~0.85ms avg — confirmed by
reading `cluster_nodes.ex:138-146`, both are plain `select: count(id)`
queries, no joins), so this is a pure query-*count* problem, not a
query-*cost* problem — an easy rewrite.

## 3b. Confirmed: sweep status IS off critical path; `restore_running_sweep` is NOT fully off it

- **Backend-update sweep** (`sweep_update_all`, `fetch_status/1` via
  `Cluster.rpc(atom, BackendInstaller, :status, [], 12_000)`) is only ever
  triggered by a user clicking "Update all backends" — never during mount —
  and uses `start_async/3` correctly, so a hung node here genuinely cannot
  stall first paint of the page. Confirmed by reading the code; this part
  works as designed.
- **`restore_running_sweep/1`** (best-effort "is a sweep already in
  progress, show spinners again after reload") runs on **every connected
  mount** (`if connected?(socket), do: restore_running_sweep(socket)`,
  index.ex:46) and, although it fans out to all connected nodes
  *concurrently* via `Task.async_stream(..., timeout: 6_000,
  on_timeout: :kill_task)`, the **entire stream is still synchronously
  awaited inside `mount/3`** before the connected socket is returned to
  Phoenix. With all 14 nodes healthy today this cost ~nothing (measured
  connected mount ≈ disconnected mount), but the code path means: **if even
  one currently-connected node is hung (not fully disconnected — e.g.
  saturated scheduler, like the large-session render case in §1c) rather
  than cleanly offline, first *connected* render of `/nodes` blocks for up
  to 6 seconds.** This was not artificially fault-injected in prod (would
  require actually hanging a node — out of scope for a safe measurement
  run), but is unambiguous from the code and the timeout constant.
- What happens to a genuinely **offline** node (never connected / not in
  `Node.list()`): `connected_targets/1` filters to `& &1.connected` before
  either `sweep_update_all` or `restore_running_sweep` ever touch it, so
  offline nodes are skipped entirely for both status paths — no timeout
  risk from them. The risk above is specifically about a node that
  `Node.list()` still considers connected but whose BEAM is slow to answer
  an `:erpc` call.

## 3c. Top 3 to fix — Nodes Index

1. **Collapse the 28-query N+1 into 2 aggregate queries.** Trivially
   fixable: replace the per-node `count_sessions_for_node`/
   `count_projects_for_node` calls with two `GROUP BY runner_node` /
   `GROUP BY node` aggregate queries (one for sessions, one for projects),
   then merge into the node list in-memory. Same pattern as any classic
   N+1→aggregate rewrite; lowest-risk, highest-value fix on this page.
2. **Move `restore_running_sweep/1`'s fan-out off the synchronous mount
   path** — e.g. via `start_async/3` the same way the sweep-button path
   already does it, updating cells as results stream in instead of
   blocking connected-mount on the slowest node (capped today at 6s).
   Moderate change (needs a `handle_async` clause mirroring
   `handle_async({:sweep_status, name}, ...)`), but structurally
   straightforward since the async pattern already exists elsewhere in
   this same module.
3. At 14 nodes today both costs are modest in the common case (healthy
   cluster: ~28ms disconnected / ~25ms connected) — the real risk is the
   *tail*, not the *median*: node-count growth makes #1 scale linearly
   (already the dominant cost), and any single unhealthy-but-connected node
   makes #2 a multi-second stall on every page load until it's fixed.

---

# Telemetry handlers (proof of cleanup)

Every `:telemetry.attach/4` call made during this investigation was
`:telemetry.detach/1`'d immediately after its measurement, confirmed live
each time via `:telemetry.list_handlers/1` showing only the app's own
built-in handlers remaining (`Phoenix.Logger`, `Phoenix.LiveView.Logger`) —
none of ours. Handlers used, all temporary:

- `[:orca_hub, :repo, :query]` — attached/detached per mount-timing script
  (Session Show ×3, Sessions Index ×1, Nodes Index ×1), each attach+measure+
  detach inside one atomic `try/after` block.
- `[:phoenix, :live_view, :mount, :stop]`, `[:phoenix, :live_view,
  :handle_params, :stop]`, `[:phoenix, :endpoint, :stop]` — attached once
  (owned by a short-lived spawned process holding a public ETS table so
  results survived across separate `rpc` invocations), used to capture the
  3 real curl-driven page loads for Session Show, then detached; final
  check confirmed `:telemetry.list_handlers/1` for all three events showed
  only the built-in `Phoenix.Logger`/`Phoenix.LiveView.Logger` entries.

No `:fprof`/`:eprof` or other whole-VM profiling was used. No handler was
left attached at the end of the session.

# Overall top 3 (across all three pages)

1. **Session Show's double payload for large sessions (§1c/§1d #1)** — by
   far the biggest real user-facing cost: ~6.6MB transferred, a 5.8s
   main-thread freeze, ~8-9s to interactive on the largest prod session.
   Everything else in this report is millisecond-scale by comparison.
2. **Sessions Index's `Cluster.node_name/1` N+1 (§2c #1)** — cheap today
   (33.5ms) only because there are just 38 sessions; it's an unbounded
   per-session `:erpc` call that will keep getting worse and is trivial to
   fix (dedupe by node).
3. **Nodes Index's count-query N+1 (§3c #1)** — same shape of bug as #2,
   smaller in absolute terms (28ms) but the single easiest fix in this
   entire report (textbook N+1 → 2 GROUP BY queries).

## Surprising findings

- **The "double mount" doesn't double the cost — it hides a bigger one-time
  cost inside the first pass.** A naive read of "mount runs twice" implies
  2× the same work; the real shape for a cold archived session is "~300ms
  paid once (runner cold-start), then ~120ms/pass steady-state" — see §1b.
- **The messages ARE sent twice, nearly byte-for-byte, and this — not
  server render time — is what causes the reported "page sits unresponsive
  after messages appear."** First paint happens at ~2.3s; the page then
  *looks* done but is frozen for ~6 more seconds applying a 2.9MB
  connected-mount diff. This was invisible to server-side timing alone;
  only the client-side long-task trace (playwright) surfaced it.
- **Large-session render time is highly variable run-to-run on identical
  input** (1.86s vs 2.23s vs the endpoint-telemetry-derived ~1.17s for the
  same 4,179-message render, all within the same test session) — consistent
  with CPU contention on the shared hub node rather than a deterministic
  cost. Treat absolute large-session numbers as a ballpark/range, not a
  fixed constant; the *relative* ranking (markdown ≈ half of render time, no
  Ecto N+1 in Session Show, real N+1s in both index pages) is the reliable
  part of this report.
- **`Cluster.build_node_map/2` and `runner_node_for/1` are red herrings** —
  despite being named like fan-out helpers, both are pure in-memory
  functions with zero network cost. The actual Sessions Index N+1 is one
  function away from where the hypothesis pointed (`Cluster.node_name/1`,
  not `build_node_map`/`runner_node_for`).
