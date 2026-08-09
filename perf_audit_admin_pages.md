# OrcaHub Admin-Page Performance Report (Round 2)

Measurement-only. No source files were edited. All numbers below were
captured live against **production** (hub pod `orca-hub-7598c6d79f-fjx54`,
namespace `lab`, image `registry.lab.ingbretsenhome.com/orca-hub:a92cd11`)
via `/app/bin/orca_hub rpc` one-shot evals and real Chromium sessions (via
the shared `playwright-mcp` upstream, reached through this session's own
`run_elixir`/`Tools.playwright__*` surface — no CLI-native playwright tool
was available in this session, so browser checks went through that route
instead), origin `http://orca-hub.lab.svc.cluster.local:4000`. Every
`:telemetry.attach/4` handler used for measurement was detached immediately
after use — see "Telemetry handlers" at the end for proof. No Ecto/
LiveView/endpoint code was modified.

This is the second round, following the same methodology as
`perf_session_load.md` (Session Show / Sessions Index / Nodes Index — all
already fixed and out of scope here). It covers the pages a sibling worker
did **not** take: `/triggers`, `/settings`, `/nodes/:id`, `/terminals`,
`/terminals/:id`, `/issues` + `/issues/:id`, and `CommandPaletteLive`.

## Methodology notes

- Mount-level numbers were captured by calling the real, public
  `mount/3` of each LiveView directly against a hand-built
  `%Phoenix.LiveView.Socket{}` (`transport_pid: nil` for the disconnected
  pass, `transport_pid: self()` for the connected pass), pre-seeded with
  whatever `on_mount` hooks normally inject (e.g. `node_filter: :all` for
  pages using `NodeFilter.on_mount/4`) — this exercises the real production
  mount code path, not a simulation.
- Ecto query counts/timings used a temporary `[:orca_hub, :repo, :query]`
  handler, attached/detached around each isolated mount call.
- Real end-to-end loads were taken two ways: `curl` from inside the hub pod
  (network-latency-free, isolates server time) and a real Chromium tab via
  the shared playwright-mcp upstream (navigation timing, DOM node counts,
  long tasks, console errors).
- Prod state at test time: **7 triggers**, **4 terminals** (all `running`,
  3 on `orca-dell`, 1 on `debian`), **14 rows** in the `nodes` table (5
  currently connected: `gb10@192.168.1.77`, `orca-dell@...`,
  `orca-discord@...`, `orca@192.168.1.18` ("mini"), `debian@192.168.1.177`),
  **25 issues** (8 open, all with **0 attempt sessions** at test time — see
  §3), **1 upstream server**, **180 projects**.
- **Issues UI deployment check:** confirmed `934ff26` (the commit that
  brought `/issues` UI up) is an ancestor of the deployed commit `a92cd11`
  (`git merge-base --is-ancestor` → true), and the deployed image tag is
  literally `a92cd11`. **Issues is deployed and was measured live in prod**,
  not dev-only.
- **Prod-safety judgment calls:** no terminal PTYs were started/stopped —
  `TerminalLive.Show`'s mount only *reads* terminal state
  (`Cluster.fan_out(HubRPC, :get_terminal, ...)`); it does not start the
  runner. All 4 existing terminals were left exactly as found (`running`).
  Login/backend-install/config-write event handlers were never invoked
  (read-only `mount/3` exercised directly, not `handle_event`) so nothing
  was installed, no code was written to any node's config, no login flow
  was started. `NodeLive.Show.mount/3` for a remote/connected node *does*
  read-execute `npm view <pkg> version` and `<cli> --version` on that node
  as an intentional part of the page's own existing design (§3) — this is
  the same class of read-only command execution the page already performs
  on every real visit; we did not invoke `run_backend_job` (the
  install/update action) itself.

---

# 1. Triggers Index — `/triggers`

