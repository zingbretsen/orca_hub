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
| `prompt` | string | yes | the initial user turn |
| `directory` | string | one of `directory`/`project_id` | working directory for the session |
| `project_id` | string | one of `directory`/`project_id` | resolves `directory` from the project when `directory` isn't given |
| `model` | string | no | passed through to the backend |
| `backend` | string | no | `"claude"` (default), `"codex"`, `"pi"` |
| `title` | string | no | defaults to `"API run"` |
| `no_tools` | boolean | no | `true` = zero built-in tools (`--tools ""`). Without a `result_schema`, this ALSO drops the MCP config entirely — the session never gets the `orca` MCP server (no `open_file`, `send_message_to_session`, etc.), so there's no file/session access of any kind, pure text-in/JSON-out reasoning. With a `result_schema`, the `orca` MCP server stays wired up (restricted to `submit_result` only — see below), since it's the run's sole result channel. Claude backend only — `400` if combined with a non-`claude` backend |
| `result_schema` | object | no | a JSON Schema the final result must validate against. The session gets an `orca` MCP server exposing exactly one tool, `submit_result`, synthesized from this schema (see below); `code_exec` is disabled on the session so `submit_result` is the only orca tool reachable — no other orca tool, no upstream tool, no code-exec meta-tools |
| `timeout_seconds` | integer | no | default `3600` |
| `max_validation_attempts` | integer | no | default `3` — how many times to re-prompt on a schema-validation failure before giving up |

### Response — `202`

```json
{"run_id": "…", "session_id": "…", "status": "running"}
```

Errors: `400` (missing prompt/directory, `no_tools` with a non-Claude
backend), `422` (invalid session params), `503` (the resolved node isn't
currently connected).

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
  "status": "running | in_progress | completed | failed | timed_out",
  "session_status": "running | idle | error | …",
  "result": { "…": "…" },
  "result_text": "raw final assistant text",
  "error": "…",
  "validation_attempts": 0
}
```

Unused keys are omitted. `result` is only present once the run is
`completed`. `result_text` is always stored on completion (or failure), even
when it didn't parse/validate, for debugging.

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
- A session that errors out marks the run `failed`. A run whose
  `timeout_seconds` has elapsed is marked `timed_out` (the session itself is
  **not** killed — `session_id` is included so you can inspect it).

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
schema run's MCP connection — the session is also created with `code_exec`
disabled so `submit_result` is the only orca tool that exists at all.

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
