# Supervision Tree

The supervision tree varies based on `OrcaHub.Mode` (hub vs agent). Both trees
are built by `OrcaHub.Application.start/2`: it picks `hub_children/1` or
`agent_children/1`, then appends `OrcaHub.Discord.children/0` (env-gated —
`[]` unless `DISCORD_BOT=true` and a Nostrum token are configured; this is
**not** mode-gated, so a hub node can in principle run the Discord bot too,
though in practice it runs on the dedicated `orca-agent-discord` agent pod).
The whole tree is one `Supervisor` (`OrcaHub.Supervisor`) with strategy
`:one_for_one`.

## Hub Mode (default)

```mermaid
graph TB
    App["OrcaHub.Application\n(Supervisor, one_for_one)"]

    App --> Telemetry["OrcaHubWeb.Telemetry\n(hub only)"]
    App --> Repo["OrcaHub.Repo\n(PostgreSQL, hub only)"]
    App --> DNS["DNSCluster"]
    App --> LibCluster["Cluster.Supervisor\n(libcluster)"]
    App --> PubSub["Phoenix.PubSub"]

    subgraph Registries["Registries"]
        SessionRegistry["SessionRegistry\n(:unique)"]
        MCPRegistry["MCPRegistry\n(:unique)"]
        TerminalRegistry["TerminalRegistry\n(:unique)"]
        ViewersRegistry["SessionViewersRegistry\n(:duplicate)"]
        JobRegistry["JobRegistry\n(:unique)"]
        BackendInstallerRegistry["BackendInstallerRegistry\n(:unique)"]
        EmailInboxRegistry["EmailInboxRegistry\n(:unique, hub only)"]
    end
    App --> Registries

    App --> BackendCache["OrcaHub.Backend.Cache"]
    App --> TaskSupervisor["Task.Supervisor"]
    App --> SessionHeartbeat["OrcaHub.SessionHeartbeat\n(hub only)"]
    App --> ChurnSampler["OrcaHub.ChurnSampler\n(hub only)"]
    App --> IndexSweep["OrcaHub.Issues.IndexSweep\n(hub only)"]
    App --> IndexTaskSup["Issues.Indexer\nIndexTaskSupervisor\n(capped, hub only)"]
    App --> PiModelSync["OrcaHub.PiModelSync\n(hub only)"]
    App --> WarmPool["OrcaHub.Streaming.WarmPool"]
    App --> SessionSupervisor["OrcaHub.SessionSupervisor\n(DynamicSupervisor)"]
    App --> SessionResumer["OrcaHub.SessionResumer"]
    App --> MemoryExtractionSweep["OrcaHub.MemoryExtractionSweep\n(hub only)"]
    App --> ForkGate["OrcaHub.ForkGate"]
    App --> TerminalSupervisor["OrcaHub.TerminalSupervisor\n(DynamicSupervisor)"]
    App --> JobSupervisor["OrcaHub.JobSupervisor\n(DynamicSupervisor)"]
    App --> JobResumer["OrcaHub.JobResumer"]
    App --> LeaseReaper["OrcaHub.Deploys.LeaseReaper\n(hub only)"]
    App --> LoginSupervisor["OrcaHub.LoginSupervisor\n(DynamicSupervisor)"]
    App --> BackendInstallerSupervisor["OrcaHub.BackendInstallerSupervisor\n(DynamicSupervisor)"]
    App --> MCPSupervisor["DynamicSupervisor\n(MCPSupervisor)"]
    App --> CodeExecGenerator["OrcaHub.MCP.CodeExec.Generator"]
    App --> CodeExecBindingStore["OrcaHub.MCP.CodeExec.BindingStore"]
    App --> SkillSync["OrcaHub.SkillSync"]
    App --> PiConfigSync["OrcaHub.PiConfigSync"]
    App --> MemoryGitServer["OrcaHub.MemoryGit.Server"]
    App --> UpstreamClient["OrcaHub.MCP.UpstreamClient\n(hub only)"]
    App --> Scheduler["OrcaHub.Scheduler\n(Quantum, hub only)"]
    App --> TriggerLoader["OrcaHub.TriggerLoader\n(hub only)"]
    App --> EmailInboxSupervisor["OrcaHub.EmailInboxSupervisor\n(DynamicSupervisor, hub only)"]
    App --> EmailInboxLoader["OrcaHub.EmailInboxLoader\n(hub only)"]
    App --> ClusterNodeTracker["OrcaHub.ClusterNodeTracker\n(hub only)"]
    App --> NodeDialer["OrcaHub.NodeDialer\n(hub only)"]
    App --> Endpoint["OrcaHubWeb.Endpoint"]
    App -.->|"DISCORD_BOT=true"| DiscordBot["OrcaHub.Discord.Bot\n(nostrum)"]

    SessionSupervisor -->|start_child| SR1["SessionRunner\n(GenStatem, one per session)"]
    TerminalSupervisor -->|start_child| TR1["TerminalRunner\n(GenServer, one per terminal)"]
    JobSupervisor -->|start_child| JW1["JobWatcher\n(GenServer, one per watched job)"]
    MCPSupervisor -->|start_child| MS1["MCP.Server\n(GenServer, one per MCP session)"]
    BackendInstallerSupervisor -->|start_child| BJ1["BackendInstaller.Job\n(GenServer, one per install/update)"]
    LoginSupervisor -->|start_child| LR1["LoginRunner / CodexLoginRunner"]
    EmailInboxSupervisor -->|start_child| EP1["EmailInbox.Poller\n(GenServer, one per inbox)"]

    SR1 -->|registered in| SessionRegistry
    MS1 -->|registered in| MCPRegistry
    TR1 -->|registered in| TerminalRegistry
    JW1 -->|registered in| JobRegistry
    EP1 -->|registered in| EmailInboxRegistry

    JW1 -.->|"polls sentinel/pid\n(process is NOT a child)"| DetachedProc["Detached OS process\n(setsid, own pgid)"]
    UpstreamClient -->|connects to| ExtMCP["External MCP\nServers"]
    Scheduler -->|fires| TriggerLoader
```

