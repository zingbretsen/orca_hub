defmodule OrcaHub.Backend.ClaudeTest do
  @moduledoc """
  Conformance tests for `OrcaHub.Backend.Claude` — Phase 0 of
  `backend_abstraction_spec.md` §9: existing SessionRunner/streaming tests
  must pass unchanged, PLUS this module asserts the adapter reproduces
  byte-identical `spawn_spec/2` args/executable/port_opts, stdin framing, and
  identity normalization vs. the pre-refactor code (as read from `git show
  HEAD` of `session_runner.ex`/`claude/config.ex` at the time of the Phase 0
  commit).

  Expected values below are independently derived (transcribed literals, or
  calls to genuinely separate/already-tested units like
  `OrcaHub.Claude.Config.build_args/2`, `OrcaHub.Env`, `OrcaHub.MCP.CodeExec`)
  — never by calling `Backend.Claude` itself — so this test can't pass
  tautologically.
  """

  # async: true is fine — DataCase gives each test its own sandboxed
  # connection, and spawn_spec/2's DB reads (scoped MCP servers) use fresh
  # UUIDs per test so there's no shared state to race on.
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Backend.Claude, as: Backend
  alias OrcaHub.Claude.Config

  # ── ctx fixture ──────────────────────────────────────────────────────
  # Mirrors the fields SessionRunner's `data` map carries (see
  # backend_abstraction_spec.md §3.2's ctx list) that Backend.Claude reads.

  defp ctx(overrides \\ %{}) do
    # session_id is a binary_id (UUID) column in the DB (see
    # UpstreamServers.list_enabled_servers_for_session/1) — use a fresh UUID
    # per test so the scoped-MCP-server query is both valid and deterministic
    # (never matches any real row).
    base = %{
      session_id: Ecto.UUID.generate(),
      project_id: nil,
      claude_session_id: nil,
      directory: "/nonexistent-dir-#{System.unique_integer([:positive])}",
      model: nil,
      orchestrator: false,
      code_exec: false,
      db_node: nil,
      engine: :streaming
    }

    Map.merge(base, Map.new(overrides))
  end

  # ── Independent expected-value derivation ───────────────────────────

  defp expected_maybe_put(opts, _key, nil), do: opts
  defp expected_maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp expected_tools(true), do: "Read,Glob,Grep,WebFetch,WebSearch,Write,Edit"
  defp expected_tools(_), do: nil

  # Transcribed from SessionRunner.build_system_prompt/1 + its private
  # helpers (pre-refactor session_runner.ex ~1246-1418), NOT computed via
  # Backend.Claude.system_prompt/1.
  defp expected_system_prompt(ctx) do
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))

    parts =
      [
        "Your OrcaHub session ID is #{ctx.session_id}.",
        expected_orchestrator_prompt(ctx.orchestrator, ctx.session_id, code_exec),
        expected_code_exec_prompt(code_exec),
        if(!ctx.orchestrator, do: expected_commit_trailer_prompt(ctx.session_id)),
        if(!ctx.orchestrator, do: expected_worker_practices_prompt()),
        if(!ctx.orchestrator, do: expected_ask_user_question_prompt()),
        expected_sibling_sessions_prompt(ctx.orchestrator, code_exec),
        # context_files_prompt/1: nil for every ctx fixture here (directory
        # never has a `.context` subdir).
        nil
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n\n")
  end

  defp expected_ask_user_question_prompt do
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

  defp expected_worker_practices_prompt do
    """
    - Verify your changes with **targeted tests** for the files you touched; \
    the full suite runs later as the orchestrator's pre-deploy gate — don't \
    burn time running it per-task unless asked.
    - Read a file before Edit/Write even when the task prompt quotes its exact \
    current content; the guardrail requires it regardless.
    - If your task restarts the service/host hosting your own session \
    (deploys, systemctl restarts), send your report **before** triggering \
    the restart — your session may die with it and post-restart delivery \
    isn't guaranteed.
    - Tests failing for environmental/flaky reasons? Root-cause and fix the \
    flake rather than retrying until green — report what you found.
    """
    |> String.trim()
  end

  defp expected_code_exec_prompt(false), do: nil

  defp expected_code_exec_prompt(true) do
    """
    # Code Execution Mode

    Your MCP tool list is intentionally small: `run_elixir`, `search_tools`, \
    `send_message_to_session`, `get_session_tail`, `report_progress`, `file_feature_request`, `list_feature_requests`, `get_feature_request`, `append_feature_request_note`, and `close_feature_request`. Every other OrcaHub and upstream tool is \
    reachable from inside `run_elixir` as a named `Tools.*` function — call \
    several tools and stitch their results together with the Elixir standard \
    library in ONE snippet instead of many separate tool calls.

    - **Discover tools** with `search_tools`, or from inside code with \
      `Tools.search("query")`, `Tools.list()`, and `Tools.schema("name")` (a \
      tool's JSON input schema). `Tools.search/1` and `Tools.list/0` return \
      maps with "name"/"description" keys (search results also include "args" \
      — argument names, optional ones suffixed "?"). `Tools.schema/1` returns \
      a map (or nil). Only tool *invocations* (below) auto-unwrap to \
      maps/lists.
    - Before first using a deferred-schema tool (`Monitor`, `TaskCreate`, \
      `WebFetch`, `ScheduleWakeup`, standalone `send_message_to_session`, or \
      an early `mcp__orca__*` tool), load its real schema with ToolSearch/\
      `search_tools`; never guess argument names. `No such tool available` or \
      `InputValidationError` means its schema was not loaded yet, not that it \
      does not exist.
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
    - **These first-party tools are ALSO standalone top-level tools** — call \
      them directly, not as `Tools.*`: `send_message_to_session`, `get_session_tail`, `report_progress`, `file_feature_request`, `list_feature_requests`, `get_feature_request`, `append_feature_request_note`, `close_feature_request`. \
      Every OTHER inter-session coordination tool (`search_sessions`, \
      `start_session`, `schedule_heartbeat`, `archive_session`, \
      `cancel_heartbeat`, etc.) is a `Tools.*` function callable only from \
      inside `run_elixir` in this session — NOT a standalone MCP tool. \
      Discover them with orca's own `search_tools` / `Tools.search`, not the \
      CLI's built-in ToolSearch — that corpus only covers the CLI's own \
      deferred tools and cannot see these.
    - The value of the last expression (and any stdout) is returned to you. \
      Keep return values slim — filter/project before returning. Pure stdlib is \
      available; OrcaHub internals, File, and System are blocked.
    - **Variables persist across `run_elixir` calls** within this session, like \
      a REPL — fetch data once into a variable, then slice/reshape it in later \
      calls instead of re-fetching:

          sessions = Tools.search_sessions(%{"status" => "error"})
          # ...next call...
          Enum.map(sessions, & &1["title"])

      Pass `"reset": true` to clear your stored variables and start fresh.
    - **Call `report_progress(phase: ..., note: ...)` at phase boundaries** \
      (e.g. planning → implementing → validating → fixing-tests) — a \
      non-interrupting way for whoever spawned you to see you're making \
      progress without messaging you.
    """
    |> String.trim()
  end

  defp expected_orchestrator_prompt(false, _session_id, _code_exec), do: nil
  defp expected_orchestrator_prompt(nil, _session_id, _code_exec), do: nil

  defp expected_orchestrator_prompt(true, _session_id, true) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase (Read, Glob, Grep) and web access (WebFetch, WebSearch) for research. You have Write/Edit access, but you must use it **only** to maintain your own file-based memory under a `.claude` directory (e.g. the project-local `./.claude/` or your home `~/.claude/projects/<slug>/memory/`). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    **Important:** Your MCP tool list is collapsed to `run_elixir`, `search_tools`, `send_message_to_session`, `get_session_tail`, `report_progress`, `file_feature_request`, `list_feature_requests`, `get_feature_request`, `append_feature_request_note`, and `close_feature_request` (code execution mode). Those are standalone MCP tools — call them directly. Every OTHER coordination tool below is NOT standalone here; call it as `Tools.<name>(args)` from inside `run_elixir`, e.g. `Tools.start_session(%{...})` (not a bare `start_session` tool call). The same applies to `Tools.schedule_heartbeat`, `Tools.search_sessions`, `Tools.archive_session`, `Tools.cancel_heartbeat`, etc.

    1. **Delegate all implementation work** to other sessions using:
       - `Tools.start_session(...)` inside `run_elixir` — spawn a new worker session with a detailed prompt. Since you're an orchestrator, the worker is automatically linked as your child: when it goes idle or errors, you automatically get a `[Session lifecycle]` message — this is the PRIMARY way to learn a worker is done, you do not need to instruct it to call `send_message_to_session` back. Pass `notify_on_completion: false` if you genuinely want a fire-and-forget spawn with no callback.
       - `send_message_to_session(...)` — direct an existing session (standalone tool, not `Tools.*`)

    2. **Prefer letting the automatic notification tell you when a worker is done.** Only ask a worker to `send_message_to_session` you explicitly if you need something mid-task (a progress update, a specific artifact) beyond "it's done" — the completion callback itself is redundant with the automatic notification.

    3. **Heartbeats are a coarse fallback, not your primary signal.** Automatic `[Session lifecycle]` messages fire the moment a worker finishes, so you shouldn't need to poll. Still set one wide-interval `Tools.schedule_heartbeat(...)` safety net (e.g. every 10-15 minutes) in case a notification is ever missed or a worker hangs mid-turn (never goes idle/error). Pass `watch_children: true` (or `watch_session_ids`) — watch lists put per-worker status/activity digests directly in the wake-up message, often enough to skip a `search_sessions` call:
       > "Check on worker sessions. Use `Tools.search_sessions(...)` inside `run_elixir` to see their status. If any are idle/error, review their work. If all work is complete, cancel the heartbeat."

    4. **Check in proactively** — If a worker session seems stuck (no lifecycle notification and no heartbeat signal within a reasonable time), use `get_session_tail(...)` to peek at its progress without interrupting it, or message it directly.

    5. **Archive completed children** — When a worker session has finished its task, use `Tools.archive_session(...)` inside `run_elixir` to archive it. This keeps the session list tidy. If you need to continue the conversation later, just send a message to the archived session — it will be automatically unarchived.

    6. **Cancel monitoring** — When all delegated work is complete, use `Tools.cancel_heartbeat(...)` inside `run_elixir` to stop monitoring.

    ## Orchestration Practices (tl;dr)

    - Rely on lifecycle notifications plus `get_session_tail(...)` / activity metadata for progress; heartbeats are a coarse fallback — re-call `Tools.schedule_heartbeat(...)` at each stage change to keep its delivered message current (it updates in place, it doesn't stack).
    - `send_message_to_session(...)` to a running session is a graceful interrupt-and-queue, not a lost message — feel free to ping a quiet worker, but peek non-interruptively with `get_session_tail(...)` first.
    - Parallel workers on disjoint files are encouraged: tell siblings each other's session IDs and file ownership so they can negotiate shared files directly. Workers verify with targeted tests only; the full suite runs once as a pre-deploy gate. No worktrees.
    - Do not Read or Glob a different project's directory; delegate with `Tools.start_session(...)` using that project's `directory` instead.
    - Use exact model ids (e.g. `claude-sonnet-5`, not `sonnet-5`).
    - Archive finished children, and have workers report back with commit SHAs and test results.
    - Hit platform friction (missing tool, awkward workflow, confusing error)? Check the backlog with `list_feature_requests(...)` first — if it's already tracked, add what you found with `append_feature_request_note(...)` instead of filing a duplicate with `file_feature_request(...)`. Once a fix for a tracked request has shipped AND been verified, close it with `close_feature_request(...)` (pass a resolution note referencing the commit).
    - Scheduled heartbeats do NOT survive a restart of your own host (e.g. a deploy) — re-call `Tools.schedule_heartbeat(...)` as your first action after waking from one.
    - Pre-deploy gate pattern: run the full suite once at the pipeline tip via a dedicated worker with an explicit allow-list of known flakes; treat any NEW failure as fix-at-root, never expand the allow-list.

    ## Example Flow

    1. Analyze the task and break it into subtasks
    2. Spawn worker sessions for each subtask via `Tools.start_session(...)` — each is auto-linked to notify you on completion
    3. Set a wide-interval heartbeat as a fallback safety net
    4. React to `[Session lifecycle]` messages as workers finish (or the heartbeat, if one is ever missed)
    5. If issues arise, provide guidance or spawn additional workers
    6. As each worker finishes, archive its session to keep the list clean
    7. When all work is complete, cancel heartbeat and summarize results

    Remember: You orchestrate, you don't implement. Apart from writing to your own `.claude` memory, if you find yourself wanting to edit a file or run a command, spawn a worker session instead.
    """
    |> String.trim()
  end

  defp expected_orchestrator_prompt(true, _session_id, _code_exec) do
    """
    # Orchestrator Session

    You are an **orchestrator session**. Your role is to coordinate work across multiple worker sessions, NOT to do the work yourself.

    ## Your Capabilities

    You have read-only access to the codebase (Read, Glob, Grep) and web access (WebFetch, WebSearch) for research. You have Write/Edit access, but you must use it **only** to maintain your own file-based memory under a `.claude` directory (e.g. the project-local `./.claude/` or your home `~/.claude/projects/<slug>/memory/`). Do NOT edit project source files, run shell commands, or make any other changes directly — delegate all implementation work to worker sessions.

    ## How to Work

    **Important:** The OrcaHub MCP tools must be called by their full namespaced name — the MCP prefix followed by the tool name, e.g. `mcp__orca__start_session` (not just `start_session`). The same applies to every tool below (`mcp__orca__send_message_to_session`, `mcp__orca__schedule_heartbeat`, `mcp__orca__search_sessions`, `mcp__orca__archive_session`, `mcp__orca__cancel_heartbeat`, etc.).

    1. **Delegate all implementation work** to other sessions using:
       - `mcp__orca__start_session` — spawn a new worker session with a detailed prompt. Since you're an orchestrator, the worker is automatically linked as your child: when it goes idle or errors, you automatically get a `[Session lifecycle]` message — this is the PRIMARY way to learn a worker is done, you do not need to instruct it to call `mcp__orca__send_message_to_session` back. Pass `notify_on_completion: false` if you genuinely want a fire-and-forget spawn with no callback.
       - `mcp__orca__send_message_to_session` — direct an existing session

    2. **Prefer letting the automatic notification tell you when a worker is done.** Only ask a worker to `mcp__orca__send_message_to_session` you explicitly if you need something mid-task (a progress update, a specific artifact) beyond "it's done" — the completion callback itself is redundant with the automatic notification.

    3. **Heartbeats are a coarse fallback, not your primary signal.** Automatic `[Session lifecycle]` messages fire the moment a worker finishes, so you shouldn't need to poll. Still set one wide-interval `mcp__orca__schedule_heartbeat` safety net (e.g. every 10-15 minutes) in case a notification is ever missed or a worker hangs mid-turn (never goes idle/error). Pass `watch_children: true` (or `watch_session_ids`) — watch lists put per-worker status/activity digests directly in the wake-up message, often enough to skip a `search_sessions` call:
       > "Check on worker sessions. Use `mcp__orca__search_sessions` to see their status. If any are idle/error, review their work. If all work is complete, cancel the heartbeat."

    4. **Check in proactively** — If a worker session seems stuck (no lifecycle notification and no heartbeat signal within a reasonable time), use `mcp__orca__get_session_tail` to peek at its progress without interrupting it, or message it directly.

    5. **Archive completed children** — When a worker session has finished its task, use `mcp__orca__archive_session` to archive it. This keeps the session list tidy. If you need to continue the conversation later, just send a message to the archived session — it will be automatically unarchived.

    6. **Cancel monitoring** — When all delegated work is complete, use `mcp__orca__cancel_heartbeat` to stop monitoring.

    ## Orchestration Practices (tl;dr)

    - Rely on lifecycle notifications plus `mcp__orca__get_session_tail` / activity metadata for progress; heartbeats are a coarse fallback — re-call `mcp__orca__schedule_heartbeat` at each stage change to keep its delivered message current (it updates in place, it doesn't stack).
    - `mcp__orca__send_message_to_session` to a running session is a graceful interrupt-and-queue, not a lost message — feel free to ping a quiet worker, but peek non-interruptively with `mcp__orca__get_session_tail` first.
    - Parallel workers on disjoint files are encouraged: tell siblings each other's session IDs and file ownership so they can negotiate shared files directly. Workers verify with targeted tests only; the full suite runs once as a pre-deploy gate. No worktrees.
    - Do not Read or Glob a different project's directory; delegate with `mcp__orca__start_session` using that project's `directory` instead.
    - Use exact model ids (e.g. `claude-sonnet-5`, not `sonnet-5`).
    - Archive finished children, and have workers report back with commit SHAs and test results.
    - Hit platform friction (missing tool, awkward workflow, confusing error)? Check the backlog with `mcp__orca__list_feature_requests` first — if it's already tracked, add what you found with `mcp__orca__append_feature_request_note` instead of filing a duplicate with `mcp__orca__file_feature_request`. Once a fix for a tracked request has shipped AND been verified, close it with `mcp__orca__close_feature_request` (pass a resolution note referencing the commit).
    - Scheduled heartbeats do NOT survive a restart of your own host (e.g. a deploy) — re-call `mcp__orca__schedule_heartbeat` as your first action after waking from one.
    - Pre-deploy gate pattern: run the full suite once at the pipeline tip via a dedicated worker with an explicit allow-list of known flakes; treat any NEW failure as fix-at-root, never expand the allow-list.

    ## Example Flow

    1. Analyze the task and break it into subtasks
    2. Spawn worker sessions for each subtask via `mcp__orca__start_session` — each is auto-linked to notify you on completion
    3. Set a wide-interval heartbeat as a fallback safety net
    4. React to `[Session lifecycle]` messages as workers finish (or the heartbeat, if one is ever missed)
    5. If issues arise, provide guidance or spawn additional workers
    6. As each worker finishes, archive its session to keep the list clean
    7. When all work is complete, cancel heartbeat and summarize results

    Remember: You orchestrate, you don't implement. Apart from writing to your own `.claude` memory, if you find yourself wanting to edit a file or run a command, spawn a worker session instead.
    """
    |> String.trim()
  end

  defp expected_sibling_sessions_prompt(true, true) do
    "Other agent sessions may be active in this directory. Use `Tools.search_sessions(%{\"status\" => ...})` inside the `run_elixir` MCP tool to discover sibling sessions you may want to coordinate with — it is NOT a standalone MCP tool in this session."
  end

  defp expected_sibling_sessions_prompt(true, _code_exec) do
    "Other agent sessions may be active in this directory. Use the `mcp__orca__search_sessions` MCP tool to discover sibling sessions you may want to coordinate with."
  end

  defp expected_sibling_sessions_prompt(_orchestrator, true) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the standalone `send_message_to_session` MCP tool to send them messages."
  end

  defp expected_sibling_sessions_prompt(_orchestrator, _code_exec) do
    "Other agent sessions may be active in this directory. Check the `.agents/` directory to discover active sessions and their IDs, then use the `mcp__orca__send_message_to_session` MCP tool to coordinate with them."
  end

  defp expected_commit_trailer_prompt(session_id) do
    """
    When making git commits, ALWAYS append this trailer to the commit message:

    OrcaHub-Session: #{session_id}

    This links the commit to your OrcaHub session. Add it as a git trailer \
    (blank line after the commit body, then the trailer line). \
    Never omit this trailer.\
    """
    |> String.trim()
  end

  # Same fragments as expected_system_prompt/1, minus everything that
  # references an orca MCP tool (orchestrator/code-exec/sibling-session
  # guidance) — the no-MCP shape (ctx.tools == "", see mcp_enabled?/1).
  defp expected_system_prompt_no_mcp(ctx) do
    [
      "Your OrcaHub session ID is #{ctx.session_id}.",
      if(!ctx.orchestrator, do: expected_commit_trailer_prompt(ctx.session_id)),
      if(!ctx.orchestrator, do: expected_worker_practices_prompt()),
      if(!ctx.orchestrator, do: expected_ask_user_question_prompt())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp expected_submit_result_prompt do
    "When you have your final answer, call the submit_result tool — your plain response text is not the deliverable."
  end

  # api_run_schema?: true shape (submit_result tool-based result submission,
  # docs/api.md) — MCP stays enabled (unlike expected_system_prompt_no_mcp/1
  # above) but the orchestrator/sibling-session fragments are skipped since
  # the only orca tool reachable on the connection is submit_result, and a
  # submit_result instruction is appended instead.
  defp expected_system_prompt_api_run(ctx) do
    [
      "Your OrcaHub session ID is #{ctx.session_id}.",
      if(!ctx.orchestrator, do: expected_commit_trailer_prompt(ctx.session_id)),
      if(!ctx.orchestrator, do: expected_worker_practices_prompt()),
      if(!ctx.orchestrator, do: expected_ask_user_question_prompt()),
      expected_submit_result_prompt()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Transcribed from SessionRunner.mcp_config/1 (pre-refactor). Every ctx
  # fixture uses a fresh unique session_id and project_id: nil, so there are
  # never any project/session-scoped MCP servers — the JSON is always just
  # the "orca" entry.
  defp expected_mcp_config_json(ctx) do
    code_exec = OrcaHub.MCP.CodeExec.enabled?(ctx.code_exec)
    api_run = Map.get(ctx, :api_run_schema?) == true

    Jason.encode!(%{
      "mcpServers" => %{
        "orca" => %{
          "type" => "http",
          "url" =>
            "http://localhost:#{expected_mcp_port()}/mcp?orca_session_id=#{ctx.session_id}" <>
              "&orchestrator=#{ctx.orchestrator == true}" <>
              "&code_exec=#{code_exec}" <>
              "&api_run=#{api_run}"
        }
      }
    })
  end

  defp expected_mcp_port do
    case OrcaHubWeb.Endpoint.config(:http) do
      config when is_list(config) -> Keyword.get(config, :port, 4000)
      _ -> 4000
    end
  end

  defp expected_env do
    node_token =
      node()
      |> Atom.to_string()
      |> OrcaHub.HubRPC.get_node_token()
      |> OrcaHub.NodeCredentials.token_env()

    OrcaHub.Env.sanitized_env(node_token)
  rescue
    _ -> OrcaHub.Env.sanitized_env([])
  end

  defp expected_streaming_opts(ctx) do
    [cwd: ctx.directory, input_format: "stream-json"]
    |> expected_maybe_put(:session_id, ctx.claude_session_id)
    |> expected_maybe_put(:model, ctx.model)
    |> expected_maybe_put(:system_prompt, expected_system_prompt(ctx))
    |> expected_maybe_put(:tools, expected_tools(ctx.orchestrator))
    |> Keyword.put(:mcp_config, expected_mcp_config_json(ctx))
  end

  defp expected_one_shot_opts(ctx) do
    [cwd: ctx.directory]
    |> expected_maybe_put(:session_id, ctx.claude_session_id)
    |> expected_maybe_put(:model, ctx.model)
    |> expected_maybe_put(:system_prompt, expected_system_prompt(ctx))
    |> expected_maybe_put(:tools, expected_tools(ctx.orchestrator))
    |> Keyword.put(:mcp_config, expected_mcp_config_json(ctx))
  end

  # ── spawn_spec/2 — :streaming ────────────────────────────────────────

  describe "spawn_spec/2 — :streaming" do
    test "no resume session id, no orchestrator/code_exec" do
      ctx = ctx()
      {expected_args, expected_port_opts} = Config.build_args(nil, expected_streaming_opts(ctx))

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.executable == System.find_executable("claude")
      assert spec.args == expected_args
      assert spec.port_opts == expected_port_opts
      assert spec.framing == :ndjson
      assert spec.env == expected_env()
    end

    test "with resume session id" do
      ctx = ctx(%{claude_session_id: "resume-sess-123", model: "claude-sonnet-4-6"})
      {expected_args, expected_port_opts} = Config.build_args(nil, expected_streaming_opts(ctx))

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
      assert "--resume" in spec.args
      assert "resume-sess-123" in spec.args
      assert spec.port_opts == expected_port_opts
    end

    test "orchestrator: true restricts --tools and swaps the system prompt" do
      ctx = ctx(%{orchestrator: true})
      {expected_args, _expected_port_opts} = Config.build_args(nil, expected_streaming_opts(ctx))

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
      assert "--tools" in spec.args
      assert "Read,Glob,Grep,WebFetch,WebSearch,Write,Edit" in spec.args
    end

    test "code_exec: true adds the code-exec system-prompt section" do
      ctx = ctx(%{code_exec: true})
      {expected_args, _expected_port_opts} = Config.build_args(nil, expected_streaming_opts(ctx))

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
    end

    test "orchestrator + code_exec together" do
      ctx = ctx(%{orchestrator: true, code_exec: true, claude_session_id: "resume-xyz"})
      {expected_args, expected_port_opts} = Config.build_args(nil, expected_streaming_opts(ctx))

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
      assert spec.port_opts == expected_port_opts
    end

    test "tools: \"\" (no_tools API run mode) sets --tools \"\" and omits --mcp-config entirely" do
      ctx = ctx(%{tools: ""})

      opts =
        [cwd: ctx.directory, input_format: "stream-json"]
        |> expected_maybe_put(:system_prompt, expected_system_prompt_no_mcp(ctx))
        |> Keyword.put(:tools, "")

      {expected_args, expected_port_opts} = Config.build_args(nil, opts)

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
      assert spec.port_opts == expected_port_opts
      assert "--tools" in spec.args

      tools_idx = Enum.find_index(spec.args, &(&1 == "--tools"))
      assert Enum.at(spec.args, tools_idx + 1) == ""

      refute "--mcp-config" in spec.args
    end

    test "tools: \"\" + api_run_schema?: true KEEPS --mcp-config (submit_result is the only result channel)" do
      ctx = ctx(%{tools: "", api_run_schema?: true})

      opts =
        [cwd: ctx.directory, input_format: "stream-json"]
        |> expected_maybe_put(:system_prompt, expected_system_prompt_api_run(ctx))
        |> Keyword.put(:tools, "")
        |> Keyword.put(:mcp_config, expected_mcp_config_json(ctx))

      {expected_args, expected_port_opts} = Config.build_args(nil, opts)

      spec = Backend.spawn_spec(:streaming, ctx)

      assert spec.args == expected_args
      assert spec.port_opts == expected_port_opts

      tools_idx = Enum.find_index(spec.args, &(&1 == "--tools"))
      assert Enum.at(spec.args, tools_idx + 1) == ""

      assert "--mcp-config" in spec.args
    end
  end

  # ── spawn_spec/2 — scrub_session_env (OrcaHub.NodePolicy) ─────────────────

  describe "spawn_spec/2 — scrub_session_env" do
    setup do
      {:ok, node_row} = OrcaHub.ClusterNodes.upsert_seen(Atom.to_string(node()), "test")
      {:ok, _} = OrcaHub.ClusterNodes.update_node(node_row, %{scrub_session_env: true})

      System.put_env("ORCA_TEST_LEAK_CLAUDE", "should-not-survive-scrubbing")
      on_exit(fn -> System.delete_env("ORCA_TEST_LEAK_CLAUDE") end)

      :ok
    end

    test "unsets an arbitrary inherited var but keeps HOME (streaming)" do
      spec = Backend.spawn_spec(:streaming, ctx())

      assert {~c"ORCA_TEST_LEAK_CLAUDE", false} in spec.env
      refute {~c"HOME", false} in spec.env
    end

    test "unsets an arbitrary inherited var but keeps HOME (one_shot)" do
      spec = Backend.spawn_spec(:one_shot, ctx(%{prompt: "hi"}))

      assert {~c"ORCA_TEST_LEAK_CLAUDE", false} in spec.env
      refute {~c"HOME", false} in spec.env
    end

    test "keeps a node+project env_allowlist entry unset-as-inherited" do
      node_row = OrcaHub.ClusterNodes.get_by_name(Atom.to_string(node()))
      {:ok, _} = OrcaHub.ClusterNodes.update_node(node_row, %{env_allowlist: ["ORCA_NODE_VAR"]})

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "p-#{System.unique_integer([:positive])}",
          directory: "/tmp/p-#{System.unique_integer([:positive])}",
          env_allowlist: ["ORCA_PROJECT_*"]
        })

      System.put_env("ORCA_NODE_VAR", "node-value")
      System.put_env("ORCA_PROJECT_TOKEN", "project-value")
      on_exit(fn -> Enum.each(~w(ORCA_NODE_VAR ORCA_PROJECT_TOKEN), &System.delete_env/1) end)

      spec = Backend.spawn_spec(:streaming, ctx(%{project_id: project.id}))

      refute {~c"ORCA_NODE_VAR", false} in spec.env
      refute {~c"ORCA_PROJECT_TOKEN", false} in spec.env
      # Still scrubbed: not on any allow-list.
      assert {~c"ORCA_TEST_LEAK_CLAUDE", false} in spec.env
    end
  end

  # ── spawn_spec/2 — :one_shot ─────────────────────────────────────────

  describe "spawn_spec/2 — :one_shot" do
    test "no resume session id" do
      ctx = ctx(%{prompt: "hello world"})

      {expected_args, expected_port_opts} =
        Config.build_args("hello world", expected_one_shot_opts(ctx))

      script_path = System.find_executable("script")
      claude_path = System.find_executable("claude")

      expected_script_args =
        case :os.type() do
          {:unix, :darwin} ->
            ["-q", "/dev/null", claude_path | expected_args]

          _ ->
            cmd = Enum.map_join([claude_path | expected_args], " ", &Config.shell_escape/1)
            ["-qc", cmd, "/dev/null"]
        end

      spec = Backend.spawn_spec(:one_shot, ctx)

      assert spec.executable == script_path
      assert spec.args == expected_script_args
      assert spec.port_opts == expected_port_opts
      assert spec.framing == :ndjson
    end

    test "with resume session id and orchestrator" do
      ctx =
        ctx(%{
          prompt: "resume me",
          claude_session_id: "one-shot-resume-1",
          orchestrator: true
        })

      {expected_args, expected_port_opts} =
        Config.build_args("resume me", expected_one_shot_opts(ctx))

      claude_path = System.find_executable("claude")

      expected_script_args =
        case :os.type() do
          {:unix, :darwin} ->
            ["-q", "/dev/null", claude_path | expected_args]

          _ ->
            cmd = Enum.map_join([claude_path | expected_args], " ", &Config.shell_escape/1)
            ["-qc", cmd, "/dev/null"]
        end

      spec = Backend.spawn_spec(:one_shot, ctx)

      assert spec.args == expected_script_args
      assert spec.port_opts == expected_port_opts
    end

    test "tools: \"\" (no_tools API run mode) sets --tools \"\" and omits --mcp-config entirely" do
      ctx = ctx(%{tools: "", prompt: "hi"})

      opts =
        [cwd: ctx.directory]
        |> expected_maybe_put(:system_prompt, expected_system_prompt_no_mcp(ctx))
        |> Keyword.put(:tools, "")

      {expected_args, expected_port_opts} = Config.build_args("hi", opts)
      assert "--tools" in expected_args
      refute "--mcp-config" in expected_args

      claude_path = System.find_executable("claude")

      expected_script_args =
        case :os.type() do
          {:unix, :darwin} ->
            ["-q", "/dev/null", claude_path | expected_args]

          _ ->
            cmd = Enum.map_join([claude_path | expected_args], " ", &Config.shell_escape/1)
            ["-qc", cmd, "/dev/null"]
        end

      spec = Backend.spawn_spec(:one_shot, ctx)

      assert spec.args == expected_script_args
      assert spec.port_opts == expected_port_opts
    end
  end

  # ── stdin framing ────────────────────────────────────────────────────

  describe "on_open/1" do
    test "no open-time handshake: empty iodata, ctx unchanged" do
      ctx = %{some: :state}
      assert Backend.on_open(ctx) == {"", ctx}
    end
  end

  describe "encode_user_turn/2" do
    test "matches the old user_turn_json/1 NDJSON frame exactly" do
      {iodata, ctx_out} = Backend.encode_user_turn("hello world", %{})
      json = IO.iodata_to_binary(iodata)

      assert String.ends_with?(json, "\n")

      assert Jason.decode!(json) == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello world"}]
               }
             }

      # ctx is threaded through unchanged (identity for Claude).
      assert ctx_out == %{}
    end
  end

  describe "encode_interrupt/2" do
    test "streaming ctx (no :engine, or :engine != :one_shot) returns the control_request frame" do
      json = Backend.encode_interrupt("int_7", %{engine: :streaming}) |> IO.iodata_to_binary()

      assert Jason.decode!(json) == %{
               "type" => "control_request",
               "request_id" => "int_7",
               "request" => %{"subtype" => "interrupt"}
             }
    end

    test "ctx with no :engine key also returns the framed iodata (matches old always-framed behavior)" do
      json = Backend.encode_interrupt("int_9", %{}) |> IO.iodata_to_binary()
      assert Jason.decode!(json)["request_id"] == "int_9"
    end

    test ":one_shot ctx returns :signal" do
      assert Backend.encode_interrupt("int_1", %{engine: :one_shot}) == :signal
    end
  end

  # ── Normalization / session id ───────────────────────────────────────

  describe "normalize/2" do
    test "is identity: {[event], ctx} unchanged" do
      event = %{"type" => "assistant", "message" => %{"content" => []}}
      ctx = %{backend_state: %{}, foo: :bar}

      assert Backend.normalize(event, ctx) == {[event], ctx}
    end
  end

  describe "session_id/1" do
    test "extracts session_id from a system event" do
      assert Backend.session_id(%{"type" => "system", "session_id" => "abc-123"}) == "abc-123"
    end

    test "nil for a system event without session_id" do
      assert Backend.session_id(%{"type" => "system", "subtype" => "status"}) == nil
    end

    test "nil for non-system events" do
      assert Backend.session_id(%{"type" => "assistant"}) == nil
      assert Backend.session_id(%{}) == nil
    end
  end

  describe "capabilities/0" do
    test "matches the Claude column of spec §3.1" do
      caps = Backend.capabilities()

      assert caps.streaming == true
      assert caps.interrupt == :protocol
      assert caps.mcp == true
      assert caps.resume == true
      assert caps.usage == true
      assert caps.system_prompt == :flag
      assert caps.warmup_turn == true
    end
  end

  describe "prepare_session/1 and cleanup_session/1" do
    test "are no-ops (MCP is passed inline, not via on-disk state)" do
      assert Backend.prepare_session(%{}) == :ok
      assert Backend.cleanup_session(%{}) == :ok
    end
  end

  describe "handle_peer_request/2" do
    test "Claude never issues peer requests: safe no-op, ctx passed through" do
      ctx = %{some: :state}
      assert Backend.handle_peer_request(%{"id" => 1, "method" => "foo"}, ctx) == {"", [], ctx}
    end
  end

  describe "system_prompt/1" do
    test "matches SessionRunner.build_system_prompt/1's pre-refactor output" do
      ctx = ctx()
      assert Backend.system_prompt(ctx) == expected_system_prompt(ctx)
    end

    test "orchestrator variant" do
      ctx = ctx(%{orchestrator: true})
      assert Backend.system_prompt(ctx) == expected_system_prompt(ctx)
    end

    test "code_exec: true swaps the sibling-sessions guidance to Tools.* inside run_elixir" do
      ctx = ctx(%{code_exec: true})
      prompt = Backend.system_prompt(ctx)

      assert prompt == expected_system_prompt(ctx)
      assert String.ends_with?(prompt, expected_sibling_sessions_prompt(false, true))
      refute prompt =~ "mcp__orca__send_message_to_session"
    end

    test "orchestrator + code_exec: true rewrites both the orchestrator and sibling-sessions guidance to Tools.* inside run_elixir" do
      ctx = ctx(%{orchestrator: true, code_exec: true})
      prompt = Backend.system_prompt(ctx)

      assert prompt == expected_system_prompt(ctx)
      assert String.ends_with?(prompt, expected_sibling_sessions_prompt(true, true))
      assert prompt =~ "Tools.start_session"
      assert prompt =~ "send_message_to_session"
      refute prompt =~ "Tools.send_message_to_session"
      assert prompt =~ "Tools.search_sessions"
      assert prompt =~ "Tools.schedule_heartbeat"
      assert prompt =~ "Tools.archive_session"
      assert prompt =~ "Tools.cancel_heartbeat"
      assert prompt =~ "mcp__orca__*"
      refute prompt =~ "mcp__orca__start_session"
    end

    test "tools: \"\" (no MCP at all): no submit_result instruction either" do
      ctx = ctx(%{tools: ""})
      prompt = Backend.system_prompt(ctx)

      assert prompt == expected_system_prompt_no_mcp(ctx)
      refute prompt =~ "submit_result"
    end

    test "api_run_schema?: true (Agent Runs API submit_result mode, docs/api.md): submit_result instruction, no orchestrator/sibling fragments" do
      ctx = ctx(%{tools: "", api_run_schema?: true})
      prompt = Backend.system_prompt(ctx)

      assert prompt == expected_system_prompt_api_run(ctx)
      assert prompt =~ "call the submit_result tool"
      refute prompt =~ "Orchestrator Session"
      refute prompt =~ "mcp__orca__start_session"
      refute prompt =~ "Other agent sessions may be active"
    end
  end

  describe "mcp_enabled?/1 (Agent Runs API, docs/api.md)" do
    test "false when tools == \"\" and no api_run schema" do
      refute Backend.mcp_enabled?(%{tools: ""})
    end

    test "true when tools == \"\" but api_run_schema?: true — submit_result must stay reachable" do
      assert Backend.mcp_enabled?(%{tools: "", api_run_schema?: true})
    end

    test "true when tools is unset/non-empty regardless of api_run_schema?" do
      assert Backend.mcp_enabled?(%{tools: nil})
      assert Backend.mcp_enabled?(%{})
      assert Backend.mcp_enabled?(%{tools: nil, api_run_schema?: false})
    end
  end

  describe "mcp_config_json (via spawn_spec) — api_run_schema?: true excludes project/session-scoped servers" do
    test "an api_run connection's --mcp-config has ONLY the orca entry, even with a project-scoped upstream server" do
      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "claude-test-project-#{System.unique_integer([:positive])}",
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}"
        })

      {:ok, server} =
        OrcaHub.Repo.insert(%OrcaHub.UpstreamServers.UpstreamServer{
          name: "some-upstream",
          url: "http://example.invalid/mcp",
          enabled: true
        })

      {:ok, _} = OrcaHub.UpstreamServers.add_server_to_project(project.id, server.id)

      ctx = ctx(%{project_id: project.id, api_run_schema?: true})

      spec = Backend.spawn_spec(:streaming, ctx)
      mcp_config_idx = Enum.find_index(spec.args, &(&1 == "--mcp-config"))
      config = spec.args |> Enum.at(mcp_config_idx + 1) |> Jason.decode!()

      assert Map.keys(config["mcpServers"]) == ["orca"]
    end

    test "a non-api_run connection's --mcp-config includes a project-scoped upstream server" do
      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "claude-test-project-#{System.unique_integer([:positive])}",
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}"
        })

      {:ok, server} =
        OrcaHub.Repo.insert(%OrcaHub.UpstreamServers.UpstreamServer{
          name: "some-upstream",
          url: "http://example.invalid/mcp",
          enabled: true
        })

      {:ok, _} = OrcaHub.UpstreamServers.add_server_to_project(project.id, server.id)

      ctx = ctx(%{project_id: project.id})

      spec = Backend.spawn_spec(:streaming, ctx)
      mcp_config_idx = Enum.find_index(spec.args, &(&1 == "--mcp-config"))
      config = spec.args |> Enum.at(mcp_config_idx + 1) |> Jason.decode!()

      assert Enum.sort(Map.keys(config["mcpServers"])) == ["orca", "some-upstream"]
    end
  end
end
