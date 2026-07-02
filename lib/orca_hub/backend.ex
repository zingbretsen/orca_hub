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
  threaded through `normalize/2`, `encode_*/2`, and `handle_peer_request/2`
  (unused by Claude's identity implementation). `SessionRunner` treats
  `backend_state` as opaque.
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
            warmup_turn: boolean
          }

    defstruct streaming: true,
              interrupt: :protocol,
              mcp: true,
              resume: true,
              usage: true,
              system_prompt: :flag,
              warmup_turn: true
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

  @doc "Bytes to write to stdin to start/append a user turn (streaming backends)."
  @callback encode_user_turn(prompt :: String.t(), ctx) :: {iodata, ctx}

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

  def resolve(other) do
    raise "OrcaHub.Backend.resolve/1: unknown backend #{inspect(other)} " <>
            "(no adapter registered yet)"
  end

  @doc """
  Backends selectable in the UI, as `{value, label}` pairs for a `<select>`.

  Phase 1: only Claude. Phase 2 appends Codex once `Backend.Codex` lands —
  callers should render nothing (or a hidden field) when this list has a
  single entry, and only show a picker once it grows past one.
  """
  @spec available() :: [{String.t(), String.t()}]
  def available, do: [{"claude", "Claude"}]
end
