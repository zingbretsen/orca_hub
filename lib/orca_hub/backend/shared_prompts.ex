defmodule OrcaHub.Backend.SharedPrompts do
  @moduledoc """
  System-prompt fragments that are NOT Claude-specific — shared by
  `Backend.Claude` and `Backend.Codex` (spec §3.2's `system_prompt/1`
  callback) so the two backends' otherwise-identical guidance can't drift.

  Fragments that genuinely depend on Claude tool names/built-ins
  (`AskUserQuestion`, the `mcp__server__tool` naming convention baked into
  `--append-system-prompt` instructions) stay private to `Backend.Claude`.
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
