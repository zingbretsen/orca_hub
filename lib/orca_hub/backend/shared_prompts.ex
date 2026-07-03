defmodule OrcaHub.Backend.SharedPrompts do
  @moduledoc """
  System-prompt fragments that are NOT Claude-specific — shared by
  `Backend.Claude`, `Backend.Codex`, and (as of the orca-mcp bridge, spec
  §12.5) `Backend.Pi` (spec §3.2's `system_prompt/1` callback) so backends'
  otherwise-identical guidance can't drift.

  `orchestrator_prompt/2` uses the `mcp__server__tool` naming convention
  directly (e.g. `mcp__orca__start_session`) — this used to be considered
  Claude-only and lived in `Backend.Claude`, but it's equally correct for any
  backend whose MCP bridge registers tools under that same convention, which
  is exactly what `priv/pi/orca-mcp.ts` does (spec §12.5). Fragments that
  depend on a Claude-only *built-in* (`AskUserQuestion`) still stay private
  to `Backend.Claude`.
  """

  @doc "Teaches a code-exec session its collapsed tool surface, when enabled."
  def code_exec_prompt(false), do: nil

  def code_exec_prompt(true) do
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

  @doc """
  Instructs an orchestrator session to delegate work via the `mcp__orca__*`
  coordination tools instead of doing it directly. Moved here verbatim from
  `Backend.Claude` (spec §12.5) when `Backend.Pi` gained the same
  `mcp__orca__*`-namespaced coordination tools via its `orca-mcp.ts` bridge —
  no text changed, only the call site.
  """
  def orchestrator_prompt(false, _session_id), do: nil
  def orchestrator_prompt(nil, _session_id), do: nil

  def orchestrator_prompt(true, session_id) do
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

  @doc """
  Renders `<directory>/.context/*.{md,mmd}` as a "Project Context" block, or
  `nil` when the directory doesn't exist / has no matching files.
  """
  def context_files_prompt(directory) do
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

  @doc "Instructs the model to append the OrcaHub-Session git trailer."
  def commit_trailer_prompt(session_id) do
    """
    When making git commits, ALWAYS append this trailer to the commit message:

    OrcaHub-Session: #{session_id}

    This links the commit to your OrcaHub session. Add it as a git trailer \
    (blank line after the commit body, then the trailer line). \
    Never omit this trailer.\
    """
    |> String.trim()
  end
end