## Agent Mode (ORCA_MODE=agent)

Agent nodes omit `Telemetry`, `Repo`, `MCP.UpstreamClient`, `Scheduler`,
`TriggerLoader`, `SessionHeartbeat`, `ChurnSampler`, `MemoryExtractionSweep`,
`Issues.IndexSweep` (and the capped `Issues.Indexer` task supervisor),
`PiModelSync`, `Deploys.LeaseReaper`,
`ClusterNodeTracker`, `NodeDialer`, and the `EmailInbox*` children. All database operations are
proxied to the hub node via `HubRPC`. Everything else — including `Streaming.WarmPool`,
`ForkGate`, `TerminalSupervisor`, `JobSupervisor`/`JobResumer`,
`LoginSupervisor`, `SkillSync`/`PiConfigSync`/`MemoryGit.Server`, and the
`BackendInstaller*`/`MCP.CodeExec.*` children — runs on agent nodes too,
since sessions, terminals, jobs, backend installs, on-disk skill/pi-config
materialization, and code-exec tool calls all execute locally wherever the
runner process lives.

```mermaid
graph TB
    App["OrcaHub.Application\n(Supervisor, one_for_one)"]

    App --> DNS["DNSCluster"]
    App --> LibCluster["Cluster.Supervisor\n(libcluster)"]
    App --> PubSub["Phoenix.PubSub"]

    subgraph Registries["Registries"]
        SessionRegistry["SessionRegistry\n(:unique)"]
        MCPRegistry["MCPRegistry\n(:unique)"]
        TerminalRegistry["TerminalRegistry\n(:unique)"]
        ViewersRegistry["SessionViewersRegistry\n(:duplicate)"]
        JobRegistry["JobRegistry\n(:unique)"]
        BackendInstallerRegistry["BackendInstallerRegistry\n(:unique)"]
    end
    App --> Registries

    App --> BackendCache["OrcaHub.Backend.Cache"]
    App --> TaskSupervisor["Task.Supervisor"]
    App --> WarmPool["OrcaHub.Streaming.WarmPool"]
    App --> SessionSupervisor["OrcaHub.SessionSupervisor\n(DynamicSupervisor)"]
    App --> SessionResumer["OrcaHub.SessionResumer"]
    App --> ForkGate["OrcaHub.ForkGate"]
    App --> TerminalSupervisor["OrcaHub.TerminalSupervisor\n(DynamicSupervisor)"]
    App --> JobSupervisor["OrcaHub.JobSupervisor\n(DynamicSupervisor)"]
    App --> JobResumer["OrcaHub.JobResumer"]
    App --> LoginSupervisor["OrcaHub.LoginSupervisor\n(DynamicSupervisor)"]
    App --> BackendInstallerSupervisor["OrcaHub.BackendInstallerSupervisor\n(DynamicSupervisor)"]
    App --> MCPSupervisor["DynamicSupervisor\n(MCPSupervisor)"]
    App --> CodeExecGenerator["OrcaHub.MCP.CodeExec.Generator"]
    App --> CodeExecBindingStore["OrcaHub.MCP.CodeExec.BindingStore"]
    App --> SkillSync["OrcaHub.SkillSync"]
    App --> PiConfigSync["OrcaHub.PiConfigSync"]
    App --> MemoryGitServer["OrcaHub.MemoryGit.Server"]
    App --> Endpoint["OrcaHubWeb.Endpoint\n(MCP endpoint only)"]
    App -.->|"DISCORD_BOT=true"| DiscordBot["OrcaHub.Discord.Bot\n(nostrum)"]

    SessionSupervisor -->|start_child| SR1["SessionRunner\n(GenStatem)"]
    TerminalSupervisor -->|start_child| TR1["TerminalRunner\n(GenServer)"]
    JobSupervisor -->|start_child| JW1["JobWatcher\n(GenServer)"]
    MCPSupervisor -->|start_child| MS1["MCP.Server\n(GenServer)"]

    SR1 -->|registered in| SessionRegistry
    MS1 -->|registered in| MCPRegistry
    TR1 -->|registered in| TerminalRegistry
    JW1 -->|registered in| JobRegistry
```

