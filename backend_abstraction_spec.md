# Backend Abstraction Spec — Pluggable Agent CLIs (Claude, Codex, grok, pi, …)

**Status:** Implemented — all four phases (§8) landed. Claude + Codex are both
selectable per-session with capability-gated UI; grok/pi remain
research-only (§12, adapters deferred).
**Goal:** Decouple OrcaHub from the Claude Code CLI so a session can be driven by
any headless coding-agent CLI. First non-Claude target: **OpenAI Codex CLI**
(via `codex app-server`). Named future targets: **grok CLI** and **pi** (Mario
Zechner's coding agent) — both CLIs, adapters deferred to post-v1 (see §12).
Selection is **per-session**. Missing features **gracefully degrade** per backend.

**Scope note:** all supported backends are *agent CLIs* — child processes that
execute their own tools and speak a machine-readable protocol on stdio. Raw chat
APIs (e.g. the xAI HTTP API directly) are out of scope: a bare API returns
tool-call *intents* with nothing executing them, so supporting one would mean
building our own agentic harness. Models reachable only via API ride in through
a multi-provider CLI instead (pi is multi-provider; Codex supports custom
OpenAI-compatible `model_providers` in config.toml).

> The Codex app-server wire protocol in §6.1 is **Verified** — ground-truthed
> against `codex app-server generate-json-schema --experimental` (codex-cli
> **0.142.5**) and a live no-API-key handshake capture (`initialize` ->
> `thread/start`) during Phase 2 implementation. Deviations found vs. the
> original SDK-corroborated draft are called out inline in §6.1/§6.3 with a
> **"0.142.5:"** prefix. The grok and pi protocols in §12 are **Verified**
> (grok: live capture against the 0.2.82 binary; pi: official docs + source)
> — adapters remain deferred, but the seam design below already accounts for
> both.

---

## 1. Motivation

Today the entire stack is welded to Claude Code's `stream-json` protocol:

- `OrcaHub.Claude.Config.build_args/2` emits Claude-CLI flags.
- `SessionRunner` spawns `claude`, writes Claude NDJSON turn frames, and its
  `handle_stream_event/2` expects Claude's event vocabulary.
- **The persisted message history and the whole rendering layer are in Claude's
  `stream-json` shape** (`type: user|assistant|tool_use|tool_result|result|system`),
  stored verbatim in `message.data` and read directly by `MessageComponents`,
  `todos.ex`, `AskUserQuestion`, and plan mode.

That last fact is the design pivot: **new backends normalize their native output
INTO the existing Claude event vocabulary**, so ~2000 lines of persistence and
rendering stay untouched and each backend is confined to one adapter module.

---

## 2. Current Claude coupling (inventory)

| # | Surface | File | What's Claude-specific |
|---|---------|------|------------------------|
| 1 | Arg builder | `lib/orca_hub/claude/config.ex` | every flag: `-p`, `--output-format stream-json`, `--resume`, `--dangerously-skip-permissions`, `--append-system-prompt`, `--model`, `--mcp-config`, `--tools`, `--allowedTools`, `--max-turns`, `--max-budget-usd` |
| 2 | Streaming spawn | `session_runner.ex` `open_port_streaming/1` (~917) | `find_executable("claude")`, direct spawn, `input_format: stream-json` |
| 3 | One-shot spawn | `session_runner.ex` `open_port/1` (~1022) | `find_executable("claude")`, `script`/PTY wrapper |
| 4 | stdin framing | `user_turn_json/1` (~950), `control_interrupt_json/1` (~964) | Claude `{"type":"user",…}` and `{"type":"control_request",…}` NDJSON |
| 5 | Output contract | `handle_stream_event/2` (~1062–1147) | keys off `type` = system/assistant/user/result; `system.session_id`; `result.is_error` |
| 6 | Session resume | `session.claude_session_id` ↔ `--resume` | column + flag |
| 7 | Warm-up turn | `@warmup_prompt`, `write_warmup_turn/1` | Claude MCP-handshake race workaround |
| 8 | MCP config | `mcp_config/1` (~1197) | `--mcp-config` JSON, `{"mcpServers":{"orca":…}}` |
| 9 | System prompt | `build_system_prompt/1` (~1246) | `--append-system-prompt`; references Claude tool names, `.claude` dirs |
| 10 | Interrupt | `send_sigint/1` (one-shot), control_request (streaming) | Claude semantics |
| 11 | Usage | `lib/orca_hub/claude/usage.ex` | Anthropic OAuth endpoint, `~/.claude/.credentials.json`, keychain |
| 12 | Rendering | `components/message_components.ex` | hardcoded Claude tool names for icons/summaries (unknown → wrench+JSON already) |
| 13 | Model picker | `session_live/show.html.heex` (~204), `index.html.heex` (~293) | `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5-…` |
| 14 | Login | `login_runner.ex`, `NodeCredentials`, settings UI | `claude setup-token`, `sk-ant-oat…` scraping |
| 15 | Transcript import | `claude_import.ex`, `mix import_claude_sessions` | `~/.claude/projects/*.jsonl` |
| 16 | Plan mode | `session_live/plan_mode.ex` | `~/.claude/plans`, `EnterPlanMode`/`ExitPlanMode` tools |
| 17 | AskUserQuestion | `ask_user_question.ex`, component | Claude built-in tool + synthetic `is_error` result |

**Already provider-agnostic (mirror this pattern):** title generation
(`session_runner.ex` ~1486–1585) switches between OpenAI and DataRobot via
`title_api_config/0` + per-format request/extractor functions.

---

## 3. Target architecture

`SessionRunner` remains the orchestrator — GenStatem states, DB writes, PubSub,
WarmPool, idle teardown, title generation, AskUserQuestion status tracking. None
of that is inherently Claude-specific. Everything Claude-specific moves behind a
behaviour.

```
OrcaHub.Backend                 # behaviour + capability struct + dispatch
├─ OrcaHub.Backend.Claude       # today's logic, moved verbatim (identity normalize)
└─ OrcaHub.Backend.Codex        # codex app-server (+ codex exec one-shot fallback)
```

A session's backend is resolved once at runner init (from the new `backend`
column) and stored in runner `data` as `backend: module`. Every Claude-specific
call site in `SessionRunner` becomes `data.backend.<callback>(…)`.

### 3.1 Capability struct

Drives graceful degradation. The UI and runner branch on capabilities, never on
the backend name.

```elixir
%OrcaHub.Backend.Capabilities{
  streaming:         true,          # long-lived port w/ multi-turn stdin
  interrupt:         :protocol,     # :protocol | :signal | :none
  mcp:               true,          # can consume the orca MCP server
  resume:            true,          # session continuity across cold reopen
  usage:             true,          # headless usage/quota query available
  system_prompt:     :flag,         # :flag | :leading_message | :session_param | :none
  warmup_turn:       true,          # needs a throwaway turn to settle MCP
  plan_mode:         true,          # EnterPlanMode/ExitPlanMode tool pair (Phase 3)
  ask_user_question: true           # built-in AskUserQuestion tool + waiting-status tracking (Phase 3)
}
```

