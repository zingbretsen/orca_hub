defmodule OrcaHub.Backend.Pi do
  @moduledoc """
  `OrcaHub.Backend` implementation for Mario Zechner's `pi` coding agent
  (npm `@earendil-works/pi-coding-agent`, bin `pi`), over `pi --mode rpc` —
  a long-lived, bidirectional JSONL-over-stdio protocol (spec §12.2).

  ## Verified against 0.80.3 (live capture, superseding the docs-only §12.2
  research pass)

  The host had `pi` 0.75.3 at implementation start; it was upgraded to
  0.80.3 mid-implementation (both the installed package and its bundled
  `docs/rpc.md` moved together). Every wire-protocol claim below was
  re-captured live against the 0.80.3 binary (a Python stdio harness driving
  `pi --mode rpc` and `pi -p --mode json`, real Fireworks-provider turns via
  `~/.pi/agent/auth.json`) — 0.75.3 was never shipped in this adapter.
  Deviations from the original §12.2 research draft:

    * **No handshake, no FSM.** §12.2 speculated an `initialize`/session-ready
      exchange might gate the first `prompt`. Live-verified: `pi --mode rpc`
      accepts `{"type":"prompt",...}` as the very first stdin write — no
      handshake, no `pending_prompt` stash. `on_open/1` still writes one
      command (`get_state`), but purely to *learn* the session id, not to
      gate anything; it and the user's first `prompt` are written
      back-to-back and pi processes/responds to both in order.
    * **Session id capture differs by mode.** Streaming (`--mode rpc`) never
      unprompted-announces a session id on stdout — `on_open/1` sends
      `{"type":"get_state"}` and `session_id/1` reads
      `response.data.sessionId` from the reply. One-shot (`-p --mode json`)
      DOES announce it unprompted: the very first stdout line is
      `{"type":"session","id":…,…}`. `normalize/2` handles both shapes.
    * **`--session-id <uuid>` (not `--session <path|id>`) is the resume
      flag to use.** 0.80.3 added `--session-id <id>` ("use exact project
      session id, creating it if missing") alongside the pre-existing
      `--session <path|id>` (which 404s — "No session found matching …" —
      if the id isn't already on disk in that `--session-dir`). Live-verified
      round-trip: spawn with `--session-id <uuid>` (fresh), later spawn again
      with the SAME `--session-id` + `--session-dir` → full prior context
      recalled. This adapter always passes `--session-id` when resuming,
      never `--session`.
    * **Everything else in §12.2 matched 0.80.3 exactly**: framing (strict
      JSONL, no `"jsonrpc"` field, commands optionally carry `id`, responses
      echo it), `{"type":"prompt","message":…}` / `{"type":"abort"}` framing,
      the `message_end`/`tool_execution_end`/`agent_end` event vocabulary,
      built-in tool names (`bash`/`read`/`write`/`edit`/`grep`/`find`/`ls`),
      the `extension_ui_request`/`extension_ui_response` sub-protocol shape,
      and `--append-system-prompt`. `agent_end.messages` additionally carries
      a harmless `willRetry` field and per-message `usage` gained a
      `cacheWrite1h` field — both ignored here.

  ## "pi backend groundwork" slice (extension-UI reply loop, orca.ts, session stats)

  Three additions on top of the Phase 4 adapter above, all still pi-only:

    * **Extension-UI reply loop.** `handle_peer_request/2` stashes a
      mid-turn `select`/`confirm`/`input`/`editor` dialog request
      (`extension_ui_request`) as a NEW `pi_ui_request` event (spec §3.3 —
      a custom type, same posture as the pre-existing `cli_error` type,
      rather than force-fitting Claude's AskUserQuestion tool_use/tool_result
      shape onto a fundamentally different wire mechanism) and tracks the
      pending request (`id` + `method` only) in `backend_state`. The answer
      travels back through `SessionRunner.answer_ui_request/3` (allowed
      mid-turn — the dialog blocks the CURRENT turn) →
      `Backend.encode_ui_response/4` → `encode_ui_response/3` below, which
      validates the id against the SAME pending-request bookkeeping and
      writes `extension_ui_response` directly to the port. Keyed purely on
      `id` — never coupled to "a tool_use is in flight" — so a FUTURE
      extension (e.g. plan-mode, popping a dialog after `agent_end` with no
      tool call at all) flows through the identical loop with no new runner
      code.
    * **`priv/pi/orca.ts`** — loaded via `-e <path>` in `spawn_spec/2`
      (`Application.app_dir/2`-resolved, so it also works from an OTP
      release). Registers a `question` tool mirroring Claude's
      AskUserQuestion as closely as pi's RPC dialog primitives allow:
      `ctx.ui.select` for multiple-choice, `ctx.ui.input` for free-form
      (pi's `ctx.ui.custom()` returns `undefined` in RPC mode, so it's
      unusable here), both with a 10-minute dialog timeout so an unanswered
      question auto-resolves instead of hanging the turn — pi's own timeout
      machinery handles that (docs/rpc.md), not Elixir-side bookkeeping.
    * **Session stats.** `get_session_stats` is queued (via
      `backend_state.pending_writes`) every time `agent_end` fires, and its
      response is normalized into a `pi_session_stats` event
      (`tokens`/`cost`/`context_usage`, verbatim field names from pi's
      response). Surfaced through a NEW `Capabilities.session_stats` flag
      (`false` by default, `true` here) — deliberately NOT reusing `usage`,
      which gates the Claude-API OAuth quota panel (`OrcaHub.Claude.Usage`),
      the wrong data source for a non-Claude backend.

  ## Design (mirrors `Backend.Codex`'s structure, simpler FSM)

  Unlike Codex (mandatory `initialize`→`initialized`→`thread/start` handshake
  before any turn can start, tracked via `backend_state.phase` +
  `pending_requests` + `pending_prompt`), pi needs none of that: every
  callback here is close to stateless. `backend_state` holds `:agent_start_ms`
  (wall-clock start of the in-flight agent run, stashed on `agent_start` and
  read back at `agent_end` to synthesize `duration_ms` — pi's own protocol
  has no elapsed-time field) plus, as of the "pi backend groundwork" slice
  below, `:pending_ui_request` (the currently-blocked extension-UI dialog, if
  any) and a one-shot `:pending_writes` entry queued at `agent_end` to
  request session stats.

  `normalize/2` treats `message_end{role:"assistant"}` as the sole source of
  assistant content (text/thinking/tool_use) and `tool_execution_end` as the
  sole source of tool results — `turn_end` and `agent_end.messages` embed the
  SAME content redundantly (useful for `agent_end`'s result-synthesis pass:
  scanning its own bundled `messages` for the last assistant's `stopReason`
  and summed `usage`/`cost`, without extra `backend_state` bookkeeping), so
  emitting from `turn_end`/`agent_end` too would duplicate every message in
  the feed. `message_update` (streaming deltas) and `tool_execution_start`/
  `tool_execution_update` are dropped per spec Q7 (v1 renders on
  completion only).
  """

  @behaviour OrcaHub.Backend

  require Logger

  alias OrcaHub.Backend.SharedPrompts

  # Extension UI methods that block waiting for an `extension_ui_response`
  # (spec's Extension UI Protocol) — everything else (`notify`, `setStatus`,
  # `setWidget`, `setTitle`, `set_editor_text`) is fire-and-forget and must
  # NOT get a reply.
  @dialog_ui_methods ~w(select confirm input editor)

  # ── Capabilities ─────────────────────────────────────────────────────

  @impl true
  def capabilities do
    %OrcaHub.Backend.Capabilities{
      streaming: true,
      interrupt: :protocol,
      # As of the orca-mcp bridge (spec §12.5): `priv/pi/orca-mcp.ts` connects
      # to the SAME `/mcp` endpoint Claude uses (URL baked via
      # `Backend.McpUrl.orca_url/1`, injected as `ORCA_MCP_URL`), discovers
      # its tools via `tools/list`, and registers each one with
      # `pi.registerTool` under the exact `mcp__orca__<tool>` name Claude
      # itself would use — so orca tools (send_message_to_session,
      # search_sessions, run_elixir in code-exec mode, …) are reachable from
      # a pi session, and MessageComponents renders their tool_use/tool_result
      # cards with ZERO pi-specific code (it already pattern-matches on the
      # `mcp__orca__*` name string). This flips the UI's orchestrator/
      # code_exec toggles and the MCP-servers modal back on for this backend
      # (spec §7's `mcp` gating list) — mirrors Claude's per-session flag
      # baking exactly (same evict_warm/cold-reopen mechanism in
      # session_runner.ex rebakes the URL, unconditionally, on every backend).
      mcp: true,
      resume: true,
      # No headless account-quota endpoint; per-turn cost/tokens still flow
      # into the synthesized `result` event from pi's own usage/cost fields
      # (better than Codex here — pi reports cost directly, no Anthropic-style
      # OAuth quota query needed for that part).
      usage: false,
      system_prompt: :flag,
      # No MCP-registration race to work around (no MCP support at all) and
      # no other startup handshake to hide behind a throwaway turn — the very
      # first `prompt` write is safe.
      warmup_turn: false,
      # No `~/.claude/plans` / EnterPlanMode/ExitPlanMode tool pair.
      plan_mode: false,
      # "pi backend groundwork" slice: the `question` tool in
      # priv/pi/orca.ts + the extension-UI reply loop
      # (handle_peer_request/2 / encode_ui_response/3) give pi the same
      # user-facing capability as Claude's built-in AskUserQuestion tool —
      # asking an interactive question mid-turn — just via a different wire
      # mechanism. The UI branches on this flag, not on which mechanism is
      # underneath (spec §12.3).
      ask_user_question: true,
      # pi reports live token/cost/context-window stats via `get_session_stats`
      # (spec §12.3) — surfaced through a pi-appropriate stats display, kept
      # deliberately separate from `usage` (the Claude-API quota panel gate).
      session_stats: true
    }
  end

  # ── Models ───────────────────────────────────────────────────────────
  # pi model ids are passthrough "provider/id" strings (live-verified: a
  # LIVE catalog: unlike Claude/Codex, pi can enumerate exactly the models
  # usable with the credentials on this node (`pi --list-models` prints an
  # aligned table of provider/model rows for AUTHENTICATED providers only).
  # `Backend.models_for/2` wraps this in the node-scoped TTL cache, so the
  # shell-out cost isn't paid per render. Any failure (pi missing, non-zero
  # exit, unparseable output) degrades to [] — the free-text model field
  # still accepts anything.

  @impl true
  def models do
    exe = Application.get_env(:orca_hub, :pi_executable) || System.find_executable("pi")

    with exe when is_binary(exe) <- exe,
         {out, 0} <- System.cmd(exe, ["--list-models"], stderr_to_stdout: true) do
      parse_model_list(out)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # Parses `pi --list-models` output: a header line
  # (`provider   model   context  max-out  thinking  images`) followed by
  # whitespace-aligned rows. The picker id is pi's combined "provider/model"
  # form (an embedded "/" resolves the provider — no separate --provider
  # flag needed); the label is the model's basename plus provider, since
  # Fireworks ids are long `accounts/fireworks/models/<name>` paths.
  @doc false
  def parse_model_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop_while(&String.starts_with?(&1, "provider"))
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [provider, model | _rest] when provider != "provider" ->
          [{"#{provider}/#{model}", "#{Path.basename(model)} (#{provider})"}]

        _ ->
          []
      end
    end)
  end

  # ── Spawn ────────────────────────────────────────────────────────────

  @impl true
  def spawn_spec(:streaming, ctx) do
    %{
      executable: pi_executable!(),
      args: ["--mode", "rpc"] ++ common_args(ctx),
      env: pi_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :ndjson
    }
  end

  # `pi -p --mode json` (non-interactive, process-and-exit) emits the exact
  # same event vocabulary as `--mode rpc` to stdout (live-verified) — the
  # :one_shot engine fallback other backends use `codex exec --json`/a `script`
  # PTY wrapper for. No PTY needed here either (plain pipe output is already
  # clean JSONL, live-verified). The prompt is a positional arg, same as
  # Claude/Codex's one-shot spawns.
  def spawn_spec(:one_shot, ctx) do
    prompt = Map.get(ctx, :prompt, "")

    %{
      executable: pi_executable!(),
      args: ["-p", "--mode", "json"] ++ common_args(ctx) ++ [prompt],
      env: pi_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :ndjson
    }
  end

  # `:orca_hub, :pi_executable` is a test-only seam (drives a real
  # SessionRunner against `test/support/fixtures/pi_stub_rpc.py` instead of a
  # real `pi` install — see OrcaHub.Backend.Pi.PiStubIntegrationTest) — unset
  # in dev/prod, so this falls through to the normal PATH lookup.
  @impl true
  def installed? do
    (Application.get_env(:orca_hub, :pi_executable) || System.find_executable("pi")) != nil
  end

  defp pi_executable! do
    Application.get_env(:orca_hub, :pi_executable) ||
      System.find_executable("pi") ||
      raise "pi executable not found in PATH (install: npm install -g @earendil-works/pi-coding-agent)"
  end

  # ORCA_MCP_URL (spec §12.5): the SAME `/mcp` URL Claude bakes into its
  # inline `--mcp-config` (`Backend.McpUrl.orca_url/1` — one shared builder,
  # so the two backends can never bake different orca_session_id/
  # orchestrator/code_exec query params). `priv/pi/orca-mcp.ts` reads this at
  # `session_start` to discover + register orca's MCP tools; the env var is
  # simply absent for a cold `pi_env/1` call made before a session context
  # exists (there is none — `pi_env/1` always has a real ctx), so the
  # extension's "degrade silently if unset" path only ever fires if URL
  # construction itself fails, not from a missing var in practice.
  defp pi_env(ctx) do
    OrcaHub.Env.sanitized_env([
      {~c"ORCA_MCP_URL", String.to_charlist(OrcaHub.Backend.McpUrl.orca_url(ctx))}
    ])
  end

  # Flags shared by :streaming and :one_shot spawns.
  defp common_args(ctx) do
    []
    |> maybe_add_model_arg(ctx[:model])
    |> Kernel.++(["--session-dir", pi_session_dir(ctx)])
    |> maybe_add_session_id_arg(ctx[:claude_session_id])
    |> Kernel.++(["--append-system-prompt", system_prompt(ctx)])
    |> Kernel.++(["-e", orca_extension_path()])
    |> Kernel.++(["-e", orca_mcp_extension_path()])
  end

  # priv/pi/orca.ts — registers the `question` tool (spec §12.3). Resolved via
  # Application.app_dir/2 (not a literal repo-relative path) so this keeps
  # working from an OTP release, where `priv/` is copied alongside the app
  # rather than living at the checkout path — `priv` files ship in releases
  # by default, no extra release config needed.
  defp orca_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca.ts")

  # priv/pi/orca-mcp.ts — bridges the orca `/mcp` endpoint's tools onto
  # dynamically-`pi.registerTool`'d tools (spec §12.5). `pi -e` accepts
  # multiple `--extension`/`-e` flags (verified: `pi --help` documents "can
  # be used multiple times"), so this loads alongside `orca.ts` rather than
  # replacing it.
  defp orca_mcp_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca-mcp.ts")

  defp maybe_add_model_arg(args, model) do
    case pi_model(model) do
      nil -> args
      m -> args ++ ["--model", m]
    end
  end

  defp maybe_add_session_id_arg(args, sid) when is_binary(sid) and sid != "" do
    args ++ ["--session-id", sid]
  end

  defp maybe_add_session_id_arg(args, _sid), do: args

  # pi model handling (mirrors Codex's omit-if-foreign guard, spec step 3):
  # passthrough string; omit when empty or a Claude model id, letting pi fall
  # back to its own default provider/model.
  defp pi_model(nil), do: nil
  defp pi_model(""), do: nil

  defp pi_model(model) do
    if String.starts_with?(model, "claude"), do: nil, else: model
  end

  # `--session-dir` is pi's per-session isolation lever (spec §12.2), pointed
  # at a directory keyed by OrcaHub session id — deterministic, computed
  # identically in spawn_spec/2 and prepare_session/1 (mirrors Codex's
  # CODEX_HOME reasoning, spec §6.3(2)/§10 Q5), so concurrent sessions in the
  # same project directory never collide and cleanup_session/1 only ever
  # removes ITS OWN session's storage, never a sibling's.
  defp pi_session_dir(ctx) do
    Path.join([ctx.directory, ".pi_sessions", to_string(ctx.session_id)])
  end

  # ── Open-time (streaming only) ────────────────────────────────────────
  # No handshake to perform (live-verified: pi accepts a `prompt` as the very
  # first stdin write) — this write exists purely to LEARN the session id via
  # its response (`normalize/2`'s `response{command:"get_state"}` clause),
  # since streaming mode never announces one unprompted. Not a gate: the
  # runner writes the real user turn immediately after this, no FSM/stash.

  @impl true
  def on_open(ctx) do
    {Jason.encode!(%{"type" => "get_state"}) <> "\n", ctx}
  end

  # ── stdin framing (user turns) ────────────────────────────────────────

  @impl true
  def encode_user_turn(prompt, ctx) do
    {Jason.encode!(%{"type" => "prompt", "message" => prompt}) <> "\n", ctx}
  end

  @impl true
  def encode_interrupt(_req_id, %{engine: :one_shot}), do: :signal
  def encode_interrupt(_req_id, _ctx), do: Jason.encode!(%{"type" => "abort"}) <> "\n"

  # ── Normalization (native pi event -> Claude-shaped events) ──────────

  # One-shot `-p --mode json`'s unprompted session-header line (live-verified
  # 0.80.3): first stdout line of every one-shot run.
  @impl true
  def normalize(%{"type" => "session", "id" => sid}, ctx) when is_binary(sid) do
    {[system_init_event(sid)], ctx}
  end

  # Streaming's session id source: the response to on_open/1's get_state.
  def normalize(
        %{"type" => "response", "command" => "get_state", "success" => true, "data" => data},
        ctx
      )
      when is_map(data) do
    case data["sessionId"] do
      sid when is_binary(sid) -> {[system_init_event(sid)], ctx}
      _ -> {[], ctx}
    end
  end

  # Defensive: a rejected prompt (e.g. `success:false` because a prior turn
  # was still streaming and we forgot `streamingBehavior`) would otherwise
  # leave the runner waiting forever for a `result` event that never comes —
  # surface it as an error result instead of hanging.
  def normalize(%{"type" => "response", "command" => "prompt", "success" => false} = resp, ctx) do
    message = resp["error"] || "pi rejected the prompt"
    {[%{"type" => "result", "is_error" => true, "result" => message}], ctx}
  end

  # get_session_stats reply (spec §12.3) — queued by the agent_end clause
  # below via pending_writes, consumed here into a normalized stats event.
  # `data` carries tokens{input,output,cacheRead,cacheWrite,total}, cost
  # (USD), and contextUsage{tokens,contextWindow,percent} verbatim per
  # docs/rpc.md — passed through with snake_case-ish key renaming only where
  # it avoids exposing pi's camelCase straight into the UI layer.
  def normalize(
        %{
          "type" => "response",
          "command" => "get_session_stats",
          "success" => true,
          "data" => data
        },
        ctx
      )
      when is_map(data) do
    {[session_stats_event(data)], ctx}
  end

  # Every other command response (abort ack, a get_state failure, a failed
  # get_session_stats, …) — no feed event.
  def normalize(%{"type" => "response"}, ctx), do: {[], ctx}

  def normalize(%{"type" => "agent_start"}, ctx) do
    bs = Map.put(ctx.backend_state, :agent_start_ms, System.monotonic_time(:millisecond))
    {[], %{ctx | backend_state: bs}}
  end

  def normalize(
        %{"type" => "message_end", "message" => %{"role" => "assistant", "content" => content}},
        ctx
      )
      when is_list(content) and content != [] do
    blocks = content |> Enum.map(&map_content_block/1) |> Enum.reject(&is_nil/1)
    events = if blocks == [], do: [], else: [assistant_event(blocks)]
    {events, ctx}
  end

  # Aborted-with-empty-content assistant messages, user/toolResult message_end
  # echoes, etc. — dropped (assistant content is emitted exactly once above;
  # tool results come from tool_execution_end below).
  def normalize(%{"type" => "message_end"}, ctx), do: {[], ctx}

  def normalize(%{"type" => "tool_execution_end", "toolCallId" => id} = ev, ctx)
      when is_binary(id) do
    content = get_in(ev, ["result", "content"]) || []
    is_error = ev["isError"] == true

    # Defensive: if a dialog request's own `timeout` (spec §12.3 — set by
    # priv/pi/orca.ts) elapsed, pi auto-resolves it INTERNALLY (no
    # extension_ui_response round-trip, no wire signal at all) — the only
    # observable evidence is the tool that was blocked on it finishing. Clear
    # any stale pending_ui_request now so a later encode_ui_response/3 call
    # for that (already-moot) id correctly no-ops instead of writing a reply
    # pi has already stopped listening for.
    bs = Map.delete(ctx.backend_state, :pending_ui_request)
    {[tool_result_event(id, content, is_error)], %{ctx | backend_state: bs}}
  end

  def normalize(%{"type" => "agent_end", "messages" => messages}, ctx) when is_list(messages) do
    event = agent_end_result(messages, ctx)

    # Spec §12.3: after every completed turn, ask pi for token/cost/context
    # stats. normalize/2 has no direct iodata slot for this — queue it onto
    # backend_state.pending_writes (spec §3.2), flushed by the SAME
    # route_frame/2 pass that called us, right after this event is handled.
    bs =
      ctx.backend_state
      |> Map.delete(:agent_start_ms)
      |> Map.put(:pending_writes, [get_session_stats_command()])

    {[event], %{ctx | backend_state: bs}}
  end

  # Deltas and everything else (turn_start/turn_end, message_start,
  # message_update, tool_execution_start/update, queue_update, compaction_*,
  # auto_retry_*, extension_error, …) — drop rather than emit a foreign shape
  # (spec §3.3 invariant). turn_end/agent_end embed the same assistant/tool
  # content as message_end/tool_execution_end already emitted from, so
  # re-emitting here would duplicate the feed.
  def normalize(_frame, ctx), do: {[], ctx}

  defp system_init_event(sid),
    do: %{"type" => "system", "session_id" => sid, "subtype" => "init"}

  defp get_session_stats_command, do: Jason.encode!(%{"type" => "get_session_stats"}) <> "\n"

  # A custom (non-Claude-vocabulary) event type — same posture as the
  # pre-existing "cli_error" type (spec §3.3's "emit nothing rather than a
  # foreign shape" rule is about not misusing an EXISTING Claude type, not a
  # ban on genuinely new ones). Rendered by MessageComponents' pi_session_stats
  # case; gated in the UI by capabilities.session_stats.
  defp session_stats_event(data) do
    %{
      "type" => "pi_session_stats",
      "tokens" => data["tokens"],
      "cost" => data["cost"],
      "context_usage" => data["contextUsage"]
    }
  end

  defp assistant_event(blocks),
    do: %{"type" => "assistant", "message" => %{"content" => blocks}}

  defp tool_result_event(id, content, is_error) do
    %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "content" => content,
            "is_error" => is_error
          }
        ]
      }
    }
  end

  # ── AssistantMessage.content -> Claude content blocks (spec §12.2) ────

  defp map_content_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  defp map_content_block(%{"type" => "thinking", "thinking" => text}) when is_binary(text) do
    %{"type" => "thinking", "thinking" => text}
  end

  defp map_content_block(%{"type" => "toolCall", "id" => id, "name" => name} = tc)
       when is_binary(id) and is_binary(name) do
    {claude_name, input} = translate_tool(name, tc["arguments"] || %{})
    %{"type" => "tool_use", "id" => id, "name" => claude_name, "input" => input}
  end

  # Unrecognized content block shape — drop rather than emit garbage.
  defp map_content_block(_other), do: nil

  # ── Built-in tool name/argument translation ────────────────────────────
  # pi's own tool ids -> the closest Claude tool name MessageComponents
  # already renders specially, with argument keys translated to match (pi's
  # read/write/edit schemas use "path", Claude's use "file_path"; pi's edit
  # tool supports N replacements via an "edits":[{oldText,newText}] array,
  # Claude's Edit is a single old_string/new_string pair — for v1 multiple
  # edits are folded into one diff block, separator-joined). Tools with no
  # Claude analogue (grep/find/ls, any extension-provided tool) pass through
  # unchanged: MessageComponents' generic tool_icon/summary/detail fallback
  # (wrench icon, empty summary, raw JSON detail) renders any unknown name
  # without crashing (spec §3.3) — verified by reading
  # lib/orca_hub_web/components/message_components.ex's catch-all clauses.

  defp translate_tool("bash", args), do: {"Bash", args}
  defp translate_tool("read", args), do: {"Read", path_input(args)}
  defp translate_tool("write", args), do: {"Write", path_input(args)}
  defp translate_tool("edit", args), do: {"Edit", edit_input(args)}
  defp translate_tool(name, args), do: {name, args}

  defp path_input(args) do
    case args["path"] do
      nil -> args
      path -> Map.put(args, "file_path", path)
    end
  end

  defp edit_input(%{"edits" => edits} = args) when is_list(edits) do
    old = edits |> Enum.map(&(&1["oldText"] || "")) |> Enum.join("\n---\n")
    new = edits |> Enum.map(&(&1["newText"] || "")) |> Enum.join("\n---\n")

    args
    |> path_input()
    |> Map.put("old_string", old)
    |> Map.put("new_string", new)
  end

  defp edit_input(args), do: path_input(args)

  # ── agent_end -> synthesized `result` ──────────────────────────────────
  # pi's protocol has no single "turn completed" summary event (unlike
  # Codex's turn/completed) — agent_end.messages is the full transcript of
  # this run, scanned here (NOT accumulated in backend_state across
  # message_end, avoiding double bookkeeping of the same data) for: the last
  # assistant message's stopReason (error detection — "aborted" is a user
  # stop, not an error, same posture as Codex's turn/completed{interrupted}),
  # its errorMessage, and the sum of every assistant message's usage/cost
  # (pi reports cost directly — unlike Codex, so total_cost_usd IS populated
  # here, read by the result card at message_components.ex ~468).

  defp agent_end_result(messages, ctx) do
    assistant_messages = Enum.filter(messages, &(&1["role"] == "assistant"))
    last_assistant = List.last(assistant_messages)
    is_error = last_assistant != nil and last_assistant["stopReason"] == "error"

    {total_cost, usage} = accumulate_usage(assistant_messages)

    %{"type" => "result", "is_error" => is_error}
    |> put_if_present("duration_ms", duration_ms(ctx))
    |> put_error_message(is_error, last_assistant)
    |> put_if_present("total_cost_usd", total_cost)
    |> put_if_present("usage", usage)
  end

  defp duration_ms(ctx) do
    case ctx.backend_state[:agent_start_ms] do
      nil -> nil
      start_ms -> System.monotonic_time(:millisecond) - start_ms
    end
  end

  defp put_error_message(map, true, %{"errorMessage" => msg}) when is_binary(msg),
    do: Map.put(map, "result", msg)

  defp put_error_message(map, _is_error, _last_assistant), do: map

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # Missing-field tolerance (spec §3.3): no assistant messages at all (should
  # be structurally impossible for agent_end, but stay nil-tolerant) -> omit
  # both total_cost_usd and usage rather than synthesize zeros.
  defp accumulate_usage([]), do: {nil, nil}

  defp accumulate_usage(assistant_messages) do
    totals =
      Enum.reduce(assistant_messages, %{input: 0, output: 0, cache_read: 0, cost: 0.0}, fn msg,
                                                                                           acc ->
        usage = msg["usage"] || %{}
        cost = usage["cost"] || %{}

        %{
          input: acc.input + (usage["input"] || 0),
          output: acc.output + (usage["output"] || 0),
          cache_read: acc.cache_read + (usage["cacheRead"] || 0),
          cost: acc.cost + (cost["total"] || 0.0)
        }
      end)

    usage_shape = %{
      "input_tokens" => totals.input,
      "output_tokens" => totals.output,
      "cache_read_input_tokens" => totals.cache_read
    }

    {totals.cost, usage_shape}
  end

  # ── Peer requests (extension UI protocol) ──────────────────────────────
  # "pi backend groundwork" slice, spec §12.3. Dialog methods
  # (select/confirm/input/editor) — e.g. our own `question` tool
  # (priv/pi/orca.ts) calling `ctx.ui.select`/`ctx.ui.input`, or a FUTURE
  # extension (plan-mode) calling one with no tool_use in flight at all —
  # block pi waiting for an `extension_ui_response`. We do NOT reply here:
  # this is the mid-turn reply-loop's request half. The request is stashed
  # in backend_state (keyed purely on `id`, per spec — never coupled to "a
  # tool_use is in flight") so a LATER `encode_ui_response/3` call (driven by
  # the user answering in the UI) can validate + write the actual reply.
  # Normalized as a NEW event type (spec's "small new component" option,
  # §3.3) rather than force-fit into Claude's AskUserQuestion tool_use/
  # tool_result shape: pi's reply travels back over the wire as a direct
  # `extension_ui_response` port write, not a plain chat turn like Claude's
  # AskUserQuestion answer — conflating the two answer mechanisms under one
  # message shape would make the LiveView's answer path ambiguous about
  # which write path to use. `SessionLive.Show` renders this event via a
  # dedicated modal/card, independent of the AskUserQuestion wizard.
  #
  # Fire-and-forget methods (notify/setStatus/setWidget/setTitle/
  # set_editor_text) expect NO reply — sending one would be protocol noise.
  # `notify` is surfaced as a passive `system`/`pi_notify` event so the user
  # sees it in the feed; the rest (TUI chrome concepts with no OrcaHub
  # analogue) are dropped.

  @impl true
  def handle_peer_request(%{"id" => id, "method" => method} = req, ctx)
      when method in @dialog_ui_methods do
    bs = Map.put(ctx.backend_state, :pending_ui_request, %{id: id, method: method})
    {"", [ui_request_event(req)], %{ctx | backend_state: bs}}
  end

  def handle_peer_request(%{"method" => "notify"} = req, ctx) do
    event = %{
      "type" => "system",
      "subtype" => "pi_notify",
      "message" => req["message"],
      "notify_type" => req["notifyType"] || "info"
    }

    {"", [event], ctx}
  end

  def handle_peer_request(%{"method" => _fire_and_forget}, ctx), do: {"", [], ctx}

  defp ui_request_event(req) do
    %{
      "type" => "pi_ui_request",
      "id" => req["id"],
      "method" => req["method"],
      "title" => req["title"],
      "message" => req["message"],
      "options" => req["options"],
      "placeholder" => req["placeholder"],
      "prefill" => req["prefill"]
    }
  end

  # ── Extension-UI reply loop: the answer half ────────────────────────────
  # Called by SessionRunner.answer_ui_request/3 (a mid-turn-allowed GenStatem
  # call — the dialog blocks the CURRENT turn, so the runner must be in
  # :running when this fires) via the Backend.encode_ui_response/4
  # dispatcher. Validates `request_id` against the SAME pending request
  # `handle_peer_request/2` stashed above; an unknown or already-answered id
  # (double submit, stale reload, a response for a request this backend_state
  # was reset for — e.g. after a cold reopen) is a no-op rather than a wire
  # write, per spec.
  @impl true
  def encode_ui_response(request_id, payload, ctx) do
    case ctx.backend_state[:pending_ui_request] do
      %{id: ^request_id} ->
        bs = Map.delete(ctx.backend_state, :pending_ui_request)
        body = Map.merge(%{"type" => "extension_ui_response", "id" => request_id}, payload)
        {:ok, Jason.encode!(body) <> "\n", %{ctx | backend_state: bs}}

      _ ->
        :noop
    end
  end

  # ── Session id extraction ───────────────────────────────────────────────

  @impl true
  def session_id(%{"type" => "system", "session_id" => sid}) when is_binary(sid), do: sid
  def session_id(_event), do: nil

  # ── Session lifecycle (--session-dir storage) ───────────────────────────
  # No auth copying needed (unlike Codex's per-session CODEX_HOME hiding
  # ~/.codex/auth.json): pi reads ~/.pi/agent/auth.json straight from HOME,
  # which the spawned child inherits unchanged (OrcaHub.Env.sanitized_env/0
  # only unsets RELEASE_* vars and cleans PATH — HOME passes through);
  # live-verified real Fireworks-provider turns succeeded with no HOME/auth
  # handling in this adapter at all.

  @impl true
  def prepare_session(ctx) do
    File.mkdir_p!(pi_session_dir(ctx))
    :ok
  rescue
    e ->
      Logger.error("[Backend.Pi] prepare_session failed: #{Exception.message(e)}")
      :ok
  end

  @impl true
  def cleanup_session(ctx) do
    File.rm_rf(pi_session_dir(ctx))
    :ok
  rescue
    _ -> :ok
  end

  # ── System prompt (:flag — --append-system-prompt) ─────────────────────
  # Reuses the non-Claude-specific SharedPrompts fragments like Codex does.
  # As of the orca-mcp bridge (spec §12.5, capabilities.mcp == true), the
  # MCP-dependent fragments are no longer inapplicable — `orca-mcp.ts`
  # registers orca's tools under the exact same `mcp__orca__<tool>` names
  # Claude uses, so `SharedPrompts.orchestrator_prompt/2`'s
  # `mcp__orca__start_session`-shaped guidance (moved out of `Backend.Claude`
  # into `SharedPrompts` for exactly this reuse) and the code-exec prompt are
  # both included here now, mirroring `Backend.Claude.system_prompt/1`
  # closely (this backend still has no AskUserQuestion-fallback text or
  # sibling-session prompt — out of scope for the MCP bridge itself).

  @impl true
  def system_prompt(ctx) do
    [
      "Your OrcaHub session ID is #{ctx.session_id}.",
      SharedPrompts.orchestrator_prompt(ctx.orchestrator, ctx.session_id),
      SharedPrompts.code_exec_prompt(
        OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))
      ),
      SharedPrompts.commit_trailer_prompt(ctx.session_id),
      SharedPrompts.context_files_prompt(ctx.directory)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