## Key Modules Added Since the Original One-Shot-Only Design

- **`OrcaHub.Streaming.WarmPool`**: GenServer admission control for
  long-lived ("warm") streaming ports — caps concurrent warm processes per
  node (`ORCA_MAX_WARM_SESSIONS`, default 6) and evicts the LRU idle/error
  victim under pressure. See `.context/message-flow.md`.
- **`OrcaHub.SessionResumer`**: auto-resumes sessions orphaned in
  `status: "running"` after a node restart or deploy.
- **`OrcaHub.SessionHeartbeat`** (hub only): manages periodic heartbeat
  messages sessions schedule via MCP tools.
- **`OrcaHub.MemoryExtractionSweep`** (hub only): a single DELAYED ONE-SHOT
  check at boot, not a repeating timer — the backstop for
  `kind: "memory_extraction"` children orphaned by a restart landing between
  a child's turn ending and `SessionRunner`'s self-archive hook
  (`MemoryExtraction.finalize_self/2`) running. Hub-only where
  `SessionResumer` is per-node, because archiving an extraction child is a
  pure DB write no matter which node it ran on, so one sweep covers the whole
  cluster. Each stale child is archived with `extract_memories: false` (an
  extraction child must never itself trigger extraction) and its transcript
  file best-effort deleted via `Cluster.rpc/5` on its own `runner_node` — a
  failure there never blocks the archive.