| | Claude | Codex |
|---|---|---|
| streaming | ✅ | ✅ (`app-server`) |
| interrupt | `:protocol` (control_request) | `:protocol` (`turn/interrupt`) |
| mcp | ✅ inline `--mcp-config` | ✅ via per-session `CODEX_HOME/config.toml` |
| resume | ✅ `--resume` | ✅ `thread/resume` |
| usage | ✅ | ❌ (`:none`) → panel hidden |
| system_prompt | `:flag` | `:leading_message` |
| warmup_turn | ✅ | ❌ — explicit `initialize`/`initialized` handshake; no MCP race |
| plan_mode | ✅ | ❌ — plan-mode badges/review card hidden; plan items still render via TodoWrite |
| ask_user_question | ✅ | ❌ — interactive wizard never initiates; falls back to plain assistant text |

### 3.2 Behaviour callbacks (as implemented, Phase 2)

```elixir
defmodule OrcaHub.Backend do
  @callback capabilities() :: Capabilities.t()

  # Executable + args + env + port framing for a spawn.
  # mode: :streaming | :one_shot
  # `framing` selects the decode layer; the decoder lives with Backend dispatch
  # (NOT hardcoded in SessionRunner) so a third framing is additive.
  @callback spawn_spec(mode :: atom, opts :: map) ::
              %{executable: String.t(), args: [String.t()], env: [{String.t(),String.t()}],
                port_opts: keyword, framing: :ndjson | :jsonrpc}

  # Bytes written to the port IMMEDIATELY AFTER IT OPENS — streaming spawns
  # only, never called for :one_shot. Codex: the mandatory `initialize`
  # request (the first leg of initialize -> await result -> initialized;
  # the rest of the handshake reacts to the response in normalize/2 via
  # pending_writes, below). Claude: not implemented / returns `{"", ctx}`
  # (no open-time handshake needed).
  @callback on_open(ctx :: map) :: {iodata, ctx :: map}

  # Bytes to write to stdin to start/append a user turn (streaming backends).
  @callback encode_user_turn(prompt :: String.t(), ctx :: map) :: {iodata, ctx :: map}

  # Bytes for a graceful interrupt, or :signal to fall back to SIGINT.
  @callback encode_interrupt(req_id :: String.t(), ctx :: map) :: iodata | :signal

  # Native decoded event map -> Claude-shaped events (may be []) + updated ctx.
  # STATEFUL by design: Codex needs it to correlate JSON-RPC request ids with
  # responses (thread/start's result arrives as a response, not a notification),
  # stash the latest thread/tokenUsage/updated for the synthesized `result`
  # event, coalesce deltas, and pair tool_use/tool_result ids. Claude's impl is
  # `{[event], ctx}` (identity on both).
  @callback normalize(native_event :: map, ctx :: map) :: {[map], ctx :: map}

  # Server-initiated peer request (has BOTH id and method) that must be answered
  # on stdin with the same id — e.g. Codex approval requests. Returns the reply
  # bytes, any Claude-shaped events to surface in the feed, and updated ctx.
  # Claude: never called. Codex v1: unconditionally reply acceptForSession
  # (or the closest equivalent — see §6.1's approval-decision-shape deviation).
  @callback handle_peer_request(request :: map, ctx :: map) ::
              {reply :: iodata, [map], ctx :: map}

  # Pull the backend session id out of a normalized/native event, or nil.
  @callback session_id(event :: map) :: String.t() | nil

  # Optional: materialize/cleanup per-session on-disk state (CODEX_HOME, config.toml).
  @callback prepare_session(ctx :: map) :: {:ok, extra_env :: keyword} | :ok
  @callback cleanup_session(ctx :: map) :: :ok

  # Build the system-prompt payload appropriate to this backend.
  # :flag  -> returned as an arg by spawn_spec
  # :leading_message -> prepended to the first user turn's text
  # :session_param   -> included in the backend's session-create message (grok ACP)
  @callback system_prompt(ctx :: map) :: String.t() | nil

  # Phase 3: selectable models as {id, label} pairs. `id` is the exact
  # passthrough string sent to the CLI — no enum validation; the UI also
  # accepts free text (§7). `Backend.models_for/1` resolves a session (or a
  # bare backend string) to this list.
  @callback models() :: [{String.t(), String.t()}]
end
```

`ctx` carries `session_id, directory, model, orchestrator, code_exec,
claude_session_id, project_id, db_node, engine` — the fields the runner's own
`data` map carries — **plus a `backend_state` map** owned by the adapter
(threaded through `normalize/2`, `encode_*/2`, `on_open/1`, and
`handle_peer_request/2`). SessionRunner treats `backend_state` as opaque, with
ONE reserved key:

**`backend_state.pending_writes`** — a list of iodata frames an adapter wants
written to the port as a REACTION to something it just saw, when the
triggering callback's own return shape has no direct iodata slot for it. The
canonical example: Codex's `normalize/2` sees the `initialize` response and
needs to immediately send `initialized` + `thread/start`, but `normalize/2`
returns `{[event], ctx}` — no iodata field. It queues both frames onto
`ctx.backend_state.pending_writes` instead.

**After every callback that returns `ctx`** (`normalize/2`,
`handle_peer_request/2`, `encode_user_turn/2`, `on_open/1`), SessionRunner
flushes `ctx.backend_state.pending_writes` to the port (in list order) and
resets it to `[]` — implemented ONCE, in a private `flush_pending_writes/1`
helper. Any DIRECT iodata a callback returns (`on_open/1`'s `{iodata, ctx}`,
`encode_user_turn/2`'s `{iodata, ctx}`, `handle_peer_request/2`'s
`{reply, events, ctx}`) is written first, then the pending-writes queue is
flushed on top of it. Backends that never populate the key (Claude) pay no
cost — the flush is a no-op on an empty/absent list.

`backend_state` is reset to `%{}` on every port teardown (idle timeout,
runtime kill-switch downgrade eviction) AND every unexpected crash
(`handle_streaming_exit/3`) — a fresh cold spawn always re-runs a stateful
backend's FSM from `on_open/1`, never resumes half-built state from a dead
port.

**Message routing in the runner's receive loop** (per decoded native
message, after `spawn_spec.framing`-selected decode — `StreamParser` for
`:ndjson`, `OrcaHub.Backend.JsonRpcFraming` for `:jsonrpc`):

1. has `id` **and** `method` → `handle_peer_request/2`; write reply to port
   (+ flush `pending_writes`), feed returned events into `handle_stream_event`.
2. otherwise → `normalize/2`; feed events into `handle_stream_event` (+ flush
   `pending_writes`).

For Claude (`framing: :ndjson`, no peer requests) this degenerates to exactly
the pre-Phase-2 `StreamParser.parse -> normalize -> handle_stream_event` path
— case 1 never matches Claude's vocabulary, and `pending_writes` is always
empty, so nothing observably changed for Claude sessions (the Phase 0
conformance tests assert this).

### 3.3 Normalization: the invariant

Every backend's `normalize/2` MUST emit events in the **Claude `stream-json`
vocabulary**, because those maps are persisted verbatim and rendered directly:

