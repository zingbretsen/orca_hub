defmodule OrcaHub.MCP.Tools.Projects do
  @moduledoc """
  MCP tools for registered projects: looking one up (`list_projects`) and
  moving its directory on disk (`move_project_directory`).

  `list_projects` exists so an agent can resolve a project UUID for tools that
  require one — `create_scheduled_trigger`/`create_webhook_trigger` (see
  `OrcaHub.MCP.Tools.Triggers`) previously required a `project_id` with
  nothing on the MCP tool surface to look one up (FR 3e2828bc).

  `move_project_directory` wraps `OrcaHub.Projects.plan_directory_move/2` and
  `move_directory/3`. It defaults to `dry_run: true` on purpose: a bare call
  must PREVIEW, never move a real directory on disk.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, Projects}

  def list do
    [
      %{
        "name" => "list_projects",
        "description" =>
          "List every registered (non-deleted) project: id, name, directory, and node. " <>
            "Use this to look up a project's UUID — e.g. for create_scheduled_trigger/" <>
            "create_webhook_trigger's project_id parameter (both also accept a `directory` " <>
            "argument as a shortcut instead).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      },
      %{
        "name" => "move_project_directory",
        "description" =>
          "Move or rename a project's directory. This MOVES A REAL DIRECTORY ON DISK (on the " <>
            "project's own node) and REWRITES DATABASE ROWS: the project row, plus every " <>
            "session, terminal, and job whose directory is under it — including other " <>
            "projects nested inside it (e.g. git worktrees), which are dragged along because " <>
            "they physically move too. It is destructive and hard to reverse. " <>
            "dry_run defaults to TRUE: a bare call only PREVIEWS the move and changes " <>
            "nothing; pass dry_run: false to actually perform it. Either way the result is " <>
            "the same JSON map: from, to, node, projects (every project row rewritten), " <>
            "sessions/terminals/jobs (row counts), blockers, warnings, side_effects. " <>
            "Live work in the directory (a session mid-turn, a running terminal PTY, a " <>
            "running job) is a blocker: a real move refuses while any blocker is listed " <>
            "unless force: true, which interrupts that work rather than waiting for it. " <>
            "A project is never moved from, or re-assigned to, a different node — if its " <>
            "node is down the move fails instead.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{
              "type" => "string",
              "description" =>
                "The project to move. Accepts a full UUID or an unambiguous hex prefix " <>
                  "(>= 8 chars) as copy-pasted from list_projects output."
            },
            "new_directory" => %{
              "type" => "string",
              "description" =>
                "Absolute destination path on the project's node. Must not already exist; " <>
                  "its parent must. No \"~\" expansion — the project may live on another " <>
                  "machine, so a path relative to a home directory is ambiguous."
            },
            "dry_run" => %{
              "type" => "boolean",
              "description" =>
                "Defaults to true. True previews the move and mutates nothing; false " <>
                  "actually moves the directory and rewrites the database rows.",
              "default" => true
            },
            "force" => %{
              "type" => "boolean",
              "description" =>
                "Defaults to false. Only meaningful with dry_run: false — proceed even " <>
                  "though live work is using the directory, interrupting it (live session " <>
                  "runners are stopped either way; a mid-turn session, running PTY or " <>
                  "running job is left to fend for itself). The blockers it overrides are " <>
                  "reported in warnings.",
              "default" => false
            }
          },
          "required" => ["project_id", "new_directory"]
        }
      }
    ]
  end

  def call("list_projects", _args, _state) do
    projects =
      HubRPC.list_projects()
      |> Enum.map(fn project ->
        %{
          id: project.id,
          name: project.name,
          directory: project.directory,
          node: Cluster.node_name(project.node || node())
        }
      end)

    text(Jason.encode!(projects))
  end

  def call("move_project_directory", args, _state) do
    with {:ok, dry_run} <- boolean_arg(args, "dry_run", true),
         {:ok, force} <- boolean_arg(args, "force", false),
         {:ok, destination} <- destination_arg(args),
         # Goes through HubRPC because `Projects.resolve_id/1` is a Repo query
         # and this tool can be called from an agent node, which has no Repo.
         {:ok, project} <- HubRPC.resolve_project_id(args["project_id"]) do
      run_move(project, destination, dry_run, force)
    else
      {:error, message} when is_binary(message) -> error(message)
      other -> error("Could not move the project directory: #{inspect(other)}")
    end
  end

  defp run_move(project, destination, true = _dry_run, _force) do
    case Projects.plan_directory_move(project, destination) do
      {:ok, plan} -> text(encode(plan, true))
      {:error, {reason, message}} -> error(move_error_message(reason, message))
    end
  end

  defp run_move(project, destination, false = _dry_run, force) do
    case Projects.move_directory(project, destination, force: force) do
      {:ok, result} -> text(encode(result, false))
      {:error, {reason, message}} -> error(move_error_message(reason, message))
    end
  end

  # The result map is returned as-is (plus the `dry_run` flag that produced
  # it, so a caller reading only the JSON can tell a preview from a completed
  # move). `node` is an atom; Jason renders it as the raw node name string.
  defp encode(result, dry_run), do: Jason.encode!(Map.put(result, :dry_run, dry_run))

  # DirectoryMove's messages are written for a human and are surfaced
  # verbatim. `:node_unavailable` gets one extra sentence, because the one
  # thing a caller must NOT take from it is "try it somewhere else" — a
  # project is never re-routed to another node.
  defp move_error_message(:node_unavailable, message),
    do:
      message <>
        " The move can only run on that project's own node, and OrcaHub never re-assigns a " <>
        "project to a different one — wait for that node to come back rather than retrying " <>
        "elsewhere."

  defp move_error_message(_reason, message), do: message

  defp destination_arg(args) do
    case args["new_directory"] do
      dir when is_binary(dir) -> {:ok, dir}
      nil -> {:error, "new_directory is required — the absolute path to move the project to."}
      other -> {:error, "new_directory must be a string, got: #{inspect(other)}"}
    end
  end

  # Deliberately strict: a non-boolean `dry_run` is an error rather than
  # something to coerce, since coercing "false" the wrong way would move a
  # real directory the caller only meant to preview.
  defp boolean_arg(args, key, default) do
    case Map.get(args, key, default) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, "#{key} must be true or false, got: #{inspect(other)}"}
    end
  end
end