- **`OrcaHub.ChurnSampler`** (hub only): every 120s it samples each
  non-archived `running` session's churn metrics (`OrcaHub.Sessions.Churn`)
  into the `churn_samples` table and emits a `[:orca_hub, :churn, :sample]`
  telemetry event for Grafana. Since 2026-09-19 that includes the QUALITATIVE
  half — batched `Sessions.FileSurgery.fetch_many/2` evidence plus what
  `Sessions.SurgeryAlertPolicy` would decide about alerting on it — which the
  sampler previously never computed at all, voiding `churn_suspected` on every
  older row (see `.context/data-model.md`). Bolted onto the tail of the same sweep,
  `ChurnSampler.AlertEvaluator` evaluates every enabled `alert_subscriptions`
  row and delivers rising-edge worker alerts to the subscribing orchestrator
  — see `.context/data-model.md`. Hub-only for the same reason as the
  heartbeat: two nodes sweeping would double-sample and double-alert. Each
  sweep is wrapped in `rescue`/log, so one bad session can't kill the timer
  loop.
- **`OrcaHub.Issues.IndexSweep`** (hub only): every 600s it reindexes at most
  20 issues whose pgvector index is behind their content
  (`issues.indexed_at`), stopping early at 400 embedded chunks — "20 issues"
  is not a bound on work when one `notes` blob is ~25 chunks. Hub-only for
  `ChurnSampler`'s reason: two nodes sweeping one table would duplicate the
  work and race each other's upserts. Deliberately does NOT repeat the
  failure mode `ChurnSampler`'s moduledoc warns about — no in-process state
  gates progress, since the watermark lives in Postgres, so a wholly failed
  tick changes nothing and the next one retries the same candidate set
  (observable from outside via `Issues.Indexer.stale_count/0`). The bulk
  counterpart is `OrcaHub.Issues.Backfill` (`mix orca.reindex_issues`, or
  `bin/orca_hub rpc` in prod), not a supervised child. Sitting next to it is
  the CAPPED `OrcaHub.Issues.IndexTaskSupervisor`
  (`Issues.Indexer.task_supervisor_spec/0`, also hub-only) that every
  write-hook `reindex_async/1` runs under: `max_children` is what stops a
  loop closing 20 issues from becoming 20 simultaneous requests to the one
  shared embedding box, and overflow is simply DROPPED — the sweep above is
  what reconciles it.
- **`OrcaHub.PiModelSync`** (hub only): hourly refresh of the `models` array
  on every `pi_config_entries` row of `kind: "provider"` that opted in with a
  `models_from` URL, resolved from the local LLM gateway's `/v1/models`. Three
  reasons it is hub-only, not just `ChurnSampler`'s: only the hub owns the DB,
  and agent pods cannot reach the gateway at all. The write fans out to every
  node through the existing `{:pi_config_updated}` broadcast that
  `PiConfigSync` already listens to. It only ever REFRESHES rows that already
  exist — it never creates a provider — and it never writes an empty list, so
  a gateway that has been down for a week is invisible on disk and shows up
  only as `models_refresh_error`.
- **`OrcaHub.Deploys.LeaseReaper`** (hub only): releases a deploy lease when
  its job ends. Hub-only for `MemoryExtractionSweep`'s reason — the
  `deploy_leases` table is the hub's and releasing is a pure DB write
  whichever node ran the deploy, so one reaper serves the cluster. It has two
  mechanisms because one of them is guaranteed to be missing: it subscribes to
  `"job:<id>"` for each deploy job it learns about (through a cluster-wide
  `"deploys"` broadcast, so a deploy started on an AGENT node still reaches
  it) and releases on `{:job_finished, …}`; and it runs a BOOT SWEEP, because
  a deploy of OrcaHub itself restarts this very process mid-flight and it
  comes back with an empty subscription set. There is deliberately no lease
  RENEWER — it would die with the same restart it exists to survive, which is
  why the lease has a TTL instead. See `.context/data-model.md`.
- **`OrcaHub.ForkGate`**: serializes forked pi children's FIRST turns, one
  FIFO per parent session — child N+1's first prompt goes out only after
  child N's first `result` event lands. A correctness mechanism, not an
  optimization: N concurrent same-prefix first turns get 1 warm cache hit and
  N−1 full cold prefills (`pi_fork_spec.md` §6/§6.1). Runs on hub + agent — a
  fork child runs wherever its parent does.
