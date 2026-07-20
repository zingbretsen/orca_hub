# Architecture Overview

```mermaid
graph TB
    subgraph Web["Web Layer"]
        Endpoint["OrcaHubWeb.Endpoint"]
        Router["Router"]
        SessionShow["SessionLive.Show"]
        SessionIndex["SessionLive.Index"]
        ProjectIndex["ProjectLive.Index"]
        ProjectShow["ProjectLive.Show"]
        IssueIndex["IssueLive.Index<br>(feature-request backlog)"]
        IssueShow["IssueLive.Show"]
        TriggerLive["TriggerLive.Index"]
        QueueLive["QueueLive"]
        UsageLive["UsageLive"]
        DashboardLive["DashboardLive"]
        SettingsLive["SettingsLive.Index"]
        NodeLive["NodeLive.Index / Show"]
        TerminalLive["TerminalLive.Index / Show"]
        CommandPalette["CommandPaletteLive"]
        MCPPlug["MCP.Plug (/mcp)"]
        WebhookCtrl["WebhookController"]
        TTSCtrl["TTSController"]
        ApiRunCtrl["ApiRunController<br>(/api/v1/runs)"]
    end

    subgraph Core["Core"]
        SessionRunner["SessionRunner<br>(GenStatem)"]
        HubRPC["HubRPC<br>(DB proxy)"]
        Mode["Mode<br>(hub/agent)"]
        Cluster["Cluster<br>(routing layer)"]
        Sessions["Sessions Context"]
        Projects["Projects Context"]
        Issues["Issues Context<br>(feature requests)"]
        Triggers["Triggers Context"]
        Terminals["Terminals Context"]
        ClusterNodes["ClusterNodes Context"]
        NodePolicy["NodePolicy<br>(isolation, env scrub, defaults)"]
        UpstreamServers["UpstreamServers Context"]
        Secrets["Secrets<br>(UpstreamSecret)"]
        ApiRuns["ApiRuns Context"]
        AgentPresence["AgentPresence"]
        SessionHeartbeat["SessionHeartbeat<br>(hub only)"]
        SessionResumer["SessionResumer"]
    end

    subgraph Backend["Backend Layer (pluggable agent CLIs)"]
        BackendBehaviour["Backend behaviour<br>+ Capabilities struct"]
        ClaudeAdapter["backend/claude.ex"]
        CodexAdapter["backend/codex.ex"]
        PiAdapter["backend/pi.ex"]
        ClaudeConfig["Claude.Config"]
        StreamParser["Claude.StreamParser"]
        JsonRpcFraming["Backend.JsonRpcFraming"]
        Usage["Claude.Usage"]
        BackendInstaller["BackendInstaller<br>+ Job + Supervisor"]
        LoginRunner["LoginRunner /<br>CodexLoginRunner"]
        BackendAuth["BackendAuth /<br>NodeCredentials"]
    end

    subgraph Streaming["Streaming Engine"]
        StreamingMod["Streaming<br>(kill switch, warm cap)"]
        WarmPool["Streaming.WarmPool"]
    end

    subgraph MCP["MCP Layer"]
        MCPServer["MCP.Server<br>(GenServer)"]
        MCPTools["MCP.Tools"]
        UpstreamClient["MCP.UpstreamClient<br>(GenServer)"]
        CodeExecMeta["CodeExec.MetaTools"]
        CodeExecSandbox["CodeExec.Sandbox +<br>Dispatcher"]
        CodeExecGenerator["CodeExec.Generator"]
        CodeExecBindingStore["CodeExec.BindingStore"]
        CodeExecToolSearch["CodeExec.ToolSearch /<br>Analyzer"]
    end

    subgraph Discord["Discord Bridge (opt-in, env-gated)"]
        DiscordBot["Discord.Bot<br>(nostrum)"]
        DiscordBridge["Discord.Bridge"]
    end

    subgraph Infra["Infrastructure"]
        PubSub["Phoenix.PubSub"]
        Repo["Ecto.Repo<br>(PostgreSQL, hub only)"]
        SessionSupervisor["SessionSupervisor<br>(DynamicSupervisor)"]
        TerminalSupervisor["TerminalSupervisor<br>(DynamicSupervisor)"]
        MCPSupervisor["MCPSupervisor<br>(DynamicSupervisor)"]
        Scheduler["Quantum Scheduler<br>(hub only)"]
        TriggerExecutor["TriggerExecutor"]
        TaskSupervisor["Task.Supervisor"]
        ClusterNodeTracker["ClusterNodeTracker<br>(hub only)"]
    end

    subgraph External["External"]
        ClaudeCLI["Claude CLI"]
        CodexCLI["Codex CLI"]
        PiCLI["pi CLI"]
        LLMApi["LLM API<br>(Title Gen)"]
        ElevenLabs["ElevenLabs API<br>(TTS)"]
        ExtMCPServers["Upstream MCP<br>Servers"]
        DiscordAPI["Discord Gateway"]
    end

    Endpoint --> Router
    Router --> SessionShow & SessionIndex & ProjectIndex & ProjectShow & IssueIndex & IssueShow
    Router --> TriggerLive & QueueLive & UsageLive & DashboardLive & SettingsLive & NodeLive & TerminalLive & CommandPalette
    Router --> MCPPlug & WebhookCtrl & TTSCtrl & ApiRunCtrl

    SessionShow -->|send_message| SessionRunner
    SessionRunner -->|broadcast| PubSub
    PubSub -->|events| SessionShow
    PubSub -->|status| SessionIndex

    SessionRunner -->|persist via| HubRPC
    HubRPC -->|hub: local call| Sessions & Projects & Issues & Triggers & Terminals & ClusterNodes
    HubRPC -.->|agent: erpc to hub| Repo
    Sessions & Projects & Issues & Triggers & Terminals & ClusterNodes --> Repo

    Cluster --> HubRPC
    SessionRunner -->|resolve engine| StreamingMod
    StreamingMod --> WarmPool
    WarmPool -->|evict/admit| SessionRunner

    SessionRunner -->|delegates CLI concerns to| BackendBehaviour
    BackendBehaviour --> ClaudeAdapter & CodexAdapter & PiAdapter
    ClaudeAdapter -->|build_args| ClaudeConfig
    ClaudeAdapter -->|parse ndjson| StreamParser
    CodexAdapter -->|parse jsonrpc| JsonRpcFraming
    ClaudeAdapter -->|open_port| ClaudeCLI
    CodexAdapter -->|open_port| CodexCLI
    PiAdapter -->|open_port| PiCLI
    SessionRunner -->|write/update| AgentPresence
    NodePolicy -->|isolation, env scrub, defaults| Sessions
    NodePolicy -->|reads| ClusterNodes

    BackendInstaller -->|installs/upgrades| ClaudeCLI & CodexCLI & PiCLI
    LoginRunner -->|drives auth flow| BackendAuth

    MCPPlug --> MCPServer
    MCPServer -->|code_exec off| MCPTools
    MCPServer -->|code_exec on| CodeExecMeta
    CodeExecMeta --> CodeExecSandbox
    CodeExecSandbox -->|generated Tools.*| CodeExecGenerator
    CodeExecSandbox --> CodeExecBindingStore
    CodeExecSandbox --> MCPTools & UpstreamClient
    CodeExecMeta --> CodeExecToolSearch
    MCPServer --> UpstreamClient
    MCPTools -->|persist via| HubRPC
    UpstreamClient --> UpstreamServers & Secrets
    UpstreamClient --> ExtMCPServers

    Scheduler --> TriggerExecutor
    WebhookCtrl -->|async via TaskSupervisor| TriggerExecutor
    TriggerExecutor --> SessionSupervisor
    SessionSupervisor --> SessionRunner
    TerminalSupervisor -.-> SessionRunner

    ApiRunCtrl --> ApiRuns
    ApiRuns --> SessionSupervisor

    DiscordAPI --> DiscordBot
    DiscordBot --> DiscordBridge
    DiscordBridge --> SessionSupervisor

    SessionHeartbeat -.->|schedules| SessionRunner
    SessionResumer -.->|resumes orphaned "running"| SessionSupervisor
    ClusterNodeTracker -.->|tracks node up/down| ClusterNodes

    UsageLive --> Usage
    TTSCtrl -.-> ElevenLabs
    SessionRunner -.->|title gen via| TaskSupervisor
    TaskSupervisor -.-> LLMApi
```

