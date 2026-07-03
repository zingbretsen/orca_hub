defmodule OrcaHub.Backend.Claude do
  @moduledoc """
  `OrcaHub.Backend` implementation for the Claude Code CLI.

  This is a verbatim move of the logic that used to live directly in
  `OrcaHub.SessionRunner` (`open_port_streaming/1` ~917, `open_port/1` ~1022,
  `user_turn_json/1`, `control_interrupt_json/1`, `build_system_prompt/1`,
  `mcp_config/1`, `node_oauth_env/0`, and friends) — moved behind the
  `OrcaHub.Backend` behaviour with ZERO behavior change (Phase 0 of
  `backend_abstraction_spec.md`). `normalize/2` is identity; MCP is passed
  inline via `--mcp-config` so `prepare_session/1` and `cleanup_session/1` are
  no-ops.
  """

  @behaviour OrcaHub.Backend

  require Logger

  alias OrcaHub.Backend.SharedPrompts
  alias OrcaHub.Claude.Config
  alias OrcaHub.HubRPC

  # ── Capabilities ─────────────────────────────────────────────────────

  @impl true
  def capabilities do
    %OrcaHub.Backend.Capabilities{
      streaming: true,
      interrupt: :protocol,
      mcp: true,
      resume: true,
      usage: true,
      system_prompt: :flag,
      warmup_turn: true,
      plan_mode: true,
      ask_user_question: true
    }
  end

  # ── Models ───────────────────────────────────────────────────────────
  # Verbatim of the model ids previously hardcoded in show.html.heex (~204)
  # and index.html.heex (~293) — Phase 3 (spec §7) moves them behind the
  # backend so the picker can be scoped per-session.

  @impl true
  def models do
    [
      {"claude-opus-4-8", "Opus 4.8"},
      {"claude-sonnet-4-6", "Sonnet 4.6"},
      {"claude-haiku-4-5-20251001", "Haiku 4.5"}
    ]
  end

  # ── Spawn ────────────────────────────────────────────────────────────
  # Verbatim move of SessionRunner.open_port_streaming/1 and open_port/1
  # (pre-refactor). `ctx` is the runner's `data` map; `ctx.prompt` (set by
  # SessionRunner only for :one_shot) supplies the positional `-p` prompt.

  @impl true
  def spawn_spec(:streaming, ctx) do
    claude_path = claude_executable!()

    opts =
      [cwd: ctx.directory, input_format: "stream-json"]
      |> maybe_put(:session_id, ctx.claude_session_id)
      |> maybe_put(:model, ctx.model)
      |> maybe_put(:system_prompt, system_prompt(ctx))
      |> maybe_put(:tools, orchestrator_tools(ctx.orchestrator))
      |> Keyword.put(:mcp_config, mcp_config_json(ctx))

    {args, port_opts} = Config.build_args(nil, opts)

    %{
      executable: claude_path,
      args: args,
      env: OrcaHub.Env.sanitized_env(node_oauth_env()),
      port_opts: port_opts,
      framing: :ndjson
    }
  end

  def spawn_spec(:one_shot, ctx) do
    claude_path = claude_executable!()
    script_path = System.find_executable("script") || raise "script executable not found in PATH"

    opts =
      [cwd: ctx.directory]
      |> maybe_put(:session_id, ctx.claude_session_id)
      |> maybe_put(:model, ctx.model)
      |> maybe_put(:system_prompt, system_prompt(ctx))
      |> maybe_put(:tools, orchestrator_tools(ctx.orchestrator))
      |> Keyword.put(:mcp_config, mcp_config_json(ctx))

    {args, port_opts} = Config.build_args(Map.get(ctx, :prompt), opts)

    script_args =
      case :os.type() do
        {:unix, :darwin} ->
          ["-q", "/dev/null", claude_path | args]

        _ ->
          cmd = Enum.map_join([claude_path | args], " ", &Config.shell_escape/1)
          ["-qc", cmd, "/dev/null"]
      end

    %{
      executable: script_path,
      args: script_args,
      env: OrcaHub.Env.sanitized_env(node_oauth_env()),
      port_opts: port_opts,
      framing: :ndjson
    }
  end

  @impl true
  def installed?, do: System.find_executable("claude") != nil

  defp claude_executable! do
    System.find_executable("claude") || raise "claude executable not found in PATH"
  end

  # If this node has been logged into Claude Code via the web UI
  # ("Log in this node" → `claude setup-token`), inject the captured OAuth
  # token so spawned `claude` ports authenticate. Returns `[]` when no token
  # is stored, leaving nodes that use `credentials.json` untouched.
  defp node_oauth_env do
    node()
    |> Atom.to_string()
    |> HubRPC.get_node_token()
    |> OrcaHub.NodeCredentials.token_env()
  rescue
    # Token lookup must never block opening a session port. If the hub is
    # briefly unreachable, fall back to the node's own credentials.
    _ -> []
  end

  # ── stdin framing ────────────────────────────────────────────────────

  # No open-time handshake — Claude's stream-json protocol accepts a user
  # turn as the first write. Nothing to send when the port opens.
  @impl true
  def on_open(ctx), do: {"", ctx}

  @impl true
  def encode_user_turn(prompt, ctx) do
    {user_turn_json(prompt), ctx}
  end

  # NDJSON framing for a user turn over stdin.
  defp user_turn_json(prompt) do
    Jason.encode!(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => prompt}]}
    }) <> "\n"
  end

  @impl true
  def encode_interrupt(_req_id, %{engine: :one_shot}), do: :signal

  def encode_interrupt(req_id, _ctx) do
    Jason.encode!(%{
      "type" => "control_request",
      "request_id" => req_id,
      "request" => %{"subtype" => "interrupt"}
    }) <> "\n"
  end

  # ── Normalization ────────────────────────────────────────────────────

  @impl true
  def normalize(native_event, ctx), do: {[native_event], ctx}

  @impl true
  def handle_peer_request(request, ctx) do
    Logger.warning(
      "[Backend.Claude] handle_peer_request/2 called unexpectedly — Claude does not " <>
        "issue id+method peer requests: #{inspect(request)}"
    )

    {"", [], ctx}
  end

  @impl true
  def session_id(%{"type" => "system", "session_id" => sid}) when is_binary(sid), do: sid
  def session_id(_event), do: nil

  # ── Session lifecycle ────────────────────────────────────────────────
  # MCP is passed inline via --mcp-config (baked in spawn_spec/2), so there's
  # no per-session on-disk state to materialize/clean up.

  @impl true
  def prepare_session(_ctx), do: :ok

  @impl true
  def cleanup_session(_ctx), do: :ok

  # ── System prompt ────────────────────────────────────────────────────
  # Verbatim move of SessionRunner.build_system_prompt/1 (public, tested) and
  # its private helpers.

  @impl true
  def system_prompt(ctx) do
    parts =
      [
        "Your OrcaHub session ID is #{ctx.session_id}.",
        SharedPrompts.orchestrator_prompt(ctx.orchestrator, ctx.session_id),
        SharedPrompts.code_exec_prompt(
          OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))
        ),
        if(!ctx.orchestrator, do: SharedPrompts.commit_trailer_prompt(ctx.session_id)),
        if(!ctx.orchestrator, do: ask_user_question_prompt()),
        sibling_sessions_prompt(ctx.orchestrator),
        SharedPrompts.context_files_prompt(ctx.directory)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  # Only non-orchestrator sessions have the AskUserQuestion tool. Headless runs
  # auto-return a placeholder/denial tool result for it, and the model tends to
  # continue as if answered — so we explicitly instruct it to stop and wait.
  defp ask_user_question_prompt do
    """
    When you use the AskUserQuestion tool to ask the user something, the \
    environment will immediately return an automatic placeholder tool result \
    (it may look like an error or a denial such as "Answer questions?"). That \
    placeholder is NOT the user's answer — do not treat it as a response and do \
    not continue based on it. After calling AskUserQuestion, stop and end your \
    turn. The user's real answer will arrive as a separate follow-up message; \
    only act on the question once the user has actually responded.\
    """
    |> String.trim()
  end

  # Orchestrator sessions can use `search_sessions`; regular sessions cannot,
  # so point them at the `.agents/` directory to discover sibling session IDs.
  defp sibling_sessions_prompt(true) do
    "Other agent sessions may be active in this directory. Use the `mcp__orca__search_sessions` MCP tool to discover sibling sessions you may want to coordinate with."
  end

  defp sibling_sessions_prompt(_orchestrator) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the `mcp__orca__send_message_to_session` MCP tool to coordinate with them."
  end

  # ── MCP config (inline --mcp-config JSON) ────────────────────────────
  # Verbatim move of SessionRunner.mcp_config/1. Needs the same DB-node
  # routing as SessionRunner's private db_call/3 (a session's MCP servers may
  # be owned by a different node in multi-hub mode) — duplicated here rather
  # than shared, since it's a tiny, self-contained 6-line helper.

  defp db_call(%{db_node: db_node}, fun, args) when not is_nil(db_node) and db_node != node() do
    :erpc.call(db_node, HubRPC, fun, args, 10_000)
  end

  defp db_call(_ctx, fun, args) do
    apply(HubRPC, fun, args)
  end

  defp mcp_config_json(ctx) do
    Logger.info(
      "[MCP] mcp_config: baking orca_session_id=#{inspect(ctx.session_id)} " <>
        "orchestrator=#{ctx.orchestrator == true} " <>
        "code_exec=#{OrcaHub.MCP.CodeExec.enabled?(ctx.code_exec)} " <>
        "into /mcp URL at port-open time"
    )

    orca_server = %{
      "type" => "http",
      "url" => OrcaHub.Backend.McpUrl.orca_url(ctx)
    }

    project_servers =
      if ctx.project_id,
        do: db_call(ctx, :list_enabled_servers_for_project, [ctx.project_id]),
        else: []

    session_servers = db_call(ctx, :list_enabled_servers_for_session, [ctx.session_id])

    scoped_servers =
      (project_servers ++ session_servers)
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn server ->
        entry = %{"type" => "http", "url" => server.url}

        entry =
          if map_size(server.headers) > 0,
            do: Map.put(entry, "headers", server.headers),
            else: entry

        {server.name, entry}
      end)

    Jason.encode!(%{"mcpServers" => Map.merge(scoped_servers, %{"orca" => orca_server})})
  end

  # ── Small helpers ────────────────────────────────────────────────────

  # Orchestrator sessions get a restricted toolset: read-only file access plus
  # web, plus Write/Edit so they can persist their file-based memory under
  # `.claude`. Writes are NOT path-enforced (skip-permissions stays on); the
  # system prompt instructs orchestrators to confine their direct writes to
  # `.claude` and to delegate all other implementation work to worker
  # sessions.
  @orchestrator_tools "Read,Glob,Grep,WebFetch,WebSearch,Write,Edit"
  defp orchestrator_tools(true), do: @orchestrator_tools
  defp orchestrator_tools(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
