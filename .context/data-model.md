# Data Model

```mermaid
erDiagram
    Project ||--o{ Session : has
    Project ||--o{ Issue : has
    Project ||--o{ Trigger : has
    Project ||--o{ Terminal : has
    Project ||--o{ DiscordChannel : maps
    Project }o--o{ UpstreamServer : "via ProjectUpstreamServer"

    Session ||--o{ Message : contains
    Session ||--o{ SessionInteraction : "sends (sender_session_id)"
    Session ||--o{ SessionInteraction : "receives (recipient_session_id)"
    Session ||--o| ApiRun : backs
    Session ||--o| DiscordChannel : "bound to"
    Session }o--o{ UpstreamServer : "via SessionUpstreamServer"

    Trigger }o--o| Session : "last_session (plain FK, no assoc)"

    Project {
        binary_id id PK
        string name
        string directory
        string node "owning node for directory"
        array env_allowlist "merged with owning node's env_allowlist"
        utc_datetime deleted_at "soft delete"
    }

    Session {
        binary_id id PK
        string directory
        string claude_session_id "CLI/native resume ID"
        string title "auto-generated"
        string status "ready|idle|running|waiting|error|compacting"
        string model
        string backend "claude|codex|pi"
        boolean orchestrator
        boolean code_exec "default true; gates MCP meta-tools mode"
        binary_id parent_session_id "spawning parent; plain field, no assoc"
        boolean notify_parent
        boolean streaming "nil = fall back to node/env default"
        string tools
        string error_detail
        string progress_phase
        string progress_note
        utc_datetime progress_updated_at
        string idempotency_key "dedupes retried spawn/send calls"
        boolean triggered
        integer priority "queue ordering"
        string runner_node "node running this session"
        string original_node "node the session was first created on"
        utc_datetime archived_at "soft archive"
        binary_id project_id FK
        binary_id issue_id "orphaned DB column, not cast/used"
    }

    Message {
        binary_id id PK
        map data "flexible JSON: type, content, tool_use, etc."
        binary_id session_id FK
    }

    Issue {
        binary_id id PK
        string title "agent-filed, prefixed [agent-fr]"
        string description
        string status "open|in_progress|closed"
        string approaches_tried "append-only"
        string notes "append-only"
        binary_id project_id FK
    }

    Trigger {
        binary_id id PK
        string name
        string prompt
        string type "scheduled|webhook"
        string cron_expression
        string webhook_secret "auto-generated"
        boolean reuse_session
        boolean archive_on_complete
        boolean enabled
        binary_id last_session_id "plain field, not association"
        utc_datetime last_fired_at
        binary_id project_id FK
    }

    Terminal {
        binary_id id PK
        string name
        string directory
        string shell "default /bin/bash"
        string status "stopped|running|dead"
        string runner_node
        integer cols
        integer rows
        binary_id project_id FK
    }

    ApiRun {
        binary_id id PK
        string status "running|completed|failed|timed_out"
        map result
        string result_text
        string error
        map result_schema "optional JSON-schema to validate result against"
        integer timeout_seconds
        integer validation_attempts
        integer max_validation_attempts
        binary_id session_id FK
    }

    DiscordChannel {
        binary_id id PK
        string discord_channel_id
        boolean enabled
        string parent_channel_id
        string last_seen_message_id
        binary_id project_id FK
        binary_id session_id FK
    }

    SessionInteraction {
        binary_id id PK
        string kind "default message"
        binary_id sender_session_id FK
        binary_id recipient_session_id FK
    }

    UpstreamServer {
        binary_id id PK
        string name
        string url
        map headers "auth headers"
        string prefix "tool namespace"
        boolean enabled
        boolean global "available to every session by default"
        boolean session_scoped "opt-in per session rather than global"
        boolean secret_injection "headers resolved from UpstreamSecret at call time"
    }

    ProjectUpstreamServer {
        binary_id project_id FK
        binary_id upstream_server_id FK
    }

    SessionUpstreamServer {
        binary_id session_id FK
        binary_id upstream_server_id FK
    }

    ClusterNode {
        binary_id id PK
        string name "Erlang node name, e.g. orca@10.0.0.5; unique"
        string display_name
        utc_datetime first_connected_at
        utc_datetime last_connected_at
        boolean isolated "blocks this node from initiating cross-node calls"
        boolean scrub_session_env "spawn sessions/terminals with allow-listed env only"
        array env_allowlist "extra vars let through when scrub_session_env is true"
        string default_backend
        string default_model
    }

    NodeCredential {
        binary_id id PK
        string node_name "loose match on ClusterNode.name, not FK"
        string oauth_token
    }

    UpstreamSecret {
        binary_id id PK
        string key
        binary value_encrypted
    }
```

## Notes

- **Issue is now the agent-filed feature-request backlog, not a "worked by sessions" concept.** The full Issues feature (UI, routes, session linkage) was removed in commit `3ebb3fe`; the schema was minimally reintroduced to back `OrcaHub.MCP.Tools.FeatureRequests`, an MCP tool agents use to file/list/annotate/close platform-friction reports (titles prefixed `[agent-fr] `, deduped by title similarity). `Session` no longer has an `issue_id` association or cast — the `issue_id` column still exists on the `sessions` table (from the original migration) but is dead weight, not read or written by the schema.
- **`ClusterNode` (`nodes` table), `NodeCredential`, and `UpstreamSecret` are not linked by Ecto foreign keys** to the entities above — they're matched by name string (`ClusterNode.name` against `Session.runner_node` / `Project.node`; `NodeCredential.node_name` against `ClusterNode.name`), not `belongs_to`/`references`. They're drawn standalone in the diagram for that reason.
- **`SessionInteraction`** captures direct session→session messaging edges (e.g. via `send_message_to_session`), distinct from `Session.parent_session_id`, which captures spawn/parent-child lineage instead.
- **`env_allowlist`** on both `Project` and `ClusterNode` are unioned (deduped), not one overriding the other — see `.context/clustering.md`.
- Full Issues feature history and the current feature-request tool surface: `OrcaHub.MCP.Tools.FeatureRequests` (`lib/orca_hub/mcp/tools/feature_requests.ex`).
