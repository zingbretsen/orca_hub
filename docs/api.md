# Agent Runs API

A small HTTP API for running an agent session from an external service and
polling for a schema-validated JSON result — no need to shell out to a CLI
directly. First consumer: the `auto-editor` project posting a video
transcript + prompt and polling back structured edit decisions.

Async by design: `POST` creates a run and returns immediately; the caller
polls `GET` until the run reaches a terminal status. There are no callbacks
and no long-blocking requests.

## Auth

Every request needs a static bearer token:

```
Authorization: Bearer <ORCA_API_TOKEN>
```

Set `ORCA_API_TOKEN` in the environment to enable the API. Unset/empty means
the API is disabled — every request gets `503 {"error": "API disabled"}`. A
missing/incorrect token gets `401 {"error": "unauthorized"}`.

## POST /api/v1/runs

Creates a session and a run, sends the prompt, and returns immediately.

### Body

| field | type | required | notes |
|---|---|---|---|
| `prompt` | string | yes | the turn to send |
| `session_id` | string | no | **continue an existing session instead of creating a new one** — see "Continuing a session" below. When given, every other body field below except `result_schema`/`timeout_seconds`/`max_validation_attempts` is ignored (the session already has a directory/backend/model/tools) |
| `directory` | string | one of `directory`/`project_id`, one-shot only | working directory for the session |
| `project_id` | string | one of `directory`/`project_id`, one-shot only | resolves `directory` from the project when `directory` isn't given |
| `model` | string | no, one-shot only | passed through to the backend |
| `backend` | string | no, one-shot only | `"claude"` (default), `"codex"`, `"pi"` |
| `title` | string | no, one-shot only | defaults to `"API run"` |
| `no_tools` | boolean | no, one-shot only | `true` = zero built-in tools (`--tools ""`). Without a `result_schema`/`client_tools`, this ALSO drops the MCP config entirely — the session never gets the `orca` MCP server (no `open_file`, `send_message_to_session`, etc.), so there's no file/session access of any kind, pure text-in/JSON-out reasoning. With a `result_schema` and/or `client_tools`, the `orca` MCP server stays wired up (restricted to the api_run surface — see below), since that's the run's sole tool/result channel. Claude backend only — `400` if combined with a non-`claude` backend |
| `result_schema` | object | no | a JSON Schema the final result must validate against. On a new (one-shot) session, this synthesizes an `orca` MCP server exposing a `submit_result` tool built from this schema (see below), with `code_exec` disabled on the session so the api_run surface is the only thing reachable. On a **continuation**, the target session's own MCP/tool config is left untouched — `submit_result` is only wired up on a fresh session, so a schema on a continuation relies on the idle-text JSON-extraction fallback (below), not the tool |
| `client_tools` | array | no, **new sessions only** | AG-UI-style client-defined ("frontend") tools — see "Client (frontend) tools" below. A list of `{"name", "description", "input_schema"}` objects. `400` if names aren't unique/non-empty, any name is `"submit_result"` (reserved), `input_schema` isn't an object, or this is combined with `session_id` (continuations aren't supported yet — see below) |
| `timeout_seconds` | integer | no | default `3600` |
| `max_validation_attempts` | integer | no | default `3` — how many times to re-prompt on a schema-validation failure before giving up |

### Response — `202`

```json
{"run_id": "…", "session_id": "…", "status": "running"}
```

Errors: `400` (missing prompt/directory, `no_tools` with a non-Claude
backend, invalid `client_tools`, `client_tools` combined with `session_id`),
`404` (`session_id` given but no such session exists), `422`
(invalid session params), `503` (the resolved node isn't currently
connected), `502` (session_id given but the session could not be revived —
see below).

## Continuing a session

Pass `session_id` (any existing session — including one that's idle, has
gone cold after the ~15 minute idle-teardown, or is archived) instead of
`directory`/`project_id` to deliver the prompt into that session's ongoing
conversation rather than starting a new one. A **new** `run_id` is created
for every continuation — each one is a fresh, independently-pollable turn —
but no new session is created and no new `session_id` is returned; poll
`GET /api/v1/runs/:id` with the new `run_id` exactly like a one-shot run.

- **Revival**: delivery goes through the same path
  `send_message_to_session` (the MCP tool sibling sessions use to message
  each other) uses — a torn-down/never-started session is restarted, and an
  archived session is automatically unarchived, before the prompt is sent.
  There's no separate "wake up" step; sending IS the wake-up.
- **Node availability**: if the session's assigned node isn't currently
  connected to the cluster, the request fails `503` before anything is
  created (same posture as a one-shot run whose node is down) — no `run_id`
  is issued and nothing is left behind. If the runner refuses to start for
  any other reason, the request fails `502` with a `run_id` that's already
  marked `failed` (so a poll on it returns the same error instead of
  `404`).
- **Auth**: there is currently only one static bearer token for the whole
  API (see "Auth" above) — any caller that can hit this endpoint at all can
  continue any session that exists. There's no per-session/per-token
  ownership check to enforce.
- **Correlation**: because a continuation's target session can already be
  `idle` (from its *previous* turn) the instant the prompt is delivered,
  the run tracks a `baseline_message_count` snapshot (the session's message
  count right before delivery) and won't treat the run as complete until
  the session's message count has grown past that snapshot — otherwise a
  poll landing in that narrow window would read the *previous* turn's reply
  as if it were this run's result. In practice `send_message` also delivers
  synchronously (the runner is already `running` in the DB by the time
  `POST` responds), so this window shouldn't really open in the first
  place; the snapshot is a belt-and-suspenders correctness guard, not the
  only thing preventing it.

### Example: create → poll → continue → poll

```bash
curl -s -X POST https://orca.example/api/v1/runs \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2+2?", "directory": "/tmp"}'
# {"run_id":"run-1","session_id":"sess-1","status":"running"}

curl -s https://orca.example/api/v1/runs/run-1 -H "Authorization: Bearer $ORCA_API_TOKEN"
# {"run_id":"run-1","session_id":"sess-1","status":"completed","result_text":"4"}

# ... possibly much later — sess-1 may have idle-torn-down by now ...

curl -s -X POST https://orca.example/api/v1/runs \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"prompt": "Now multiply that by 10.", "session_id": "sess-1"}'
# {"run_id":"run-2","session_id":"sess-1","status":"running"}

curl -s https://orca.example/api/v1/runs/run-2 -H "Authorization: Bearer $ORCA_API_TOKEN"
# {"run_id":"run-2","session_id":"sess-1","status":"completed","result_text":"40"}
```

## GET /api/v1/runs/:id

Poll-driven: each call advances the run's state machine one step (checks the
session, extracts/validates a result, retries validation, or times out) and
returns the current state. There is no background monitor — polling is what
drives completion.