## 1a. Ranked table (7 triggers, 5 connected nodes)

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **Per-trigger `Cluster.node_name/1` in the template** (`index.html.heex:216`) | ~2.3–5.4ms for 7 triggers | yes | yes (dead+connected) | **confirmed N+1, same bug class as the already-fixed Sessions Index**: `:for={trigger <- project_triggers}` renders `OrcaHub.Cluster.node_name(Map.get(@node_map, trigger.id))` once per trigger row instead of once per distinct node — a ~1.4× multiplier today (7 triggers / 5 nodes), calls `:erpc.call(n, Cluster, :display_name, [], 5_000)` per remote trigger |
| 2 | `mount/3` total (both `Cluster.list_triggers()` + `Cluster.list_projects()` + `build_node_map`) | 4.4ms disconnected / 3.3ms connected | yes | yes | flat, does not scale badly at today's size |
| 3 | Ecto (2 queries: `triggers` w/ `preload(:project)`, `projects`) | ~3.5ms disconnected / ~2.5ms connected | yes | yes | **no N+1** — `Triggers.list_triggers/0` uses a proper Ecto `preload(:project)` (single batched query), not a per-trigger lookup |

## 1b. Cleared suspicions

- `Cluster.build_node_map/2` (used by this page too) is confirmed pure/local
  again here — no network cost, consistent with last round's finding on
  Sessions Index.
- `Triggers.list_triggers/0`'s `preload: [:project]` is a real Ecto preload
  (one extra batched query), not an N+1 despite grouping by `& &1.project`
  in the template (`Enum.group_by(@triggers, & &1.project)` — 2-arg form,
  no eagerly-evaluated default-arg trap like the one found and stacked-fixed
  on Sessions Index last round).
- Checked every `Enum.group_by` call site across all 6 assigned pages
  (`terminal_live/index.ex`, `trigger_live/index.html.heex`,
  `command_palette_live.ex`) for the same "3rd-arg default eagerly
  evaluated" pattern that re-introduced a per-row call on Sessions Index
  last round — none present; all are 2-arg calls.

## 1c. Top fix — Triggers Index

1. **Dedupe `Cluster.node_name/1` by node, not by trigger** — identical fix
   shape to the one already shipped for Sessions Index: build a
   `%{node => name}` map once over the distinct nodes in `@node_map`'s
   values before rendering, look up per row from that map. Trivial, and
   caps the damage (today ~1.4×, but unbounded as trigger count grows) —
   same trivially-fixable N+1 as before, just not yet ported to this page.

---

# 2. Terminals — `/terminals` (Index) and `/terminals/:id` (Show)

## 2a. Terminals Index ranked table (4 terminals, 5 connected nodes)

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **Per-terminal `Cluster.node_name/1` in the template** (`index.html.heex:92`) | ~3.5ms for 4 terminals | yes | yes | same bug as §1, one call per terminal row instead of per distinct node |
| 2 | `mount/3` total | 9.2ms disconnected / 8.0ms connected | yes | yes | |
| 3 | Ecto (13 queries) | ~13.6ms disconnected / ~8.7ms connected | yes | yes | terminals + projects list, no N+1 — flat regardless of terminal count |

## 2b. Terminals Show — the real finding: an unnecessary N-node fan-out

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | **`find_terminal!/1`'s `Cluster.fan_out(HubRPC, :get_terminal, [id])`** | 7.7–13.3ms today (6 nodes incl. self) vs. **1.5ms** for the equivalent direct `HubRPC.get_terminal(id)` call — a genuine **5–9× overhead for zero benefit** | yes, blocking | no (mount runs once meaningfully; no cold-runner concept) | **confirmed dead-weight fan-out**: `HubRPC.get_terminal/1` already resolves to the ONE real DB (hub) regardless of which node calls it — hub+agent topology has a single DB, not one per node. `fan_out` calls this identical function on *every connected node* concurrently and (critically) **waits for ALL of them to answer or time out** (`Enum.flat_map` fully consumes the `Task.async_stream`) before returning, even though the very first node's answer would already be correct. `TerminalLive.Index`'s own `Cluster.list_terminals()` (used one page over) already just calls `HubRPC.list_terminals()` directly with no fan-out — this Show-page fan-out looks like vestigial code from the legacy multi-hub (per-node-DB) topology described in `project_clustering.md`, not an intentional safeguard. |
| 2 | `mount/3` total | 6.6ms disconnected / 4.8ms connected | yes | yes | cheap only because all 5 connected nodes are healthy today |
| — | Ecto (12 queries) | ~7.0ms / ~5.0ms | yes | yes | flat |

