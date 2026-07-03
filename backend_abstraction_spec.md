# Backend Abstraction Spec — Pluggable Agent CLIs (Claude, Codex, grok, pi, …)

**Status:** Implemented — all four phases (§8) landed, plus a pi adapter
(§12.2) landed post-Phase-3, plus the "pi backend groundwork" slice (§12.3),
pi plan mode (§12.4), the orca-mcp bridge (§12.5), and pi mid-turn
steering/queue visibility/compaction events (§12.6). Claude + Codex + pi are
all selectable per-session with capability-gated UI; grok remains
research-only (§12.1, adapter deferred).
**Goal:** Decouple OrcaHub from the Claude Code CLI so a session can be driven by
any headless coding-agent CLI. First non-Claude target: **OpenAI Codex CLI**
(via `codex app-server`); second: **pi** (Mario Zechner's coding agent, over
`pi --mode rpc`). Named future target: **grok CLI** — adapter deferred to
post-v1 (see §12.1). Selection is **per-session**. Missing features
**gracefully degrade** per backend.

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
> **"0.142.5:"** prefix. The grok protocol in §12.1 is **Verified** (live
> capture against the 0.2.82 binary) — its adapter remains deferred, but the
> seam design already accounts for it. The pi protocol in §12.2 is
> **Verified against 0.80.3** (live capture — superseding the original
> docs-only research pass, done against 0.75.3/0.80.3's identical
> `docs/rpc.md`) and its adapter is **Implemented**; see §12.2's "Verified
> against 0.80.3" note for every deviation found.

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
  plan_mode:         true,          # EnterPlanMode/ExitPlanMode tool pair (Phase 3); pi's own read-only mode (§12.4)
  plan_mode_toggle:  false,         # whether the USER can flip plan_mode directly (pi only, §12.4)
  ask_user_question: true           # built-in AskUserQuestion tool + waiting-status tracking (Phase 3)
}
```

| | Claude | Codex | pi |
|---|---|---|---|
| streaming | ✅ | ✅ (`app-server`) | ✅ (`--mode rpc`) |
| interrupt | `:protocol` (control_request) | `:protocol` (`turn/interrupt`) | `:protocol` (`{"type":"abort"}`) |
| mcp | ✅ inline `--mcp-config` | ✅ via per-session `CODEX_HOME/config.toml` | ❌ — no MCP support by design (§12.2); orchestrator/code_exec toggles hidden |
| resume | ✅ `--resume` | ✅ `thread/resume` | ✅ `--session-id <uuid>` |
| usage | ✅ | ❌ (`:none`) → panel hidden | ❌ (`:none`) → panel hidden; per-turn cost/tokens still populate `result` |
| system_prompt | `:flag` | `:leading_message` | `:flag` (`--append-system-prompt`) |
| warmup_turn | ✅ | ❌ — explicit `initialize`/`initialized` handshake; no MCP race | ❌ — no handshake at all; first `prompt` write is safe immediately |
| plan_mode | ✅ (model-initiated `EnterPlanMode`/`ExitPlanMode`) | ❌ — plan-mode badges hidden; plan items still render via TodoWrite | ✅ (§12.4 — `priv/pi/orca-plan.ts`, USER-toggled) |
| plan_mode_toggle | ❌ — no user-facing toggle exists for Claude's model-initiated flow | ❌ | ✅ — `/plan` via `SessionRunner.toggle_plan_mode/1` |
| ask_user_question | ✅ | ❌ — interactive wizard never initiates; falls back to plain assistant text | ❌ — same |

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
  changeset validates inclusion in `["claude", "codex", "pi"]`.
- **Reuse `claude_session_id` as the generic backend session id** (holds Codex's
  `thread_id`, or pi's session UUID). No rename migration; document that the
  column is backend-scoped. (Optional later cleanup: rename →
  `agent_session_id`.)
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

- **New-session form:** backend selector (`Claude` / `Codex` / `Pi`) → model list
  scoped to the chosen backend. Codex/pi models are passthrough strings (e.g.
  `gpt-5.5`, `gpt-5.3-Codex-Spark`, `fireworks/accounts/fireworks/models/glm-5`)
  — no hardcoded enum; keep a small default list + free entry.
- **Session header / model picker:** show backend; restrict model buttons to the
  session's backend.
- **Capability-gated chrome:** usage panel, plan-mode affordances, and
  AskUserQuestion rendering appear only when the session's backend advertises them.
- **`mcp: false` gating:** hide the orchestrator/code_exec toggles on session
  creation for backends without MCP support — pi (§12.2, no MCP support by
  design, unless/until an extension bridges it) is the first backend to
  actually exercise this gate; Claude and Codex are both `mcp: true`.

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
  button are hidden when `capabilities.mcp == false`. Claude and Codex are
  both `mcp: true`, so this was inert wiring through Phase 3; the pi adapter
  (§12.2) is the first backend with `mcp: false` and the first to actually
  exercise the hidden path — covered by `show_test.exs`'s "MCP toggles —
  absent for pi" describe block and `index_test.exs`'s new-session-form
  equivalent.
- **Model picker:** `Backend.Claude.models/0` returns the exact pre-Phase-3
  hardcoded list (Opus 4.8 / Sonnet 4.6 / Haiku 4.5).
  `Backend.Codex.models/0` returns a small default list
  (`gpt-5-codex`, `gpt-5.3-Codex-Spark`, `gpt-5.5` — the latter two are this
  section's own example passthrough strings). `Backend.Pi.models/0` returns
  four `provider/id` passthrough strings (two Fireworks ids live-verified
  against this host's configured auth during implementation; the
  Anthropic/OpenAI ones are pi's own docs examples). The new-session form's
  model field is a single text input + `<datalist>` of backend-scoped
  suggestions (native free-text entry, no enum); it re-renders on the
  existing `"validate"` LiveView event (already firing on every field
  change, including the backend `<select>`) — no new event was needed. The
  in-session model switcher (`session_live/show.html.heex`) iterates
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
- **Phase 4 — pi adapter. LANDED.** `Backend.Pi` over `pi --mode rpc`
  (streaming) / `pi -p --mode json` (`:one_shot` fallback) — see §12.2 for
  the full verified protocol, normalization map, and every deviation found
  vs. the pre-implementation research draft (re-verified live against
  0.80.3 after the host's `pi` install was upgraded mid-implementation from
  0.75.3). Unlike Codex, needed NO runner contract changes at all — pi's
  protocol has no handshake to gate the first turn on, so the existing
  `on_open/1`/`pending_writes`/`:ndjson` framing seams (already built for
  Claude/Codex) were sufficient as-is. First backend with `mcp: false`,
  exercising that gate in the UI for the first time (§7). Registry: `"pi"`
  added to `Backend.resolve/1`, `Backend.available/0`, and
  `Session.changeset/2`'s `validate_inclusion`. Gated by: full test suite
  (357 tests, the same 1 pre-existing unrelated `TriggersTest` failure as
  every prior phase's baseline) — new coverage: `pi_test.exs` (43 unit
  fixtures against live-captured 0.80.3 frames), `pi_stub_integration_test.exs`
  + `pi_stub_rpc.py` (a REAL `SessionRunner` driven against a Python stub
  speaking the wire protocol), `backend_test.exs`/`show_test.exs`/
  `index_test.exs` extensions. **Live smoke outcome (RESOLVED):** a full
  real turn (Fireworks provider, `gpt-oss-20b`) PASSED end-to-end through
  the real `SessionRunner` — session id captured via the `get_state`
  round-trip, a `Bash` tool_use/tool_result pair from a real `bash` tool
  call, final assistant text, and a `result` event with real
  `total_cost_usd`/`duration_ms`/`usage` (pi reports cost directly, unlike
  Codex — no adapter gap analogous to Codex's Phase 2 auth-copy issue was
  found; pi reads `~/.pi/agent/auth.json` from the inherited `HOME`
  directly, no per-session credential materialization needed). Commit.

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
- Codex/pi usage/quota scraping (both `usage: :none` — per-turn cost/tokens
  still flow into the `result` event where the underlying protocol reports
  them; pi does, Codex doesn't).
- Node-login UI parity for Codex/pi (env-based auth acceptable initially; pi
  needs no OrcaHub-side auth handling at all — see §12.2).
- pi MCP bridging (an extension shipping orca's tools to pi sessions) —
  `mcp: false` and the hidden orchestrator/code_exec toggles are the accepted
  v1 gap (§12.2).
- grok adapter *implementation* (protocol research + capability row in §12.1
  now; the adapter is additive later — pi's landed first since its protocol
  needed no new runner seams beyond what Codex already built).
- Raw-API backends (no CLI). See scope note in the header — a bare chat API has
  no tool executor; multi-provider CLIs are the on-ramp for API-only models.

---

## 12. grok CLI (deferred) & pi (implemented)

**Rule: no adapter gets written before a §6-style verified protocol section
exists for its CLI.** The capability table and adapter design must come from
observed wire behavior (docs + source + a captured session), not assumption.
§12.1 records the research pass for grok, still deferred. §12.2 records pi's
research pass AND its subsequent implementation (Phase 4, §8) — kept in this
section rather than promoted to a numbered §6/§7-style section of its own
since its research-to-implementation delta was small enough to document
inline (see §12.2's "Verified against 0.80.3" note).

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

### 12.2 pi (IMPLEMENTED — `Backend.Pi`, `lib/orca_hub/backend/pi.ex`)

Mario Zechner's coding agent. Repo `github.com/earendil-works/pi` (formerly
`badlogic/pi-mono`); npm `@earendil-works/pi-coding-agent` (`bin: pi`); very
active. Docs: `pi.dev/docs` + the installed package's own
`docs/rpc.md`/`docs/sessions.md`.

**Fit: excellent.** `pi --mode rpc` is a long-lived bidirectional JSONL-over-stdio
process explicitly built for non-Node embedding — functionally equivalent to
Claude's `stream-json` streaming mode, in places richer. Confirmed the
simplest of the three implemented backends: pi needed **zero runner contract
changes** beyond what Codex already built (`on_open/1`, `pending_writes`,
`:ndjson`/`:jsonrpc` framing dispatch) — its own `backend_state` FSM barely
exists (one key: `:agent_start_ms`).

> **Verified against 0.80.3** (live capture, superseding the docs-only
> research pass below, which was written against pi 0.80.3's `docs/rpc.md`
> already but never live-tested until implementation). The host had pi
> 0.75.3 installed at the start of implementation; both 0.75.3's and
> 0.80.3's bundled `docs/rpc.md` describe an IDENTICAL RPC command/event
> vocabulary (confirmed diffing the two), and 0.80.3 was live-captured
> exclusively (a Python stdio harness driving `pi --mode rpc` and
> `pi -p --mode json`, real turns against this host's configured Fireworks
> auth in `~/.pi/agent/auth.json`, plus reading the installed package's
> compiled tool-schema source under `dist/core/tools/*.js` for exact
> argument field names) — 0.75.3 was never shipped in this adapter.
> **Deviations found vs. the research draft below:**
>
> - **No handshake, no FSM to gate the first turn.** The draft below left
>   open whether an `initialize`/session-ready exchange might be needed
>   before the first `prompt`. Live-verified: `pi --mode rpc` accepts
>   `{"type":"prompt",...}` as the very first stdin write, written
>   back-to-back with `on_open/1`'s own command with no waiting — unlike
>   Codex's mandatory `initialize`→`initialized`→`thread/start` chain, there
>   is no `pending_prompt` stash anywhere in `Backend.Pi`.
> - **Session id capture differs by engine, and neither is "the session
>   header event" as drafted.** Streaming (`--mode rpc`) never
>   unprompted-announces a session id on stdout at all — `on_open/1` sends
>   `{"type":"get_state"}` purely to learn it, and `session_id/1` reads
>   `response.data.sessionId` from that reply. One-shot (`-p --mode json`)
>   DOES announce one unprompted, but as the very first stdout line's
>   `{"type":"session","id":…}` (not a `message_end`/`turn_end` field as the
>   draft implied) — `normalize/2` handles both shapes with separate clauses.
> - **`--session-id <uuid>` (not `--session <path|id>`), for resume.** The
>   draft only knew about `--session <path|id>`, which 404s
>   ("No session found matching …") if the id isn't already on disk under
>   the given `--session-dir` — useless for a fresh OrcaHub session that
>   hasn't picked an id yet. 0.80.3 added `--session-id <id>` ("use exact
>   project session id, creating it if missing"); live-verified round-trip:
>   spawn with a fresh `--session-id` (creates it), spawn again later with
>   the SAME `--session-id` + `--session-dir` → full prior context recalled.
>   `Backend.Pi` always uses `--session-id`, never `--session`.
> - **Everything else matched the research draft exactly**: strict-JSONL
>   framing (no `"jsonrpc"` field, commands optionally carry `id`, responses
>   echo it verbatim, events never have one), `{"type":"prompt","message":…}`
>   / `{"type":"abort"}` stdin framing, the
>   `message_end`/`tool_execution_end`/`agent_end` event vocabulary and field
>   names (`toolCallId`, `isError`, `stopReason` ∈
>   `stop|length|toolUse|error|aborted`, `usage:{input,output,cacheRead,
>   cacheWrite,cost:{total,…}}`), built-in tool names
>   (`bash`/`read`/`write`/`edit`/`grep`/`find`/`ls`) confirmed from the
>   compiled tool source, the `extension_ui_request`/`extension_ui_response`
>   sub-protocol shape (dialog vs. fire-and-forget methods), and
>   `--append-system-prompt`. One tool-schema surprise: pi's own read/write/
>   edit schemas use `"path"` (not Claude's `"file_path"`), and pi's edit
>   tool takes an `"edits":[{oldText,newText}]` ARRAY (not Claude's single
>   `old_string`/`new_string` pair) — `Backend.Pi`'s tool-argument
>   translation layer (not drafted below at this level of detail) handles
>   both, folding multiple edits into one separator-joined diff block for
>   v1. `agent_end.messages` additionally carries a harmless `willRetry`
>   field and per-message `usage` gained a `cacheWrite1h` field on 0.80.3 —
>   both ignored.

- **Spawn:** `pi --mode rpc --model <provider/id> --session-dir <dir>
  [--session-id <uuid>] --append-system-prompt <text>` (streaming);
  `pi -p --mode json <same flags> <prompt>` (`:one_shot` fallback — emits the
  IDENTICAL event vocabulary to stdout, live-verified; no PTY/`script`
  wrapper needed, unlike Claude's one-shot spawn). `--session-dir` points at
  `<session.directory>/.pi_sessions/<session.id>` — per-session, nested under
  a per-project parent (mirrors Codex's `CODEX_HOME` reasoning: computed
  identically in `spawn_spec/2` and `prepare_session/1`/`cleanup_session/1`
  via one private helper, so concurrent sessions never collide and cleanup
  only ever touches its own session's directory).
- **Framing:** strict JSONL, LF-only delimiter. Custom command/response/event
  protocol (NOT JSON-RPC): stdin commands optionally carry `id`; stdout emits
  `{"type":"response","command":…,"id":…,"success":…}` for commands and
  un-id'd typed events otherwise. Uses the existing `:ndjson` decode layer
  (`StreamParser`) — no new framing needed.
- **Multi-turn stdin:** `{"type":"prompt","message":…}`, written immediately
  by `encode_user_turn/2` every time (no FSM/stash). Native mid-turn
  `steer`/`follow_up` commands exist but v1 still uses interrupt-then-resend
  for uniformity with the other backends (Q6).
- **Interrupt:** protocol — `{"type":"abort"}`.
- **Resume:** `--session-id <uuid>` (see the verification note above) +
  `--session-dir`; sessions are plain JSONL trees under the per-session
  directory. Session UUID comes from `on_open/1`'s `get_state` round-trip
  (streaming) or the unprompted session-header line (one-shot) → `session_id/1`
  → synthesized `system`/`init` event, stored in `claude_session_id` as usual.
- **System prompt:** `--append-system-prompt` flag ⇒ `system_prompt: :flag` —
  same as Claude. `Backend.Pi.system_prompt/1` reuses `SharedPrompts`'
  non-MCP-dependent fragments (session id line, commit trailer, `.context/`
  files) and drops the orchestrator/code-exec/sibling-session fragments
  entirely, since `mcp: false` makes them all inapplicable.
- **Events → normalize:** `message_end{role:"assistant",content:[…]}` (only,
  not `turn_end`/`agent_end.messages`, which embed the same content
  redundantly) → one Claude `assistant` event per pi message, with
  `content:[{type:"text"}|{type:"thinking"}|{type:"toolCall",id,name,
  arguments}]` blocks mapped to Claude's text/thinking/tool_use shapes
  (tool-argument translation per the verification note above);
  `tool_execution_end{toolCallId,result:{content},isError}` → `user`
  tool_result (ids pair natively — §3.3 invariant satisfied verbatim);
  `agent_end{messages}` → synthesized `result`, scanning its own bundled
  `messages` (not accumulated separately in `backend_state`) for the last
  assistant's `stopReason` (`"error"` → `is_error:true` + `errorMessage`;
  `"aborted"` → `is_error:false`, same posture as Codex's
  `turn/completed{interrupted}`) and the SUM of every assistant message's
  `usage`/`cost.total` across the run — pi reports cost directly (unlike
  Codex), so `total_cost_usd` IS populated here. `duration_ms` is
  synthesized wall-clock (`agent_start` stashes `System.monotonic_time`,
  read back at `agent_end`) since pi's protocol has no elapsed-time field.
  Deltas (`message_update`, `tool_execution_start`/`update`) dropped per Q7.
- **Peer requests:** extensions can emit `extension_ui_request` (id'd method,
  dialog types `select`/`confirm`/`input`/`editor` block waiting for an
  `extension_ui_response`; fire-and-forget types `notify`/`setStatus`/
  `setWidget`/`setTitle`/`set_editor_text` expect NO reply) →
  `handle_peer_request/2`; replies `{"cancelled":true}` to dialog methods,
  sends nothing for fire-and-forget ones. Shouldn't fire without extensions
  installed (v1 loads none), handled defensively.
- **Auth/models:** per-provider env vars or OAuth via `/login` →
  `~/.pi/agent/auth.json`, read straight from the inherited `HOME` — the
  spawned child needs NO special env handling (`OrcaHub.Env.sanitized_env/0`
  only unsets `RELEASE_*`/cleans `PATH`; `HOME` passes through unchanged),
  live-verified with real Fireworks-provider turns. `Backend.Pi.models/0`
  returns four `provider/id` passthrough strings (two Fireworks ids
  live-verified against this host's configured auth; the Anthropic/OpenAI
  ones are pi's own docs examples) — not an enum, same posture as Codex.

**Capability row (as implemented — see §3.1's three-column table):**

| capability | pi |
|---|---|
| streaming | ✅ (`--mode rpc`) |
| interrupt | `:protocol` (`{"type":"abort"}`) |
| mcp | ❌ **no MCP support by design** — orca MCP tools unavailable unless a pi TypeScript extension bridges them (not built); UI hides the orchestrator/code_exec toggles and MCP-servers modal (§7) |
| resume | ✅ (`--session-id <uuid>` + `--session-dir`, JSONL on disk) |
| usage | `:none` for account quota; per-turn tokens AND cost flow into `result` (`total_cost_usd`/`usage` both populated — better than Codex here) |
| system_prompt | `:flag` (`--append-system-prompt`) |
| warmup_turn | ❌ (no handshake of any kind) |
| plan_mode | ❌ |
| ask_user_question | ✅ (as of the "pi backend groundwork" slice, §12.3 — via `priv/pi/orca.ts`'s `question` tool + the extension-UI reply loop, not Claude's built-in tool) |
| session_stats | ✅ (§12.3 — `get_session_stats`; pi-only, distinct from `usage`) |
| steering | ✅ (`{"type":"steer",…}` — §12.6) |

Also absent: permission prompts/sandboxing (runs with spawning user's perms —
same posture as our `--dangerously-skip-permissions` Claude usage), sub-agents.
All capability-gated by §3.1/§7.

The MCP gap remains the one real cost: pi sessions can't call orca tools
(send_message_to_session etc.) until an extension exists — accepted as a v1
gap (§11). **Closed in §12.5** by `priv/pi/orca-mcp.ts`, which flips
`capabilities().mcp` to `true`.

### 12.3 "pi backend groundwork" slice (IMPLEMENTED — extension-UI reply loop, `priv/pi/orca.ts`, session stats)

Three additions on top of §12.2's adapter, landed together, all pi-only.
**Live-verified against the real 0.80.3 binary** (not just the stub) — see
the live-smoke evidence below; every payload shape matched
`docs/rpc.md`/`docs/extensions.md` exactly, no deviations found.

**1. Extension-UI reply loop.** pi extensions can block mid-turn on user
input via `ctx.ui.select`/`confirm`/`input`/`editor`, which surface as a
blocking `extension_ui_request` on stdout (has BOTH `id` and `method`, so
the existing peer-request dispatch in `session_runner.ex`'s `route_frame/2`
already routes it to `handle_peer_request/2` — no new runner message-routing
code was needed). `Backend.Pi.handle_peer_request/2` now, for the four
dialog methods, does NOT reply immediately (the pre-existing behavior was an
instant auto-`cancelled:true` — replaced): it stashes `%{id, method}` in
`backend_state.pending_ui_request` and emits a new normalized event,
`%{"type" => "pi_ui_request", "id", "method", "title", "message", "options",
"placeholder", "prefill"}` — a genuinely new event type (same posture as the
pre-existing `cli_error` type; §3.3's "no foreign shapes" rule is about not
misusing an *existing* Claude type, not a ban on new ones). Deliberately
**not** force-fit into Claude's `AskUserQuestion` tool_use/tool_result shape:
pi's answer travels back as a direct `extension_ui_response` port write, not
a plain chat turn, so conflating the two shapes would make the LiveView's
answer path ambiguous about which write mechanism to use.

The answer half: `SessionRunner.answer_ui_request/3` (new public API,
`GenStatem.call`) — allowed **only in `:running`**, since the dialog blocks
the CURRENT turn, so it can never be pending in `:ready`/`:idle`/`:error`
(those states reply `{:error, :not_running}`). It dispatches through a new
`OrcaHub.Backend.encode_ui_response/4` function (NOT the bare
`backend.encode_ui_response/3` — that would raise for Claude/Codex) to a new
**optional** behaviour callback, `@callback encode_ui_response(request_id,
payload, ctx) :: {:ok, iodata, ctx} | :noop` (`@optional_callbacks
encode_ui_response: 3` — Claude/Codex implement nothing, the dispatcher
returns `:noop` for them via `function_exported?/3`).
`Backend.Pi.encode_ui_response/3` validates `request_id` against the SAME
`pending_ui_request` bookkeeping (ignoring unknown/already-answered ids per
spec) and writes `{"type":"extension_ui_response","id":…, …payload}` to the
port. On success the runner persists/broadcasts a `pi_ui_response` event and
clears the pending marker.

**Keyed purely on `request_id`, never on "a tool_use is in flight"** — a
FUTURE extension (e.g. plan-mode popping a dialog after `agent_end` with no
tool call running at all) flows through the IDENTICAL loop
(`handle_peer_request/2` → `pi_ui_request` event →
`SessionRunner.answer_ui_request/3` → `encode_ui_response/3`) with zero new
runner code — only that extension's own request/response field shapes need
handling, and the current implementation already passes through whatever
`title`/`message`/`options`/`placeholder`/`prefill` the request carries.

`SessionLive.Show` renders `pi_ui_request` via a small dedicated modal
(`session_live/show.html.heex`, gated on `@capabilities.ask_user_question &&
@pending_ui_request` — independent of `@status`, since pi's dialog blocks
the port directly rather than going through Claude's
synthetic-tool_result/"waiting" mechanism) and answers via two new events,
`"piui_answer"`/`"piui_cancel"`, which call `Cluster.answer_ui_request/4` →
`SessionRunner.answer_ui_request/3`. `@pending_ui_request` is reconstructed
purely from message history (`pending_ui_request_from_messages/1`: the last
`pi_ui_request` with no later matching `pi_ui_response`) — not tracked as
separate runner state — so a page reload, even against a dead runner falling
back to `HubRPC.list_messages/1`, still shows the pending card. `notify`
(fire-and-forget) now surfaces as a passive `system`/`pi_notify` event
instead of being silently dropped; the remaining fire-and-forget methods
(`setStatus`/`setWidget`/`setTitle`/`set_editor_text` — TUI chrome concepts
with no OrcaHub analogue) are still dropped.

**Runner robustness fix found along the way (general, not pi-specific):**
`SessionRunner`'s `:idle`/`:error` states had no `{port, {:data, raw}}`
matcher — any port data arriving after a turn's `result` event (but before
idle timeout) fell through to the generic `:info` catch-all and was
SILENTLY DROPPED. This was latent but real: item 3 below (`get_session_stats`)
writes its request the moment `agent_end` is normalized, but the response is
a separate async port message that typically arrives AFTER the runner has
already transitioned `:running` → `:idle` (both happen synchronously within
one GenStatem message-handling pass, before another port message can be
received). Fixed by factoring the decode+route logic into
`process_port_data/2` and adding `idle`/`error` matchers for it (guarded
`engine: :streaming`, since one-shot ports are already dead by the time
`:idle` is entered). Backend-agnostic — benefits any backend with a
late-arriving async write, not just pi.

**2. `priv/pi/orca.ts`** — an OrcaHub-authored pi extension, loaded via
`-e <path>` in `Backend.Pi.spawn_spec/2` (`common_args/1`), resolved through
`Application.app_dir(:orca_hub, "priv/pi/orca.ts")` — NOT a literal
repo-relative path — so it keeps working from an OTP release (`priv/` ships
with the release by default; verified `Application.app_dir/2` resolves and
`File.exists?/1` the file in both `mix test` and, by construction, a prod
release). Registers a `question` tool mirroring Claude's built-in
`AskUserQuestion` as closely as pi's RPC dialog primitives allow — pi's
`ctx.ui.custom()` explicitly returns `undefined` in RPC mode
(`docs/rpc.md`), so it's unusable; only `ctx.ui.select()` (options given →
single choice) and `ctx.ui.input()` (no options → free text) actually work
over the wire. Both dialogs pass a 10-minute `timeout`, delegating the
"don't hang forever" requirement to pi's OWN agent-side timeout machinery
(`docs/rpc.md`: "the agent-side will auto-resolve with a default value when
the timeout expires") rather than building Elixir-side bookkeeping for it;
on timeout (`select`/`input` resolve `undefined`) the tool returns a result
saying the user didn't answer, `isError: false`. `Backend.Pi.normalize/2`'s
`tool_execution_end` clause defensively clears any stale
`backend_state.pending_ui_request` on every tool completion, since a
timeout auto-resolves *inside* pi with no wire signal to the host at all —
the only observable evidence is the blocked tool finishing.

**3. Session stats.** `Backend.Pi.normalize/2`'s `agent_end` clause now also
queues `{"type":"get_session_stats"}` onto `backend_state.pending_writes`
(spec §3.2 — flushed by the same `route_frame/2` pass, right after the
turn's synthesized `result` event). The response
(`{"type":"response","command":"get_session_stats","success":true,"data":{tokens,cost,contextUsage}}`)
is normalized into a new `pi_session_stats` event
(`tokens`/`cost`/`context_usage`, field names passed through close to
verbatim). Surfaced through a NEW `Capabilities.session_stats` boolean
(`false` by default; `true` for pi only) — **deliberately NOT reusing
`usage`**: `usage: true` gates the Claude-API OAuth quota panel backed by
`OrcaHub.Claude.Usage` (a headless-account-quota fetch, entirely unrelated
to session message history — see that module), which would be the WRONG
data source wired up for a non-Claude backend. `pi_session_stats` renders
inline in the message feed (`MessageComponents.pi_session_stats_message/1`)
— tokens/cost/context% — right after each turn's own cost/duration card.

**Live smoke (2026-07-03, real `pi` 0.80.3 binary, Fireworks
`minimax-m2p7`, NOT the ExUnit stub):** a Python harness spawned
`~/.local/bin/pi --mode rpc --session-dir <tmp> -e priv/pi/orca.ts` and sent
"Use the question tool to ask me whether I prefer red or blue, then tell me
my answer." The model called `question` with
`{"question":"Do you prefer red or blue?","header":"Color Preference","options":[{"label":"Red","description":"…"},{"label":"Blue","description":"…"}]}`;
pi emitted
`{"type":"extension_ui_request","id":"80b3fa64-…","method":"select","title":"Color Preference: Do you prefer red or blue?","options":["Red — I prefer the color red","Blue — I prefer the color blue"],"timeout":600000}`
— matching `handle_peer_request/2`'s `ui_request_event/1` shape exactly, no
docs deviation. The harness answered
`{"type":"extension_ui_response","id":"80b3fa64-…","value":"Blue — I prefer the color blue"}`;
pi resumed with `tool_execution_end{… "content":[{"text":"User answered:
Blue"}], "isError":false}` and a final assistant message reflecting the
answer ("The user answered \"Blue\" to my question…"). `get_session_stats`
returned real numbers:
`tokens:{"input":7453,"output":136,"cacheRead":7329,"cacheWrite":0,"total":14918}`,
`cost:0.00283884`,
`contextUsage:{"tokens":7484,"contextWindow":196608,"percent":3.8…}` —
exactly the field names `session_stats_event/1` expects.

A second live run exercised interrupt-while-a-dialog-is-pending
(`encode_interrupt/2` itself is untouched by this slice — still just sends
`{"type":"abort"}`) and found a REAL gap, now fixed:
`priv/pi/orca.ts`'s `question` tool originally ignored `execute`'s own
`signal` (AbortSignal) parameter and passed only `{timeout:
DIALOG_TIMEOUT_MS}` to `ctx.ui.select`/`ctx.ui.input`. Live-verified: with
that first version, sending `{"type":"abort"}` while a `select` dialog was
blocked produced NO further stdout at all — no `turn_end`, no `agent_end` —
for 60+s (pi's `abort` cancels the agent/model loop, but a dialog already
awaiting user input isn't tied to that cancellation unless the extension
explicitly passes its own `signal`). Fixed by passing `{ signal, timeout:
DIALOG_TIMEOUT_MS }` (the tool call's own `AbortSignal`) to both dialog
calls. Re-verified live: `{"type":"abort"}` while pending now resolves the
dialog (`choice === undefined`, same code path as a timeout — the tool
returns "The user did not answer in time." and completes) and `turn_end`/
`agent_end` fire immediately instead of hanging. This is the shape the
"pi backend groundwork" reply loop needs for interrupt to actually work
end-to-end, not just avoid crashing — a lesson worth carrying into any
FUTURE extension that pops a dialog (e.g. plan-mode): always thread the
handler's own abort signal into `ctx.ui.*` calls.

**Test coverage:** `pi_test.exs` extended (dialog-method stashing +
`pi_ui_request` event shape, `encode_ui_response/3` matching/unknown-id/no-
pending cases, `tool_execution_end`'s defensive clear, `get_session_stats`
request queuing + response normalization, capability values,
`-e`/`Application.app_dir/2` spawn arg). `pi_stub_rpc.py` extended with an
"ask a question" prompt scenario (emits the toolCall, blocks on stdin for
the `extension_ui_response` exactly like the real binary, then completes)
and a `get_session_stats` command handler; `pi_stub_integration_test.exs`
gained three new tests: a full `SessionRunner`-driven extension-UI round
trip via `answer_ui_request/3`, an unknown-request-id no-op while a
different turn is running, and a `pi_session_stats` event landing via the
new `idle(:info, {port, {:data, raw}})` fallback (deliberately polled for
AFTER the turn already went `:idle`, to exercise the race window that
motivated the runner robustness fix). `message_components_test.exs` gained
rendering coverage for `pi_session_stats`/`pi_ui_response`/hidden
`pi_ui_request`/`system pi_notify`. `backend_test.exs` and `show_test.exs`
updated for the flipped `ask_user_question` capability and the new
`session_stats` capability. Full suite: 390 tests, the same 1 pre-existing
unrelated `TriggersTest` failure as every prior phase's baseline.

### 12.4 pi plan mode (IMPLEMENTED — `priv/pi/orca-plan.ts`, `Backend.Pi.encode_toggle_plan_mode/1`)

Gives pi sessions the same `plan_mode`-gated header chrome Claude sessions
have (the "planning" badge, `session_live/show.html.heex` ~152), flipping
`Backend.Pi.capabilities().plan_mode` from `false` (§12.2/§12.3) to `true` —
but via a fundamentally different mechanism than Claude's. Claude's plan mode
is **model-initiated**: the LLM itself decides to call the built-in
`EnterPlanMode`/`ExitPlanMode` tools (`OrcaHubWeb.SessionLive.PlanMode.detect/1`
scans the message history for these tool_use names); there is **no
user-facing toggle for Claude at all** — OrcaHub only ever *reflects* Claude's
own decision, never drives it. pi's plan mode is the opposite: **user-toggled**
via pi's own `/plan` extension command, with no analogous built-in tool pair.
A new `plan_mode_toggle` capability (default `false`; `true` only for pi)
distinguishes the two so the UI's toggle BUTTON only ever renders for
backends that actually have one — `plan_mode` alone (shared, unchanged
semantics for the existing badge/chrome) is not enough to gate it safely,
since Claude's `plan_mode` was already `true` before this slice.

**1. `priv/pi/orca-plan.ts`** — vendored and adapted from pi's own bundled
example extension (`@earendil-works/pi-coding-agent`'s
`examples/extensions/plan-mode/{index,utils}.ts`), loaded via a SECOND `-e`
in `Backend.Pi.spawn_spec/2`'s `common_args/1`, right after `orca.ts` (same
`Application.app_dir/2` resolution, release-safe). A read-only exploration
mode: `/plan` toggles `write`/`edit` OUT of the active tool set entirely
(`pi.setActiveTools`, so the model can't even see those tools, not just have
calls rejected) and installs a `tool_call` hook that blocks any `bash`
command not matching a read-only allowlist (`cat`/`grep`/`git status`/etc. —
verbatim from the upstream example). When the model proposes a plan (a
`Plan:` header with numbered steps), `agent_end` shows a "what next?" dialog
(execute / stay in plan mode / refine) via `ctx.ui.select`. Three deliberate
deviations from the upstream example, vendored into this single file (project
convention — `orca.ts` is also single-file) rather than pi's original
directory-with-`index.ts`+`utils.ts` layout:

  - **`registerShortcut` dropped** — keyboard shortcuts (`Ctrl+Alt+P` in the
    upstream example) are a TUI-only concept; there's no terminal on the
    other end of `--mode rpc`. `/plan` (the command) is the only toggle
    surface that exists over RPC, and it's exactly what
    `Backend.Pi.encode_toggle_plan_mode/1` sends.
  - **AbortSignal threaded into every dialog call** (the groundwork lesson,
    §12.3's live-smoke finding, restated here because it bit again during
    THIS slice's own live smoke — see below): `ctx.ui.select`/`ctx.ui.editor`
    in the `agent_end` handler now pass `{ signal: ctx.signal, timeout:
    DIALOG_TIMEOUT_MS }` (10 minutes, matching `orca.ts`). Without `signal`,
    `{"type":"abort"}` while the "what next?" dialog is pending has no way to
    unblock it.
  - **`"questionnaire"` (a tool that doesn't exist in this deployment)
    replaced with `"question"`** in `PLAN_MODE_TOOLS` — reuses the `question`
    tool `orca.ts` already registers (loaded first, via the earlier `-e`) so
    the model can still ask read-only clarifying questions while planning,
    matching the upstream example's intent with a tool that actually exists
    here.

  Plan-mode state changes (toggle, execution start/complete) call a new
  `broadcastPlanState(ctx)` helper: `ctx.ui.setStatus("orca-plan-mode",
  JSON.stringify({enabled, executing}))` — a fire-and-forget `setStatus`
  UI call, chosen over `ctx.ui.notify`'s free-text message because OrcaHub
  needs a machine-readable signal, not a human-readable one, to drive
  `@plan_mode`. Fires on `session_start` too (a resumed/cold-reopened session
  re-broadcasts its `pi.appendEntry("plan-mode", …)`-persisted state), which
  is what makes it reliable for state reconstruction after a runner restart.

**2. The toggle mechanism.** `SessionRunner.toggle_plan_mode/1` (new public
GenStatem call) — deliberately the OPPOSITE scope of
`answer_ui_request/3` (§12.3): only reachable from `:idle` with an
ALREADY-WARM port (`data.port != nil`), refused everywhere else (`:ready` —
never started, nothing to cold-open just for a toggle; `:running` — a turn is
already using the port; `:error`). This scope was chosen after LIVE-VERIFYING
(not assumed) that pi's `/plan` is a pure extension command: sending
`{"type":"prompt","message":"/plan"}` over RPC produces `extension_ui_request`
events (from `broadcastPlanState`/`notify`) followed by
`{"type":"response","command":"prompt","success":true}` with **NO**
`agent_start`/`agent_end` at all — confirmed via `get_state`'s
`messageCount` staying unchanged across the round trip. This matters because
`SessionRunner`'s `:running` state only ever transitions back to `:idle` off a
synthesized `result` event (itself only ever emitted from `agent_end` for
pi) — routing `/plan` through the NORMAL `send_message`/`:running` path
would have left the runner hung in `:running` forever, waiting for a `result`
that would never arrive. `toggle_plan_mode/1` sidesteps this entirely by
writing directly to the port and staying in `:idle` — no state transition,
no wait.

Wire encoding: `Backend.encode_toggle_plan_mode/2` (a NEW optional callback,
`@optional_callbacks encode_toggle_plan_mode: 1`, dispatched via
`function_exported?/3` exactly like `encode_ui_response/4` — Claude/Codex
implement nothing and get `:noop`). `Backend.Pi.encode_toggle_plan_mode/1`
reuses `encode_user_turn("/plan", ctx)` verbatim rather than hand-rolling a
new frame — `/plan`'s wire shape IS a `{"type":"prompt","message":…}` command,
just one pi's own command dispatcher intercepts before it ever reaches agent
processing.

`Cluster.toggle_plan_mode/2` mirrors `answer_ui_request/4`'s plain RPC-through
posture (no ensure-started dance — a cold/never-started runner already
returns `{:error, :not_running}`). `SessionLive.Show`'s `"toggle_plan_mode"`
event handler (gated in the template on `@capabilities.plan_mode_toggle`)
calls it and OPTIMISTICALLY flips `@plan_mode` on success (before any wire
confirmation arrives) so the click feels responsive; the authoritative
`pi_plan_mode` event (below) reconciles moments later regardless — same
"optimistic, then reconciled" posture the task asked for.

**3. State tracking.** `Backend.Pi.handle_peer_request/2` gained one new
clause: a `setStatus` request with `statusKey: "orca-plan-mode"` decodes its
`statusText` JSON and emits a NEW normalized event type, `pi_plan_mode`
(`%{"type" => "pi_plan_mode", "enabled" => bool, "executing" => bool}` — a
genuinely new type, same posture as `pi_ui_request`/`cli_error`, spec §3.3).
It is PERSISTED (so `SessionLive.Show`'s mount-time reconstruction —
`pi_plan_mode_from_messages/1`, mirroring `pending_ui_request_from_messages/1`'s
"scan for the last matching event" pattern — survives a page reload, even
against a dead runner falling back to `HubRPC.list_messages/1`) but marked
`hidden_message?/1` in `MessageComponents` (it fires on every toggle AND
every `session_start`/execution-progress tick — rendering each as a feed card
would be noisy; the header badge already reflects the state). Live,
`handle_pi_plan_events/2` (mirrors `handle_pi_ui_events/2`) updates
`@plan_mode` off the SAME event as it streams in. `@plan_mode` only ever maps
pi's boolean to `:planning` or `false` — there is no pi-side equivalent of
Claude's transient `:review` state (the post-plan "what next?" moment is
handled entirely by the extension-UI dialog described above, not a persisted
review phase).

**Live smoke (2026-07-03, real `pi` 0.80.3 binary, Fireworks
`minimax-m2p7`, NOT the ExUnit stub):** a Python harness spawned
`~/.local/bin/pi --mode rpc --session-dir <tmp> -e priv/pi/orca.ts -e
priv/pi/orca-plan.ts` and drove all four surfaces:

1. `{"type":"prompt","message":"/plan"}` -> `extension_ui_request{method:
   "setStatus", statusKey:"orca-plan-mode",
   statusText:"{\"enabled\":true,\"executing\":false}"}`, an
   `extension_ui_request{method:"notify", message:"Plan mode enabled. Built-in
   write tools disabled."}`, then `{"type":"response","command":"prompt",
   "success":true}` — **no `agent_start`/`agent_end`**, confirming the
   extension-command bypass the toggle mechanism above relies on.
2. A real turn asked the model to run `rm -rf …` via bash and to explain (in
   text) that it couldn't write files. Result: `tool_execution_end` for the
   bash call carried `"isError":true,"result":{"content":[{"type":"text",
   "text":"Plan mode: command blocked (not allowlisted). Use /plan to disable
   plan mode first.\nCommand: rm -rf /tmp/orca_plan_smoke_should_not_run"}]}`
   — the `tool_call` allowlist hook fired — and the model never attempted a
   `write`/`edit` tool call at all (not offered, per `setActiveTools`).
3. Asked for a `Plan:` section -> `agent_end`'s dialog fired as
   `extension_ui_request{method:"select", title:"Plan mode - what next?",
   options:["Execute the plan (track progress)","Stay in plan
   mode","Refine the plan"]}` — matching `handle_peer_request/2`'s
   `pi_ui_request` normalization exactly, no docs deviation.
4. **The AbortSignal lesson, re-confirmed for THIS extension's own dialog:**
   `{"type":"abort"}` sent while that "what next?" dialog was pending
   resolved it (`choice === undefined`, same code path as a timeout) and the
   process returned to idle in **0.00s** (measured via an immediate
   `get_state` round-trip, `isStreaming:false`) — not the 60+s hang §12.3
   documented for the FIRST (unfixed) version of `orca.ts`'s `question` tool.
   This is direct evidence the `{ signal: ctx.signal, … }` fix applied to
   `orca-plan.ts`'s dialog calls (item 1 above) is load-bearing, not
   cosmetic — an extension that pops a dialog and forgets to thread its own
   handler's `AbortSignal` will hang pi indefinitely on abort, every time.

**Test coverage:** `pi_test.exs` gained `capabilities/0`'s `plan_mode: true`/
`plan_mode_toggle: true` assertions, a second-`-e` spawn-arg test (confirms
`orca-plan.ts` loads AFTER `orca.ts`), `handle_peer_request/2` coverage for
the `orca-plan-mode` `setStatus` clause (happy path, a DIFFERENT `statusKey`
falling through to the generic fire-and-forget catch-all unchanged, and
malformed JSON dropping safely), and `encode_toggle_plan_mode/1`'s exact wire
frame. `backend_test.exs` gained an `encode_toggle_plan_mode/2` dispatcher
describe block (pi dispatches through; Claude/Codex `:noop`) and updated
`capabilities_for/1` expectations. `pi_stub_rpc.py` gained a `/plan` scenario
mirroring the live-verified no-agent-turn shape; `pi_stub_integration_test.exs`
gained a full `SessionRunner`-driven round trip (`toggle_plan_mode/1` refused
against a `:ready` runner, then `:ok` against a warm `:idle` one, landing a
persisted `pi_plan_mode` event without ever leaving `:idle`).
`show_test.exs` gained `plan_mode_toggle` capability-assign coverage per
backend and a template test confirming the toggle button renders for pi only.
Full suite: 397 tests, the same 1 pre-existing unrelated `TriggersTest`
failure as every prior phase's baseline.

### 12.5 orca-mcp bridge (IMPLEMENTED — `priv/pi/orca-mcp.ts`, `mcp: true`)

Closes the one gap §12.2/§12.3 called out as "accepted as a v1 gap": pi has
no built-in MCP client, so a pi session couldn't reach OrcaHub's own `/mcp`
tools (send_message_to_session, start_session, search_sessions, the
code-exec meta-tools, any project/session-scoped upstream server). This
slice bridges that gap entirely from userspace — no new wire protocol on the
Elixir side, no changes to `OrcaHub.MCP.Plug`/`OrcaHub.MCP.Server` at all.

**Transport, confirmed by reading the hub's own code (not assumed):**
`OrcaHub.MCP.Plug` (`lib/orca_hub/mcp/plug.ex`) implements MCP **Streamable
HTTP**, but the SIMPLE half of that spec — every POST gets back a single
`application/json` body (`json_response/3`), never an `text/event-stream`
SSE stream; there is no GET-based server push (`call(%{method: "GET"} = conn,
_)` unconditionally 405s). Auth/session correlation is the `mcp-session-id`
response header `initialize` returns, echoed back as a REQUEST header on
every subsequent call; `orca_session_id`/`orchestrator`/`code_exec` are
query params baked in at `initialize` time and never re-read after
(`OrcaHub.MCP.Server.init/1`). This is the exact same transport
`OrcaHub.MCP.UpstreamClient` (the module that connects the HUB itself
outbound to third-party MCP servers like Tavily) already speaks with `Req`,
one Elixir-side precedent confirming the shape independent of reading the
Plug — both call sites confirm plain-JSON, no SSE, ever, from this
specific server implementation.

**`OrcaHub.Backend.McpUrl.orca_url/1` was ALREADY the shared URL builder**
(landed with the Codex adapter, before this slice) — `Backend.Claude` and
`Backend.Pi` both call it now, so `orca_session_id`/`orchestrator`/
`code_exec` can never drift between the two backends' baked URLs. No new
extraction was needed; this slice just added the second caller.
`Backend.Pi.spawn_spec/2` injects the built URL as the `ORCA_MCP_URL` env
var (`pi_env/1`) alongside the existing `-e priv/pi/orca.ts` flag, adding a
SECOND `-e priv/pi/orca-mcp.ts` (`pi -e` is documented as repeatable, and
`--help` confirms it live: "can be used multiple times").

**`priv/pi/orca-mcp.ts`** — hand-rolls an MCP JSON-RPC client over `fetch`
(Node 18+ global; no npm dependency added, per the task's explicit
constraint) rather than pulling in an MCP SDK. At `session_start`: reads
`ORCA_MCP_URL` from `process.env`; if absent, logs once to **stderr**
(`console.error` — `--mode rpc`'s **stdout is the NDJSON RPC channel
itself**, so this extension never writes to stdout, unlike some of the
docs' own TUI-mode examples) and returns, registering zero tools. If
present: `initialize` → `notifications/initialized` → `tools/list`, each
step wrapped so ANY failure (connection refused, non-2xx, timeout, bad
JSON) is caught, logged once, and degrades to zero tools — never throws out
of the `session_start` handler, never blocks/hangs the session. A request
timeout (15s) is layered onto every call via an internal `AbortController`,
combined (`combineSignals`) with whatever `AbortSignal` the caller passes —
for `tools/call` specifically, that's the tool's own `execute(...,
signal, ...)` argument, so an OrcaHub "stop" click aborts an in-flight
`tools/call` fetch immediately instead of leaving the turn stuck. This is
the exact lesson §12.3 found the hard way for `priv/pi/orca.ts`'s `question`
tool dialogs (thread the handler's own `AbortSignal` into any blocking
call) — carried into every blocking call this second extension makes too.

**Tool naming: `mcp__orca__<raw_name>`, matching Claude byte-for-byte.**
`Backend.Claude.mcp_config_json/1` points ONE `mcpServers` entry, keyed
literally `"orca"`, at this same `/mcp` endpoint — the Claude CLI's own MCP
client then names every tool that connection returns
`mcp__<config-key>__<tool-name>` = `mcp__orca__<tool-name>`.
`OrcaHub.MCP.Server`'s `tools/list` already returns upstream-server tools
PRE-prefixed with their own server prefix
(`OrcaHub.MCP.UpstreamClient.put_cache/1`:
`"#{conn.prefix}__#{tool["name"]}"`), so from Claude's perspective an
upstream tool ends up double-prefixed, e.g. `mcp__orca__tavily__
tavily_search` — confirmed live in this slice's own smoke test (tools/list
returned `tavily__tavily_crawl`/`tavily__tavily_search`/etc. verbatim,
alongside bare-named first-party tools `open_file`/
`send_message_to_session`). `orca-mcp.ts` mirrors this exactly: every tool
`tools/list` returns is registered `mcp__orca__<raw_name>` verbatim, no
other transformation — `Backend.Pi.normalize/2`'s `translate_tool/2`
already passes unrecognized tool names through unchanged (its `bash`/
`read`/`write`/`edit` clauses are the only special cases), so a `toolCall`
named `mcp__orca__open_file` or `mcp__orca__tavily__tavily_search` reaches
`MessageComponents` completely unmodified. Confirmed by reading
`message_components.ex`: its `mcp__orca__run_elixir`/`search_tools`/
`read_tool` pattern matches (~736-763) plus its generic `mcp__*`-agnostic
`tool_icon`/`tool_summary` catch-alls mean **zero rendering changes were
needed anywhere** — verified live (see smoke evidence below), not just by
code reading.

An MCP tool's `inputSchema` is raw JSON Schema, not directly a TypeBox
schema (TypeBox's runtime validator dispatches on a `[Kind]` symbol plain
JSON Schema objects don't carry) — `Type.Unsafe(schema)` is TypeBox's
documented escape hatch for exactly this, and it's not a novel trick:
`@earendil-works/pi-ai`'s own `StringEnum` helper (a pi dependency) uses the
identical `Type.Unsafe({...raw JSON schema...})` pattern.

A tool's `execute` proxies to `tools/call` and converts the MCP result
(`{content:[{type:"text",text}], isError}`) to pi's tool-result shape:
`isError: true` is converted to a **thrown** `Error` (`docs/extensions.md`:
"throw to signal an error... returning a value never sets the error flag"),
mirroring `OrcaHub.MCP.Tools.Result.error/1`'s content onto pi's own error
convention; a plain object is returned on success.

**Per-session flags and mid-session changes need NO pi-specific code.**
Both were true before writing a single line of eviction logic, confirmed by
reading `session_runner.ex`: `apply_flag_change_no_turn/3` and
`apply_flag_change_running/3` (the two functions
`update_orchestrator`/`update_code_exec` casts dispatch through) key
entirely on `Map.get(data, key) != value` and `data.port`/
`data.pending_rebake` — no `data.backend`/capability check anywhere in that
path. `evict_warm_now/1` force-closes ANY backend's warm port
unconditionally. So: (1) the flags are baked into `ORCA_MCP_URL` exactly
the way Claude bakes them into its inline `--mcp-config` URL — same
`McpUrl.orca_url/1` call, same query params; (2) a flag change while idle
evicts the warm pi process immediately, and a flag change mid-turn marks
`pending_rebake`, consumed at the next `:running` → `:idle`/`:error`
transition — in both cases the NEXT `spawn_spec/2` call re-bakes
`ORCA_MCP_URL` from the new flag values, and the fresh pi process re-runs
`orca-mcp.ts`'s `session_start` handshake against the updated URL from
scratch. Zero `session_runner.ex` changes were needed for this slice.

**System prompt.** `Backend.Claude.system_prompt/1` injects an orchestrator-
mode prompt block (`mcp__orca__start_session`-shaped delegation guidance)
that was previously a private `Backend.Claude` function precisely because it
uses the `mcp__server__tool` naming convention — now equally correct for
`Backend.Pi`, since `orca-mcp.ts` registers tools under the identical
convention. Moved verbatim (byte-for-byte, only the call site changed) into
`OrcaHub.Backend.SharedPrompts.orchestrator_prompt/2`; `Backend.Claude` and
`Backend.Pi` both call the shared version now. `Backend.Codex` was NOT
switched to it — Codex's own `orchestrator_system_prompt/2` uses bare
(non-`mcp__`-prefixed) tool names, a genuinely different convention for a
genuinely different MCP client, so it correctly keeps its own private copy.
`Backend.Pi.system_prompt/1` also now includes
`SharedPrompts.code_exec_prompt/1` (already shared, just a new call site) —
needed because code-exec mode collapses the bridged tool set down to the
`run_elixir`/`search_tools`/`read_tool` meta-tools, and the model needs the
same usage guidance Claude gets to use them well. Both fragments are
correctly ABSENT when the corresponding flag is off (verified in
`pi_test.exs`). Out of scope, deliberately: pi's `AskUserQuestion`-fallback
prompt text (Claude-built-in-tool-specific, pi has its own `question` tool
with no equivalent need) and Claude's non-orchestrator `sibling_sessions_
prompt/1` (lower-value, kept the diff tight).

**Capability flip.** `Backend.Pi.capabilities().mcp` flips `false` → `true`.
This is the ONLY capability changed — every UI surface it gates
(orchestrator toggle, code_exec toggle, MCP-servers modal in
`session_live/show.html.heex` and the new-session picker in
`session_live/index.html.heex`) is ALREADY conditioned purely on
`@capabilities.mcp`, with no pi-specific markup anywhere in either
template — confirmed by reading both `.heex` files, not just asserted. Pi
sessions get this chrome for free.

**Live smoke (2026-07-03, real `pi` 0.80.3 binary + the real hub `/mcp`
endpoint, NOT a stub):** the hub was booted in `:hub` mode on
`127.0.0.1:4002` (a throwaway `Application.ensure_all_started(:orca_hub)`
script, port/watchers overridden — port 4000/4001 are off-limits on this
host, a prod agent runs there) with a real dev-DB `Tavily` upstream MCP
server already enabled. A curl-driven handshake against `/mcp` first
confirmed the transport claims above directly (plain `200
application/json`, `mcp-session-id` response header, `202` empty body for
the `notifications/initialized` POST) before touching pi at all. Then a
Python harness spawned `pi --mode rpc --no-session -e priv/pi/orca.ts -e
priv/pi/orca-mcp.ts` with `ORCA_MCP_URL` pointed at the live endpoint and
prompted: "Call the mcp__orca__open_file tool with file_path=\"README.md\"
… then tell me the exact text the tool returned." Captured:

```
{"type":"tool_execution_start","toolCallId":"call_1c01625a61f04c6cb4025091","toolName":"mcp__orca__open_file","args":{"file_path":"README.md"}}
{"type":"tool_execution_end","toolCallId":"call_1c01625a61f04c6cb4025091","toolName":"mcp__orca__open_file","result":{"content":[{"type":"text","text":"Opened README.md in the session file viewer."}],"details":{}},"isError":false}
```

— and the model's final answer correctly quoted `"Opened README.md in the
session file viewer."`, the exact string `OrcaHub.MCP.Tools.Files.call/3`
returns. Cross-checked hub-side logs for the SAME `mcp_session_id` show the
full handshake: `[MCP] session start` → `initialize` → `notifications/
initialized` → `tools/list … tool_count=7` (2 first-party + 5 Tavily) →
`tools/call: name="open_file" … path=local` → `tools/call result:
name="open_file" isError=false`. Two degrade-silently cases were also
live-verified: `ORCA_MCP_URL` unset → one stderr line
(`[orca-mcp] ORCA_MCP_URL not set — no orca MCP tools registered`), pi
proceeds normally, the model just reports it lacks that tool; endpoint
unreachable (`127.0.0.1:4009`, nothing listening) → one stderr line
(`[orca-mcp] failed to bridge orca MCP tools from … fetch failed`), process
exits cleanly, no hang.

**Known gap kept out of scope:** unlike `Backend.Claude`'s
`orchestrator_tools/1` (which restricts the Claude CLI's *native* built-in
tool set — no Bash, Read/Glob/Grep/WebFetch/WebSearch/Write/Edit only — for
an orchestrator session), `Backend.Pi` does not restrict pi's native
built-in tools (`bash`/`read`/`write`/`edit`) by the orchestrator flag. An
orchestrator pi session gets the full native tool set PLUS the bridged
`mcp__orca__*` coordination tools, rather than Claude's read-only-plus-
delegate posture. Fixing this would need pi CLI-flag research
(`--no-tools`/`--no-builtin-tools` scope to a specific allowlist, not just
on/off) out of scope for this MCP-bridge-focused slice.

**Test coverage:** `pi_test.exs`'s capability row updated (`mcp: true`);
its `system_prompt/1` describe block extended with two new tests
(orchestrator-mode injects `SharedPrompts.orchestrator_prompt/2`'s text,
code_exec-mode injects `SharedPrompts.code_exec_prompt/1`'s text) replacing
the now-inverted "orchestrator flag has no effect" test.  `backend_test.exs`
updated for pi's flipped `mcp` capability. `show_test.exs`/`index_test.exs`
updated: the orchestrator toggle and MCP-servers modal now assert PRESENT
for pi (previously asserted absent — pi was the one exercise of the
`mcp: false` gate; now all three backends exercise the `mcp: true` path
identically). No `message_components.ex` test changes — zero rendering code
changed, so the existing generic `mcp__*` coverage already covers this.
Full suite: 391 tests (+1 net: two new pi system_prompt tests, one
retired), the same 1 pre-existing unrelated `TriggersTest` failure as every
prior phase's baseline.

### 12.6 pi mid-turn steering, queue visibility, and compaction events (IMPLEMENTED)

Pi's `docs/rpc.md` documents three pieces of protocol OrcaHub didn't use at
all through §12.2/Phase 4: `steer`/`follow_up` (mid-turn message delivery
distinct from `prompt`), `queue_update` (what's currently queued), and
`compaction_start`/`compaction_end` (manual/automatic context compaction).
This section adds all three, live-verified against the real 0.80.3 binary.

**Capability seam.** `Capabilities` (§3.1) gained a `steering: boolean` field,
defstruct-defaulted to `false` — Claude and Codex needed **zero code changes**
to keep behaving identically; only `Backend.Pi.capabilities/0` sets
`steering: true`. `OrcaHub.Backend` gained a new **optional** callback,
`encode_steer_turn/2` (`@optional_callbacks encode_steer_turn: 2`), mirroring
`encode_user_turn/2`'s `{iodata, ctx}` shape. It's optional (not every
`@behaviour OrcaHub.Backend` adopter needs a stub clause) because
`SessionRunner` gates every call site with BOTH the capability flag AND
`function_exported?(backend, :encode_steer_turn, 2)` (private `steerable?/1`
in `session_runner.ex`) — a backend can advertise `steering: true` without
implementing the callback and safely fall back to the default path instead of
raising. `Backend.Pi.encode_steer_turn/2` writes
`{"type":"steer","message":…}` (the dedicated `steer` command, not
`{"type":"prompt",…,"streamingBehavior":"steer"}` — the docs offer both, this
adapter uses the former since it needs no extra field on the existing
`encode_user_turn/2` path). `follow_up` (pi's "deliver only once fully idle"
variant) was deliberately NOT wired up: the runner's `:idle` state already
starts a fresh turn via plain `encode_user_turn/2` for any message sent while
idle, which is observably the same outcome `follow_up` describes — no new
seam needed for that half of the docs section.

**Runner mid-turn dispatch (`session_runner.ex`, `:running` state).** The
existing `running({:call, from}, {:send_message, prompt}, %{engine:
:streaming, port: port} = data)` clause (the ONLY call site that used to
unconditionally queue + `send_control_interrupt/1`) now branches:
`steerable?(data)` (capability + `function_exported?/3`, both true only for
pi today) → `write_steer_turn/2` (mirrors `write_user_turn/2`: calls
`backend.encode_steer_turn/2`, `Port.command/2`s the iodata, flushes
`pending_writes` per §3.2) and **stays in `:running`** — no
`pending_prompts` bookkeeping, no interrupt, the in-flight turn is never
touched. The default branch (Claude/Codex, or any future backend that hasn't
implemented the callback) is **byte-identical to before**: queue + interrupt.
The user's message is persisted/broadcast identically either way — only what
happens to the RUNNING TURN differs. The `warming_up` guard is kept for
symmetry even though no `steering: true` backend today ever sets
`warmup_turn: true`.

**Composer UI (`show.ex`/`show.html.heex`).** The composer was ALREADY
enabled while `:running` for every backend — sending mid-turn was never
blocked; the existing behavior for Claude/Codex is queue+interrupt (spec's
pre-existing behavior, unchanged). The only additions: (1) a subtle hint line
below the composer, `@capabilities.steering && @status == :running` gated —
"Sending now will steer the running turn instead of interrupting it."; (2) a
small pending-queue indicator (see below) above the composer. Neither
touches the Send/Interrupt buttons or textarea itself.

**Queue visibility.** `Backend.Pi.normalize/2` maps pi's `queue_update`
event to a synthesized **`system`** event:
`%{"type"=>"system","subtype"=>"queue_update","steering"=>[…],"follow_up"=>[…]}`
(pi's `followUp` key snake_cased to match the rest of the normalized
vocabulary's key style). `SessionRunner.handle_stream_event/2` special-cases
this exact `subtype` — mirroring the PRE-EXISTING Claude
`"system"`/`"status"`/`"compacting"` clause right below it — to **broadcast
only** (`{:queue_update, steering, follow_up}` over the session's PubSub
topic) and explicitly NOT persist/append it to `data.messages`: it fires on
every queue change, so persisting it would spam message history with
transient state. `SessionLive.Show` holds the latest snapshot in a new
transient `:pi_queue` assign (`%{steering: [], follow_up: []}`, never part of
`@messages`), updated by a new `handle_info({:queue_update, steering,
follow_up}, socket)` clause. The template renders it as a small row of
`badge-ghost` chips above the composer, gated on
`@capabilities.steering && (@pi_queue.steering != [] || @pi_queue.follow_up != [])`.

**Compaction events.** Unlike `queue_update`, compaction is a one-off
occurrence worth keeping in history, so `compaction_start`/`compaction_end`
normalize onto **persisted** `system` events — no special-casing in
`SessionRunner`, they fall through to the pre-existing generic `"system"`
clause (same path the synthesized `"init"` event already uses) and render via
`MessageComponents`' existing `system_message/1` component, **zero new
components**. `compaction_start` → `%{"type"=>"system",
"subtype"=>"compaction_start","reason"=>reason}` (`reason` ∈
`"manual"|"threshold"|"overflow"`, passed through verbatim).
`compaction_end` → `%{"type"=>"system","subtype"=>"compaction_end",
"reason"=>…, "aborted"=>bool}` plus, when present on the wire,
`"tokens_before"`/`"estimated_tokens_after"` (from `result.tokensBefore`/
`result.estimatedTokensAfter`, snake_cased) and `"error_message"` (from
`errorMessage`) — all three via the pre-existing `put_if_present/2` helper
(reused, not duplicated) so a `nil`/absent `result` (aborted or failed
compaction) omits them rather than synthesizing `nil`s. `system_message/1`
grew a small `system_message_label/1` private helper (still ONE component,
same `<div>`/icon markup) producing a friendlier label for these two
subtypes specifically — "Compacting context (threshold)", "Compacted context
(150000 → 32000 tokens)", "Compaction aborted", or the raw `error_message`
(pi's own message is often already self-describing — live-verified
`"Compaction failed: Nothing to compact (session too small)"` — so the
label only ADDS a `"Compaction failed: "` prefix when the message doesn't
already start with "compaction", avoiding a stutter); every other subtype
(incl. `"init"`) falls back to the raw subtype string exactly as before.

**Rejected `steer` (defensive).** A `{"type":"response","command":"steer",
"success":false}` (e.g. steering disabled) must NOT synthesize a `"result"`
event the way the pre-existing rejected-`prompt` defensive clause does —
that would incorrectly end the STILL-RUNNING turn. It normalizes to a
non-terminal persisted `%{"type"=>"system","subtype"=>"steer_failed",
"message"=>…}` instead — visible in the feed, turn keeps going.

**Testing.** `test/orca_hub/backend/pi_test.exs`: `encode_steer_turn/2`
framing, `queue_update`/`compaction_start`/`compaction_end` normalization
(success/aborted/failed-with-self-describing-message shapes), rejected-steer
handling, plus the pre-existing "drops silently" test narrowed (queue_update/
compaction_start moved out of the drop list into their own describes).
`test/orca_hub_web/components/message_components_test.exs`: a new "pi
compaction events" describe feeding real `Backend.Pi.normalize/2` output
through `MessageComponents.message_feed/1` (same posture as the existing
Codex renderer-check test), covering all four label branches.
`test/orca_hub/backend/pi_stub_integration_test.exs` +
`test/support/fixtures/pi_stub_rpc.py`: the stub gained a `"PAUSE_FOR_STEER"`
sentinel prompt (pauses after `agent_start` instead of completing, so a real
mid-flight turn exists to steer against) and a `steer` command handler
(acks, emits `queue_update`+`compaction_start`+`compaction_end`, then
finishes with text echoing the steered instruction) plus an optional
`PI_STUB_LOG` env var that logs every received command type — the new
integration test drives a REAL `SessionRunner` through the full
pause→steer→finish cycle and asserts (a) exactly one `result` event (not two
— proof the turn was steered, not interrupted-and-resent), (b) both user
messages preserved distinctly, (c) the steered text was actually produced,
(d) `compaction_start`/`compaction_end` persisted with the right fields, (e)
`queue_update` did NOT leak into persisted messages, and (f) the stub's
command log contains `"prompt"` and `"steer"` each exactly once and never
`"abort"` — the strongest possible proof (short of the live smoke below)
that steering took the non-interrupt path.

**Live smoke (RESOLVED).** Ran `pi --mode rpc --no-session --model
fireworks/accounts/fireworks/models/gpt-oss-20b` directly (no Elixir/Phoenix
involved), driving the real 0.80.3 binary from a throwaway Python script:
started a turn ("count to 20 slowly, one bash tool call per number"), let it
run one bash call, sent `{"type":"steer","message":"Actually stop counting
and just say STEERED"}` mid-turn. Observed on the wire, in order:
`queue_update` with the steering message queued
(`{"steering":["Actually stop counting and just say STEERED"],"followUp":[]}`),
`{"type":"response","command":"steer","success":true}`, the in-flight bash
call finishing normally, a SECOND `queue_update` with an now-empty queue
(delivered before the next LLM call, exactly as `docs/rpc.md` describes),
then a new assistant turn whose thinking block says *"We need to stop
counting... Just respond with STEERED"* and whose final text is literally
`"STEERED"` — the steer was genuinely delivered mid-turn, not
queued-and-resent. Then, once idle, sent `{"type":"compact"}`: observed
`{"type":"compaction_start","reason":"manual"}` immediately followed by
`{"type":"compaction_end","reason":"manual","aborted":false,"willRetry":false,
"errorMessage":"Compaction failed: Nothing to compact (session too small)"}`
— this session was too small to actually compact, so the SUCCESS shape
(`result.tokensBefore`/`estimatedTokensAfter`) wasn't captured live; that
shape is taken verbatim from `docs/rpc.md`'s own example and covered by the
unit tests above instead. No adapter gaps found — every field OrcaHub's
normalizer reads matched the live wire output exactly.

**Deferred (stretch, not attempted).** `get_entries`'s `since:<entryId>`
cursor (reconnect hardening — replay only entries after the last one seen,
across a runner restart) was explicitly out of scope for this change per the
brief and is left as clean future work: it would need a new persisted
"last seen pi entry id" per session (a candidate: reuse `backend_state`
plumbing, but that's reset on every port teardown per §3.2, so it would need
its OWN persisted column or piggyback on `claude_session_id`'s row) and a
reconnect path that calls `get_entries{since:…}` instead of relying on pi's
own `--session-id` resume replaying everything — a larger, separate change
better scoped on its own.