### Response

```json
{
  "run_id": "…",
  "session_id": "…",
  "status": "running | in_progress | awaiting_tool_result | completed | failed | timed_out",
  "session_status": "running | idle | error | …",
  "result": { "…": "…" },
  "result_text": "raw final assistant text",
  "error": "…",
  "validation_attempts": 0,
  "tool_call": { "id": "…", "name": "…", "arguments": { "…": "…" } }
}
```

Unused keys are omitted. `result` is only present once the run is
`completed`. `result_text` is always stored on completion (or failure), even
when it didn't parse/validate, for debugging. `tool_call` is only present
while `status` is `awaiting_tool_result` — see "Client (frontend) tools"
below.

- **No `result_schema`**: on session idle, the final assistant text is
  stored as `result_text`; if it parses as JSON (bare, or inside a ` ```json `
  fence), it's also stored as `result` and the run completes.
- **With `result_schema`**: the run's primary (and intended) completion path
  is the model calling the `submit_result` MCP tool — see below. That
  happens **within the model's turn**, so a poll can see `status: "completed"`
  even while `session_status` still reports `running` (the tool call landed
  before the turn ended) — `GET` checks the run's own status first, before
  looking at the session at all, so this is picked up on the very next poll.
  As a **fallback**, if the session goes idle with the run still `running`
  (the model never called the tool), the assistant's JSON is extracted from
  its final text and validated server-side against the schema exactly like
  v1 — valid → `completed` with `result`; invalid or unparsable → the session
  is re-prompted to call `submit_result` (`status: "in_progress"`,
  `validation_attempts` incremented) until `max_validation_attempts` is
  exhausted, at which point the run is `failed` with the errors in `error`.
- **With `client_tools`**: when the model calls one, `status` becomes
  `awaiting_tool_result` and `tool_call` is set — see "Client (frontend)
  tools" below. `awaiting_tool_result` is authoritative over the session's
  own status: the idle-text completion path above never fires while a tool
  call is pending, even if the session itself goes idle in the meantime.
- A session that errors out marks the run `failed`. A run whose
  `timeout_seconds` has elapsed is marked `timed_out` (the session itself is
  **not** killed — `session_id` is included so you can inspect it) — this
  applies even while `awaiting_tool_result`, so a caller that never answers
  a tool call doesn't leave the run open forever.

## `submit_result`: the result channel for schema runs

When a run has a `result_schema`, the session's `orca` MCP server exposes
exactly one tool:

- **`submit_result`** — `inputSchema` IS your `result_schema` when its
  top-level `"type"` is `"object"` (the common case); any other top-level
  type (array, string, ...) is wrapped as
  `{"type": "object", "properties": {"result": <your schema>}, "required": ["result"]}`
  and unwrapped server-side on submission. The model sees your schema
  natively via tool-use — no fence-parsing, no guessing the expected shape.

Validation runs server-side (`ExJsonSchema`, never trusted to the model) on
every call:

- **Valid** → the run completes immediately (`status: "completed"`,
  `result` set) and the tool returns "Result accepted." A run that already
  completed returns "Result already submitted." as a no-op — the stored
  result is never overwritten by a later call.
- **Invalid** → the tool call returns an MCP **error result** (`isError: true`)
  listing the validation failures, delivered to the model **within the same
  turn** — it can immediately retry with a corrected submission, no
  round-trip through `GET`/re-prompting required.

No other orca tool, upstream tool, or code-exec meta-tool is reachable on a
schema/`client_tools` run's MCP connection — the session is also created
with `code_exec` disabled so the api_run surface (below) is the only thing
that exists at all.

## Client (frontend) tools

AG-UI-style client-defined ("frontend") tools: the caller supplies tool
definitions with the run, the agent can call them, but the call is never
executed on OrcaHub — it's forwarded back to the caller to run and answer.
Useful for anything only the calling application can do (query its own
database, call an internal API, prompt its own user) without giving the
agent direct network/tool access.

- Pass `client_tools` on `POST /api/v1/runs` (new sessions only — see the
  v1 restriction below): a list of
  `{"name": "…", "description": "…", "input_schema": {...}}` objects. Names
  must be non-empty and unique, and none may be `"submit_result"` (reserved
  for the schema result channel above). `input_schema` must be an object
  (a JSON Schema); non-object top-level schemas are wrapped the same way
  `submit_result`'s is (see above) and unwrapped before you see the call's
  arguments. `client_tools` may be combined with `result_schema` (the tool
  surface is client tools + `submit_result`) or used alone (result
  extraction falls back to the idle-text behavior described above).
- Each client tool's description gets a short note appended telling the
  model it's executed by the calling application and to end its turn after
  calling it.
- **When the model calls one**: the run moves to
  `status: "awaiting_tool_result"` and the call is exposed via `GET
  /api/v1/runs/:id` as `tool_call: {"id", "name", "arguments"}`. The
  underlying `tools/call` request from the agent is held open server-side
  (it does **not** get an immediate reply) — this is invisible to you as the
  caller; it only changes how the answer gets back to the model, not
  anything about this API's request/response shapes.
- **One at a time**: if the model calls a second client tool before you've
  answered the first (e.g. two tool calls in the same turn), only the first
  is recorded — the second gets an MCP error result telling the model to
  wait for the pending call's result before calling another.
- **Answer with `POST /api/v1/runs/:id/tool_result`**:
  ```json
  {"tool_call_id": "…", "result": {"…": "…"}}
  ```
  or, for a failed tool execution:
  ```json
  {"tool_call_id": "…", "error": "…"}
  ```
  `tool_call_id` must match the run's current pending call
  (`409` if it doesn't, or if the run isn't currently
  `awaiting_tool_result`). The response is always `202 {"run_id",
  "session_id", "status": "running"}` — poll `GET /api/v1/runs/:id` again
  from there, exactly like after the initial `POST`. What happens to the
  agent depends on timing:
  - **Usually** (you answered before the hold timed out — see below): your
    `result`/`error` is delivered as the tool call's actual return value,
    **within the model's same turn** — the held `tools/call` request
    resolves right there, and the model continues from that tool result
    exactly like a normal, synchronously-executed tool call.
  - **If the hold already timed out** (you took too long — the model has
    since been told to end its turn, so there's no longer a held request to
    answer): falls back to v1 behavior — the result is delivered into the
    session as a **new** message ("Result of your `<name>` tool call (id
    `<id>`): ...\n\nContinue the task."), waking the session back up for a
    fresh turn. From your side as the caller this looks identical (`202`
    then poll) either way; only the agent-facing mechanics differ.
  - The hold budget defaults to the run's own remaining `timeout_seconds`
    (capped at 10 minutes) — in practice, only a caller that's slow to
    answer (or offline) hits the fallback.
- **Restarts / retries**: if the connection holding a call open is
  interrupted (e.g. a node restart) before you've answered, the agent CLI
  will typically retry the identical tool call — that retry is matched
  against the **same** pending call (same `tool_call_id`) rather than
  creating a new one you'd have to answer twice.
- **v1 restriction**: `client_tools` is only supported on **new** sessions,
  not continuations (`session_id`) — `400` if both are given. A
  continuation's MCP connection flag and cached tool list are baked in at
  session creation, so there's currently no way to add `client_tools` onto
  an already-existing session's connection.

## Example: plain text-in/JSON-out reasoning

```bash
curl -s -X POST https://orca.example/api/v1/runs \
  -H "Authorization: Bearer $ORCA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Summarize the sentiment of this review in one word: \"Absolutely loved it!\"",
    "directory": "/tmp",
    "no_tools": true,
    "result_schema": {"type": "object", "properties": {"sentiment": {"type": "string"}}, "required": ["sentiment"]}
  }'
