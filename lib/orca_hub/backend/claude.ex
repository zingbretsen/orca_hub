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
      warmup_turn: true
    }
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
        orchestrator_system_prompt(ctx.orchestrator, ctx.session_id),
        code_exec_system_prompt(OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))),
        if(!ctx.orchestrator, do: commit_trailer_prompt(ctx.session_id)),
        if(!ctx.orchestrator, do: ask_user_question_prompt()),
        sibling_sessions_prompt(ctx.orchestrator),
        context_files_prompt(ctx.directory)
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

  # Teaches a code-exec session its collapsed tool surface. Only added when the
  # feature is enabled for the session (and not killed node-wide).
  defp code_exec_system_prompt(false), do: nil

  defp code_exec_system_prompt(true) do
    """
    # Code Execution Mode

    Your MCP tool list is intentionally small: `run_elixir`, `search_tools`, and \
    `read_tool`. Every other OrcaHub and upstream tool is reachable from inside \
    `run_elixir` as a named `Tools.*` function — call several tools and stitch \
    their results together with the Elixir standard library in ONE snippet \
    instead of many separate tool calls.

    - **Discover tools** with `search_tools`/`read_tool`, or from inside code \
      with `Tools.search("query")`, `Tools.list()`, and `Tools.schema("name")`. \
      `Tools.search/1` and `Tools.list/0` return `{name, description}` TUPLES — \
      match the tuple (`Enum.map(fn {name, _} -> name end)`), do NOT index with \
      `["name"]`. `Tools.schema/1` returns a map (or nil). Only tool \
      *invocations* (below) auto-unwrap to maps/lists.
    - **Call a tool** as `Tools.<raw_mcp_name>(args)`, e.g. \
      `Tools.open_file(%{"file_path" => "lib/foo.ex"})` or \
      `Tools.github__get_issue(%{"number" => 7})`. Named functions \
      **auto-unwrap** the result (text → string; JSON → decoded map/list) and \
      **raise `Tools.Error`** if the tool fails — so they compose with `|>` and \
      `Enum`:

          Tools.github__list_issues(%{"repo" => "o/r"})
          |> Enum.filter(& &1["state"] == "open")
          |> Enum.map(& &1["title"])

    - For explicit error handling use `Tools.try_call("name", args)` which \
      returns `{:ok, value} | {:error, reason}`; for the faithful raw MCP \
      envelope use `Tools.call("name", args)`.
    - The value of the last expression (and any stdout) is returned to you. \
      Keep return values slim — filter/project before returning. Pure stdlib is \
      available; OrcaHub internals, File, and System are blocked.
    """
    |> String.trim()
  end

  defp orchestrator_system_prompt(false, _session_id), do: nil
  defp orchestrator_system_prompt(nil, _session_id), do: nil

  defp orchestrator_system_prompt(true, session_id) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase (Read, Glob, Grep) and web access (WebFetch, WebSearch) for research. You have Write/Edit access, but you must use it **only** to maintain your own file-based memory under a `.claude` directory (e.g. the project-local `./.claude/` or your home `~/.claude/projects/<slug>/memory/`). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    **Important:** The OrcaHub MCP tools must be called by their full namespaced name — the MCP prefix followed by the tool name, e.g. `mcp__orca__start_session` (not just `start_session`). The same applies to every tool below (`mcp__orca__send_message_to_session`, `mcp__orca__schedule_heartbeat`, `mcp__orca__search_sessions`, `mcp__orca__archive_session`, `mcp__orca__cancel_heartbeat`, etc.).

    1. **Delegate all implementation work** to other sessions using:
       - `mcp__orca__start_session` — spawn a new worker session with a detailed prompt
       - `mcp__orca__send_message_to_session` — direct an existing session

    2. **Request callbacks** — When delegating work, explicitly ask the worker session to message you back when done:
       > "When you have completed this task, use `mcp__orca__send_message_to_session` to notify session #{session_id} with a summary of what you did."

    3. **Set up monitoring** — After spawning workers, use `mcp__orca__schedule_heartbeat` to wake yourself up periodically (e.g., every 2-5 minutes) to check on progress:
       > "Check on worker sessions. Use `mcp__orca__search_sessions` to see their status. If any are idle/error, review their work. If all work is complete, cancel the heartbeat."

    4. **Check in proactively** — If you don't hear back from a worker session within a reasonable time, send it a message asking for a status update.

    5. **Archive completed children** — When a worker session has finished its task, use `mcp__orca__archive_session` to archive it. This keeps the session list tidy. If you need to continue the conversation later, just send a message to the archived session — it will be automatically unarchived.

    6. **Cancel monitoring** — When all delegated work is complete, use `mcp__orca__cancel_heartbeat` to stop monitoring.

    ## Example Flow

    1. Analyze the task and break it into subtasks
    2. Spawn worker sessions for each subtask, requesting they message back when done
    3. Set a heartbeat to check on progress
    4. When workers report back or heartbeat fires, check status
    5. If issues arise, provide guidance or spawn additional workers
    6. As each worker finishes, archive its session to keep the list clean
    7. When all work is complete, cancel heartbeat and summarize results

    Remember: You orchestrate, you don't implement. Apart from writing to your own `.claude` memory, if you find yourself wanting to edit a file or run a command, spawn a worker session instead.
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

  defp commit_trailer_prompt(session_id) do
    """
    When making git commits, ALWAYS append this trailer to the commit message:

    OrcaHub-Session: #{session_id}

    This links the commit to your OrcaHub session. Add it as a git trailer \
    (blank line after the commit body, then the trailer line). \
    Never omit this trailer.\
    """
    |> String.trim()
  end

  defp context_files_prompt(directory) do
    context_dir = Path.join(directory, ".context")

    if File.dir?(context_dir) do
      context_dir
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) in ~w(.md .mmd)))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        content = File.read!(Path.join(context_dir, filename))
        "## #{Path.rootname(filename)}\n\n#{content}"
      end)
      |> case do
        [] -> nil
        parts -> "# Project Context\n\n#{Enum.join(parts, "\n\n")}"
      end
    else
      nil
    end
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
    port =
      case OrcaHubWeb.Endpoint.config(:http) do
        config when is_list(config) -> Keyword.get(config, :port, 4000)
        _ -> 4000
      end

    # Honor the env kill switch at bake time so a disabled node never advertises
    # code-exec mode (and a stale URL can't re-enable it).
    code_exec = OrcaHub.MCP.CodeExec.enabled?(ctx.code_exec)

    Logger.info(
      "[MCP] mcp_config: baking orca_session_id=#{inspect(ctx.session_id)} " <>
        "orchestrator=#{ctx.orchestrator == true} code_exec=#{code_exec} " <>
        "into /mcp URL at port-open time"
    )

    orca_server = %{
      "type" => "http",
      "url" =>
        "http://localhost:#{port}/mcp?orca_session_id=#{ctx.session_id}" <>
          "&orchestrator=#{ctx.orchestrator == true}" <>
          "&code_exec=#{code_exec}"
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
