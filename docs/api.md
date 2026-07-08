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
| `no_tools` | boolean | no | `true` = pure text-in/JSON-out reasoning: zero built-in tools (`--tools ""`) AND no MCP config at all — the session never gets the `orca` MCP server (no `open_file`, `send_message_to_session`, etc.), so there's no file/session access of any kind. Claude backend only — `400` if combined with a non-`claude` backend |
| `result_schema` | object | no | a JSON Schema the final result must validate against; appended to the prompt as an instruction and enforced server-side (see below) |
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
- **With `result_schema`**: the assistant's JSON is extracted and validated
  server-side against the schema. Valid → `completed` with `result`. Invalid
  → the session is re-prompted with the validation errors and told to
  respond with corrected JSON (`status: "in_progress"`,
  `validation_attempts` incremented) until `max_validation_attempts` is
  exhausted, at which point the run is `failed` with the errors in `error`.
- A session that errors out marks the run `failed`. A run whose
  `timeout_seconds` has elapsed is marked `timed_out` (the session itself is
  **not** killed — `session_id` is included so you can inspect it).

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
# {"run_id":"…","session_id":"…","status":"completed","result":{"sentiment":"positive"},"result_text":"```json\n{\"sentiment\": \"positive\"}\n```","validation_attempts":0}
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