# {"run_id":"…","session_id":"…","status":"running"}

curl -s https://orca.example/api/v1/runs/<run_id> \
  -H "Authorization: Bearer $ORCA_API_TOKEN"
# Completed via the submit_result tool (the primary path — result_text is
# only set by the idle-text fallback described above):
# {"run_id":"…","session_id":"…","status":"completed","result":{"sentiment":"positive"},"validation_attempts":0}
```

## Example: auto-editor (transcript → cut list)

```bash
curl -s -X POST https://orca.example/api/v1/runs \
  -H "Authorization: Bearer $ORCA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Given this transcript (word-indexed), propose cuts that remove filler words and dead air. Transcript: [{\"i\":0,\"w\":\"So\"},{\"i\":1,\"w\":\"um\"},{\"i\":2,\"w\":\"today\"},{\"i\":3,\"w\":\"we\"},{\"i\":4,\"w\":\"are\"},{\"i\":5,\"w\":\"going\"}]",
    "directory": "/tmp",
    "no_tools": true,
    "timeout_seconds": 600,
    "result_schema": {
      "type": "object",
      "properties": {
        "cuts": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "start_word_index": {"type": "integer"},
              "end_word_index": {"type": "integer"},
              "reason": {"type": "string"}
            },
            "required": ["start_word_index", "end_word_index"]
          }
        }
      },
      "required": ["cuts"]
    }
  }'
