defmodule OrcaHub.ClaudeImport do
  @moduledoc """
  Imports Claude Code sessions from ~/.claude/ into OrcaHub.

  Scans ~/.claude/projects/ for session transcript .jsonl files,
  creates projects as needed, and imports sessions with their messages.
  Skips sessions that are already managed by OrcaHub (matched by claude_session_id).

  Can import from remote agent nodes by passing the `node` option —
  file reads happen on the target node via RPC, DB writes go through HubRPC.
  """

  import Ecto.Query
  alias OrcaHub.{Repo, Projects, Projects.Project, Sessions, Sessions.Session, Sessions.Message}
  require Logger

  @doc """
  Imports all Claude Code sessions found in ~/.claude/projects/.
  Returns a summary map with counts of imported/skipped sessions and created projects.

  Options:
    - `verbose` - log progress (default: false)
    - `node` - the Erlang node to read files from (default: local node)
  """
  def import_all(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    target_node = Keyword.get(opts, :node, node())

    claude_dir = resolve_claude_dir(target_node)
    projects_dir = Path.join(claude_dir, "projects")

    # Get all existing claude_session_ids so we know what to skip
    existing_session_ids = existing_claude_session_ids()

    # Get all existing projects by directory for matching
    existing_projects = existing_projects_by_directory()

    # Get directories of deleted projects so we don't recreate them
    deleted_dirs = deleted_project_directories()

    # Scan all project directories (on the target node)
    project_dirs = list_project_dirs(target_node, projects_dir)

    summary = %{sessions_imported: 0, sessions_skipped: 0, projects_created: 0, errors: []}

    Enum.reduce(project_dirs, summary, fn project_dir, acc ->
      project_path = decode_project_dir(target_node, Path.basename(project_dir))
      resolved_path = resolve_worktree_parent(project_path)

      # Skip directories whose projects were deleted
      if MapSet.member?(deleted_dirs, resolved_path) do
        if verbose, do: Logger.info("[skip] Project #{resolved_path} was deleted, skipping")
        acc
      else

      # Find or create project
      {project, acc} = find_or_create_project(project_path, target_node, existing_projects, acc, verbose)

      # Import sessions from this project dir
      transcript_files = rpc_call(target_node, Path, :wildcard, [Path.join(project_dir, "*.jsonl")])

      Enum.reduce(transcript_files, acc, fn file, acc ->
        session_id = Path.basename(file, ".jsonl")

        if MapSet.member?(existing_session_ids, session_id) do
          if verbose, do: Logger.info("[skip] Session #{session_id} already exists")
          %{acc | sessions_skipped: acc.sessions_skipped + 1}
        else
          try do
            case import_session(target_node, file, session_id, project, verbose) do
              {:ok, _session} ->
                %{acc | sessions_imported: acc.sessions_imported + 1}

              {:error, reason} ->
                if verbose, do: Logger.warning("[error] Session #{session_id}: #{inspect(reason)}")
                %{acc | errors: [{session_id, reason} | acc.errors]}
            end
          rescue
            e ->
              if verbose, do: Logger.warning("[error] Session #{session_id}: #{Exception.message(e)}")
              %{acc | errors: [{session_id, Exception.message(e)} | acc.errors]}
          end
        end
      end)
      end
    end)
  end

  defp import_session(target_node, file, claude_session_id, project, verbose) do
    entries = read_transcript(target_node, file)

    if entries == [] do
      {:error, :empty_transcript}
    else
      # Extract metadata from the first meaningful entry
      first_entry = Enum.find(entries, &(&1["type"] in ["user", "assistant"]))
      directory = get_in(first_entry, ["cwd"]) || project_directory(project)
      model = find_model(entries)
      title = extract_title(entries)

      # Get timestamps for inserted_at/updated_at
      first_ts = parse_timestamp(List.first(entries)["timestamp"])
      last_ts = parse_timestamp(List.last(entries)["timestamp"])

      # Filter to just user/assistant/system messages (skip progress, file-history-snapshot, queue-operation)
      messages = Enum.filter(entries, &(&1["type"] in ["user", "assistant", "system"]))

      if verbose do
        Logger.info("[import] Session #{claude_session_id} (#{length(messages)} messages) - #{title || "untitled"}")
      end

      Repo.transaction(fn ->
        # Create the session
        session_attrs = %{
          directory: directory,
          claude_session_id: claude_session_id,
          title: title,
          status: "idle",
          model: model,
          project_id: project && project.id,
          runner_node: Atom.to_string(target_node),
          archived_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        {:ok, session} = Sessions.create_session(session_attrs)

        # Override timestamps to match the original session
        if first_ts do
          from(s in Session, where: s.id == ^session.id)
          |> Repo.update_all(set: [
            inserted_at: first_ts,
            updated_at: last_ts || first_ts
          ])
        end

        # Bulk insert messages
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        message_rows =
          messages
          |> Enum.with_index()
          |> Enum.map(fn {entry, idx} ->
            msg_ts = parse_naive_timestamp(entry["timestamp"]) || NaiveDateTime.add(now, idx, :second)

            %{
              id: Ecto.UUID.generate(),
              session_id: session.id,
              data: entry,
              inserted_at: msg_ts,
              updated_at: msg_ts
            }
          end)

        # Insert in batches of 500 to avoid huge queries
        message_rows
        |> Enum.chunk_every(500)
        |> Enum.each(fn batch ->
          Repo.insert_all(Message, batch)
        end)

        session
      end)
    end
  end

  defp read_transcript(target_node, file) do
    # Read file content from the target node
    content = rpc_call(target_node, File, :read!, [file])

    content
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      # Remove null bytes that PostgreSQL can't store in text/jsonb
      clean_line = String.replace(line, <<0>>, "")

      case Jason.decode(String.trim(clean_line)) do
        {:ok, entry} -> [sanitize_null_bytes(entry) | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  # Recursively remove null bytes from all string values in a nested structure
  defp sanitize_null_bytes(value) when is_binary(value) do
    String.replace(value, <<0>>, "")
  end

  defp sanitize_null_bytes(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {sanitize_null_bytes(k), sanitize_null_bytes(v)} end)
  end

  defp sanitize_null_bytes(value) when is_list(value) do
    Enum.map(value, &sanitize_null_bytes/1)
  end

  defp sanitize_null_bytes(value), do: value

  defp find_model(entries) do
    Enum.find_value(entries, fn entry ->
      get_in(entry, ["message", "model"])
    end)
  end

  defp extract_title(entries) do
    # Use the first user message text as the title
    first_user = Enum.find(entries, &(&1["type"] == "user"))

    case first_user do
      nil ->
        nil

      %{"message" => %{"content" => content}} when is_binary(content) ->
        truncate_title(content)

      %{"message" => %{"content" => content}} when is_list(content) ->
        text_block = Enum.find(content, &(&1["type"] == "text"))
        if text_block, do: truncate_title(text_block["text"]), else: nil

      _ ->
        nil
    end
  end

  defp truncate_title(nil), do: nil

  defp truncate_title(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp find_or_create_project(project_path, target_node, existing_projects, acc, verbose) do
    # If this is a worktree path, resolve to the parent project directory
    project_path = resolve_worktree_parent(project_path)

    case Map.get(existing_projects, project_path) do
      nil ->
        name = project_path |> Path.basename() |> String.replace(~r/[-_]/, " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

        case Projects.create_project(%{name: name, directory: project_path, node: Atom.to_string(target_node)}) do
          {:ok, project} ->
            if verbose, do: Logger.info("[create] Project #{name} (#{project_path})")
            {project, %{acc | projects_created: acc.projects_created + 1}}

          {:error, _} ->
            # Directory might not exist anymore, still import without project
            {nil, acc}
        end

      project ->
        {project, acc}
    end
  end

  # Worktree paths like /foo/bar/.worktrees/branch or /foo/bar/worktrees/branch -> /foo/bar
  defp resolve_worktree_parent(path) do
    parts = Path.split(path)

    case Enum.find_index(parts, &(&1 in [".worktrees", "worktrees"])) do
      nil -> path
      idx -> parts |> Enum.take(idx) |> Path.join()
    end
  end

  defp existing_claude_session_ids do
    Repo.all(from s in Session, where: not is_nil(s.claude_session_id), select: s.claude_session_id)
    |> MapSet.new()
  end

  defp existing_projects_by_directory do
    Repo.all(from p in Project, where: is_nil(p.deleted_at), select: {p.directory, p})
    |> Map.new()
  end

  defp deleted_project_directories do
    Repo.all(from p in Project, where: not is_nil(p.deleted_at), select: p.directory)
    |> MapSet.new()
  end

  defp list_project_dirs(target_node, projects_dir) do
    case rpc_call(target_node, File, :ls, [projects_dir]) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(projects_dir, &1))
        |> Enum.filter(fn path -> rpc_call(target_node, File, :dir?, [path]) end)

      {:error, _} ->
        []
    end
  end

  defp decode_project_dir(target_node, encoded) do
    parts = String.split(encoded, "-", trim: true)
    find_valid_path(target_node, parts, "/")
  end

  defp find_valid_path(_target_node, [], current), do: current

  defp find_valid_path(target_node, parts, current) do
    1..length(parts)
    |> Enum.find_value(fn n ->
      segment = Enum.take(parts, n) |> Enum.join("-")
      remaining = Enum.drop(parts, n)

      candidates = [
        Path.join(current, segment),
        Path.join(current, String.replace(segment, "-", "_")),
        Path.join(current, String.replace(segment, "-", ".")),
        Path.join(current, "." <> segment),
        Path.join(current, "." <> String.replace(segment, "-", "_")),
        Path.join(current, "." <> String.replace(segment, "-", "."))
      ]

      Enum.find_value(candidates, fn candidate ->
        cond do
          remaining == [] and rpc_call(target_node, File, :dir?, [candidate]) ->
            candidate

          remaining == [] ->
            nil

          rpc_call(target_node, File, :dir?, [candidate]) ->
            find_valid_path(target_node, remaining, candidate)

          true ->
            nil
        end
      end)
    end) || fallback_path(target_node, parts, current)
  end

  defp fallback_path(target_node, parts, current) do
    fallback = "/" <> Enum.join(parts, "/")
    if rpc_call(target_node, File, :dir?, [fallback]), do: fallback, else: Path.join(current, Enum.join(parts, "-"))
  end

  defp project_directory(nil), do: "/"
  defp project_directory(%Project{directory: dir}), do: dir

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case NaiveDateTime.from_iso8601(ts) do
      {:ok, ndt} -> NaiveDateTime.truncate(ndt, :second)
      _ -> nil
    end
  end

  defp parse_timestamp(ts) when is_integer(ts) do
    ts
    |> div(1000)
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
  end

  defp parse_naive_timestamp(ts), do: parse_timestamp(ts)

  defp resolve_claude_dir(target_node) do
    home = rpc_call(target_node, System, :user_home!, [])
    Path.join(home, ".claude")
  end

  # RPC helper — local passthrough, remote via :erpc
  defp rpc_call(n, mod, fun, args) when n == node(), do: apply(mod, fun, args)
  defp rpc_call(n, mod, fun, args), do: :erpc.call(n, mod, fun, args, 30_000)
end
