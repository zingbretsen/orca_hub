defmodule OrcaHub.Backend do
  @moduledoc """
  Behaviour for pluggable agent-CLI backends (Claude, Codex, grok, pi, …).

  `SessionRunner` remains the orchestrator (GenStatem states, DB writes,
  PubSub, WarmPool, idle teardown, title generation, AskUserQuestion status
  tracking). Everything specific to the underlying agent CLI — spawning the
  process, framing stdin turns, decoding/normalizing its native event
  vocabulary into the persisted Claude `stream-json` shape, and answering any
  server-initiated peer requests — lives behind this behaviour.

  A session's backend is resolved once (via `resolve/1`) at runner init and
  stored in runner `data` as `backend: module`. Every backend-specific call
  site in `SessionRunner` goes through `data.backend.<callback>(...)`.

  See `backend_abstraction_spec.md` §3 for the full design. Phase 0 wires up
  only `OrcaHub.Backend.Claude` (a verbatim move of today's logic, with
  identity `normalize/2`); `resolve/1` maps every input to Claude until the
  `backend` DB column exists (Phase 1).

  ## `ctx`

  Every callback below takes (and most return) a `ctx` map. In Phase 0,
  `SessionRunner` passes its own runner `data` map as `ctx` — it already
  carries every field a backend needs (`session_id`, `directory`, `model`,
  `orchestrator`, `code_exec`, `claude_session_id`, `project_id`, `db_node`,
  `engine`, …) plus a `backend_state` map reserved for adapter-owned state
  threaded through `normalize/2`, `encode_*/2`, `on_open/1`, and
  `handle_peer_request/2` (unused by Claude's identity implementation).
  `SessionRunner` treats `backend_state` as opaque, with ONE exception (Phase
  2, spec §3.2): the reserved key `backend_state.pending_writes` — a list of
  iodata frames an adapter wants written to the port as a REACTION to
  something it just saw (e.g. Codex's `normalize/2` seeing the `initialize`
  response and wanting to immediately send `initialized` + `thread/start`,
  even though `normalize/2`'s own return shape has no direct iodata slot).

  After every callback below that returns `ctx` (`normalize/2`,
  `handle_peer_request/2`, `encode_user_turn/2`, `on_open/1`), the runner
  flushes `ctx.backend_state.pending_writes` to the port (in list order) and
  resets it to `[]` — implemented once, in `SessionRunner`'s private
  `flush_pending_writes/1`. Backends that never populate this key (Claude) pay
  no cost: the flush is a no-op on an empty/absent list. Any DIRECT iodata a
  callback returns (`on_open/1`'s `{iodata, ctx}`, `encode_user_turn/2`'s
  `{iodata, ctx}`, `handle_peer_request/2`'s `{reply, events, ctx}`) is written
  first, then the pending-writes queue is flushed on top of it.
  """

  defmodule Capabilities do
    @moduledoc """
    Drives graceful degradation. The UI and runner branch on capabilities,
    never on the backend name. See spec §3.1.
    """

    @type interrupt :: :protocol | :signal | :none
    @type system_prompt :: :flag | :leading_message | :session_param | :none

    @type t :: %__MODULE__{
            streaming: boolean,
            interrupt: interrupt,
            mcp: boolean,
            resume: boolean,
            usage: boolean,
            system_prompt: system_prompt,
            warmup_turn: boolean,
            plan_mode: boolean,
            plan_mode_toggle: boolean,
            ask_user_question: boolean,
            session_stats: boolean,
            steering: boolean
          }

    defstruct streaming: true,
              interrupt: :protocol,
              mcp: true,
              resume: true,
              usage: true,
              system_prompt: :flag,
              warmup_turn: true,
              # Phase 3 (backend_abstraction_spec.md §7/§8): whether this
              # backend supports the `EnterPlanMode`/`ExitPlanMode` plan-mode
              # tool pair, and whether it has SOME mechanism for asking the
              # user an interactive question mid-turn and tracking a
              # `waiting`-ish status against it. Claude does this via its
              # built-in `AskUserQuestion` tool; pi does it via the
              # `question` tool in `priv/pi/orca.ts` + the extension-UI reply
              # loop (`Backend.Pi.handle_peer_request/2` /
              # `encode_ui_response/3`) — same capability flag, two different
              # backend-specific mechanisms under it, gating the appropriate
              # UI card either way (spec §12.3). Codex has neither.
              plan_mode: true,
              # Whether the USER can flip plan mode on/off directly (spec
              # §12.4), as opposed to Claude's `plan_mode` chrome, which only
              # ever reflects a model-INITIATED EnterPlanMode/ExitPlanMode
              # tool call — there is no user-facing toggle for Claude.
              # `SessionLive.Show`'s toggle button (`toggle_plan_mode` event
              # -> `SessionRunner.toggle_plan_mode/1`) is gated on THIS flag,
              # never on `plan_mode` alone, so Claude/Codex sessions (which
              # both leave this `false`) never see an affordance that would
              # write a meaningless "/plan" turn into their native protocol.
              plan_mode_toggle: false,
              ask_user_question: true,
              # pi-only (spec §12.3): whether this backend can report
              # token/cost/context-window session stats on demand (pi's
              # `get_session_stats` RPC command). Deliberately NOT the same
              # flag as `usage` — `usage: true` gates the Claude-API quota
              # panel backed by `OrcaHub.Claude.Usage`, which is the wrong
              # data source for a non-Claude backend. `session_stats` gates a
              # pi-appropriate per-session tokens/cost/context% display fed
              # by the backend's own normalized `pi_session_stats` event.
              session_stats: false,
              # spec §12.6: whether a message sent while a turn is in flight
              # (:running) is delivered as an in-place STEER of that turn
              # (`Backend.encode_steer_turn/2`) instead of the default
              # interrupt-then-resend queueing every other backend uses.
              # Defaults false so Claude/Codex need no code change here — only
              # `Backend.Pi` overrides it (pi's native `steer` command).
              steering: false
  end

  @typedoc "Long-lived streaming port vs. a per-turn one-shot process."
  @type mode :: :streaming | :one_shot

  @typedoc "Opaque context map threaded through backend callbacks (see moduledoc)."
  @type ctx :: map

  @doc "Static capability advertisement for this backend."
  @callback capabilities() :: Capabilities.t()

  @doc """
  Executable + args + env + port framing for a spawn.

  `framing` selects the decode layer (NOT hardcoded in `SessionRunner`) so a
  third framing (e.g. JSON-RPC) is additive.
  """
  @callback spawn_spec(mode, opts :: ctx) ::
              %{
                executable: String.t(),
                args: [String.t()],
                env: [{charlist() | String.t(), charlist() | String.t() | false}],
                port_opts: keyword,
                framing: :ndjson | :jsonrpc
              }

  @doc """
  Bytes to write to the port immediately after it opens (streaming backends
  only — never called for `:one_shot` spawns).

  Codex: the mandatory `initialize` request (the first leg of its
  `initialize` → await result → `initialized` handshake — the rest of the
  handshake reacts to the response in `normalize/2` via `pending_writes`, see
  the moduledoc). Claude has no open-time handshake: returns `{"", ctx}`.
  """
  @callback on_open(ctx) :: {iodata, ctx}

  @doc "Bytes to write to stdin to start/append a user turn (streaming backends)."
  @callback encode_user_turn(prompt :: String.t(), ctx) :: {iodata, ctx}

  @doc """
  OPTIONAL (spec §12.6). Bytes to write to stdin to STEER an in-flight turn
  in place, instead of interrupting it. Only meaningful — and only ever
  called — when `capabilities().steering` is true; `SessionRunner` checks
  `function_exported?/3` before calling it, so a backend can flip
  `steering: true` without a hard compile-time requirement to implement this.
  `Backend.Pi` is the only implementor today (`{"type":"steer","message":…}`).
  """
  @callback encode_steer_turn(prompt :: String.t(), ctx) :: {iodata, ctx}

  @doc "Bytes for a graceful interrupt, or `:signal` to fall back to SIGINT."
  @callback encode_interrupt(req_id :: String.t(), ctx) :: iodata | :signal

  @doc """
  Native decoded event map -> Claude-shaped events (may be `[]`) + updated ctx.

  STATEFUL by design (see spec §3.2): non-Claude backends may need to
  correlate JSON-RPC request/response ids, stash usage for a synthesized
  `result` event, coalesce deltas, or pair `tool_use`/`tool_result` ids.
  Claude's implementation is `{[event], ctx}` (identity on both).
  """
  @callback normalize(native_event :: map, ctx) :: {[map], ctx}

  @doc """
  Server-initiated peer request (has BOTH `id` and `method`) that must be
  answered on stdin with the same id — e.g. Codex approval requests.

  Returns `{reply_iodata, events, ctx}`: bytes to write back to the port, any
  Claude-shaped events to surface in the feed, and updated ctx.

  Claude never issues peer requests — `Backend.Claude` implements this as a
  no-op that logs a warning and returns `{"", [], ctx}` (empty reply,
  no events, ctx unchanged).
  """
  @callback handle_peer_request(request :: map, ctx) :: {reply :: iodata, [map], ctx}

  @doc "Pull the backend session id out of a normalized/native event, or nil."
  @callback session_id(event :: map) :: String.t() | nil

  @doc "Optional: materialize per-session on-disk state (e.g. CODEX_HOME, config.toml)."
  @callback prepare_session(ctx) :: {:ok, extra_env :: keyword} | :ok

  @doc "Optional: clean up whatever `prepare_session/1` materialized."
  @callback cleanup_session(ctx) :: :ok

  @doc """
  Build the system-prompt payload appropriate to this backend.

  `:flag` -> returned as an arg by `spawn_spec/2`
  `:leading_message` -> prepended to the first user turn's text
  `:session_param` -> included in the backend's session-create message
  """
  @callback system_prompt(ctx) :: String.t() | nil

  @doc """
  Selectable models for this backend, as `{id, label}` pairs (Phase 3, spec
  §7). `id` is the exact passthrough string sent to the CLI — there is no
  enum validation, callers may also submit an arbitrary free-text id the UI
  didn't list.

  May be node-dependent and non-static (pi shells out to `pi --list-models`
  behind a TTL cache) — call it on the node that runs the CLI, via
  `models_for/2`.
  """
  @callback models() :: [{String.t(), String.t()}]

  @doc """
  Whether this backend's CLI is actually runnable on THIS node (executable
  resolvable). Drives node-scoped picker filtering via `available_on/1` —
  a backend that isn't installed on a node is hidden from that node's
  pickers, while `resolve/1`/changeset validation stay node-agnostic.
  """
  @callback installed?() :: boolean

  # encode_steer_turn/2 is opt-in (spec §12.6) — only backends advertising
  # `capabilities().steering: true` need to implement it; SessionRunner
  # guards every call site with `function_exported?/3` rather than relying on
  # this alone, but declaring it optional keeps every existing `@behaviour
  # OrcaHub.Backend` adopter (Claude, Codex) compiling without a stub clause.
  @optional_callbacks encode_steer_turn: 2

  @doc """
  OPTIONAL — encodes the user's answer to a backend-native mid-turn UI
  dialog (pi's extension-UI reply loop; "pi backend groundwork" slice) into
  bytes to write back to the port, keyed purely on `request_id` (NOT on any
  in-flight tool_use — an extension can pop a dialog with no tool call
  running at all, e.g. a future plan-mode extension).

  Returns `{:ok, iodata, ctx}` on success (`iodata` already framed for the
  wire; `ctx` has the pending-request bookkeeping cleared) or `:noop` when
  `request_id` doesn't match a currently-pending request (unknown or
  already-answered — callers must no-op rather than write anything).

  Backends that never emit a mid-turn dialog request (Claude, Codex) don't
  implement this callback at all — see `@optional_callbacks` below and the
  `encode_ui_response/4` dispatcher, which returns `:noop` for any backend
  lacking an implementation.
  """
  @callback encode_ui_response(request_id :: String.t(), payload :: map, ctx) ::
              {:ok, iodata, ctx} | :noop

  @doc """
  OPTIONAL — encodes a backend-native command that toggles a live
  session-level mode (currently only pi's plan mode, spec §12.4) into bytes
  to write to the port, when NOT mid-turn (`SessionRunner.toggle_plan_mode/1`
  is only reachable from `:idle` with a warm port — see that function's doc).

  Returns `{:ok, iodata, ctx}` on success or `:noop` when this backend has no
  such toggle (Claude, Codex — `plan_mode` there is model-initiated, not
  user-toggled). `Backend.Pi.encode_toggle_plan_mode/1` writes pi's `/plan`
  extension command via the SAME wire shape `encode_user_turn/2` already
  produces — reused directly rather than duplicated.
  """
  @callback encode_toggle_plan_mode(ctx) :: {:ok, iodata, ctx} | :noop

  @optional_callbacks encode_ui_response: 3, encode_toggle_plan_mode: 1

  @doc """
  Resolves a backend identifier (the `sessions.backend` DB column value) to
  its implementing module.

  Phase 1: only `"claude"` (and `nil`, for rows/paths that predate the
  `backend` column default) resolve. Any other value — including `"codex"`,
  which is accepted at the data layer ahead of its Phase 2 adapter — fails
  loudly here rather than silently falling back to Claude, so a
  not-yet-implemented backend can never be run by accident.
  """
  @spec resolve(String.t() | nil) :: module
  def resolve(nil), do: OrcaHub.Backend.Claude
  def resolve("claude"), do: OrcaHub.Backend.Claude
  def resolve("codex"), do: OrcaHub.Backend.Codex
  def resolve("pi"), do: OrcaHub.Backend.Pi

  def resolve(other) do
    raise "OrcaHub.Backend.resolve/1: unknown backend #{inspect(other)} " <>
            "(no adapter registered yet)"
  end

  @doc """
  Backends selectable in the UI, as `{value, label}` pairs for a `<select>`.

  Claude + Codex + pi. Callers should render nothing (or a hidden field) when
  this list has a single entry, and only show a picker once it grows past
  one.
  """
  @spec available() :: [{String.t(), String.t()}]
  def available, do: [{"claude", "Claude"}, {"codex", "Codex"}, {"pi", "Pi"}]

  @doc """
  The subset of `available/0` whose CLI is installed on THIS node.
  Runs locally — use `available_on/1` to ask about another node.
  """
  @spec installed_backends() :: [{String.t(), String.t()}]
  def installed_backends do
    Enum.filter(available(), fn {value, _label} -> resolve(value).installed?() end)
  end

  # Node-scoped facts are re-read on every render; cache them briefly.
  @availability_ttl_ms 60_000
  @models_ttl_ms 300_000

  @doc """
  The subset of `available/0` whose CLI is installed on `node` (RPC'd and
  cached #{div(@availability_ttl_ms, 1000)}s). An unreachable node falls back
  to `[{"claude", "Claude"}]` — Claude is the one backend present on every
  node, and a too-small picker beats a picker offering backends that can't
  spawn.
  """
  @spec available_on(node | String.t() | nil) :: [{String.t(), String.t()}]
  def available_on(node) do
    node = normalize_node(node)

    OrcaHub.Backend.Cache.get_or_run({:available_on, node}, @availability_ttl_ms, fn ->
      OrcaHub.Cluster.rpc(node, __MODULE__, :installed_backends, [])
    end)
  rescue
    _ -> [{"claude", "Claude"}]
  end

  defp normalize_node(nil), do: node()
  defp normalize_node(n) when is_atom(n), do: n

  defp normalize_node(n) when is_binary(n) do
    String.to_existing_atom(n)
  rescue
    ArgumentError -> node()
  end

  @doc """
  Resolves a session (or a bare `backend` column value) to its
  `Capabilities` struct (Phase 3, spec §7/§9). The UI branches on the
  returned struct's fields, never on the backend name string.

  Accepts anything with a `:backend` key (a `Session` struct, a runner `ctx`
  map, ...) as well as a bare backend string/`nil`. Never raises on a
  legacy/nil backend — that resolves to Claude's capabilities, same as
  `resolve/1`.
  """
  @spec capabilities_for(%{optional(any) => any, backend: String.t() | nil} | String.t() | nil) ::
          Capabilities.t()
  def capabilities_for(%{backend: backend}), do: capabilities_for(backend)

  def capabilities_for(backend) when is_binary(backend) or is_nil(backend) do
    resolve(backend).capabilities()
  end

  @doc """
  Selectable models for a session's (or a bare `backend` column value's)
  backend, as `{id, label}` pairs (Phase 3, spec §7). Scopes the model
  picker/switcher to the backend actually driving the session.
  """
  @spec models_for(%{optional(any) => any, backend: String.t() | nil} | String.t() | nil) ::
          [{String.t(), String.t()}]
  def models_for(%{backend: backend}), do: models_for(backend)

  def models_for(backend) when is_binary(backend) or is_nil(backend) do
    resolve(backend).models()
  end

  @doc """
  Like `models_for/1` but evaluated on `node` (RPC'd + cached
  #{div(@models_ttl_ms, 1000)}s) — required for backends whose `models/0` is
  live/node-dependent (pi's `--list-models`). An unreachable node or a raise
  inside `models/0` falls back to `[]`; the free-text model field still
  covers everything.
  """
  @spec models_for(term, node | String.t() | nil) :: [{String.t(), String.t()}]
  def models_for(backend_ref, node) do
    backend = backend_string(backend_ref)
    node = normalize_node(node)

    OrcaHub.Backend.Cache.get_or_run({:models_for, backend, node}, @models_ttl_ms, fn ->
      OrcaHub.Cluster.rpc(node, __MODULE__, :models_for, [backend])
    end)
  rescue
    _ -> []
  end

  defp backend_string(%{backend: backend}), do: backend_string(backend)
  defp backend_string(nil), do: "claude"
  defp backend_string(backend) when is_binary(backend), do: backend

  @doc """
  Dispatches to `backend.encode_ui_response/3` when the backend implements
  the optional callback, else returns `:noop`. `SessionRunner` calls this
  instead of the bare `backend.encode_ui_response/3` so Claude/Codex sessions
  answering a stray/impossible `answer_ui_request` call never hit
  `UndefinedFunctionError`.
  """
  @spec encode_ui_response(module, String.t(), map, ctx) :: {:ok, iodata, ctx} | :noop
  def encode_ui_response(backend, request_id, payload, ctx) do
    if function_exported?(backend, :encode_ui_response, 3) do
      backend.encode_ui_response(request_id, payload, ctx)
    else
      :noop
    end
  end

  @doc """
  Dispatches to `backend.encode_toggle_plan_mode/1` when the backend
  implements the optional callback, else returns `:noop`. Mirrors
  `encode_ui_response/4`'s dispatch pattern (spec §12.4).
  """
  @spec encode_toggle_plan_mode(module, ctx) :: {:ok, iodata, ctx} | :noop
  def encode_toggle_plan_mode(backend, ctx) do
    if function_exported?(backend, :encode_toggle_plan_mode, 1) do
      backend.encode_toggle_plan_mode(ctx)
    else
      :noop
    end
  end
end