**Latent risk (task ask #4 — call out regardless of current timing):** because
`fan_out` blocks on the *slowest* responder, a single hung-but-still-
`Node.list()`-connected node turns every `/terminals/:id` load into a stall
of up to `timeout + 2_000` = **12 seconds** (`@timeout` = 10s default),
identical in shape to the already-fixed `NodeLive.Index`
`restore_running_sweep` pattern from last round — except here there's no
`start_async` involved at all; it's just an unnecessary synchronous
fan-out where a single direct call was already sufficient.

## 2c. Cleared suspicion — terminal scrollback is NOT a large-payload problem

Checked because the task flagged it as a candidate (mirroring Session
Show's 27k-DOM-node/6.6MB duplicate-payload problem from round 1): terminal
scrollback is **not** sent through the LiveView mount/render payload at
all. It's a bounded 64KB ring buffer (`@scrollback_size` in
`terminal_runner.ex`) delivered once via a real Phoenix **Channel** join
reply (`TerminalChannel`, `Base.encode64/1`-encoded), entirely separate
from LiveView's dead-render/connected-mount cycle. Confirmed live via
Chromium: `/terminals/:id` loads in **~105ms**, DOM is **229 nodes**,
**0 long tasks**, transfer size **4.9KB**. This page has no rendering-scale
problem today or as scrollback grows (bounded).

## 2d. Top fix — Terminals

1. **Replace `Cluster.fan_out(HubRPC, :get_terminal, [id])` with a direct
   `HubRPC.get_terminal(id)` call** in `TerminalLive.Show.find_terminal!/1`
   — trivial one-line fix, removes both the redundant network traffic
   (5–9× today) and the latent multi-second stall risk entirely, and makes
   this page's DB-fetch pattern consistent with how `TerminalLive.Index`
   already fetches the same data.
2. Same per-row `Cluster.node_name/1` dedupe as Triggers (§1c) — trivial.

---

# 3. Node Show — `/nodes/:id` — headline finding of this round

`NodeLive.Index`'s per-node COUNT-query N+1 was already fixed last round.
**`NodeLive.Show` does NOT share that pattern** (its two counts —
`HubRPC.count_sessions_for_node`/`count_projects_for_node` — are single
calls, once per mount, not per-row). But it has a much bigger problem of
its own, and it is **not latent — it is real, reproducible, and currently
firing on every single page view.**

## 3a. Ranked table — real HTTP end-to-end (`curl`, pod-local)

| target node | `curl time_total` | note |
|---|---|---|
| **mini** (`orca@192.168.1.18`, remote, npm+CLIs installed) | **1.65s** | |
| **hub itself** (`orca@orca-hub...`, LOCAL — no `:erpc` hop at all) | **2.06s** | slowest of all despite paying zero network-hop cost — see below |
| **orca-dell** (remote agent) | *(isolated call below: ~1.7–2.2s)* | |
| **gb10** (remote, "no AI services yet" per node notes) | **0.10s** | the one fast case — see §3d |
| offline node (`ymir`, not in `Node.list()`) | *(mount-only, below)* | fast path, skips everything |

## 3b. Component breakdown (`:timer.tc` on each of the 12 items `mount/3` calls serially)

Isolated timing of each call `mount/3` makes, run against 4 representative
targets:

| item | hub (local) | gb10 | orca-dell | mini |
|---|---|---|---|---|
| `NodeConfig.list_config(:claude\|:codex\|:pi)` ×3 (serial) | 1.3/0.7/0.6ms | 1.7/0.4/1.6ms | 98.7/51.6/65.3ms | 1.7/1.2/1.2ms |
| `SkillSync.managed_skill_names(:claude\|:codex\|:pi)` ×3 (serial) | 0.7/0.2/0.2ms | 0.4/0.5/0.6ms | 43.8/2.7/8.4ms | 0.7/0.6/1.5ms |
| **`BackendInstaller.status` (all 3 backends, concurrent inside)** | **1990–2213ms** | **82ms** | **1787ms** | **1547–3493ms** |
| `BackendInstaller.running_backends` | 0.01ms | 0.2ms | 0.6ms | 0.8ms |
| `GlobalGitignore.status` | 2.6ms | 2.4ms | 3.3ms | 6.0ms |
| `Cluster.codex_status` | 0.1ms | 0.2ms | 0.5ms | 1.1ms |
| `Cluster.codex_env_conflict?` | 0.01ms | 0.7ms | 0.3ms | 0.7ms |
| `Cluster.list_pi_providers` | 0.1ms | 0.2ms | 0.3ms | 0.6ms |
| **sum of everything else (11 of 12 items)** | **~6ms** | **~8ms** | **~275ms** | **~15ms** |

`BackendInstaller.status` alone is **>99% of hub's and mini's total mount
cost**, and re-ran 3× each for reproducibility (hub: 2147/2213/2039ms;
mini: 1556/1547/1568ms — stable, not a one-off spike).

## 3c. Root cause — synchronous, uncached `npm view` over the real network, on every mount

`OrcaHub.BackendInstaller.status/0` (`backend_installer.ex:124`) fans out
over `[:claude, :codex, :pi]` and, for each of codex/pi, calls
`latest_version/2` → `exec(npm_executable(), ["view", pkg, "version"],
@npm_timeout)` → **`System.cmd/3` shelling out to `npm view <pkg> version`**,
a real network round-trip to the npm registry, bounded at `@npm_timeout` =
4,000ms, inside an overall `@status_task_timeout` = 9,000ms per-backend cap.
This is task-ask #5 ("anything shelling out synchronously") landing
squarely on this page. Two compounding factors make it worse than a single
slow call:

1. **No caching at all.** Contrast with `Backend.available_on/1` and
   `Backend.models_for/2` (used elsewhere on this same page, for the
   default-backend/model pickers) — both already wrapped in
   `OrcaHub.Backend.Cache.get_or_run/3` with a 60s/300s TTL. `latest_version`
   has no equivalent cache — it re-hits the npm registry from scratch on
   **every single mount**.
2. **Mount runs twice per real page view**, and `node_config`/
   `backend_installer_status`/etc. are computed unconditionally (not gated
   behind `if connected?(socket)`) — so the full ~1.5–2.2s cost is paid
   **twice**: once for the dead-render HTTP response, once again
   (invisible to `curl`/navigation-timing, but still blocking the LiveView
   join) for the connected mount. Confirmed via direct `mount/3` calls with
   both `transport_pid: nil` and `transport_pid: self()` — both passes pay
   the full cost independently, back-to-back on a real navigation.

Real browser confirmation (mini node): `responseStart` ≈ 1.55s,
`domContentLoaded`/`loadEvent` ≈ 1.99s, but only **320 DOM nodes** and
**6.5KB transferred** — unlike Session Show's problem, this is *purely* a
server-side synchronous-network-call cost, not a rendering/payload-size
problem. There is no client-side long task to find here because the
bottleneck happens entirely before the first byte is sent.

## 3d. Why gb10 is fast (not a fix, an observation)

gb10 (82ms) is the one target where `BackendInstaller.status` is cheap.
Per its own node notes ("no AI services yet"), this appears to be
environment-specific (its `npm view` calls resolve quickly from that node's
network path) rather than evidence the underlying design is safe — hub,
dell, and mini all show the same 1.5–3.5s cost consistently.

## 3e. Cleared suspicion — offline nodes are fast, correctly

A node not in `Node.list()` (e.g. `ymir@192.168.1.19`) takes the
`connected? = false` branch and skips all 12 calls entirely —
**6.95ms disconnected / 3.06ms connected**. No wasted work on stale/
disconnected node rows, confirmed live.

## 3f. Top 3 to fix — Node Show

1. **Cache `BackendInstaller.status/0`'s per-node result with a short TTL**,
   the same pattern already used for `Backend.available_on/1`/
   `models_for/2` on this exact page (`Backend.Cache.get_or_run/3`, e.g.
   30–60s TTL). This is the single highest-value fix in this entire report:
   it would take the dominant, currently-reproducing ~1.5–2.2s-per-mount
   (~3–4.5s per real page view) cost down to near-zero on every view after
   the first, for every visit to every node's page. Moderate-trivial: the
   caching primitive already exists in the codebase, this is applying it to
   one more call site.
2. **Move `load_backend_installer_status/1` off the synchronous mount path**
   via `start_async/3` — the same pattern already used elsewhere on this
   exact page's sibling data flow (`IssueLive.Show`'s `live_attempts`,
   `NodeLive.Index`'s `restore_running_sweep`). Even with caching (#1) this
   is worth doing so a *cold*-cache mount doesn't block first paint;
   combined with #1 it also means a slow/cold node degrades gracefully
   (spinner + eventual update) instead of a multi-second blank load.
3. **Stop recomputing `node_config`/`managed_skills`/etc. on the
   disconnected pass at all** — since none of it is rendered differently
   between disconnected and connected states here (unlike Session Show,
   where the dead render legitimately needs the message feed), consider
   gating the whole config-loading block behind
   `if connected?(socket) do ... end` the way the PubSub subscribe already
   is, and showing a loading state on first (dead) render. This alone would
   halve the real-world cost even without caching, since today it's paid
   twice per navigation for identical reasons.

---

# 4. Settings — `/settings`

## 4a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | `node_records_map/1` (`HubRPC.get_node_by_name/1` × connected nodes + `Cluster.node_info()`) | 11.3ms (5 connected nodes) | yes | no | bounded by connected-node count, not by any unbounded collection — one query per *node*, not per session/project/anything that grows |
| 2 | `mount/3` total (incl. everything below) | 6.0ms disconnected / 6.0ms connected | yes | no | |
| 3 | Ecto (8 queries) | ~3.1ms both passes | yes | no | |
| 4 | `OrcaHub.MCP.UpstreamClient.list_tools()` | negligible | yes | no | ETS lookup on hub, not a network call — confirmed by reading source |

## 4b. Cleared suspicions

- **This page does NOT share Node Show's `BackendInstaller.status` problem**,
  despite touching very similar "connected nodes" data — `Settings`
  only calls `BackendInstaller`/npm-check functionality from an explicit
  user-clicked action (`push_all_code`, `check_drift`, `run_backend_job` is
  actually on Node Show, not here) via `handle_event`/`handle_info`, never
  from `mount/3`. This mirrors the good pattern already noted for
  `NodeLive.Index`'s "Update all backends" button last round: button-
  triggered work correctly stays off the critical mount path here.
- `tool_count_for_server/2`, called once per upstream server in the
  template, is a pure in-memory `Enum.count` over the already-loaded
  `@upstream_tools` list (no DB, no network) — O(servers × tools) but with
  1 server / a handful of tools today, and even at scale this never leaves
  memory.
- `OrcaHub.MCP.UpstreamClient.refresh/0` (an actual reconnect-all-upstream-
  servers network operation) is confirmed button-triggered only
  (`handle_event("refresh_connections", ...)`), never on mount.

## 4c. Top fix — Settings

Nothing urgent today. The one thing worth watching: `node_records_map/1`
issues one `HubRPC.get_node_by_name/1` query per **connected** node (not
per session/project), so it scales with cluster size, not data volume —
same shape as `Cluster.node_info()` itself, which every page pays already.
Not worth a dedicated fix at 5 nodes; would only become worth revisiting
alongside a general "cache node display names" fix if the cluster grows
much larger (see Sessions Index's already-filed but not-yet-fully-adopted
suggestion from round 1).

---

# 5. Issues — `/issues` (Index) and `/issues/:id` (Show)

**Confirmed deployed in prod** (see Methodology notes) and measured live,
not in dev.

## 5a. Issues Index ranked table (25 issues, capped at `limit: 200`)

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | `mount/3` total | 5.1ms disconnected / 2.5ms connected | yes | no | |
| 2 | Ecto (2 queries) | ~4.6ms / ~2.0ms | yes | no | `list_issues/1` already does `preload(:project)` |

## 5b. Cleared suspicion — the module's own stated N+1 concern doesn't fire

The module docstring explicitly calls out that attempts/commits fan-out is
deliberately excluded from the index page ("too expensive to run for an
entire index page of issues") — confirmed correct by reading `Show`'s
mount, which is the only place that logic lives. Separately: `issue_key/1`
(→ `HubRPC.render_issue_key` → `Issues.render_key/1`, which lazily
`Repo.preload`s `:project` if not already loaded) is called **3 times per
row** in the index template (`row_click`, the key badge, and the nav link)
— looked like a candidate per-row N+1 at first glance, but `list_issues/1`
already `preload(:project)`s every row in its single query, so all 3 calls
per row hit an already-loaded association — **zero additional DB queries**,
confirmed by the 2-query Ecto count above holding regardless of issue
count. The 3× redundant calls are pure string-formatting CPU, immeasurably
small.

## 5c. Issues Show ranked table

| # | item | open issue (0 attempts) | closed issue | critical path? | runs 2×? | note |
|---|---|---|---|---|---|---|
| 1 | `mount/3` total | 11.5ms disc / 10.4ms conn | 7.9ms disc | yes | yes | small, constant number of queries (`resolve_issue_id` + `render_issue_key` + optional `get_project`/`superseded_by` lookups) |
| 2 | Ecto (4–5 queries) | ~6.8ms / ~4.8ms | ~6.0ms | yes | yes | flat, not size-dependent |
| — | `live_attempts` (async, open issues only) | **not on critical path** | n/a (closed issues use the frozen `attempts` column, no fetch) | **no** | connected only | see §5d |

## 5d. Cleared suspicion — the "live git-log fan-out" the task flagged is real but already well-designed

`Issues.live_attempts/1` does exactly what the task description warned
about: a per-attempt-session `Cluster.rpc(node, Sessions,
:list_session_commits, ...)` — a live `git log` shelled out on the node
that owns each attempt's directory — plus a `Sessions.last_assistant_text/1`
DB query per attempt. This genuinely *is* an N-per-attempt fan-out. But:

- It's already loaded via `start_async/3` from `mount/3`
  (`maybe_load_attempts/1`), fully off the synchronous mount critical path
  — matching the exact pattern this report recommends adding to Node Show
  (§3f #2).
- It's capped at `@live_attempts_full_detail_cap` = 20 — attempts beyond
  the most recent 20 get a bare `%{session_id, status}` with no git-log
  call at all.
- **Measured live impact today: zero** — all 8 open issues in prod
  currently have **0 linked attempt sessions** (`Session.issue_id` column,
  confirmed via direct query), so this code path has nothing to iterate
  over right now. Flagging as designed-correctly-but-unexercised rather
  than cleared-by-absence: worth a spot check once issues actually
  accumulate attempts, since the fan-out is still serial
  (`Enum.map(full_sessions, &live_attempt_detail/1)`, not concurrent) and
  could stack up to `20 × (git-log round trip)` if a single issue ever
  collects a full cap's worth of attempts on slow/remote nodes — bounded,
  async, and best-effort (an unreachable node doesn't blank the whole
  response — issues_spec.md's stated design goal), so this is a "watch,
  don't fix yet" item, not a live problem.

## 5e. Top fix — Issues

Nothing needs fixing today. If attempts volume grows, revisit whether
`live_attempt_detail/1`'s serial `Enum.map` over up to 20 sessions should
become a `Task.async_stream` (mirroring `BackendInstaller.status`'s
internal concurrency) — but this is speculative, not measured.

---

# 6. CommandPaletteLive — fully cleared

## 6a. Ranked table

| # | item | time | critical path? | runs 2×? | note |
|---|---|---|---|---|---|
| 1 | Component `mount/2` (palette closed, default state) | ~0ms | no | no | assigns 7 static keys, no DB/network work at all |
| 2 | Opening the palette (`open_palette/1` → `build_results("", :search, nil)`) | ~0ms | yes, but trivial | no | empty-query path is a pure in-memory filter over 9 hardcoded nav/action commands — **no query loaded, nothing unbounded** |
| 3 | `Projects.search/1` (on typing a query) | 3.97ms | yes | no | `limit: 5` DB query — bounded, confirmed via direct measurement against 180 real projects |
| 4 | `Cluster.search/2` → `Sessions.search/2` (on typing a query) | 3.87ms | yes | no | `limit: 5` DB query, `preload(:project)` — bounded |

## 6b. Verdict

The task flagged this as worth checking for "unbounded collections" — there
are none. Nothing is loaded at mount or at open; every search path is
`limit: 5`; and the client already debounces input at 150ms
(`phx-debounce="150"`) before even sending the `search` event. Combined
server cost for a real keystroke (both queries, if a query string is
present) is **under 8ms**. No action needed.

---

# Telemetry handlers (proof of cleanup)

Every `:telemetry.attach/4` call made during this investigation was
`:telemetry.detach/1`'d immediately after its measurement (each `measure`
helper attached and detached within the same synchronous call, and every
measured `mount/3` call returned `{:ok, socket}` without raising, so every
detach ran). Confirmed live at the end of the session via
`:telemetry.list_handlers/1` for all three events used
(`[:orca_hub, :repo, :query]`, `[:phoenix, :live_view, :mount, :stop]`,
`[:phoenix, :endpoint, :stop]`) — only the app's own built-in
`Phoenix.LiveView.Logger`/`Phoenix.Logger` handlers remain; zero handlers
of ours left attached.

No `:fprof`/`:eprof` or other whole-VM profiling was used. No terminal PTYs
were started or stopped. No config was written to any node, no backend
install/update job was started, no login flow was started — `mount/3` was
exercised directly and read-only handler code paths were never invoked.

---

# Overall ranking across all 6 pages/components

1. **Node Show's uncached, synchronous `npm view` calls in
   `BackendInstaller.status/0` (§3)** — by a wide margin the biggest,
   *currently reproducing* (not latent) cost in this entire round: a real,
   stable ~1.5–2.2s server-side stall on every single mount, paid **twice**
   per real page view (dead render + connected mount, both uncached), for
   **every** connected node except the one (gb10) whose npm-registry path
   happens to be fast today. This is worse in kind than anything found last
   round because it's not an N+1 that only bites at scale — it bites on
   literally every visit, right now, at n=1. **Needs restructuring**
   (caching + `start_async`), but the caching primitive already exists
   elsewhere in this codebase (`Backend.Cache`), making it a
   moderate-effort, very-high-value fix.
2. **Terminals Show's redundant N-node `fan_out` for a single-DB lookup
   (§2b)** — not slow today (5–9× overhead on a call that's cheap either
   way), but structurally wrong (vestigial legacy-topology code) and a
   genuine multi-second latent stall risk if any connected node hangs,
   exactly the failure mode the task asked to flag "regardless of current
   timing." **Trivial one-line fix.**
3. **Triggers/Terminals Index's per-row `Cluster.node_name/1` (§1, §2a)** —
   the same bug class as the already-shipped Sessions Index fix from round
   1, just not yet ported to these two pages. Cheap today (7 and 4 rows
   respectively) for the same reason Sessions Index was cheap before its
   fix: not yet at scale. **Trivial dedupe-by-node fix**, same shape as the
   existing fix.

Everything else audited this round — Settings, Issues (Index + Show),
CommandPaletteLive, and Node Show's own two count queries — was already
fast and well-designed at current prod scale, several of them (Issues
Show's async attempts, Settings' button-gated backend-install actions)
explicitly built with the exact off-critical-path patterns this and the
prior report recommend. Two of those are documented above as **cleared
suspicions** the task specifically asked to look for and rule out, not
overlooked risks.

## Trivial vs. needs-restructuring

**Trivial (small, isolated, low-risk):**
- Terminals Show: replace `fan_out` with a direct `HubRPC.get_terminal/1`
  call.
- Triggers Index + Terminals Index: dedupe per-row `Cluster.node_name/1`
  calls by node (identical fix already proven on Sessions Index).

**Needs restructuring (moderate effort, high value):**
- Node Show: cache `BackendInstaller.status/0` per node with a TTL (mirror
  `Backend.Cache.get_or_run/3`, already used twice on this same page for a
  near-identical problem) and move it off the synchronous mount path via
  `start_async/3`; consider gating the whole config-loading block behind
  `connected?(socket)` so the dead-render pass doesn't pay it at all.

## Surprising findings

- **The single biggest problem this round isn't an N+1 at all — it's a
  synchronous, uncached shell-out to an external network service
  (`npm view`) that fires on every mount regardless of data volume.**
  Every other finding in both rounds so far has been "gets worse as X
  grows"; this one is already maximally bad at n=1 and simply doesn't
  improve no matter how few nodes/sessions/triggers exist.
- **The exact caching primitive needed to fix the #1 finding already exists
  in the same file, applied to two sibling problems on the very same
  page** (`Backend.available_on/1`/`models_for/2`, both already
  `Backend.Cache`-wrapped) — `BackendInstaller.status/0` is the one call on
  this page that was never given the same treatment.
- **Terminal scrollback, flagged by the task as a likely large-DOM
  candidate mirroring Session Show's problem, turned out to be a complete
  non-issue** — it never enters LiveView's render payload at all; it's
  delivered once via a bounded-size (64KB) Phoenix Channel join reply,
  architecturally separate from the mount/render cycle entirely.
- **A page that looks structurally identical to a slow one can be
  completely clean** — Settings touches the same "connected nodes" data as
  Node Show and even shares the same `Cluster`/`BackendInstaller` module
  dependencies, but because its backend-install-related work is
  button-triggered rather than mount-triggered, it's fast. The difference
  between these two pages is a good illustration of why "off the critical
  mount path" is the right default for anything that shells out or crosses
  a node boundary.
