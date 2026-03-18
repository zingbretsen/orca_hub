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