- **`OrcaHub.TerminalSupervisor`** / **`TerminalRegistry`**: per-node
  DynamicSupervisor + Registry for `TerminalRunner` PTY processes — see
  `.context/terminals.md`.
- **`OrcaHub.JobSupervisor`** / **`JobRegistry`** / **`OrcaHub.JobResumer`**:
  the Jobs subsystem (`OrcaHub.Jobs`) — durable records of DETACHED OS
  background processes. The processes themselves are deliberately NOT
  supervision children: `Jobs.Launcher` starts them with `setsid` in their own
  process group, stdout/stderr to a durable log and the exit code to a
  sentinel file, so they survive idle teardown, WarmPool eviction, and OrcaHub
  restarts entirely. The BEAM only ever OBSERVES one, via a disposable
  `JobWatcher` polling the sentinel/pid/declared progress metric.
  `JobResumer` re-attaches watchers to this node's non-terminal jobs on boot —
  the job-subsystem analog of `SessionResumer`.
- **`OrcaHub.LoginSupervisor`**: DynamicSupervisor for `LoginRunner` /
  `CodexLoginRunner` processes that drive interactive CLI login flows
  (`claude setup-token`, codex auth) from the web UI, one per in-progress
  login.
- **`OrcaHub.BackendInstallerSupervisor`** + **`BackendInstallerRegistry`**:
  DynamicSupervisor/Registry for `BackendInstaller.Job` processes that
  install/upgrade agent CLIs (claude/codex/pi) on a node, streaming progress
  via PubSub.
- **`OrcaHub.MCP.CodeExec.Generator`**: GenServer that (re)generates the
  in-memory `Tools` module exposing every MCP tool as a callable
  `Tools.<name>/1` Elixir function for `run_elixir` sandboxes.
- **`OrcaHub.MCP.CodeExec.BindingStore`**: GenServer persisting per-session
  Elixir variable bindings across `run_elixir` calls (REPL-like state).
- **`OrcaHub.SkillSync`** / **`OrcaHub.PiConfigSync`**: hub-DB-to-local-disk
  materializers, both running on EVERY node. No agent CLI supports remote
  config, so the hub DB is the source of truth and each node writes its own
  copy: `SkillSync` renders the `skills` table to `<home_root>/skills/<name>/
  SKILL.md` per installed backend, `PiConfigSync` renders `pi_config_entries`
  into `~/.pi/agent/` (`models.json` providers, `settings.json` keys, and
  files under `extensions/`/`prompts/`/`themes/`). Both keep an on-disk
  ownership manifest so a disabled/deleted row is removed rather than
  orphaned, and both boot-sync with bounded retry since an agent may not have
  hub connectivity yet.
- **`OrcaHub.MemoryGit.Server`**: serializes per-node git snapshot+sync passes
  over the on-disk agent memory stores (`~/.claude/projects/<slug>/memory/**`,
  `~/.codex/memories`), pushing to Gitea. Triggered by `SessionRunner` idle
  transitions; soft-degrades on a missing `git`/unreachable Gitea.
- **`OrcaHub.EmailInboxSupervisor`** / **`EmailInboxRegistry`** /
  **`OrcaHub.EmailInboxLoader`** (hub only): one `EmailInbox.Poller` per
  enabled `email_inboxes` row, IMAP-polling for messages that fire `type:
  "email"` triggers. Hub-only for the same reason as the scheduler — an
  inbox's credentials and its UID watermark are hub state, and two nodes
  polling one mailbox would race to fire the same trigger twice.
- **`OrcaHub.Backend.Cache`**: caches backend capability/model lookups.
- **`OrcaHub.ClusterNodeTracker`** (hub only): tracks Erlang node
  connect/disconnect events into the `nodes` table backing the Nodes UI —
  see `.context/clustering.md`.
- **`OrcaHub.NodeDialer`** (hub only): dials out every 5s to each `nodes` row
  flagged `dial: true` — see `.context/clustering.md`.
- **`OrcaHub.Discord.Bot`**: conditionally-started Nostrum gateway consumer;
  see `lib/orca_hub/discord/`.
