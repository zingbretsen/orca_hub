# Assistant-delta frame fixtures

Native frames feeding the `OrcaHub.Backend.Deltas` normalization tests
(voice phase 2, contract C1). Provenance differs per file — read this before
trusting one as "what the CLI really sends".

## `pi_message_updates.ndjson` — REAL CAPTURE

Recorded 2026-09-18 from pi 0.85.1 (`@earendil-works/pi-coding-agent`):

    pi -p --mode json --model ai-gateway/qwen3-coder-next \
       "Count to five, one number per line. No tools."

filtered to the `message_start` / `message_update` / `message_end` frames.
`--mode json` emits the same event vocabulary as the `--mode rpc` OrcaHub
actually spawns (see `Backend.Pi.spawn_spec/2`'s note).

Two things this capture pins that the docs alone would not:

  * `message_update` is **delta-only** — `assistantMessageEvent.delta` is the
    CHUNK, not a cumulative snapshot. Upstream removed the cumulative
    `message` field and `assistantMessageEvent.partial` (quadratic output
    growth); so the normalizer needs no diffing against a previous string.
  * a pi `AgentMessage` has **no `id`** (it carries api/content/model/provider/
    responseId/role/stopReason/timestamp/usage — `responseId` names the
    PROVIDER response, not the message), which is why `Backend.Pi` mints the
    C1 `stream_id` itself.

## `codex_agent_message.ndjson` — REAL CAPTURE

Recorded 2026-09-18 from codex-cli 0.154.0 by driving `codex app-server`
through the exact handshake `Backend.Codex.on_open/1` uses, but with
`item/agentMessage/delta` left OUT of `optOutNotificationMethods` — i.e. the
post-change adapter's own wire config. Filtered to the `item/started` /
`item/agentMessage/delta` / `item/completed` frames.

Pins the delta params shape: `{threadId, turnId, itemId, delta}` — the text
chunk is `delta`, and `itemId` is what correlates it with the `item/started`
and `item/completed` frames for the same `agentMessage` item. Note the
`userMessage` item's own started/completed frames are included on purpose:
they are what the normalizer must NOT open a stream for.

## `claude_stream_events.ndjson` — HAND-WRITTEN TO A VERIFIED SCHEMA

**Not a live capture.** Every `claude` spawn from the authoring session's
process tree failed with `Failed to authenticate: OAuth session expired and
could not be refreshed` (`~/.claude/.credentials.json` reads back with
zero-length `accessToken`/`refreshToken` from inside that sandbox, while
OrcaHub-spawned sessions on the same host authenticate fine) — so no real
frame sequence could be recorded. Re-record this file the first time a
capture is possible; the tests should pass unchanged if the shapes below hold.

The shapes were instead read out of the installed CLI binary itself
(`~/.local/share/claude/versions/2.1.270`, an unstripped ELF bundling the JS):

  * the frame envelope, from its own zod validator —
    `{type:"stream_event", event:…, parent_tool_use_id: nullable, uuid, session_id,
    ttft_ms?: int, user_message_uuid?}`;
  * the inner events are the RAW Anthropic Messages-API streaming events
    (`message_start` / `content_block_start` / `content_block_delta` /
    `content_block_stop` / `message_delta` / `message_stop`), confirmed by the
    binary's own emitters, e.g.
    `uv=(e)=>({type:"stream_event",event:e})` used for
    `{type:"content_block_delta",index,delta:{type:"input_json_delta",…}}`;
  * `message_start.message.id` is required to be a string
    (`case"message_start": return q(e.message) && typeof e.message.id==="string"`)
    and that same message object seeds the accumulator that becomes the final
    whole `assistant` event (`case"message_start":{… qb=ll.message …}`) — which
    is why `stream_id` can be the API message id with nothing minted.

The last two lines carry a non-nil `parent_tool_use_id` (a nested/subagent
stream). They exist so the test can pin that those are dropped rather than
interleaved into the parent's block-index space.
