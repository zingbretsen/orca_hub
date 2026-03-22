# Clustering Architecture

OrcaHub supports a **hub + agent** topology. One hub node owns the database
and runs the full stack (scheduler, triggers, web UI). Agent nodes are
lightweight — they run SessionRunner processes and forward all database
operations to the hub via `HubRPC` (which uses `:erpc` under the hood).

The mode is set via `ORCA_MODE=agent` (default: `hub`). `OrcaHub.Mode`
exposes `hub?()` / `agent?()` and discovers the hub node at runtime.

## Hub + Agent Topology

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster"]
        subgraph Node1["k8s Node: debian (hub)"]
            OrcaA["OrcaHub Pod A<br/>orca@pod-ip-a<br/>ORCA_MODE=hub"]
            DBA[(PostgreSQL)]
            CLIA["Claude CLI"]
            OrcaA --> DBA
            OrcaA --> CLIA
        end

        subgraph Node2["k8s Node: nuc (agent)"]
            OrcaB["OrcaHub Pod B<br/>orca@pod-ip-b<br/>ORCA_MODE=agent"]
            CLIB["Claude CLI"]
            OrcaB --> CLIB
        end

        HeadlessSvc["Headless Service<br/>(DNS discovery)"]
        HeadlessSvc -.->|DNSPoll| OrcaA
        HeadlessSvc -.->|DNSPoll| OrcaB
    end

    subgraph LAN["Local Network"]
        Laptop["Laptop<br/>orca@192.168.x.x<br/>ORCA_MODE=hub"]
        DBL[(PostgreSQL)]
        CLIL["Claude CLI"]
        Laptop --> DBL
        Laptop --> CLIL
    end

    OrcaA <-->|"Erlang Distribution<br/>EPMD 4369 + ports 9100-9105"| OrcaB
    OrcaA <-->|"Erlang Distribution<br/>(static EPMD)"| Laptop
    OrcaB <-->|"Erlang Distribution"| Laptop
    OrcaB -.->|"HubRPC (erpc)<br/>all DB operations"| OrcaA
```

## Hub Node Architecture

```mermaid
graph TB
    subgraph HubNode["Hub Node (full stack)"]
        Repo["Ecto.Repo<br/>(PostgreSQL)"]
        SR["SessionRegistry<br/>(local Registry)"]
        SS["SessionSupervisor<br/>(local DynamicSupervisor)"]
        Runners["SessionRunner<br/>processes"]
        PS["Phoenix.PubSub<br/>(auto-distributes via :pg)"]
        Sched["Quantum Scheduler"]
        TL["TriggerLoader"]
        EP["Phoenix Endpoint<br/>(web UI)"]
        MCP["MCP.Server + UpstreamClient"]

        SS --> Runners
        Runners -->|register| SR
        Runners -->|broadcast| PS
        Runners -->|persist via HubRPC| Repo
        TE["TriggerExecutor"]
        Sched -->|fire triggers| TE
        TE --> SS
        EP -->|LiveView| PS
    end
```

## Agent Node Architecture

```mermaid
graph TB
    subgraph AgentNode["Agent Node (lightweight)"]
        SR2["SessionRegistry<br/>(local Registry)"]
        SS2["SessionSupervisor<br/>(local DynamicSupervisor)"]
        Runners2["SessionRunner<br/>processes"]
        PS2["Phoenix.PubSub<br/>(auto-distributes via :pg)"]
        EP2["Phoenix Endpoint<br/>(MCP endpoint)"]
        HubRPC["HubRPC<br/>(erpc proxy to hub)"]

        SS2 --> Runners2
        Runners2 -->|register| SR2
        Runners2 -->|broadcast| PS2
        Runners2 -->|persist via| HubRPC
        EP2 -->|MCP requests| PS2
    end

    HubNode["Hub Node"]
    HubRPC -.->|":erpc.call"| HubNode
```

## Query Flow (Hub + Agent)

```mermaid
sequenceDiagram
    participant UI as LiveView<br/>(Any Node)
    participant Cluster as OrcaHub.Cluster
    participant HubRPC as HubRPC
    participant Hub as Hub Node<br/>(Sessions Context)

    UI->>Cluster: list_sessions(filter)
    Cluster->>HubRPC: list_sessions(filter)
    alt Hub node (local)
        HubRPC->>Hub: Sessions.list_sessions(filter)
    else Agent node
        HubRPC->>Hub: :erpc.call(hub, Sessions, :list_sessions, [filter])
    end
    Hub-->>HubRPC: [session1, session2, session3]
    HubRPC-->>Cluster: sessions
    Cluster->>Cluster: Tag each session with<br/>runner_node_for(session),<br/>sort by updated_at
    Cluster-->>UI: [{nodeA, s1}, {nodeB, s2}, ...]
