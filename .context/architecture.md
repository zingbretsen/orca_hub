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
        IssueIndex["IssueLive.Index"]
        IssueShow["IssueLive.Show"]
        TriggerLive["TriggerLive.Index"]
        QueueLive["QueueLive"]
        UsageLive["UsageLive"]
        DashboardLive["DashboardLive"]
        SettingsLive["SettingsLive.Index"]
        MCPPlug["MCP.Plug"]
        WebhookCtrl["WebhookController"]
        TTSCtrl["TTSController"]
    end

    subgraph Core["Core"]
        SessionRunner["SessionRunner\n(GenStatem)"]
        Sessions["Sessions Context"]
        Projects["Projects Context"]
        Issues["Issues Context"]
        Feedback["Feedback Context"]
        Triggers["Triggers Context"]
        UpstreamServers["UpstreamServers Context"]
        AgentPresence["AgentPresence"]
    end

    subgraph Claude["Claude Integration"]
        Config["Claude.Config"]
        StreamParser["Claude.StreamParser"]
        Usage["Claude.Usage"]
    end

    subgraph MCP["MCP Layer"]
        MCPServer["MCP.Server\n(GenServer)"]
        MCPTools["MCP.Tools"]
        UpstreamClient["MCP.UpstreamClient\n(GenServer)"]
    end

    subgraph Infra["Infrastructure"]
        PubSub["Phoenix.PubSub"]
        Repo["Ecto.Repo\n(PostgreSQL)"]
        SessionSupervisor["SessionSupervisor\n(DynamicSupervisor)"]
        MCPSupervisor["MCPSupervisor\n(DynamicSupervisor)"]
        Scheduler["Quantum Scheduler"]
        TriggerExecutor["TriggerExecutor"]
        TaskSupervisor["Task.Supervisor"]
    end

    subgraph External["External"]
        ClaudeCLI["Claude CLI\n(Port)"]
        LLMApi["LLM API\n(Title Gen)"]
        ElevenLabs["ElevenLabs API\n(TTS)"]
        ExtMCPServers["Upstream MCP\nServers"]
    end

    Endpoint --> Router
    Router --> SessionShow & SessionIndex & ProjectIndex & ProjectShow & IssueIndex & IssueShow & TriggerLive & QueueLive & UsageLive & DashboardLive & SettingsLive
    Router --> MCPPlug & WebhookCtrl & TTSCtrl

    SessionShow -->|send_message| SessionRunner
    SessionRunner -->|broadcast| PubSub
    PubSub -->|events| SessionShow
    PubSub -->|status| SessionIndex

    SessionRunner -->|persist| Sessions
    Sessions --> Repo
    Projects --> Repo
    Issues --> Repo
    Feedback --> Repo
    Triggers --> Repo

    SessionRunner -->|build_args| Config
    SessionRunner -->|parse output| StreamParser
    SessionRunner -->|open_port| ClaudeCLI
    SessionRunner -->|write/update| AgentPresence

    MCPPlug --> MCPServer
    MCPServer --> MCPTools
    MCPTools --> Sessions & Issues & Feedback & Triggers & Projects
    MCPServer --> UpstreamClient
    UpstreamClient --> UpstreamServers
    UpstreamClient --> ExtMCPServers

    Scheduler --> TriggerExecutor
    WebhookCtrl -->|async via TaskSupervisor| TriggerExecutor
    TriggerExecutor --> SessionSupervisor
    SessionSupervisor --> SessionRunner

    UsageLive --> Usage
    TTSCtrl -.-> ElevenLabs
    SessionRunner -.->|title gen via| TaskSupervisor
    TaskSupervisor -.-> LLMApi
```
