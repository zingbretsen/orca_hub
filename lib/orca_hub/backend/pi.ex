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

  ## Design (mirrors `Backend.Codex`'s structure, simpler FSM)

  Unlike Codex (mandatory `initialize`→`initialized`→`thread/start` handshake
  before any turn can start, tracked via `backend_state.phase` +
  `pending_requests` + `pending_prompt`), pi needs none of that: every
  callback here is close to stateless. `backend_state` only ever holds
  `:agent_start_ms` (wall-clock start of the in-flight agent run, stashed on
  `agent_start` and read back at `agent_end` to synthesize `duration_ms` —
  pi's own protocol has no elapsed-time field). No `pending_writes` are ever
  queued (nothing here reacts to a response by writing more commands).

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
      # No MCP support by design (spec §12.2) — orca tools (send_message_to_
      # session, search_sessions, …) are unreachable from a pi session until
      # a pi TypeScript extension bridges them. UI hides the
      # orchestrator/code_exec toggles and the MCP-servers modal for this
      # backend (spec §7's `mcp: false` gating list).
      mcp: false,
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
      # No built-in AskUserQuestion tool.
      ask_user_question: false
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
      env: pi_env(),
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
      env: pi_env(),
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

  defp pi_env, do: OrcaHub.Env.sanitized_env()

  # Flags shared by :streaming and :one_shot spawns.
  defp common_args(ctx) do
    []
    |> maybe_add_model_arg(ctx[:model])
    |> Kernel.++(["--session-dir", pi_session_dir(ctx)])
    |> maybe_add_session_id_arg(ctx[:claude_session_id])
    |> Kernel.++(["--append-system-prompt", system_prompt(ctx)])
  end

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

  # Every other command response (abort ack, a get_state failure, …) — no
  # feed event.
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
    {[tool_result_event(id, content, is_error)], ctx}
  end

  def normalize(%{"type" => "agent_end", "messages" => messages}, ctx) when is_list(messages) do
    event = agent_end_result(messages, ctx)
    bs = Map.delete(ctx.backend_state, :agent_start_ms)
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
  # Shouldn't fire without extensions installed (v1 never loads any) — handled
  # defensively per spec. Dialog methods (select/confirm/input/editor) block
  # waiting for a response: reply `cancelled:true` so they never hang.
  # Fire-and-forget methods (notify/setStatus/setWidget/setTitle/
  # set_editor_text) expect NO reply — sending one would be protocol noise.

  @impl true
  def handle_peer_request(%{"id" => id, "method" => method}, ctx)
      when method in @dialog_ui_methods do
    reply =
      Jason.encode!(%{"type" => "extension_ui_response", "id" => id, "cancelled" => true}) <>
        "\n"

    {reply, [], ctx}
  end

  def handle_peer_request(%{"method" => _fire_and_forget}, ctx), do: {"", [], ctx}

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
  # Reuses the non-Claude-specific SharedPrompts fragments like Codex does,
  # but DROPS every MCP-dependent fragment (orchestrator coordination
  # guidance, code-exec mode, sibling-session discovery via orca MCP tools)
  # since capabilities.mcp == false makes all of them inapplicable — a pi
  # session has no orca MCP tools to reference. Keeps only the session id
  # line, the commit trailer prompt, and project .context/ files.

  @impl true
  def system_prompt(ctx) do
    [
      "Your OrcaHub session ID is #{ctx.session_id}.",
      SharedPrompts.commit_trailer_prompt(ctx.session_id),
      SharedPrompts.context_files_prompt(ctx.directory)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