```

Poll `GET /api/v1/runs/<run_id>` until `status` is `completed`; `result.cuts`
is the validated cut list, ready to feed back into `auto-editor` without any
further parsing.

## Example: client (frontend) tool round-trip

```bash
curl -s -X POST https://orca.example/api/v1/runs \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "prompt": "What is the weather in Boston right now?",
    "directory": "/tmp",
    "client_tools": [
      {
        "name": "get_weather",
        "description": "Look up the current weather for a city.",
        "input_schema": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }
    ]
  }'
# {"run_id":"run-1","session_id":"sess-1","status":"running"}

curl -s https://orca.example/api/v1/runs/run-1 -H "Authorization: Bearer $ORCA_API_TOKEN"
# The model called get_weather — the run is now waiting on YOU to answer it:
# {"run_id":"run-1","session_id":"sess-1","status":"awaiting_tool_result",
#  "tool_call":{"id":"call-1","name":"get_weather","arguments":{"city":"Boston"}}}

# ... look up the weather yourself, then answer the call ...

curl -s -X POST https://orca.example/api/v1/runs/run-1/tool_result \
  -H "Authorization: Bearer $ORCA_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"tool_call_id": "call-1", "result": {"conditions": "sunny", "temp_f": 72}}'
# {"run_id":"run-1","session_id":"sess-1","status":"running"}

curl -s https://orca.example/api/v1/runs/run-1 -H "Authorization: Bearer $ORCA_API_TOKEN"
# {"run_id":"run-1","session_id":"sess-1","status":"completed","result_text":"It's sunny and 72°F in Boston."}
```
