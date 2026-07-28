# A2A (Agent2Agent) server

An inbound A2A v0.3.0 JSON-RPC server surface: external services can
dispatch work to OrcaHub agents over the standard A2A protocol instead of
the OrcaHub-specific [Agent Runs API](api.md). First consumer: `voice_prompt`,
which speaks A2A generically to reach multiple backends.

This is a separate, independent surface from the Agent Runs API — separate
task model (`a2a_tasks`, not `api_runs`), separate endpoints, no shared
state. See "Roadmap / not in v1" below for where the two overlap and how
that boundary is expected to move over time.

## Agents = projects

An A2A "agent" is an OrcaHub **project**. The agent id is the project id
(a UUID). There's no separate "agent" concept to configure — every non-
deleted project is automatically discoverable and dispatchable as an agent.
A `message/send` against an agent creates a new OrcaHub session in that
project's directory (or continues an existing one — see below).

## Auth

Same static bearer token as the Agent Runs API:

```
Authorization: Bearer <ORCA_API_TOKEN>
```

Set `ORCA_API_TOKEN` to enable it. Unset/empty → `503 {"error": "API disabled"}`.
Missing/incorrect token → `401 {"error": "unauthorized"}`.

## Hub-only

This surface needs the database directly and is **not** on the agent-mode
HTTP allow-list (`OrcaHubWeb.Endpoint.agent_mode_allowed?/1`) — it only
runs on the hub node, same as the rest of the DB-backed web UI. Point
callers at the hub's URL, not an agent node's.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/a2a/agents` | List every non-deleted project as an agent |
| `GET` | `/a2a/agents/:id/.well-known/agent-card.json` | A2A agent card for one project |
| `POST` | `/a2a/agents/:agent_id` | JSON-RPC 2.0 endpoint — `message/send`, `tasks/get`, `tasks/cancel` |

### `GET /a2a/agents`

```json
{"agents": [{"id": "…", "name": "…", "description": "/path/to/project"}]}
```

`description` is the project's directory (or `null`).

### `GET /a2a/agents/:id/.well-known/agent-card.json`

```json
{
  "name": "my-project",
  "description": "/home/me/my-project",
  "url": "https://orca.example/a2a/agents/<project-id>",
  "protocolVersion": "0.3.0",
  "capabilities": {"streaming": false, "pushNotifications": false},
  "defaultInputModes": ["text/plain"],
  "defaultOutputModes": ["text/plain"],
  "skills": [{"id": "run-session", "name": "…", "description": "…", "tags": ["agent", "coding"]}]
}
```

`404 {"error": "agent not found"}` for an unknown/deleted project id.

### `POST /a2a/agents/:agent_id` — JSON-RPC 2.0

Standard JSON-RPC envelope in, envelope out:

```json
{"jsonrpc": "2.0", "id": 1, "method": "message/send", "params": {"...": "..."}}
```

```json
{"jsonrpc": "2.0", "id": 1, "result": {"...": "..."}}
```

or

```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": "…"}}
```

JSON-RPC errors are returned with **HTTP 200** (standard JSON-RPC practice
— the transport succeeded, the RPC call itself failed). Error codes:

| Code | Meaning |
|---|---|
| `-32600` | Invalid Request — `jsonrpc` isn't `"2.0"` |
| `-32601` | Method not found |
| `-32602` | Invalid params (e.g. no text parts in `message.parts`, or `message.taskId` given instead of `contextId`) |
| `-32001` | Task not found (unknown/malformed task id on `tasks/get`/`tasks/cancel`; also used for an unknown/foreign `contextId` on `message/send` — see below) |
| `-32002` | Task not cancelable (already terminal) |
| `-32003` | Push notifications not supported (`tasks/pushNotificationConfig/*`) |
| `-32004` | Unsupported operation (`message/stream`, `tasks/resubscribe`, `tasks/list` — no streaming/subscriptions) |
| `-32000` | Server error (e.g. the session's assigned node isn't currently connected) |

A `404 {"error": "agent not found"}` (plain HTTP, not a JSON-RPC error) is
returned instead of dispatching at all when `:agent_id` doesn't match a
non-deleted project.

## `message/send`

```json
{
  "message": {
    "messageId": "…",
    "role": "user",
    "parts": [{"kind": "text", "text": "What is 2+2?"}]
  }
}
```

Only `"kind": "text"` parts are read; their text is concatenated (in order)
to form the prompt. `400`/`-32602` if there's no non-empty text part.

- **No `contextId`**: starts a **new** OrcaHub session in the agent's
  project directory. The session's title is a truncated first line of the
  prompt text.
- **`contextId` present**: continues an **existing** session — `contextId`
  IS the session id (see "contextId == session id" below). The session must
  belong to the same agent (project); a `contextId` for a session in a
  different project, or one that doesn't exist, is rejected `-32001`.
- **`message.taskId`**: not supported for follow-ups and rejected
  `-32602` — one OrcaHub A2A task maps to exactly one turn, so there's no
  "add another message to an existing task" concept. Use `contextId`
  (the *session's* id) to continue a conversation across multiple tasks
  instead.

Response `result` is a task object in state `"submitted"` or `"working"`
(see "Task object shape" below) — poll `tasks/get` to drive it forward.

## `tasks/get`

```json
{"id": "<task id>"}
```

Poll-driven, like the Agent Runs API's `GET /api/v1/runs/:id`: **every call
advances the task's state** — there's no background process pushing it
forward. Returns the current task object. Unknown/malformed `id` → `-32001`.

## `tasks/cancel`

```json
{"id": "<task id>"}
```

Best-effort interrupts the underlying session's in-flight turn and marks
the task `"canceled"`. A task that's already terminal
(`completed`/`failed`/`canceled`) can't be canceled — `-32002`.

## Task object shape

```json
{
  "id": "<task id>",
  "contextId": "<session id>",
  "kind": "task",
  "status": {
    "state": "submitted | working | completed | failed | canceled",
    "timestamp": "2026-07-28T12:00:00Z",
    "message": {
      "role": "agent",
      "messageId": "…",
      "parts": [{"kind": "text", "text": "the agent's reply"}],
      "kind": "message"
    }
  }
}
```

`status.message` is only present on a `"completed"` task (the final
assistant text) or a `"failed"` one that has error text — omitted
otherwise. `submitted` means the task was created but no turn activity has
been observed yet; `working` means the session is actively processing (or
mid-turn but not yet re-polled since submission).

## `contextId` == session id, one task per turn

There is no separate "A2A context" concept layered on top — an A2A
`contextId` **is** the OrcaHub `session.id`, directly. Each `message/send`
call (new or continuation) creates exactly one new `a2a_tasks` row mapped
1:1 to one session turn; a multi-turn conversation is a sequence of tasks
sharing the same `contextId`, exactly mirroring how the Agent Runs API's
`session_id` continuation works.

## Example: create → poll → continue → poll

```bash
curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "message/send",
    "params": {"message": {"messageId": "m1", "role": "user",
      "parts": [{"kind": "text", "text": "What is 2+2?"}]}}
  }'
# {"jsonrpc":"2.0","id":1,"result":{"id":"task-1","contextId":"sess-1","kind":"task","status":{"state":"submitted","timestamp":"…"}}}

curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 2, "method": "tasks/get", "params": {"id": "task-1"}}'
# {"jsonrpc":"2.0","id":2,"result":{"id":"task-1","contextId":"sess-1","kind":"task",
#  "status":{"state":"completed","timestamp":"…",
#    "message":{"role":"agent","messageId":"…","parts":[{"kind":"text","text":"4"}],"kind":"message"}}}}

# Continue the same conversation — contextId is sess-1 from above.
curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0", "id": 3, "method": "message/send",
    "params": {"message": {"messageId": "m2", "role": "user", "contextId": "sess-1",
      "parts": [{"kind": "text", "text": "Now multiply that by 10."}]}}
  }'
# {"jsonrpc":"2.0","id":3,"result":{"id":"task-2","contextId":"sess-1","kind":"task","status":{"state":"submitted","timestamp":"…"}}}

curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 4, "method": "tasks/get", "params": {"id": "task-2"}}'
# {"jsonrpc":"2.0","id":4,"result":{"id":"task-2","contextId":"sess-1","kind":"task",
#  "status":{"state":"completed","timestamp":"…",
#    "message":{"role":"agent","messageId":"…","parts":[{"kind":"text","text":"40"}],"kind":"message"}}}}
```

## Example: cancel

```bash
curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 5, "method": "tasks/cancel", "params": {"id": "task-2"}}'
# {"jsonrpc":"2.0","id":5,"result":{"id":"task-2","contextId":"sess-1","kind":"task","status":{"state":"canceled","timestamp":"…"}}}
```

## OrcaHub as an A2A client, too

`OrcaHub.A2A` (`lib/orca_hub/a2a.ex`) is the matching **outbound** client —
the same module OrcaHub uses to call *other* A2A-speaking services (e.g.
phx-app). It's wire-compatible with this server: `OrcaHub.A2A.send_message/4`,
`get_task/3`, `cancel_task/3`, and `reply_text/1` all work unmodified
against this controller (see the symmetry test in
`test/orca_hub_web/controllers/a2a_controller_test.exs`), so OrcaHub could
in principle call its own `/a2a` endpoint, or another OrcaHub instance's.

## Roadmap / not in v1

This v1 deliberately covers the plain text-in/text-out conversational
subset of A2A. A few things stay out of scope for now and remain on the
[Agent Runs API](api.md) instead:

- **A2A protocol-level artifacts** — A2A's `artifact` concept (structured,
  named outputs attached to a task, distinct from the reply message) isn't
  implemented. Only `status.message` text parts are produced.
- **Structured/schema-validated results** — the Agent Runs API's
  `result_schema` + server-side `ExJsonSchema` validation has no A2A
  equivalent yet. An A2A task's result is always plain reply text
  (`status.message.parts`), never a validated JSON object.
- **Client-defined ("frontend") tools** — the Agent Runs API's
  `client_tools` + `submit_result`/tool-call round-trip (docs/api.md
  "Client (frontend) tools") isn't ported here. The natural A2A mapping
  would be the `input-required` task state (task pauses, caller supplies
  more input, task resumes) but that's a larger protocol surface than v1
  needs.

A caller that needs schema-validated results or client-side tool execution
today should use the Agent Runs API directly. These are reasonable
candidates for a later A2A version — if/when they land, expect them to
extend the task object (new states, an `artifacts` field) rather than
change anything documented above.