- `%{"type" => "system", "session_id" => …, "subtype" => …}`
- `%{"type" => "assistant", "message" => %{"content" => [%{"type"=>"text"|"thinking"|"tool_use", …}]}}`
- `%{"type" => "user", "message" => %{"content" => [%{"type"=>"tool_result", …}]}}`
- `%{"type" => "result", "is_error" => bool, "total_cost_usd" => …, "duration_ms" => …, "usage" => …}`

A backend that surfaces a novel event type it can't map should emit nothing (drop)
rather than a foreign shape — the renderer's unknown-`type` fallback dumps raw
JSON, which we reserve for genuinely unknown tool *names*, not event types.

**Tool-use id pairing is part of the invariant.** `MessageComponents` groups by
`tool_use_id`/`parent_tool_use_id` (message_components.ex ~19–49) to pair each
`tool_use` with its `tool_result` and to nest subagent feeds. Every synthesized
`tool_use` MUST carry a stable unique `id`, echoed as `tool_use_id` on its
`tool_result`. Codex item ids are unique per thread — use them verbatim.

**Missing-field tolerance.** Non-Claude backends won't populate every `result`
field (`total_cost_usd`, `duration_ms` — read by the result card at
message_components.ex ~468). String-key map access renders missing keys as
nil rather than crashing, but this is load-bearing now: assert it in tests (§9)
and keep new renderer code nil-tolerant on `result` fields.

---

## 4. Data model changes

- **Migration:** add `backend :string, null: false, default: "claude"` to
  `sessions`.
- `OrcaHub.Sessions.Session`: add `field :backend, :string, default: "claude"`;
  changeset validates inclusion in `["claude", "codex"]`.
- **Reuse `claude_session_id` as the generic backend session id** (holds Codex's
  `thread_id`). No rename migration; document that the column is backend-scoped.
  (Optional later cleanup: rename → `agent_session_id`.)
- New-session creation path carries `backend` alongside `model`
  (`Sessions.create_session`, `Cluster` start path, LiveView form).

---

## 5. `SessionRunner` refactor (Phase 0, zero behavior change)

The runner keeps its state machine. Mechanical replacements:

| Current | Becomes |
|---|---|
| `Config.build_args(...)` + `find_executable("claude")` in `open_port*` | `data.backend.spawn_spec(mode, ctx)` |
| `user_turn_json/1`, `write_warmup_turn/1` | `data.backend.encode_user_turn/2`; warm-up gated on `capabilities.warmup_turn` |
| `control_interrupt_json/1` / `send_sigint/1` | `data.backend.encode_interrupt/2` (`:signal` → keep SIGINT path) |
| `StreamParser.parse` → `handle_stream_event` | decode (per `spawn_spec.framing`) → peer-request check → `data.backend.normalize/2` → existing `handle_stream_event` on Claude-shaped maps |
| `claude_session_id` capture from `system.session_id` | `data.backend.session_id/1` |
| `mcp_config/1` inline JSON | `data.backend.prepare_session/1` returns extra env (Codex) OR spawn arg (Claude) |
| `build_system_prompt/1` via `--append-system-prompt` | `capabilities.system_prompt` decides flag vs leading-message |

**Warm-up gating is more than skipping the write.** The runner has a dedicated
`handle_stream_event(event, %{warming_up: true})` suppression branch
(session_runner.ex ~1062) that swallows the entire hidden warm-up turn. For
`warmup_turn: false` backends the runner must never enter `warming_up: true` at
all — gate the state flag, not just `write_warmup_turn/1` — otherwise the first
real turn gets suppressed.

`Backend.Claude` implements all of these as thin wrappers over the code that
exists today, so Phase 0 produces identical Claude behavior. **Verify Claude
end-to-end before writing any Codex code.**

---

## 6. Codex adapter (`Backend.Codex`)

**Primary transport: `codex app-server`** — long-lived JSON-RPC 2.0 over
newline-delimited stdio. Maps onto the streaming runner (long-lived port, warm
pool, protocol interrupt). `codex exec --json` is the `:one_shot`-engine
fallback.

### 6.1 Wire protocol (VERIFIED — ground-truthed against codex-cli 0.142.5)

**Ground truth:** `codex app-server generate-json-schema --experimental --out
./schemas` (codex-cli **0.142.5**, installed via `npm install -g
@openai/codex`) emits the authoritative JSON Schema for every method/
notification/item shape — `--experimental` is needed or several
experimental-API methods/fields are omitted. Cross-checked with a live
no-API-key handshake capture (`initialize` → `thread/start`, no `turn/start`,
so no model call / no cost). The SDK-corroborated draft below was accurate on
almost every point; **deviations found are called out inline with a
"0.142.5:" prefix.**

**0.142.5 deviations from the original SDK-corroborated draft:**
- `ThreadStartParams.sandbox` is a **kebab-case STRING enum**
  (`"read-only" | "workspace-write" | "danger-full-access"`), NOT the
  `SandboxPolicy` object shape (`{"type":"dangerFullAccess"}`) — that object
  shape is `TurnStartParams.sandboxPolicy` (a per-turn OVERRIDE) and
  `ThreadStartResponse.sandbox` (the response echo), not the request field.
  Live-verified: `thread/start` with `"sandbox":"danger-full-access"` returns
  `"sandbox":{"type":"dangerFullAccess"}` in the response — same policy, two
  different shapes at request vs. response time.
- `item/permissions/requestApproval`'s response is **NOT** `{"decision":…}`
  like the other two approval types — it's
  `{"permissions": GrantedPermissionProfile, "scope"?, "strictAutoReview"?}`
  (all fields optional; `{}` is a valid minimal grant). Only reachable under a
  `granular` `AskForApproval` policy we don't request in v1, so this is a
  backstop-of-a-backstop, but `handle_peer_request/2` branches on `method` to
  send the right shape rather than assuming a uniform `{"decision":…}` across
  all three.
- `mcp_servers.<name>.experimental_use_rmcp_client` **does not exist** in
  0.142.5's config schema (confirmed: absent from the full `ConfigToml` field
  dump in the compiled binary's string table). Streamable-HTTP MCP servers
  work directly via `[mcp_servers.<name>] url = "…"` — no flag needed; live
  round-tripped with `codex mcp add orca --url <url>` writing exactly that.
  `default_tools_approval_mode` (`"auto" | "prompt" | "approve"`) IS real and
  confirmed (string-table `PluginMcpServerConfig` dump).
