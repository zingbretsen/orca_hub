defmodule OrcaHub.Projects.DirectoryMove do
  @moduledoc """
  Moves (renames or relocates) a project's directory on disk and keeps every
  OrcaHub row that points into it consistent.

  Editing `project.directory` through the ordinary project form only rewrites
  ONE column: nothing moves on disk, and every `sessions.directory` /
  `terminals.directory` / `jobs.directory` row under the old path is silently
  left dangling. This module does the whole operation:

      preflight/plan  ->  filesystem move  ->  DB prefix rewrite  ->  side effects

  ## Shape

  `plan/2` and `move/3` both return `{:ok, map}` with exactly these keys:

      %{
        from: String.t(),       # normalized absolute source
        to: String.t(),         # normalized absolute destination
        node: atom(),           # node the filesystem move runs/ran on
        projects: [%{id:, name:, from:, to:}],
        sessions: non_neg_integer(),
        terminals: non_neg_integer(),
        jobs: non_neg_integer(),
        blockers: [String.t()],
        warnings: [String.t()],
        side_effects: [String.t()]
      }

  `plan/2` mutates nothing and always returns `side_effects: []`. `move/3`
  refuses (`{:error, {:blocked, msg}}`) when `blockers` is non-empty unless
  `force: true`, in which case the blockers are copied into `warnings`.

  Errors are `{:error, {reason, message}}` where `message` is ready to surface
  to a human. Reasons: `:node_unavailable`, `:invalid_path`, `:same_directory`,
  `:source_missing`, `:not_a_directory`, `:destination_exists`,
  `:destination_parent_missing`, `:nested_destination`, `:blocked`,
  `:move_failed`, `:rewrite_failed`.

  ## Node ownership

  Every filesystem operation runs on `Cluster.project_node_for(project)` via
  `Cluster.rpc/5` — never locally when the project belongs to another node, and
  never re-routed to a reachable node when that one is down (a project is never
  silently re-assigned; an unavailable node is an error, not a fallback).
  Database work goes through `HubRPC`, since `Repo` is hub-owned and this may
  be invoked from an agent node.

  ## Prefix rewrite

  The rewrite matches `directory = from` OR `directory` under `from <> "/"`,
  and replaces only that leading prefix — anchored at a `/` boundary, so moving
  `/a/foo` leaves `/a/foobar` completely alone. It deliberately catches rows
  belonging to OTHER projects nested under the moved directory (including git
  worktrees under `.worktrees/`): those directories physically moved too, so
  their rows must follow. Every affected project row is listed in `:projects`.
  All four tables are rewritten in ONE transaction, one `update_all` each.

  ## Live work

  A session mid-turn, a running terminal PTY, or a non-terminal job inside the
  moved subtree is a blocker — their processes hold the OLD inode as their cwd.
  Beyond that, any session with a LIVE runner (including an idle-but-warm one)
  caches `data.directory` in the runner's state and in a warm port's cwd, so
  each one is stopped on its OWN runner node before the move; the next message
  cold-spawns a fresh runner that reads the new directory from the DB. What was
  stopped is recorded in `:warnings`.
  """

  import Ecto.Query

  require Logger

  alias OrcaHub.Cluster
  alias OrcaHub.HubRPC
  alias OrcaHub.Jobs.Job
  alias OrcaHub.Projects.MoveSideEffects
  alias OrcaHub.Projects.Project
  alias OrcaHub.Repo
  alias OrcaHub.SessionSupervisor
  alias OrcaHub.Sessions.Session
  alias OrcaHub.Terminals.Terminal

  # Persisted session statuses that mean a turn is in flight. `waiting` and
  # `compacting` are overlaid statuses rather than GenStatem states, but all
  # three mean the CLI process is alive with the old directory as its cwd —
  # see `.context/session-lifecycle.md`.
  @live_session_statuses ~w(running waiting compacting)

  # `OrcaHub.Jobs.Job.nonterminal_statuses/0` — a detached OS process is still
  # running (or being verified) out of the job's directory.
  @live_job_statuses ~w(running verifying)

  @type result :: %{
          from: String.t(),
          to: String.t(),
          node: atom(),
          projects: [%{id: String.t(), name: String.t(), from: String.t(), to: String.t()}],
          sessions: non_neg_integer(),
          terminals: non_neg_integer(),
          jobs: non_neg_integer(),
          blockers: [String.t()],
          warnings: [String.t()],
          side_effects: [String.t()]
        }

  @type error :: {:error, {atom(), String.t()}}

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Dry run: validates the move and reports everything it would touch, without
  mutating anything (no filesystem call beyond `stat`, no DB write).
  """
  @spec plan(Project.t() | %Project{}, String.t()) :: {:ok, result()} | error()
  def plan(%Project{} = project, destination) do
    with {:ok, ctx} <- preflight(project, destination), do: {:ok, ctx.plan}
  end

  @doc """
  Performs the move: stops live runners in the subtree, moves the directory on
  the project's node, then rewrites every `directory` row under it.

  Options:

    * `force: true` — proceed despite blockers (they move into `:warnings`).

  Internal test seam (not part of the public contract): `rewrite_fun` — a
  2-arity `(from, to) -> {:ok, counts} | {:error, message}` replacing the DB
  rewrite, used to exercise the rollback path.
  """
  @spec move(Project.t() | %Project{}, String.t(), keyword()) :: {:ok, result()} | error()
  def move(%Project{} = project, destination, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, ctx} <- preflight(project, destination),
         {:ok, ctx} <- check_blockers(ctx, force) do
      do_move(ctx, opts)
    end
  end

  # -------------------------------------------------------------------
  # Preflight
  # -------------------------------------------------------------------

  defp preflight(%Project{} = project, destination) do
    with {:ok, from} <- normalize_source(project),
         {:ok, to} <- normalize_destination(destination),
         :ok <- validate_pair(from, to),
         node <- Cluster.project_node_for(project),
         :ok <- check_filesystem(node, from, to),
         {:ok, scan} <- scan_db(node, from) do
      {:ok, build_context(project, node, from, to, scan)}
    end
  end

  defp normalize_source(%Project{directory: directory}) when is_binary(directory) do
    trimmed = String.trim(directory)

    cond do
      trimmed == "" ->
        {:error, {:invalid_path, "This project has no directory set."}}

      not String.starts_with?(trimmed, "/") ->
        {:error,
         {:invalid_path,
          "This project's directory (#{trimmed}) is not an absolute path, so it cannot be moved."}}

      true ->
        {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_source(_),
    do: {:error, {:invalid_path, "This project has no directory set."}}

  defp normalize_destination(destination) when is_binary(destination) do
    trimmed = String.trim(destination)

    cond do
      trimmed == "" ->
        {:error, {:invalid_path, "Enter a destination directory."}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid_path, "The destination path contains a null byte."}}

      # Deliberately no `~` expansion: `Path.expand/1` would resolve it against
      # THIS node's home directory, which is the wrong machine whenever the
      # project lives on another node.
      not String.starts_with?(trimmed, "/") ->
        {:error,
         {:invalid_path,
          "The destination must be an absolute path starting with \"/\" (got: #{trimmed})."}}

      true ->
        {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_destination(_),
    do: {:error, {:invalid_path, "The destination must be a path string."}}

  defp validate_pair(from, to) do
    cond do
      from == to ->
        {:error,
         {:same_directory, "The destination is the same as the current directory (#{from})."}}

      String.starts_with?(to, from <> "/") ->
        {:error,
         {:nested_destination,
          "The destination (#{to}) is inside the directory being moved (#{from})."}}

      true ->
        :ok
    end
  end

  defp check_filesystem(node, from, to) do
    case Cluster.rpc(node, __MODULE__, :fs_preflight, [from, to]) do
      %{} = stat -> interpret_fs_preflight(stat, node, from, to)
      {:error, reason} -> {:error, {:node_unavailable, node_unavailable_message(node, reason)}}
    end
  end

  defp interpret_fs_preflight(stat, node, from, to) do
    where = on_node(node)

    cond do
      not stat.source_exists ->
        {:error, {:source_missing, "#{from} does not exist#{where}."}}

      not stat.source_is_dir ->
        {:error, {:not_a_directory, "#{from} is not a directory#{where}."}}

      stat.destination_exists ->
        {:error, {:destination_exists, "#{to} already exists#{where}."}}

      not stat.destination_parent_is_dir ->
        {:error,
         {:destination_parent_missing,
          "The destination's parent directory (#{Path.dirname(to)}) does not exist#{where} — " <>
            "create it first."}}

      true ->
        :ok
    end
  end

  defp scan_db(node, from) do
    case HubRPC.call(__MODULE__, :scan, [from], timeout: 30_000) do
      %{} = scan -> {:ok, scan}
      other -> {:error, {:rewrite_failed, "Could not inspect affected rows: #{inspect(other)}"}}
    end
  rescue
    e ->
      {:error,
       {:rewrite_failed,
        "Could not inspect affected rows#{on_node(node)}: " <> Exception.message(e)}}
  end

  defp build_context(project, node, from, to, scan) do
    projects =
      Enum.map(scan.projects, fn p ->
        %{id: p.id, name: p.name, from: p.directory, to: rewrite_path(p.directory, from, to)}
      end)

    blockers = blockers_for(scan)
    warnings = plan_warnings(project, scan, projects)

    plan = %{
      from: from,
      to: to,
      node: node,
      projects: projects,
      sessions: scan.sessions,
      terminals: scan.terminals,
      jobs: scan.jobs,
      blockers: blockers,
      warnings: warnings,
      side_effects: []
    }

    %{project: project, node: node, from: from, to: to, scan: scan, plan: plan}
  end

  defp blockers_for(scan) do
    Enum.map(scan.live_sessions, fn s ->
      "session #{session_label(s)} is #{s.status}"
    end) ++
      Enum.map(scan.live_terminals, fn t ->
        "terminal #{t.name || t.id} (#{t.id}) is running"
      end) ++
      Enum.map(scan.live_jobs, fn j ->
        "job #{job_label(j)} is #{j.status}"
      end)
  end

  defp plan_warnings(project, scan, projects) do
    other_projects = Enum.reject(projects, &(&1.id == project.id))

    nested_warning =
      if other_projects == [] do
        []
      else
        [
          "#{length(other_projects)} other project row(s) live under this directory and will " <>
            "be rewritten too: " <>
            Enum.map_join(other_projects, ", ", &"#{&1.name} (#{&1.from})")
        ]
      end

    terminal_warning =
      if scan.live_terminals == [] do
        []
      else
        [
          "#{length(scan.live_terminals)} terminal(s) have a running PTY in the old directory; " <>
            "their shell keeps the old working directory until it is stopped and restarted."
        ]
      end

    job_warning =
      if scan.live_jobs == [] do
        []
      else
        [
          "#{length(scan.live_jobs)} job(s) are detached OS processes already running out of " <>
            "the old directory; moving it does not relocate a running process."
        ]
      end

    nested_warning ++ terminal_warning ++ job_warning
  end

  defp check_blockers(%{plan: %{blockers: []}} = ctx, _force), do: {:ok, ctx}

  defp check_blockers(%{plan: %{blockers: blockers}} = ctx, true) do
    forced =
      Enum.map(blockers, &("forced past blocker: " <> &1)) ++
        ["Moved with force: true — live work above was interrupted, not waited for."]

    {:ok, put_in(ctx.plan.warnings, ctx.plan.warnings ++ forced)}
  end

  defp check_blockers(%{plan: %{blockers: blockers}}, _force) do
    {:error,
     {:blocked,
      "Refusing to move: live work is using this directory (" <>
        Enum.join(blockers, "; ") <> "). Stop it first, or move with force."}}
  end

  # -------------------------------------------------------------------
  # Move
  # -------------------------------------------------------------------

  defp do_move(ctx, opts) do
    %{node: node, from: from, to: to} = ctx

    ctx = put_in(ctx.plan.warnings, ctx.plan.warnings ++ stop_live_runners(ctx))

    case Cluster.rpc(node, __MODULE__, :fs_move, [from, to], 60_000) do
      :ok ->
        finish_move(ctx, opts)

      {:fs_error, message} ->
        {:error, {:move_failed, "Could not move #{from} to #{to}#{on_node(node)}: #{message}"}}

      {:error, reason} ->
        {:error, {:node_unavailable, node_unavailable_message(node, reason)}}
    end
  end

  defp finish_move(ctx, opts) do
    %{node: node, from: from, to: to} = ctx
    rewrite_fun = Keyword.get(opts, :rewrite_fun, &default_rewrite/2)

    case safe_rewrite(rewrite_fun, from, to) do
      {:ok, counts} ->
        {:ok, complete(ctx, counts, opts)}

      {:error, message} ->
        {:error, {:rewrite_failed, rewrite_failed_message(node, from, to, message)}}
    end
  end

  defp safe_rewrite(rewrite_fun, from, to) do
    case rewrite_fun.(from, to) do
      {:ok, counts} -> {:ok, counts}
      {:error, message} -> {:error, to_message(message)}
      other -> {:error, "unexpected rewrite result: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # `Repo` is hub-owned, so both DB halves go through HubRPC (which is a plain
  # local `apply/3` on the hub and an `:erpc` to it from an agent node) — a
  # move driven from an agent node behaves exactly like one driven from the
  # hub. `HubRPC.call/4` directly rather than a named wrapper: the rewrite
  # touches four tables in one transaction and wants its own erpc budget.
  defp default_rewrite(from, to),
    do: HubRPC.call(__MODULE__, :rewrite, [from, to], timeout: 60_000)

  # The on-disk move already succeeded, so leaving it moved with stale rows
  # everywhere is the worst outcome — put the directory back and say plainly
  # whether that worked.
  defp rewrite_failed_message(node, from, to, message) do
    rollback =
      case Cluster.rpc(node, __MODULE__, :fs_move, [to, from], 60_000) do
        :ok ->
          "The directory was moved back to #{from}, so nothing is out of sync."

        {:fs_error, reason} ->
          "ROLLBACK FAILED: the directory is still at #{to} but the database still points at " <>
            "#{from} (#{reason}) — move it back by hand."

        {:error, reason} ->
          "ROLLBACK FAILED: could not reach the node to move the directory back (" <>
            node_unavailable_message(node, reason) <>
            ") — the directory is still at #{to} " <>
            "while the database still points at #{from}."
      end

    "The directory moved, but rewriting the database failed (#{message}). " <> rollback
  end

  defp complete(ctx, counts, opts) do
    %{node: node, from: from, to: to, plan: plan} = ctx

    {side_effects, side_effect_warnings} = run_side_effects(node, from, to, opts)

    result = %{
      plan
      | sessions: counts.sessions,
        terminals: counts.terminals,
        jobs: counts.jobs,
        warnings: plan.warnings ++ side_effect_warnings,
        side_effects: side_effects
    }

    broadcast(ctx, result)
    result
  end

  # Best effort by contract: the move is already done and the DB is already
  # rewritten, so nothing here may fail the operation.
  defp run_side_effects(node, from, to, opts) do
    case MoveSideEffects.apply(node, from, to, opts) do
      {:ok, notes} when is_list(notes) ->
        {notes, []}

      # Today's stub can only return {:ok, []}; this covers the follow-up
      # worker's real implementation failing without taking the move with it.
      other ->
        {[], ["Post-move side effects did not succeed: #{describe_side_effect_result(other)}"]}
    end
  rescue
    e ->
      Logger.error("DirectoryMove side effects raised: #{Exception.message(e)}")
      {[], ["Post-move side effects raised: #{Exception.message(e)}"]}
  catch
    kind, reason ->
      Logger.error("DirectoryMove side effects exited: #{kind} #{inspect(reason)}")
      {[], ["Post-move side effects failed: #{kind} #{inspect(reason)}"]}
  end

  # -------------------------------------------------------------------
  # Runner eviction
  # -------------------------------------------------------------------

  # A live SessionRunner caches its working directory in `data.directory` and,
  # when streaming, holds a warm port whose cwd is the OLD inode. Evicting only
  # the warm port would leave the stale `data.directory` behind, so the runner
  # itself is stopped (SessionSupervisor.stop_session/1, the existing API the
  # UI/cluster layer already uses) and the next message cold-spawns a fresh one
  # that reads the rewritten directory from the DB.
  defp stop_live_runners(%{scan: scan}) do
    scan.runner_sessions
    |> Enum.group_by(& &1.runner_node, & &1.id)
    |> Enum.flat_map(fn {runner_node, session_ids} ->
      stop_runners_on_node(runner_node, session_ids)
    end)
  end

  defp stop_runners_on_node(nil, session_ids) do
    ["#{length(session_ids)} session(s) have no assigned node; their runners were not checked."]
  end

  defp stop_runners_on_node(runner_node, session_ids) do
    node_atom = String.to_atom(runner_node)

    case Cluster.rpc(node_atom, __MODULE__, :stop_runners, [session_ids], 30_000) do
      results when is_list(results) ->
        Enum.map(results, fn
          {:stopped, id} ->
            "Stopped the live session runner for #{id} on #{runner_node} so its next turn " <>
              "cold-starts in the new directory."

          {:failed, id, reason} ->
            "Could not stop the live session runner for #{id} on #{runner_node} (#{reason}); " <>
              "it may keep using the old directory until it is restarted."
        end)

      {:error, reason} ->
        [
          "Could not reach #{runner_node} to stop #{length(session_ids)} session runner(s) (" <>
            node_unavailable_message(node_atom, reason) <>
            "); any live runner there may keep using the old directory until it is restarted."
        ]
    end
  end

  @doc false
  # Runs ON the session's own runner node.
  def stop_runners(session_ids) do
    Enum.flat_map(session_ids, fn id ->
      if SessionSupervisor.session_alive?(id) do
        case SessionSupervisor.stop_session(id) do
          :ok -> [{:stopped, id}]
          other -> [{:failed, id, inspect(other)}]
        end
      else
        []
      end
    end)
  end

  # -------------------------------------------------------------------
  # Filesystem (runs on the project's node)
  # -------------------------------------------------------------------

  @doc false
  def fs_preflight(from, to) do
    %{
      source_exists: File.exists?(from),
      source_is_dir: File.dir?(from),
      # lstat, so a dangling symlink at the destination still counts as taken.
      destination_exists: match?({:ok, _}, File.lstat(to)),
      destination_parent_is_dir: File.dir?(Path.dirname(to))
    }
  end

  @doc false
  def fs_move(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      # Cross-filesystem rename: fall back to `mv`, which copies + unlinks.
      {:error, :exdev} ->
        case System.cmd("mv", ["--", from, to], stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, code} -> {:fs_error, "mv exited #{code}: #{String.trim(out)}"}
        end

      {:error, reason} ->
        {:fs_error, :file.format_error(reason) |> to_string()}
    end
  end

  # -------------------------------------------------------------------
  # Database (runs on the hub, via HubRPC)
  # -------------------------------------------------------------------

  @doc """
  Hub-side scan of everything under `from`. Always reached through
  `OrcaHub.HubRPC.call/4`, never called directly by a caller on an agent node
  (there is no `Repo` there).
  """
  def scan(from) do
    %{
      projects:
        Repo.all(
          from(p in subtree(Project, from),
            select: %{id: p.id, name: p.name, directory: p.directory},
            order_by: [asc: p.directory]
          )
        ),
      sessions: Repo.aggregate(subtree(Session, from), :count, :id),
      terminals: Repo.aggregate(subtree(Terminal, from), :count, :id),
      jobs: Repo.aggregate(subtree(Job, from), :count, :id),
      live_sessions:
        Repo.all(
          from(s in subtree(Session, from),
            where: s.status in ^@live_session_statuses and is_nil(s.archived_at),
            select: %{id: s.id, title: s.title, status: s.status}
          )
        ),
      live_terminals:
        Repo.all(
          from(t in subtree(Terminal, from),
            where: t.status == "running",
            select: %{id: t.id, name: t.name}
          )
        ),
      live_jobs:
        Repo.all(
          from(j in subtree(Job, from),
            where: j.status in ^@live_job_statuses,
            select: %{id: j.id, label: j.label, command: j.command, status: j.status}
          )
        ),
      # Candidates for runner eviction: any non-archived session in the subtree
      # may have a live runner, including an idle-but-warm one.
      runner_sessions:
        Repo.all(
          from(s in subtree(Session, from),
            where: is_nil(s.archived_at),
            select: %{id: s.id, runner_node: s.runner_node}
          )
        )
    }
  end

  @doc """
  Hub-side prefix rewrite of all four `directory` columns, in ONE transaction,
  one `update_all` per table. Always reached through `OrcaHub.HubRPC.call/4`.

  Returns `{:ok, %{projects: n, sessions: n, terminals: n, jobs: n}}` or
  `{:error, message}`.
  """
  def rewrite(from, to) do
    case Repo.transaction(fn ->
           %{
             projects: rewrite_table(Project, from, to),
             sessions: rewrite_table(Session, from, to),
             terminals: rewrite_table(Terminal, from, to),
             jobs: rewrite_table(Job, from, to)
           }
         end) do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp rewrite_table(schema, from, to) do
    # `substring(directory from <length(from) + 1>)` keeps everything after the
    # matched prefix — the WHERE clause guarantees every matched row starts
    # with it. Character offsets (String.length/1), not bytes: Postgres'
    # `substring(text from int)` counts characters.
    offset = String.length(from) + 1

    query =
      from(r in subtree(schema, from),
        update: [
          set: [
            directory:
              fragment(
                # `?::int` because Ecto renders an :integer param as bigint,
                # and Postgres' substring(text, bigint) has no overload.
                "? || substring(? from ?::int)",
                type(^to, :string),
                r.directory,
                type(^offset, :integer)
              )
          ]
        ]
      )

    # `updated_at` is deliberately NOT bumped: the sessions index groups by
    # directory and sorts by recency, so touching it would reshuffle every
    # moved session to the top for a change the user didn't make to the work.
    {count, _} = Repo.update_all(query, [])
    count
  end

  # -------------------------------------------------------------------
  # Query helpers
  # -------------------------------------------------------------------

  # `directory = from OR directory LIKE from || '/%'` — anchored at a `/`
  # boundary, so moving `/a/foo` never matches `/a/foobar`. LIKE
  # metacharacters in `from` are escaped (Postgres' default LIKE escape is a
  # backslash): real project paths contain `_` all the time
  # (`/home/zach/orca_hub`), and an unescaped `_` matches ANY character, which
  # would drag unrelated sibling directories into the rewrite.
  defp subtree(queryable, from) do
    pattern = escape_like(from) <> "/%"

    from(r in queryable, where: r.directory == ^from or like(r.directory, ^pattern))
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp rewrite_path(directory, from, to) do
    if directory == from do
      to
    else
      to <> String.replace_prefix(directory, from, "")
    end
  end

  # -------------------------------------------------------------------
  # Broadcasts
  # -------------------------------------------------------------------

  defp broadcast(ctx, result) do
    payload = %{
      project_id: ctx.project.id,
      from: result.from,
      to: result.to,
      node: result.node
    }

    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "projects",
      {ctx.project.id, {:project_directory_moved, payload}}
    )

    # The sessions/terminals index+show LiveViews reload on any message on
    # these topics — same shape the session/terminal update paths broadcast.
    Enum.each(ctx.scan.runner_sessions, fn s ->
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{s.id}",
        {:directory_moved, payload}
      )

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "sessions",
        {s.id, {:directory_moved, payload}}
      )
    end)

    # ProjectLive.Show only subscribes to "sessions" today, so a project with
    # no sessions under the moved path still needs a nudge there.
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "sessions",
      {ctx.project.id, {:project_directory_moved, payload}}
    )

    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "terminals",
      {ctx.project.id, {:project_directory_moved, payload}}
    )

    :ok
  end

  # -------------------------------------------------------------------
  # Misc
  # -------------------------------------------------------------------

  defp session_label(%{id: id, title: title}) when is_binary(title) and title != "",
    do: "#{title} (#{id})"

  defp session_label(%{id: id}), do: id

  defp job_label(%{id: id, label: label}) when is_binary(label) and label != "",
    do: "#{label} (#{id})"

  defp job_label(%{id: id, command: command}) when is_binary(command),
    do: "#{String.slice(command, 0, 60)} (#{id})"

  defp job_label(%{id: id}), do: id

  defp on_node(node) do
    if node == node(), do: "", else: " on #{Cluster.node_name(node)}"
  end

  defp node_unavailable_message(node, reason) do
    Cluster.node_unavailable_message(reason) ||
      "The project's node (#{Cluster.node_name(node)}) could not be used: #{inspect(reason)}"
  end

  defp to_message(message) when is_binary(message), do: message
  defp to_message(message), do: inspect(message)

  defp describe_side_effect_result(result) do
    case result do
      {:error, reason} -> to_message(reason)
      other -> inspect(other)
    end
  end
end
