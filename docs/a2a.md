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
| `-32602` | Invalid params (e.g. no text parts in `message.parts`, or `message.taskId` given instead of `contextId`; **v2 draft**: a `taskId`-bearing send whose `tool_call_id` was never issued for that task and whose task isn't `input-required`, or `client_tools`/`result_schema`/`max_validation_attempts` declared on a continuation) |
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

### Metadata extensions

`message.metadata` is A2A's standard per-message extension point. One key
is currently recognized:

- **`no_tools: true`** — creates the new session with an empty tool
  allow-list (mirrors the [Agent Runs API](api.md)'s `no_tools` option),
  useful for a pure text-in/text-out "polish"-style agent that shouldn't be
  able to call any tools at all. Only supported when the effective backend
  for the request is `"claude"` (same restriction as the Agent Runs API) —
  a request with `no_tools: true` against a project whose node defaults to
  a non-Claude backend is rejected `-32602`. Any value other than `true`
  (including `false` or the key being absent) is the default — no error,
  normal tool access.
- **Ignored on continuations**: `contextId` present means an *existing*
  session, whose tool surface was already baked in at creation time — a
  `no_tools` in `message.metadata` on a continuation is silently ignored.
- Any other `metadata` key is ignored (forward-compatible).

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

## v2 (DRAFT — not implemented): client tools + structured results

> **⚠️ Draft contract — not implemented.** This section describes a
> proposed contract under review between the A2A implementer-orchestrator
> and its first prospective consumer. Nothing below is served by the
> current deployment: no code, no schema, no endpoint behavior described
> here exists yet. The authoritative, shipped surface is everything
> **above** this section. Treat this as a specification for future work,
> not documentation of current behavior.

### Declaration (session-creating `message/send` only)

- `message.metadata.client_tools`: `[{"name", "description", "input_schema"}]`
  — the same validation rules as the Agent Runs API's `client_tools`
  (docs/api.md "Client (frontend) tools"): names must be non-empty and
  unique, none may be `"submit_result"` (reserved), and `input_schema`
  must be an object.
- `message.metadata.result_schema`: a JSON Schema the final result must
  validate against, same as the Runs API's `result_schema`.
  `message.metadata.max_validation_attempts` (default `3`) caps corrective
  retries, same as the Runs API field of the same name.
- Both are inherited by `contextId` continuations — declared once at
  session creation, they apply to every task in that conversation.
- **Declaring any of `client_tools`, `result_schema`, or
  `max_validation_attempts` on a continuation is rejected `-32602`** —
  including `max_validation_attempts` given alone, with neither of the
  other two present. This is a deliberate asymmetry with `no_tools`
  (silently ignored on continuations, see "Metadata extensions" above): a
  silently-dropped `client_tools`/`result_schema` on a continuation would
  be a correctness trap (the caller believes structured output/tool
  routing is active when it isn't); a silently-ignored `no_tools` is
  harmless, since the session's tool surface was already fixed at
  creation either way.
- Backend restriction mirrors the Runs API where applicable — today only
  `no_tools` itself carries the Claude-only restriction; `client_tools`/
  `result_schema` don't add any further restriction beyond that.

### Tool-call loop (A2A-native)

- When the agent calls a client tool, the task transitions to state
  `"input-required"` (nonterminal — same "poll again" contract as
  `submitted`/`working`).
- `tasks/get` on an `input-required` task returns the pending call as a
  `DataPart` on `status.message.parts`:
  ```json
  {"kind": "data", "data": {"tool_call_id": "…", "name": "…", "arguments": {"...": "..."}},
   "metadata": {"orcahub_part": "tool_call"}}
  ```
- The client answers by calling `message/send` **with `taskId` set on the
  message object** — this narrows v1's blanket `-32602` on `message.taskId`
  (see the error table above). The message must carry a `DataPart`:
  ```json
  {"kind": "data", "data": {"tool_call_id": "…", "result": "<any JSON>"}}
  ```
  or, for a failed client-side tool execution:
  ```json
  {"kind": "data", "data": {"tool_call_id": "…", "error": "…"}}
  ```
  `contextId` is optional alongside `taskId` here; if present it must
  match the task's own `contextId` (mismatch → `-32602`) — `taskId` alone
  is sufficient to identify the task. Response `result` is the task
  object; state moves to `"working"`, except when the idempotent-ack
  precedence below applies, in which case the task's current (possibly
  terminal) state is returned unchanged.
- **Precedence: idempotent ack beats the state gate** (spelled out
  precisely — this was negotiated carefully). Answering **any**
  `tool_call_id` that was previously **issued** for that task — including
  one already answered, and regardless of the task's current state —
  always succeeds, returning the task's current (possibly terminal)
  object; no client-side dedup required. This takes precedence over the
  state check below because it covers a legitimate transport-retry of an
  answer arriving *after* the task has already moved on (e.g. the agent
  went straight from this tool call to `submit_result`, and the task is
  now `completed`) — exactly the case idempotency exists for.
- The `-32602` **state gate** ("task is not awaiting input") applies
  **only** to a `taskId`-bearing send whose `tool_call_id` was **never**
  issued for that task in the first place — i.e. one that isn't a retry
  of anything real.
- **Stale re-advertisement**: an answered call may continue to appear in
  `tasks/get` for a few more polls before server-side state catches up to
  the agent's actual progress. Combined with the idempotent-ack precedence
  above, this is harmless — re-answering a stale call is a no-op, not an
  error.
- The idempotent-ack guarantee assumes the **client's own tool handler is
  idempotent or read-only** — the server can safely ack a duplicate
  answer, but it cannot un-run a side effect the client already performed
  once.
- Multiple sequential tool calls per turn are normal (the agent can call
  several client tools one after another); only **one** call is ever
  pending (`input-required`) at a time.
- `tasks/cancel` is allowed on an `input-required` task: the parked tool
  call is simply abandoned (never answered), the underlying session's
  turn is interrupted best-effort exactly as in v1, and the task moves to
  `"canceled"`.

### Structured results

- With `result_schema` declared, the hub synthesizes a `submit_result`
  tool (same mechanics as the Runs API — see "`submit_result`: the result
  channel for schema runs" above) and validates it server-side, with up to
  `max_validation_attempts` corrective retries.
- Corrective retries are never observable as a distinct task state: the
  primary channel (the `submit_result` tool returning a validation error)
  retries within the same agent turn, and even the idle-text fallback's
  corrective re-prompt keeps the task `"working"` to pollers. A poller
  only ever sees `submitted`/`working`/`input-required` → terminal —
  there's no separate "validating" state.
- **If `max_validation_attempts` is exhausted without a valid
  submission**, the task moves to `"failed"` with error text
  `"validation failed after N attempts: <errors>"`, and `status.message`
  carries a `TextPart` with the last raw (invalid) response — no result
  `DataPart` is produced, since nothing ever validated. This mirrors the
  Agent Runs API's identical failure case.
- The completed task's `status.message.parts` then contains the
  **validated** result as a `DataPart`:
  ```json
  {"kind": "data", "data": {"...": "..."}, "metadata": {"orcahub_part": "result"}}
  ```
  alongside an optional `TextPart` carrying the raw prose reply. The
  `metadata.orcahub_part` discriminator (`"tool_call"` vs `"result"`) is
  the documented way to tell the two `DataPart` shapes apart — no
  structural shape-sniffing needed.
- Text-only v1 clients are unaffected either way — prose still arrives in
  `TextPart`s exactly as it does today.

### Timeouts & holds

- The task's `timeout_seconds` budget is wall-clock from task creation and
  **includes** time spent parked in `"input-required"` — there is no
  `awaiting_tool_result`-style exemption; this matches the Agent Runs API
  exactly (docs/api.md: the budget applies even while
  `awaiting_tool_result`). A caller with a slow tool handler should keep
  its answers well inside the task's own timeout budget.
- Server-side, a pending tool call is held open for at most the shared
  client-tool hold cap (~10 minutes — see
  `OrcaHub.MCP.Server.client_tool_hold_cap_ms/0`), which bounds how long
  any single parked call can consume; past that the loop degrades
  gracefully exactly like the Runs API's fallback — the answer is
  delivered as a new message into the session instead of resolving the
  held call, transparent to the client apart from one extra turn of
  latency.
- There is a known CLI-side hold-timeout issue where the Claude CLI can
  cut the effective hold to roughly 4m50s rather than the full cap —
  tracked separately, not a v2-spec concern.
- If a consumer ever needs more headroom than the task's own
  `timeout_seconds` provides, a `metadata.timeout_seconds` declaration is
  the natural future extension — not specified here.

### Example (draft): declare → input-required → answer via taskId → completed with result

```bash
curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0", "id": 1, "method": "message/send",
    "params": {"message": {"messageId": "m1", "role": "user",
      "parts": [{"kind": "text", "text": "What is the weather in Boston right now?"}],
      "metadata": {
        "client_tools": [{
          "name": "get_weather",
          "description": "Look up the current weather for a city.",
          "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}
        }],
        "result_schema": {"type": "object", "properties": {"summary": {"type": "string"}}, "required": ["summary"]}
      }}}
  }'
# {"jsonrpc":"2.0","id":1,"result":{"id":"task-1","contextId":"sess-1","kind":"task","status":{"state":"submitted","timestamp":"…"}}}

curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 2, "method": "tasks/get", "params": {"id": "task-1"}}'
# The model called get_weather — the task is now waiting on the CALLER to answer it:
# {"jsonrpc":"2.0","id":2,"result":{"id":"task-1","contextId":"sess-1","kind":"task",
#  "status":{"state":"input-required","timestamp":"…",
#    "message":{"role":"agent","messageId":"…","kind":"message",
#      "parts":[{"kind":"data","data":{"tool_call_id":"call-1","name":"get_weather","arguments":{"city":"Boston"}},
#                "metadata":{"orcahub_part":"tool_call"}}]}}}}

# ... look up the weather, then answer via message/send WITH taskId ...
curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0", "id": 3, "method": "message/send",
    "params": {"message": {"messageId": "m2", "role": "user", "taskId": "task-1",
      "parts": [{"kind": "data", "data": {"tool_call_id": "call-1", "result": {"conditions": "sunny", "temp_f": 72}}}]}}
  }'
# {"jsonrpc":"2.0","id":3,"result":{"id":"task-1","contextId":"sess-1","kind":"task","status":{"state":"working","timestamp":"…"}}}

curl -s -X POST https://orca.example/a2a/agents/<project-id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "id": 4, "method": "tasks/get", "params": {"id": "task-1"}}'
# Agent called submit_result next, validated against result_schema:
# {"jsonrpc":"2.0","id":4,"result":{"id":"task-1","contextId":"sess-1","kind":"task",
#  "status":{"state":"completed","timestamp":"…",
#    "message":{"role":"agent","messageId":"…","kind":"message",
#      "parts":[{"kind":"text","text":"It's sunny and 72°F in Boston."},
#                {"kind":"data","data":{"summary":"It's sunny and 72°F in Boston."},
#                 "metadata":{"orcahub_part":"result"}}]}}}}
```

## Roadmap / not in v1

This v1 deliberately covers the plain text-in/text-out conversational
subset of A2A. A few things stay out of scope for v1 and remain on the
[Agent Runs API](api.md) instead:

- **Structured/schema-validated results** — specified in the "v2 (DRAFT —
  not implemented)" section above; not implemented yet. An A2A task's
  result today is always plain reply text (`status.message.parts`), never
  a validated JSON object.
- **Client-defined ("frontend") tools** — likewise specified in the v2
  draft above, via the `input-required` task state (task pauses, caller
  supplies more input, task resumes); not implemented yet.
- **A2A protocol-level artifacts** — A2A's `artifact` concept (structured,
  named outputs attached to a task, distinct from the reply message) isn't
  implemented and has no draft yet either. Only `status.message` text
  parts are produced.

A caller that needs schema-validated results or client-side tool execution
today should use the Agent Runs API directly — the v2 draft above is a
proposed contract under review, not shipped behavior. If/when it lands,
expect it to extend the task object exactly as specified above (the
`input-required` state, `DataPart`-shaped status messages) rather than
changing anything else documented in this file.