- `agentMessage.phase` (`MessagePhase`: `"commentary" | "final_answer"`) is
  explicitly documented by the schema as inconsistently emitted across model
  providers ("callers must treat `None` as phase unknown and keep
  compatibility behavior for legacy models") — the normalizer maps EVERY
  completed `agentMessage` item to assistant text regardless of `phase`,
  rather than filtering to `phase:"final_answer"` only.
- Everything else below (framing, message discrimination, handshake shape,
  thread/turn lifecycle, notification names, item shapes, token usage
  location, approval method names) matched the SDK-corroborated draft
  exactly.

**Launch:** `codex app-server` (stdio is the default transport; no flag). WS/unix
transports exist but are unneeded for a local port.

**Auth (child env):** precedence `CODEX_API_KEY` → `auth.json "OPENAI_API_KEY"` →
`OPENAI_API_KEY` → ChatGPT OAuth in `auth.json`. Set `OPENAI_API_KEY` in the
spawned child's env for API-key auth, or rely on a prior `codex login` writing
`$CODEX_HOME/auth.json`. **`CODEX_HOME` isolates config/sessions/auth per
session** — this is our per-session lever (see §6.3). Because that isolation
also hides the user's real `auth.json`, `prepare_session/1` copies it from the
source `CODEX_HOME` (env, else `~/.codex`) into the per-session home on every
spawn — without this, `codex login` credentials never reach the child.

**Framing:** newline-delimited JSON, JSON-RPC 2.0 shapes but the `"jsonrpc":"2.0"`
field is **OMITTED on the wire**; `params`/`data` omitted when empty. One compact
object per line, UTF-8. IDs may be **int or string** (echo the server's id
verbatim when answering peer requests).
- Request (client→server): `{"id":10,"method":"thread/start","params":{…}}`
- Response: `{"id":10,"result":{…}}` XOR `{"id":10,"error":{"code",…}}`
- Notification (no `id`): `{"method":"turn/started","params":{…}}`

**Message discrimination (critical — server issues peer requests too):**
| shape | meaning |
|---|---|
| has `id` **and** `method` | **peer request from server** (approval) — you MUST respond with same `id` |
| `method`, no `id` | notification |
| `id` + `result` | response to your request |
| `id` + `error` | error response |

**Handshake is mandatory** before any other method: send `initialize` request
→ await result → send `initialized` notification (no params). Calls before this
error with `"Not initialized"`. `initialize` params:
```json
{"id":0,"method":"initialize",
 "params":{"clientInfo":{"name":"orca_hub","version":"…"},
           "capabilities":{"experimentalApi":true}}}
```
`experimentalApi:true` is needed for granular approval policies / `approvalsReviewer`.
Optional `capabilities.optOutNotificationMethods:["item/agentMessage/delta",…]`
suppresses noisy deltas. **This handshake replaces Claude's warm-up-turn hack** —
there is no MCP-registration race to work around (MCP startup surfaces via
`mcpServer/startupStatus/updated` notifications). ⇒ Codex `warmup_turn: false`.

**Thread/turn lifecycle:**
- `thread/start {model, cwd, approvalPolicy, sandbox, baseInstructions|developerInstructions, config, …}`
  → `result.thread.id` (**persist this**; = the resume `threadId`).
- `turn/start {threadId, input:[…blocks…], model, effort, sandboxPolicy, approvalPolicy, outputSchema?}`
  → `result.turn = {id, status:"inProgress", items:[], error:null}`, then streams
  notifications. `input` is an **array of blocks**: `{"type":"text","text":…}`,
  `{"type":"image","url":…}`, `{"type":"localImage","path":…}`,
  `{"type":"mention",…}`, `{"type":"skill",…}` (bare string auto-wrapped as text).
- `turn/steer {threadId, input, expectedTurnId}` — inject input into the in-flight
  turn (an alternative to interrupt-then-resend for our queued-prompt path).
- `turn/interrupt {threadId, turnId}` → `{}`; turn ends with
  `turn/completed status:"interrupted"`, **thread survives** (start/steer next turn).
- `thread/resume {threadId, …}` / `thread/fork {threadId}` (fork returns a new id).

**Notifications during a turn** (SDK-verified names):
`turn/started {turn.id}` · `item/started {item}` · deltas
(`item/agentMessage/delta {itemId,delta}`, `item/reasoning/textDelta`,
`item/commandExecution/outputDelta`) · `item/completed {item}` ·
`turn/plan/updated {plan:[{step,status}]}` · `turn/diff/updated {diff}` ·
`turn/completed {turn:{id,status,items,error}}` · `error {error,willRetry,…}`.

**⚠ Token usage is NOT on `turn/completed`.** It arrives on
`thread/tokenUsage/updated`: `params.tokenUsage.{total,last}` each
`{totalTokens,inputTokens,cachedInputTokens,outputTokens,reasoningOutputTokens}`,
plus `params.rateLimits`. Our normalizer must synthesize the `result` event's
usage from the latest `thread/tokenUsage/updated`, then emit `result` on
`turn/completed`.

**Item shapes** (`type` camelCase): `agentMessage {text, phase}` (**final answer
text**, `phase:"final_answer"`) · `reasoning {summary,content}` ·
`commandExecution {command,cwd,aggregatedOutput,exitCode,status,durationMs}` ·
`fileChange {changes:[{path,kind:add|delete|update,diff}]}` ·
`mcpToolCall {server,tool,arguments,result,error,status}` · `webSearch {query}` ·
`plan {text}`.

**Approvals** are peer requests (id+method, server→client):
`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval`. Respond `{"id":<same>,"result":{"decision":…}}`
with `decision ∈ accept | acceptForSession | decline | cancel`. **For hands-off
operation:** `approvalPolicy:"never"` + permissive `sandboxPolicy` + MCP
`default_tools_approval_mode="auto"` so none are raised; the
`handle_peer_request/2` callback (§3.2) is the backstop — Codex v1 implements it
as unconditional `acceptForSession`.

> **Reference impl:** `nshkrdotcom/codex_sdk` (cloned to scratchpad during
> research). Key files to mirror: `app_server/connection.ex` (GenServer owning the
> child; requests/init run in Tasks off the loop; `:ready` phase gate),
> **`io/buffer.ex` (manual binary accumulator split on `\n`, NOT `{:packet,:line}`
> — tolerates non-JSON stdout noise; replicate exactly)**, `app_server/protocol.ex`
> (framing + message discriminator), `app_server/notification_adapter.ex` &
> `item_adapter.ex` (decode tables = authoritative field names),
> `app_server/approvals.ex` (non-blocking peer-request reply via ref token).

### 6.2 Normalization map (Codex native → Claude shape)

| Codex event | Claude-shaped output |
|---|---|
| `thread/start` result `thread.id` | `%{"type"=>"system","session_id"=>thread_id,"subtype"=>"init"}` |
| `item/completed{agentMessage,text,phase:"final_answer"}` | `%{"type"=>"assistant","message"=>%{"content"=>[%{"type"=>"text","text"=>…}]}}` |
| `item/completed{reasoning}` (or `item/reasoning/textDelta`) | assistant `content` `%{"type"=>"thinking","thinking"=>…}` |
| `item/completed{commandExecution}` | `assistant` `tool_use` (name `"Bash"`, `command`→input) + `user` `tool_result` (`aggregatedOutput`/`exitCode`) |
| `item/completed{fileChange{changes}}` | `tool_use` (`Write`/`Edit` per `kind`) + `tool_result` |
| `item/completed{mcpToolCall{server,tool}}` | `tool_use` name `mcp__{server}__{tool}` + `tool_result` |
| `item/completed{webSearch}` | `tool_use` `WebSearch` + `tool_result` |
| `turn/plan/updated{plan}` | `tool_use` `TodoWrite` (feeds existing todos.ex) |
| `thread/tokenUsage/updated{tokenUsage}` | stash latest usage in `ctx` (not emitted alone) |
| `turn/completed{status:"completed"}` | `%{"type"=>"result","is_error"=>false,"usage"=>«latest tokenUsage»,…}` |
| `turn/completed{status:"failed"}` / `error` | `%{"type"=>"result","is_error"=>true,…}` |
| `turn/completed{status:"interrupted"}` | `%{"type"=>"result","is_error"=>false,…}` (user stop, not error) |

**Streaming deltas** (`item/agentMessage/delta`, `item/commandExecution/outputDelta`):
v1 ignores deltas and renders on `item/completed` only (Q7 — RESOLVED); prefer
`optOutNotificationMethods` at `initialize` to suppress them at the source.
Usage is carried in `ctx.backend_state` from the most recent
`thread/tokenUsage/updated` and attached when the `result` event is synthesized
at `turn/completed` — this is why `normalize/2` returns `{events, ctx}` (§3.2).
`tool_use`/`tool_result` pairs synthesized from one item reuse the Codex item id
as the `tool_use` `id` / `tool_result` `tool_use_id` (§3.3 pairing invariant).

Mapping command/file/mcp items to the existing tool-name icons means
`MessageComponents` renders Codex runs with zero rendering changes.

### 6.3 Codex-specific gaps & graceful degradation

1. **System prompt** — no `--append-system-prompt`; `experimental_instructions_file`
   400s on GPT-5-Codex. → `system_prompt: :leading_message`: prepend a
   Codex-flavored system prompt (`Backend.Codex.system_prompt/1`, sharing the
   non-Claude-specific fragments with `Backend.Claude` via
   `OrcaHub.Backend.SharedPrompts` — code-exec mode, project `.context/`
   files, the commit trailer; the `AskUserQuestion` guidance and the
   `mcp__server__tool` naming caveat are genuinely Claude-CLI-specific and
   dropped) to the first user turn per thread.
2. **MCP** — config-file only (no inline `mcpServers` param on `thread/start`).
   → `prepare_session/1` writes a per-session `CODEX_HOME` with a generated
   `config.toml`; **IMPLEMENTED as-built:** `spawn_spec/2` independently
   computes the SAME deterministic `CODEX_HOME` path and bakes it into the
   child's env itself (both derive it from `ctx.directory`/`ctx.session_id`
   via the same private helper), so `prepare_session/1` returns plain `:ok`
   — no `extra_env` plumbing through the runner needed for Codex (the
   `{:ok, extra_env}` shape in the behaviour remains available for a future
   backend that DOES need it). `cleanup_session/1` removes the directory.
   0.142.5-verified minimal streamable-HTTP stanza for the orca server (see
   §6.1's deviation note — no `experimental_use_rmcp_client` flag exists):
   ```toml
   [mcp_servers.orca]
   url = "http://localhost:4000/mcp?orca_session_id=…&orchestrator=…&code_exec=…"
   default_tools_approval_mode = "auto"          # run orca tools w/o prompting
   ```
   The URL is built by `OrcaHub.Backend.McpUrl.orca_url/1` — the SAME helper
   `Backend.Claude`'s inline `--mcp-config` JSON uses, extracted in Phase 2 so
   the query params (`orca_session_id`, `orchestrator`, `code_exec`) can never
   drift between the two backends. Combine with `thread/start`
   `approvalPolicy:"never"` + `sandbox:"danger-full-access"` so nothing
   prompts. Keep an auto-`acceptForSession` (or method-appropriate — see
   §6.1) peer-request handler as a backstop in case an approval is still
   raised. **Not implemented in v1:** project/session-scoped MCP servers
   (`UpstreamServers.list_enabled_servers_for_*`) are NOT added to Codex's
   `config.toml` — only the orca server. Claude gets all scoped servers via
   its inline `--mcp-config`; Codex sessions get orca tools only for now
   (documented gap, not a silent drop — add per-server TOML stanzas in a
   follow-up if needed).
3. **Usage** — no headless quota endpoint. → `usage: :none`; the usage panel is
   hidden for Codex sessions. Per-turn token counts from `turn.completed.usage`
   still flow into the `result` event for display.
4. **Plan mode** — no `~/.claude/plans`/`EnterPlanMode`. → hidden for Codex
   (capability-gated); Codex `todo`/plan items still render via TodoWrite mapping.
5. **AskUserQuestion** — Claude built-in tool absent. → falls back to a plain
   assistant question; `waiting` status not auto-driven for Codex.
6. **Login** — no `claude setup-token`. → Codex uses `OPENAI_API_KEY` (env) or
   `codex login` (`~/.codex/auth.json`); node-login UI branches per backend
   (or defers to env for v1).
7. **Interrupt** — `turn/interrupt` (graceful, thread survives) for streaming;
   SIGINT for the `codex exec` one-shot fallback.

---

## 7. UI changes

- **New-session form:** backend selector (`Claude` / `Codex`) → model list scoped
  to the chosen backend. Codex models are passthrough strings (e.g. `gpt-5.5`,
  `gpt-5.3-Codex-Spark`) — no hardcoded enum; keep a small default list + free entry.
- **Session header / model picker:** show backend; restrict model buttons to the
  session's backend.
- **Capability-gated chrome:** usage panel, plan-mode affordances, and
  AskUserQuestion rendering appear only when the session's backend advertises them.
- **`mcp: false` gating:** hide the orchestrator/code_exec toggles on session
  creation for backends without MCP support (pi, unless/until an extension
  bridges it — §12.2).

**IMPLEMENTED as-built (Phase 3):**

- `OrcaHub.Backend.capabilities_for/1` and `OrcaHub.Backend.models_for/1`
  (`lib/orca_hub/backend.ex`) resolve a session (or a bare `backend` column
  value) to its `Capabilities` struct / `{id, label}` model list. Both accept
  `nil` without raising (legacy rows → Claude); templates and LiveViews call
  these, never the backend name string.
- `SessionLive.Show` assigns `:capabilities` once at mount
  (`Backend.capabilities_for(session)`) and every template gate below reads
  off that struct.
- **Usage:** the global "Usage" nav link (`OrcaHubWeb.Layouts.app/1`,
  `lib/orca_hub_web/components/layouts.ex`) — the only UI backed by
  `OrcaHub.Claude.Usage` — is hidden while viewing a session whose
  capabilities have `usage: false`. It's a node-level page, not
  session-scoped, so this is "hidden while looking at an incapable session,"
  not a per-session widget (none existed to gate).
- **Plan mode:** the "planning"/"needs review" header badges and the plan
  review card (`session_live/show.html.heex`) are gated on
  `@capabilities.plan_mode`, on top of the fact that `@plan_mode` can
  structurally never become non-`false` for Codex (it only flips on the
  Claude-only `EnterPlanMode`/`ExitPlanMode` tool names).
- **AskUserQuestion:** the interactive wizard modal, and the `aq_open`
  flag that opens it (`assign_ask_user_question/3`, `sync_question_modal/1`
  in `session_live/show.ex`), are gated on `@capabilities.ask_user_question`.
  Persisted question messages still render in the feed via the normal
  tool_use/tool_result path (unaffected — MessageComponents doesn't
  special-case AskUserQuestion beyond generic tool rendering).
- **MCP toggles:** the orchestrator-mode checkbox (new-session form) /
  toggle button (session header) and the MCP-servers modal + its header
  button are hidden when `capabilities.mcp == false`. Both current backends
  have `mcp: true`, so this is inert wiring today, asserted by tests that it
  still shows for both.
- **Model picker:** `Backend.Claude.models/0` returns the exact pre-Phase-3
  hardcoded list (Opus 4.8 / Sonnet 4.6 / Haiku 4.5).
  `Backend.Codex.models/0` returns a small default list
  (`gpt-5-codex`, `gpt-5.3-Codex-Spark`, `gpt-5.5` — the latter two are this
  section's own example passthrough strings). The new-session form's model
  field is a single text input + `<datalist>` of backend-scoped suggestions
  (native free-text entry, no enum); it re-renders on the existing
  `"validate"` LiveView event (already firing on every field change,
  including the backend `<select>`) — no new event was needed. The in-session
  model switcher (`session_live/show.html.heex`) iterates
  `Backend.models_for(@session.backend)` plus a small custom-model form.
- **Backend badge:** the session header shows a subtle badge with the
  capitalized backend name, but ONLY when `@session.backend != "claude"` — no
  visual change for the (still overwhelmingly common) Claude case.

---

## 8. Phasing & deliverables

- **Phase 0 — Seam extraction (no behavior change).** `Backend` behaviour +
  `Capabilities` + `Backend.Claude` (verbatim move); route `SessionRunner` through
  it; `backend` field defaults to Claude. **Gate: Claude works byte-for-byte
  (manual + existing tests).** Commit.
- **Phase 1 — Schema + selection.** Migration; `Session` field/changeset; create
  path + `Cluster` plumb `backend`; new-session UI picker. Commit.
- **Phase 2 — Codex adapter. LANDED.** `Backend.Codex` over `codex app-server`
  (framing, thread/turn/item → normalize), `codex exec --json` one-shot
  fallback, per-session `CODEX_HOME`+`config.toml` for orca MCP,
  `turn/interrupt`, `thread/resume`, leading-message system prompt. Runner
  contract extended (`on_open/1`, `pending_writes`, `:jsonrpc` framing/message
  routing — §3.2) with the Phase 0 Claude conformance tests staying green
  unchanged. Gated by: full test suite (Claude regression + new Codex
  normalization fixtures + a stub-app-server SessionRunner integration test —
  254 tests, 1 pre-existing unrelated failure) and a live smoke run against
  the real CLI. **Live smoke outcome (RESOLVED):** handshake + MCP config
  materialization + `turn/interrupt` (mid-turn, against a real
  `codex app-server` process) verified live during Phase 2; the model turn
  itself was initially blocked by a 401 (account/key-scope restriction on
  the Responses API — not an OrcaHub bug). After the user signed in via
  ChatGPT `codex login`, the live smoke surfaced one real adapter gap: the
  per-session `CODEX_HOME` hid `~/.codex/auth.json`, so the spawned
  app-server had no credentials at all (401 even with a valid login).
  Fixed: `prepare_session/1` now copies `auth.json` from the source
  `CODEX_HOME` (env override, else `~/.codex`) into the per-session home,
  mode 0600, re-copied on every spawn so re-logins are picked up. Known
  caveat: a mid-session ChatGPT token refresh writes to the session copy
  only; the source stays stale until the user's next interactive codex run.
  With that fix, a full live turn PASSED through the real SessionRunner
  path (`gpt-5.5`, ChatGPT auth): user message persisted, `system`/init
  with thread id, `assistant` text, `result` with token usage — the
  normalized message shapes rendered by the existing components. Also
  surfaced a pre-existing (not Codex-specific) gap — see §10 Q5's addendum
  on `trap_exit`.
- **Phase 3 — Peripherals. LANDED.** `Capabilities` grew `plan_mode` and
  `ask_user_question` fields; `capabilities_for/1`/`models_for/1` helpers;
  `SessionLive.Show` assigns `:capabilities` once at mount and every
  capability-gated chrome element (§7) branches on it. Backend-scoped model
  picker (new-session `<datalist>` + in-session switcher) replaces the
  hardcoded Claude-only lists; free-text entry for passthrough Codex model
  ids. Cleanup-on-stop fix (§10 Q5 addendum, resolved below) —
  `SessionSupervisor.stop_session/1` now calls `backend.cleanup_session/1`
  directly, so Codex's `CODEX_HOME` is removed on an explicit stop too, not
  just on runner-process death. Renderer check: zero `MessageComponents`
  changes needed (confirmed by feeding real `Backend.Codex.normalize/2`
  output through `message_feed/1` in a test — §6.2's tool-name mapping onto
  Bash/Write/Edit/mcp__*/WebSearch/TodoWrite already renders with existing
  icon/summary code). Docs updated (`CLAUDE.md`, this spec). Gated by: full
  test suite (283 tests, the same 1 pre-existing unrelated `TriggersTest`
  failure as Phase 0-2's baseline). Commit.

---

## 9. Testing

- **Phase 0 regression:** existing SessionRunner/streaming tests must pass
  unchanged; add a `Backend.Claude` conformance test asserting identity
  normalization and byte-identical arg/frame output vs. the pre-refactor code.
- **Normalization unit tests:** feed captured Codex `app-server` JSONL fixtures to
  `Backend.Codex.normalize/2`, assert Claude-shaped output → rendered by existing
  components. Cover the stateful paths explicitly: tokenUsage stashed then attached
  to `result`; JSON-RPC response↔request id correlation; `tool_use` id / `tool_result`
  `tool_use_id` pairing; peer request → `handle_peer_request` reply bytes.
- **Renderer nil-tolerance:** `result` card renders without `total_cost_usd` /
  `duration_ms` / `usage` (non-Claude backends omit them).
- **Capability gating:** LiveView tests that usage/plan-mode/AskUserQuestion chrome
  is absent for a Codex session and present for Claude.
- **Live smoke:** one real Codex multi-turn session (MCP tool call + interrupt +
  resume after cold teardown).

---

## 10. Open questions

- ~~Q1: warm-up turn for MCP?~~ **RESOLVED — no.** App-server has an explicit
  `initialize`/`initialized` handshake; no MCP-registration race. `warmup_turn:false`.
- ~~Q2: MCP servers inline in `thread/start`?~~ **RESOLVED — no inline param.**
  Config-file (`CODEX_HOME/config.toml`) or runtime `config/value/write`. Phase 2
  picks between the two.
- ~~Q3: temp `CODEX_HOME`+`config.toml` vs. runtime `config/value/write` for the
  orca server?~~ **RESOLVED — the file, Phase 2 as-built.** `config/value/write`
  would mutate a config layer we'd then need to unwind; a per-session file is
  simpler to reason about and to clean up deterministically (see Q5).
- Q4 (open): Rename `claude_session_id` → `agent_session_id` now (migration) or
  defer? (Reuse works; rename is cosmetic.) Still deferred post-Phase-2 — no
  new pressure to rename it; Codex's thread id round-trips through the column
  exactly like Claude's session id does.
- ~~Q5: Per-session `CODEX_HOME` location on disk + cleanup on runner
  terminate/crash?~~ **RESOLVED, Phase 2 as-built:**
  `<session.directory>/.codex_home/<session_id>/` — under the session's own
  working directory (not `/tmp`; codex 0.142.5 warns and refuses to install
  PATH-alias helpers under a temp-dir `CODEX_HOME`), in a dotdir, keyed by
  session id so concurrent sessions sharing a directory don't collide.
  `prepare_session/1` rewrites `config.toml` on EVERY spawn (mirrors Claude's
  per-spawn `--mcp-config` bake — an orchestrator/code_exec flag flip is
  picked up on the next cold reopen, same as Claude). `cleanup_session/1`
  removes the directory, called from `SessionRunner.terminate/3` — i.e. on
  RUNNER-PROCESS death, not on every idle-timeout port teardown, so a warm
  process cycling cold/warm within one runner's life doesn't repeatedly
  create/destroy the directory. `backend_state` (the in-memory protocol FSM)
  is separately reset to `%{}` on every port teardown/crash (§3.2) — that's
  independent of the on-disk `CODEX_HOME`, which persists across those cycles.
  ⚠ **Gap found during the Phase 2 live smoke test (pre-existing, NOT
  introduced by Codex):** `SessionRunner` never calls
  `Process.flag(:trap_exit, true)`, and `GenStatem`/`:gen_statem` does not do
  so automatically. `terminate/3` DOES run on a crash or an internal
  `{:stop, reason}` return (both go through `:gen_statem`'s own loop), but
  `SessionSupervisor.stop_session/1` → `DynamicSupervisor.terminate_child/2`
  sends a raw `exit(pid, :shutdown)`, which — since the process isn't
  trapping exits — kills it immediately WITHOUT running `terminate/3`.
  Live-verified: a session stopped via `stop_session/1` left its
  `CODEX_HOME` directory on disk. Pre-existing for the `Port.close/1` call in
  `terminate/3` too (harmless there — a dying process's ports auto-close
  regardless), but genuinely leaks `cleanup_session/1`'s on-disk state on
  this path.

  **RESOLVED, Phase 3 as-built:** fixed the narrow way instead of flipping
  `trap_exit` globally (which would change shutdown semantics for every
  crash/exit path across every backend, not just this one).
  `SessionSupervisor.stop_session/1` (`lib/orca_hub/session_supervisor.ex`)
  calls `Backend.resolve(session.backend).cleanup_session/1` directly, once
  `DynamicSupervisor.terminate_child/2` confirms the child is gone.
  `cleanup_session/1` only ever needed `directory`/`session_id` — never a
  live runner process — so this works purely off the DB record, with no
  changes to `SessionRunner`, `terminate/3`, port teardown, or WarmPool
  semantics. Blast radius: one new private function in
  `SessionSupervisor`, called only from the existing `stop_session/1`
  success path, wrapped in the same `try/rescue` that already guards the
  post-termination status sync (a cleanup failure can't fail
  `stop_session/1`'s return value). No-op for Claude
  (`cleanup_session/1` is `:ok`). Covered by
  `test/orca_hub/session_supervisor_test.exs`, which stops a real
  stub-app-server-backed Codex session and asserts `CODEX_HOME` is gone.
- ~~Q6: `turn/steer` vs interrupt-then-resend for queued prompts?~~ **RESOLVED —
  interrupt-then-resend for v1.** It matches the existing queued-prompt semantics
  exactly; `steer` is a later optimization behind a capability if wanted.
- ~~Q7: stream deltas incrementally?~~ **RESOLVED — `item/completed` only for v1.**
  Deltas add PubSub churn and a coalescing layer for zero persistence benefit;
  opt out at `initialize` where possible.

---

## 11. Non-goals (v1)

- Codex transcript import (`~/.codex/sessions`), analogous to `claude_import`.
- Codex usage/quota scraping.
- Node-login UI parity for Codex (env-based auth acceptable initially).
- grok / pi adapter *implementations* (protocol research + capability rows in
  §12 now; adapters are additive later).
- Raw-API backends (no CLI). See scope note in the header — a bare chat API has
  no tool executor; multi-provider CLIs are the on-ramp for API-only models.

---

## 12. Future backends: grok CLI & pi (research findings)

**Rule: no adapter gets written before a §6-style verified protocol section
exists for its CLI.** The capability table and adapter design must come from
observed wire behavior (docs + source + a captured session), not assumption.
This section records the research pass for the two named future targets.

### 12.1 grok CLI (VERIFIED — live binary capture + embedded docs, 2026-07-02)

**Canonical CLI = xAI's official "Grok Build" CLI** (`grok`, Rust binary,
install via `curl -fsSL https://x.ai/cli/install.sh | bash`; verified against
v0.2.82). Docs: docs.x.ai/build/cli/headless-scripting. ⚠ The community
`superagent-ai/grok-cli` (npm `grok-dev`, formerly `@vibe-kit/grok-cli`) is a
DIFFERENT unaffiliated project with different flags — many blog posts conflate
them; ignore it.

**Fit: excellent.** The embedding mode is **`grok agent stdio`** — ACP
(Agent Client Protocol, agentclientprotocol.com): JSON-RPC 2.0,
newline-delimited, over stdio. Live-captured handshake confirmed on 0.2.82.
ACP is an open standard also spoken by Zed and Gemini CLI, so an ACP decode
layer is reusable beyond grok (an Elixir client lib exists: ACPex on hex).

- **Spawn:** `grok agent stdio` with `XAI_API_KEY` in child env (live-verified:
  unlocks the `xai.api_key` auth method, no `authenticate` call needed).
  Always pass `--no-auto-update`. ⚠ Unauthenticated runs block on interactive
  device-auth — preflight auth before spawning.
- **Handshake:** `initialize {protocolVersion:1, clientCapabilities}` →
  `session/new {cwd, mcpServers:[…]}` → `result.sessionId` (UUIDv7 — persist).
  Replaces warm-up (`warmup_turn: false`). **Advertise NO fs/terminal client
  capabilities** so grok uses its own executor instead of delegating
  `fs/read_text_file`/`terminal/*` requests to us.
- **Turns:** repeated `session/prompt {sessionId, prompt:[{type:"text",…}]}` on
  one process; response carries `stopReason` + `_meta.{totalTokens,inputTokens,outputTokens}`.
- **Interrupt:** `session/cancel` notification → in-flight prompt resolves
  `stopReason:"cancelled"` ⇒ `:protocol`.
- **Resume:** `session/load {sessionId, cwd, mcpServers}` (capability
  `loadSession:true` live-confirmed). Session store: `~/.grok/sessions/`
  (`GROK_HOME` overrides `~/.grok` — the per-session isolation lever, same role
  as `CODEX_HOME`).
- **MCP:** first-class — `mcpServers` array passed inline in
  `session/new`/`session/load`, `mcpCapabilities:{http:true,sse:true}` ⇒ orca's
  streamable-HTTP URL works directly, no config file needed (better than Codex).
  ⚠ **Compat auto-merge:** grok auto-loads MCP servers from `~/.claude.json`,
  `.cursor/mcp.json`, and project `.mcp.json` (live-verified: it picked up the
  user's "orca" server from Claude config — with the wrong/stale session
  params). `prepare_session/1` must disable this (`[compat.claude] mcps=false`
  / `GROK_CLAUDE_MCPS_ENABLED=0`, or an isolated `GROK_HOME`) so the only orca
  server is the one we inject with the right `orca_session_id`.
- **System prompt:** `--rules <text>` appends; ACP `session/new` `_meta.rules`
  / `_meta.systemPromptOverride` ⇒ `system_prompt: :session_param` (§3.1 enum
  gains this value: delivered as a session/new parameter, not a CLI flag or
  leading message).
- **Events → normalize** (`session/update` notifications,
  `params.update.sessionUpdate`): `agent_message_chunk`/`agent_thought_chunk`
  are DELTA-only — unlike Codex there is no completed-message event, so the
  normalizer must accumulate chunks in `backend_state` and emit the assistant
  text/thinking event at turn end (`session/prompt` response). `tool_call
  {toolCallId,title,kind,status,rawInput}` → `tool_use`; `tool_call_update
  {toolCallId,status,content}` (terminal status) → `tool_result` (ids pair
  natively). `plan` → TodoWrite. `session/prompt` response → synthesized
  `result` with `_meta` token counts. Parser must tolerate unknown/unsolicited
  methods (`x.ai/*` notifications, `skills-reload` observed live).
- **Peer requests:** `session/request_permission` → `handle_peer_request/2`,
  reply `{"outcome":{"outcome":"selected","optionId":"allow_always"}}`; avoid
  most prompts up front with `--permission-mode bypassPermissions` (or
  `--always-approve`) at spawn.
- **Tool-name mapping** (internal ids → Claude icon names):
  `run_terminal_cmd`→Bash, `search_replace`→Edit, `read_file`→Read,
  `grep`→Grep, `list_dir`→LS, `web_search`→WebSearch, `web_fetch`→WebFetch,
  `spawn_subagent`→Task, `search_tool`/`use_tool`→MCP dynamic discovery.
- **Models:** `-m/--model`, default `grok-build`; `--effort low…max`; ACP
  `session/set_model`. BYO models via `[model.<name>]` in config.toml.

**Capability row:**

| capability | grok |
|---|---|
| streaming | ✅ (`grok agent stdio`, ACP) |
| interrupt | `:protocol` (`session/cancel`) |
| mcp | ✅ (inline `mcpServers` in session/new, http/sse) |
| resume | ✅ (`session/load`) |
| usage | `:none` for account quota; per-turn tokens from `session/prompt` response `_meta` |
| system_prompt | `:session_param` (`_meta.rules`) |
| warmup_turn | ❌ (initialize handshake) |

One-shot fallback exists (`grok -p --output-format streaming-json`) but hides
tool activity (text/thought/end/error only) — acceptable for the `:one_shot`
engine, but ACP is the real mode.

### 12.2 pi (VERIFIED — docs + source, 2026-07-02)

Mario Zechner's coding agent. Repo `github.com/earendil-works/pi` (formerly
`badlogic/pi-mono`); npm `@earendil-works/pi-coding-agent` (v0.80.3, `bin: pi`);
very active. Docs: `pi.dev/docs` + `packages/coding-agent/docs/{rpc,json,sdk,session-format,providers}.md`.

**Fit: excellent.** `pi --mode rpc` is a long-lived bidirectional JSONL-over-stdio
process explicitly built for non-Node embedding — functionally equivalent to
Claude's `stream-json` streaming mode, in places richer.

- **Spawn:** `pi --mode rpc --provider <p> --model <m> [--session <id>|--no-session] [--append-system-prompt …]`.
- **Framing:** strict JSONL, LF-only delimiter. Custom command/response/event
  protocol (NOT JSON-RPC): stdin commands optionally carry `id`; stdout emits
  `{"type":"response","command":…,"id":…,"success":…}` for commands and
  un-id'd typed events otherwise. Fits the `:ndjson` decode layer + a pi
  discriminator in the adapter.
- **Multi-turn stdin:** `{"type":"prompt","message":…,"images":[…]}`; native
  mid-turn `steer`/`follow_up` commands (Q6's steer option exists here too;
  v1 still uses interrupt-then-resend for uniformity).
- **Interrupt:** protocol — `{"type":"abort"}` (plus `abort_bash`, `abort_retry`).
- **Resume:** sessions are plain JSONL trees under `~/.pi/agent/sessions/…`
  (custom via `--session-dir`); resume by `--session <path|id>`; RPC
  `switch_session`/`new_session`/`fork`/`clone`; `get_entries {since}` cursor
  allows crash-safe incremental ingestion. Session UUID comes from the session
  header event → `session_id/1`, stored in `claude_session_id` as usual.
- **System prompt:** `--append-system-prompt` flag (or `APPEND_SYSTEM.md`)
  ⇒ `system_prompt: :flag` — same as Claude.
- **Events → normalize:** `message_end`/`turn_end` carry `AssistantMessage`
  (`content: [{type:"text"}|{type:"toolCall",id,name,arguments}]`,
  `usage:{input,output}`, `stopReason`) → assistant text/tool_use;
  `tool_execution_end {toolCallId,toolName,result,isError}` → user tool_result
  (ids pair natively — §3.3 invariant satisfied verbatim); `agent_end` →
  synthesized `result` with usage accumulated in `backend_state`. Built-in tool
  names map directly: `read`→Read, `bash`→Bash, `edit`→Edit, `write`→Write
  (+ optional `grep`/`find`/`ls`). Deltas (`message_update`, thinking deltas)
  ignored in v1 per Q7.
- **Peer requests:** extensions can emit `extension_ui_request` (id'd, expects
  `extension_ui_response` on stdin; dialogs hang if unanswered) → exactly
  `handle_peer_request/2`; v1 replies `{"cancelled":true}` to dialog methods and
  ignores notify/status methods. Shouldn't fire without extensions installed,
  but must be handled defensively.
- **Auth/models:** per-provider env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `GEMINI_API_KEY`, xAI, …) or OAuth via `/login` → `~/.pi/agent/auth.json`;
  25+ providers incl. xAI — **pi is also the cheapest route to grok-the-model**
  if the grok CLI itself proves unembeddable. Models: `--provider X --model Y`
  or `--model provider/model`, thinking suffix (`sonnet:high`); passthrough
  strings in our UI, same as Codex.

**Gaps / capability row:**

| capability | pi |
|---|---|
| streaming | ✅ (`--mode rpc`) |
| interrupt | `:protocol` (`abort`) |
| mcp | ❌ **no MCP support by design** — orca MCP tools unavailable unless we ship a pi TypeScript extension (defer; capability-gate like usage) |
| resume | ✅ (`--session`, JSONL on disk) |
| usage | `:none` for account quota; per-turn tokens from `AssistantMessage.usage` still flow into `result` (`get_session_stats` RPC available if wanted) |
| system_prompt | `:flag` (`--append-system-prompt`) |
| warmup_turn | ❌ |

Also absent: permission prompts/sandboxing (runs with spawning user's perms —
same posture as our `--dangerously-skip-permissions` Claude usage), plan mode,
AskUserQuestion, sub-agents. All already capability-gated by §3.1/§7.

The MCP gap is the one real cost: pi sessions can't call orca tools
(send_message_to_session etc.) until an extension exists. Add
`mcp: false → hide orchestrator/code_exec toggles` to the §7 gating list.