```

## Cross-Node Action Routing

```mermaid
sequenceDiagram
    participant UI as LiveView<br/>(Node A)
    participant Cluster as OrcaHub.Cluster<br/>(Node A)
    participant Runner as SessionRunner<br/>(Node B)

    UI->>Cluster: send_message(nodeB, session_id, prompt)
    Cluster->>Runner: :erpc.call(nodeB, SessionRunner, :send_message, ...)
    Runner->>Runner: Opens port, runs Claude CLI
    Runner-->>Cluster: :ok
    Note over Runner,UI: PubSub events flow back<br/>automatically via :pg
```

## Hub vs Agent: Component Comparison

| Component | Hub | Agent | Notes |
|-----------|-----|-------|-------|
| **Ecto.Repo (PostgreSQL)** | Yes | No | Agent proxies all DB ops via HubRPC |
| **Phoenix Endpoint** | Full web UI | MCP endpoint only | Agent needs HTTP for Claude CLI MCP |
| **Telemetry** | Yes | No | |
| **SessionSupervisor** | Yes | Yes | Both nodes run Claude CLI sessions |
| **SessionRegistry** | Yes | Yes | Local registry per node |
| **TerminalSupervisor** | Yes | Yes | Both nodes run terminal PTYs |
| **TerminalRegistry** | Yes | Yes | Local registry per node |
| **MCPSupervisor** | Yes | Yes | Per-session MCP servers |
| **MCP.UpstreamClient** | Yes | No | Upstream MCP connections hub-only |
| **Quantum Scheduler** | Yes | No | Cron triggers fire on hub only |
| **TriggerLoader** | Yes | No | Syncs triggers into scheduler on boot |
| **PubSub** | Yes | Yes | Auto-distributes via `:pg` |
| **Task.Supervisor** | Yes | Yes | Async work (title gen, archival) |
| **libcluster** | Yes | Yes | Both participate in discovery |
| **AgentPresence** | Cleanup on boot | Write only | Hub cleans stale `.agents/` files |

### Key Modules

- **`OrcaHub.Mode`**: Returns `:hub` or `:agent` based on `ORCA_MODE` env var (default: `:hub`). `hub_node/0` returns self on hub, discovers hub via `:erpc` on agent.
- **`OrcaHub.HubRPC`**: Transparent proxy — calls locally on hub, forwards via `:erpc.call/5` on agent. Wraps all context modules (Sessions, Projects, Issues, Feedback, Triggers, Terminals).
- **`OrcaHub.Cluster`**: Routing layer used by LiveViews and other callers. Queries go through HubRPC (single DB), actions route to the correct runner node via `rpc/5`.

### Node Routing

All entities are routed to their owning node through two fields:

- **Sessions/Terminals**: `runner_node` field (string) on the record itself. Resolved by `Cluster.runner_node_for/1`.
- **Projects/Issues/Triggers**: `node` field on the associated project. Resolved by `Cluster.project_node_for/1`. Triggers inherit routing from their project (`trigger → project → project.node`).

If the stored node is not in the current cluster, routing falls back to the local node.

### What Agents Cannot Do

Agent nodes are intentionally limited:

- **No direct DB access** — all reads/writes go through HubRPC to the hub
- **No trigger scheduling** — cron jobs only fire on the hub (but execution routes to the correct agent)
- **No upstream MCP connections** — `MCP.UpstreamClient` is hub-only
- **No web UI** — the Endpoint runs but only serves the MCP HTTP endpoint for Claude CLI
- **No agent presence cleanup** — hub handles stale `.agents/` file cleanup on boot

## Discovery Strategies

```mermaid
graph LR
    subgraph Strategies["libcluster topologies (run simultaneously)"]
        DNS["DNSPoll Strategy<br/>CLUSTER_DNS_QUERY env var<br/>(k8s headless service)"]
        EPMD["Epmd Strategy<br/>CLUSTER_NODES env var<br/>(static list for LAN nodes)"]
    end

    DNS -->|discovers| K8sPods["k8s Pods"]
    EPMD -->|connects to| LaptopNode["Laptop / External Nodes"]
```
