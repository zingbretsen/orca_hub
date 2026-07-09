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
      |> maybe_put(:tools, tools_for(ctx))
      |> maybe_put_mcp_config(ctx)

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
      |> maybe_put(:tools, tools_for(ctx))
      |> maybe_put_mcp_config(ctx)

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
  def installed?,
    do:
      (Application.get_env(:orca_hub, :claude_executable) || System.find_executable("claude")) !=
        nil

  # `:orca_hub, :claude_executable` is a test-only seam (mirrors
  # `:codex_executable`/`:pi_executable`) letting tests point spawn_spec/2 at
  # a stub script instead of a real, network-calling `claude` binary.
  defp claude_executable! do
    Application.get_env(:orca_hub, :claude_executable) ||
      System.find_executable("claude") ||
      raise "claude executable not found in PATH"
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
    # No MCP (no_tools API run mode) means no orca server at all, so every
    # fragment below that references an `mcp__orca__*` tool or the code-exec
    # `Tools.*` surface would describe tools the model doesn't have — skip
    # them rather than mislead the model into calling something nonexistent.
    mcp = mcp_enabled?(ctx)
    api_run = api_run_schema?(ctx)
    code_exec = mcp and OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))
    # An api_run connection's orca MCP server exposes ONLY submit_result (see
    # MCP.Server) — no orchestrator/code-exec/sibling-session tools exist on
    # it, so skip fragments that reference them even though mcp/1 is true.
    mcp_orchestration = mcp and not api_run

    parts =
      [
        "Your OrcaHub session ID is #{ctx.session_id}.",
        if(mcp_orchestration,
          do: SharedPrompts.orchestrator_prompt(ctx.orchestrator, ctx.session_id, code_exec)
        ),
        SharedPrompts.code_exec_prompt(code_exec),
        if(!ctx.orchestrator, do: SharedPrompts.commit_trailer_prompt(ctx.session_id)),
        if(!ctx.orchestrator, do: ask_user_question_prompt()),
        if(mcp_orchestration, do: sibling_sessions_prompt(ctx.orchestrator, code_exec)),
        if(api_run, do: submit_result_prompt()),
        SharedPrompts.context_files_prompt(ctx.directory)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  # Agent Runs API (docs/api.md): steer the model at the submit_result tool
  # instead of letting it think a plain final-turn response is the deliverable.
  defp submit_result_prompt do
    "When you have your final answer, call the submit_result tool — your plain response text is not the deliverable."
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
  # In code-exec mode, `search_sessions` only exists as a `Tools.*` function
  # callable from inside `run_elixir` — it is NOT a standalone `mcp__orca__*`
  # tool, so the flat-tool-name guidance above is wrong and must be swapped
  # out. `send_message_to_session` is the exception: it's promoted to a
  # standalone tool even in code-exec mode (see `MCP.CodeExec.MetaTools`).
  defp sibling_sessions_prompt(true, true) do
    "Other agent sessions may be active in this directory. Use `Tools.search_sessions(%{\"status\" => ...})` inside the `run_elixir` MCP tool to discover sibling sessions you may want to coordinate with — it is NOT a standalone MCP tool in this session."
  end

  defp sibling_sessions_prompt(true, _code_exec) do
    "Other agent sessions may be active in this directory. Use the `mcp__orca__search_sessions` MCP tool to discover sibling sessions you may want to coordinate with."
  end

  defp sibling_sessions_prompt(_orchestrator, true) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the standalone `send_message_to_session` MCP tool to send them messages."
  end

  defp sibling_sessions_prompt(_orchestrator, _code_exec) do
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
        "api_run=#{api_run_schema?(ctx)} " <>
        "into /mcp URL at port-open time"
    )

    orca_server = %{
      "type" => "http",
      "url" => OrcaHub.Backend.McpUrl.orca_url(ctx)
    }

    # Agent Runs API (docs/api.md): an api_run connection's orca server exposes
    # ONLY submit_result — project/session-scoped upstream servers are wired
    # DIRECTLY into --mcp-config as their own top-level entries (the Claude CLI
    # talks to them independently of orca's own tools/list), so they must be
    # omitted here too, not just filtered out of orca's tool list.
    scoped_servers = if api_run_schema?(ctx), do: %{}, else: scoped_mcp_servers(ctx)

    Jason.encode!(%{"mcpServers" => Map.merge(scoped_servers, %{"orca" => orca_server})})
  end

  defp scoped_mcp_servers(ctx) do
    project_servers =
      if ctx.project_id,
        do: db_call(ctx, :list_enabled_servers_for_project, [ctx.project_id]),
        else: []

    session_servers = db_call(ctx, :list_enabled_servers_for_session, [ctx.session_id])

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

  # A session-level `--tools` override (Agent Runs API "no filesystem tools"
  # mode, ctx.tools — see Sessions.Session) always wins over the
  # orchestrator-derived default when set, including the empty string
  # ("" = zero built-in tools).
  defp tools_for(ctx) do
    case Map.get(ctx, :tools) do
      nil -> orchestrator_tools(ctx.orchestrator)
      tools -> tools
    end
  end

  # "" is the same "no built-in tools" sentinel `tools_for/1` checks — MCP
  # tools (open_file, send_message_to_session, …) are just as much a
  # wander-into-files/other-sessions risk as built-in ones, so a no_tools API
  # run (docs/api.md) gets neither. EXCEPT when the run has a result_schema:
  # its only reachable orca tool is submit_result (see MCP.Server), which is
  # the run's sole result channel — MCP stays wired up even under tools == ""
  # so submit_result is still reachable. See the Backend.mcp_enabled?/2 doc.
  @impl true
  def mcp_enabled?(ctx), do: Map.get(ctx, :tools) != "" or api_run_schema?(ctx)

  defp api_run_schema?(ctx), do: Map.get(ctx, :api_run_schema?) == true

  defp maybe_put_mcp_config(opts, ctx) do
    if mcp_enabled?(ctx) do
      Keyword.put(opts, :mcp_config, mcp_config_json(ctx))
    else
      opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
