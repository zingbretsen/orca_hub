defmodule OrcaHub.Probes do
  @moduledoc """
  Node-local, read-only probe primitives for git/filesystem/disk state —
  ORCAHUB3-28. Every function here runs entirely LOCALLY on whichever node
  it executes on; the cross-node part of "node-routed probes" is entirely
  `OrcaHub.Cluster.rpc/5`, called from `OrcaHub.MCP.Tools.Probes` on the
  CALLING node. Nothing here touches the database, a session, or a project
  struct — every function takes plain directory/path strings and returns
  plain data, so it stays trivially `Cluster.rpc`-able and unit-testable
  without DB fixtures.

  Path scoping and `NodePolicy` isolation are enforced by the CALLER
  (`OrcaHub.MCP.Tools.Probes`) before a call ever reaches across nodes —
  see that module's moduledoc for the policy and the reasoning behind it.
  This module has no opinion on WHICH directories are allowed; it just
  executes against whatever directory/path it's given.

  ## Injection-safety approach (ORCAHUB3-28's anti-requirement)

  This module never builds a shell command string, and a caller-supplied
  value is never allowed to stand in for a git/df FLAG. Every `System.cmd`
  call here passes a fixed argv list (no shell interpolation at all), and
  every value that could plausibly start with `-` is handled one of two
  ways: a **path** is always placed after a literal `"--"` pathspec
  separator, and a **git revision** (commit sha) is validated against a
  strict hex-only format (`valid_rev?/1`) BEFORE it ever reaches argv —
  flags always start with `-`, hex shas never do. This closes off the
  `-c core.pager=...` / `--upload-pack=...` / `--output=...` class of
  flag-injection the driving issue calls out, without resorting to a
  generic command allowlist. Revisions here are deliberately hex-sha-only
  (no branch names, no `HEAD~2`) — narrower than plain `git` accepts, but
  that narrowness is exactly what makes the validation airtight.
  """

  @max_log_entries 200
  @default_log_limit 20
  @max_stat_entries 50_000
  @default_stat_entries 5_000

  # ---------------------------------------------------------------------
  # git_probe primitives
  # ---------------------------------------------------------------------

  @doc "`git status --porcelain` for `directory` — `{:ok, %{clean:, entries:}}` or `{:error, reason}`."
  def git_status(directory) do
    with :ok <- ensure_repo(directory) do
      case System.cmd("git", ["status", "--porcelain"], cd: directory, stderr_to_stdout: true) do
        {output, 0} ->
          entries =
            output
            |> String.split("\n", trim: true)
            |> Enum.map(fn line ->
              {status, path} = String.split_at(line, 2)
              %{status: String.trim(status), path: String.trim(path)}
            end)

          {:ok, %{clean: entries == [], entries: entries}}

        {output, _} ->
          {:error, String.trim(output)}
      end
    end
  end

  @doc "Current HEAD sha/short_sha/subject for `directory` — `{:ok, %{sha:, short_sha:, subject:}}` or `{:error, reason}`."
  def git_head(directory) do
    with :ok <- ensure_repo(directory) do
      case System.cmd("git", ["log", "-1", "--format=%H%n%h%n%s"],
             cd: directory,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case String.split(String.trim(output), "\n", parts: 3) do
            [sha, short_sha, subject] ->
              {:ok, %{sha: sha, short_sha: short_sha, subject: subject}}

            _ ->
              {:error, "no commits in #{directory}"}
          end

        {output, _} ->
          {:error, String.trim(output)}
      end
    end
  end

  @doc """
  `git log` for `directory`, optionally scoped to `path` (a pathspec inside
  the repo). `limit` is clamped to 1..#{@max_log_entries} (default
  #{@default_log_limit}). Returns `{:ok, [%{hash:, short_hash:, subject:,
  author:, date:}, ...]}` or `{:error, reason}`.
  """
  def git_log(directory, path \\ nil, limit \\ @default_log_limit) do
    limit = clamp(limit || @default_log_limit, 1, @max_log_entries)

    with :ok <- ensure_repo(directory) do
      args =
        ["log", "--format=%H%n%h%n%s%n%an%n%aI", "--max-count=#{limit}"] ++
          if(path, do: ["--", path], else: [])

      case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
        {output, 0} -> {:ok, parse_log(output)}
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  @doc """
  Does `commit` (a hex sha, see `valid_rev?/1`) touch `path` in `directory`?
  Returns `{:ok, boolean}` or `{:error, reason}`.
  """
  def git_commit_touches_path?(directory, commit, path) do
    with :ok <- ensure_repo(directory),
         :ok <- validate_rev(commit) do
      case System.cmd(
             "git",
             ["diff-tree", "--no-commit-id", "--name-only", "-r", commit, "--", path],
             cd: directory,
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, String.trim(output) != ""}
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  @doc """
  Structured diff summary between two hex shas in `directory`, via
  `git diff --numstat` (per-file added/deleted line counts — more precise
  and easier to consume than the `--stat` ASCII bar chart, same underlying
  question). Returns `{:ok, %{files:, files_changed:, insertions:,
  deletions:}}` or `{:error, reason}`.
  """
  def git_diff_stat(directory, from_sha, to_sha) do
    with :ok <- ensure_repo(directory),
         :ok <- validate_rev(from_sha),
         :ok <- validate_rev(to_sha) do
      case System.cmd("git", ["diff", "--numstat", from_sha, to_sha],
             cd: directory,
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, parse_numstat(output)}
        {output, _} -> {:error, String.trim(output)}
      end
    end
  end

  @doc "Hex sha format check (4-40 hex chars) — the only revision shape this module ever accepts."
  def valid_rev?(rev), do: is_binary(rev) and Regex.match?(~r/^[0-9a-fA-F]{4,40}$/, rev)

  defp validate_rev(rev) do
    if valid_rev?(rev) do
      :ok
    else
      {:error, "invalid revision (must be a 4-40 character hex sha): #{inspect(rev)}"}
    end
  end

  # Deliberately asks git itself (`rev-parse --is-inside-work-tree`) rather
  # than a cheap `File.dir?(Path.join(directory, ".git"))` check — a git
  # WORKTREE's ".git" is a file (a `gitdir:` pointer), not a directory, and
  # this repo uses worktrees (`Project.git_create_worktree/2`), so the cheap
  # check would misreport every worktree as "not a repo".
  defp ensure_repo(directory) do
    if File.dir?(directory) do
      case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
             cd: directory,
             stderr_to_stdout: true
           ) do
        {"true\n", 0} -> :ok
        {output, _} -> {:error, "not a git repository: #{String.trim(output)}"}
      end
    else
      {:error, "not a directory: #{directory}"}
    end
  rescue
    ErlangError -> {:error, "not a directory: #{directory}"}
  end

  defp parse_log(""), do: []

  defp parse_log(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> Enum.chunk_every(5)
    |> Enum.filter(&(length(&1) == 5))
    |> Enum.map(fn [hash, short_hash, subject, author, date] ->
      %{hash: hash, short_hash: short_hash, subject: subject, author: author, date: date}
    end)
  end

  defp parse_numstat(output) do
    files =
      output
      |> String.trim()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, "\t", parts: 3) do
          [added, deleted, path] ->
            %{
              path: path,
              added: parse_numstat_count(added),
              deleted: parse_numstat_count(deleted),
              binary: added == "-"
            }

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      files: files,
      files_changed: length(files),
      insertions: Enum.reduce(files, 0, &(&2 + (&1.added || 0))),
      deletions: Enum.reduce(files, 0, &(&2 + (&1.deleted || 0)))
    }
  end

  defp parse_numstat_count("-"), do: nil
  defp parse_numstat_count(str), do: String.to_integer(str)

  # ---------------------------------------------------------------------
  # stat_paths primitives
  # ---------------------------------------------------------------------

  @doc """
  Batch metadata-only stat for `paths` — existence/type/size/mtime, never
  content. For a directory, also a BOUNDED recursive entry count + total
  size, capped at `max_entries` (default #{@default_stat_entries}, hard cap
  #{@max_stat_entries}) so probing something huge can't turn into an
  unbounded filesystem walk. Returns a plain list, same order as `paths`
  (never `{:ok, _}`/`{:error, _}` — a missing/unreadable path is just
  `%{exists: false}`, not a call failure).
  """
  def stat_paths(paths, max_entries \\ @default_stat_entries) do
    Enum.map(paths, &stat_path(&1, max_entries))
  end

  defp stat_path(path, max_entries) do
    max_entries = clamp(max_entries || @default_stat_entries, 1, @max_stat_entries)

    case File.stat(path, time: :posix) do
      {:error, _} ->
        %{path: path, exists: false}

      {:ok, %File.Stat{type: :directory} = stat} ->
        {entry_count, total_size, truncated} = walk_dir(path, max_entries)

        %{
          path: path,
          exists: true,
          type: "directory",
          mtime: posix_to_iso8601(stat.mtime),
          entry_count: entry_count,
          total_size_bytes: total_size,
          truncated: truncated
        }

      {:ok, stat} ->
        %{
          path: path,
          exists: true,
          type: to_string(stat.type),
          size_bytes: stat.size,
          mtime: posix_to_iso8601(stat.mtime)
        }
    end
  end

  defp walk_dir(root, cap), do: do_walk([root], 0, 0, cap)

  defp do_walk([], count, size, _cap), do: {count, size, false}
  defp do_walk(_stack, count, size, cap) when count >= cap, do: {count, size, true}

  defp do_walk([entry | rest], count, size, cap) do
    case File.stat(entry, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          case File.ls(entry) do
            {:ok, names} -> Enum.map(names, &Path.join(entry, &1))
            {:error, _} -> []
          end

        do_walk(children ++ rest, count, size, cap)

      {:ok, %File.Stat{size: sz}} ->
        do_walk(rest, count + 1, size + sz, cap)

      {:error, _} ->
        do_walk(rest, count, size, cap)
    end
  end

  defp posix_to_iso8601(nil), do: nil
  defp posix_to_iso8601(posix), do: posix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # ---------------------------------------------------------------------
  # disk_free primitive
  # ---------------------------------------------------------------------

  @doc """
  Free/used/total bytes for the filesystem containing `path`, via
  `df -kP -- path` (POSIX single-line format, 1024-byte blocks). Returns
  `{:ok, %{filesystem:, mounted_on:, total_bytes:, used_bytes:,
  available_bytes:}}` or `{:error, reason}`.
  """
  def disk_free(path) do
    case System.cmd("df", ["-kP", "--", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df(output)
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp parse_df(output) do
    lines = output |> String.trim() |> String.split("\n")

    case List.last(lines) do
      nil ->
        {:error, "no df output"}

      line ->
        case String.split(line) do
          [filesystem, total_kb, used_kb, avail_kb, _capacity | mounted_on_parts]
          when mounted_on_parts != [] ->
            {:ok,
             %{
               filesystem: filesystem,
               mounted_on: Enum.join(mounted_on_parts, " "),
               total_bytes: String.to_integer(total_kb) * 1024,
               used_bytes: String.to_integer(used_kb) * 1024,
               available_bytes: String.to_integer(avail_kb) * 1024
             }}

          _ ->
            {:error, "could not parse df output: #{inspect(line)}"}
        end
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)
end