## Subsystem Notes

- **Backend Layer** (`lib/orca_hub/backend.ex` + `backend/*.ex`): a
  behaviour + `Capabilities` struct (`streaming`, `interrupt`, `mcp`,
  `resume`, `usage`, `plan_mode`, `ask_user_question`, `steering`, …) that
  every adapter implements. `SessionRunner` resolves `data.backend` once at
  init and never branches on the backend name string directly — UI chrome
  and model lists branch on `Capabilities` fields instead. See
  `.context/message-flow.md` for the spawn/normalize call sequence.
- **Streaming Engine** (`lib/orca_hub/streaming.ex`,
  `streaming/warm_pool.ex`): the default long-lived-port engine, with a
  per-node runtime kill switch and `WarmPool` admission control. See
  `.context/message-flow.md`.
- **MCP CodeExec Layer** (`lib/orca_hub/mcp/code_exec/`): when a session has
  `code_exec: true` (default), its MCP tool surface collapses to
  `run_elixir`/`search_tools`/passthroughs; other tools are called as
  generated `Tools.<name>/1` Elixir functions inside a sandboxed
  `run_elixir` eval. See `.context/message-flow.md`.
- **NodeLive + NodePolicy**: `/nodes` (`NodeLive.Index`/`Show`) manages the
  `nodes` table and lets an operator install/upgrade backends across nodes.
  `OrcaHub.NodePolicy` resolves per-node isolation, session env scrubbing
  (allow-list merged from node + project), and default backend/model
  applied in `Sessions.create_session/1`. See `.context/clustering.md`.
