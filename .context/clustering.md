# Clustering Architecture

OrcaHub nodes connect via Erlang distribution. Each node keeps its own database,
registry, and supervisors. Cross-node visibility comes through `OrcaHub.Cluster`
which fans out queries via `:erpc` and routes actions to the owning node.

## Multi-Node Topology

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster"]
        subgraph Node1["k8s Node: debian"]
            OrcaA["OrcaHub Pod A<br/>orca@pod-ip-a"]
            DBA[(PostgreSQL A)]
            CLIA["Claude CLI"]
            OrcaA --> DBA
            OrcaA --> CLIA
        end

        subgraph Node2["k8s Node: nuc"]
            OrcaB["OrcaHub Pod B<br/>orca@pod-ip-b"]
            DBB[(PostgreSQL B)]
            CLIB["Claude CLI"]
            OrcaB --> DBB
            OrcaB --> CLIB
        end

        HeadlessSvc["Headless Service<br/>(DNS discovery)"]
        HeadlessSvc -.->|DNSPoll| OrcaA
        HeadlessSvc -.->|DNSPoll| OrcaB
    end

    subgraph LAN["Local Network"]
        Laptop["Laptop<br/>orca@192.168.x.x"]
        DBL[(PostgreSQL C)]
        CLIL["Claude CLI"]
        Laptop --> DBL
        Laptop --> CLIL
    end

    OrcaA <-->|"Erlang Distribution<br/>EPMD 4369 + ports 9100-9105"| OrcaB
    OrcaA <-->|"Erlang Distribution<br/>(static EPMD)"| Laptop
    OrcaB <-->|"Erlang Distribution"| Laptop
```

## Per-Node Architecture (unchanged)

```mermaid
graph TB
    subgraph EachNode["Each Node (independent)"]
        Repo["Ecto.Repo<br/>(own PostgreSQL)"]
        SR["SessionRegistry<br/>(local Registry)"]
        SS["SessionSupervisor<br/>(local DynamicSupervisor)"]
        Runners["SessionRunner<br/>processes"]
        PS["Phoenix.PubSub<br/>(auto-distributes via :pg)"]
        Sched["Quantum Scheduler<br/>(own triggers)"]
        EP["Phoenix Endpoint<br/>(own web UI)"]

        SS --> Runners
        Runners -->|register| SR
        Runners -->|broadcast| PS
        Runners -->|persist| Repo
        TE["TriggerExecutor"]
        Sched -->|fire triggers| TE
        TE --> SS
        EP -->|LiveView| PS
    end
```

## Cross-Node Query Flow

```mermaid
sequenceDiagram
    participant UI as LiveView<br/>(Node A)
    participant Cluster as OrcaHub.Cluster<br/>(Node A)
    participant NodeA as Sessions Context<br/>(Node A)
    participant NodeB as Sessions Context<br/>(Node B)
    participant Laptop as Sessions Context<br/>(Laptop)

    UI->>Cluster: list_sessions(filter)
    par Fan-out via :erpc
        Cluster->>NodeA: Sessions.list_sessions(filter)
        Cluster->>NodeB: Sessions.list_sessions(filter)
        Cluster->>Laptop: Sessions.list_sessions(filter)
    end
    NodeA-->>Cluster: [session1, session2]
    NodeB-->>Cluster: [session3]
    Laptop-->>Cluster: [session4, session5]
    Cluster->>Cluster: Tag with origin node,<br/>sort by updated_at
    Cluster-->>UI: [{nodeA, s1}, {nodeA, s2},<br/>{nodeB, s3}, {laptop, s4}, ...]
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