- **BackendInstaller**: installs/upgrades agent CLIs (claude/codex/pi) on a
  target node via `Cluster.rpc`, one `BackendInstaller.Job` per install,
  streaming progress over PubSub.
- **Login / BackendAuth / NodeCredentials**: `LoginRunner`/
  `CodexLoginRunner` drive interactive CLI login (`claude setup-token`,
  codex auth) from the web UI; `NodeCredentials` persists the resulting
  per-node OAuth tokens.
- **Secrets**: `OrcaHub.Secrets` + `UpstreamSecret` schema — values injected
  into upstream MCP tool call headers at call time when an `UpstreamServer`
  has `secret_injection: true`.
- **Discord Bridge** (`lib/orca_hub/discord/`): a Nostrum gateway bot
  (env-gated by `DISCORD_BOT`/`DISCORD_BOT_TOKEN`) whose `Bridge` module
  maps a Discord channel to a session — auto-provisioning a project/session
  on an unmapped channel — sends the @-mention in, and posts the reply back.
- **Agent Runs API** (`lib/orca_hub/api_runs.ex`,
  `api_run_controller.ex`, `POST/GET /api/v1/runs`): an async-poll HTTP API
  — create a run, poll `GET /api/v1/runs/:id` for `running`/`completed`/
  `failed`/`timed_out`, with optional JSON-schema validation + retry.
- **SessionHeartbeat** (hub only) / **SessionResumer**: heartbeat delivers
  scheduled reminder messages into a session; resumer recovers sessions
  stuck in `status: "running"` after a node restart or deploy.
- **ClusterNodeTracker** (hub only): tracks Erlang node connect/disconnect
  events into the `nodes` table backing `NodeLive`.

## Data Flow Summary

1. User sends a message via `SessionLive.Show` → `SessionRunner`.
2. `SessionRunner` resolves the engine (streaming vs one-shot) and delegates
   spawn/encode/normalize to the session's `Backend` adapter.
3. Events are persisted (via `HubRPC`, proxying to the hub `Repo` on agent
   nodes) and broadcast over `PubSub` back to every subscribed LiveView.
4. Tool calls from the CLI go through `MCP.Plug` → `MCP.Server`, either
   directly to `MCP.Tools`/`MCP.UpstreamClient` or — in the default
   code-exec mode — through the `CodeExec` sandbox layer first.
5. `TriggerExecutor` (cron via `Scheduler`, or webhook via `WebhookController`)
   and the Discord `Bridge` are the two non-UI entry points that create or
   message sessions; both ultimately go through `SessionSupervisor` →
   `SessionRunner` like a manual send.
