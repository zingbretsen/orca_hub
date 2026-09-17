defmodule OrcaHub.Projects.MoveSideEffects do
  @moduledoc """
  The OUT-OF-DATABASE consequences of moving a project's directory
  (`OrcaHub.Projects.DirectoryMove`).

  Everything OrcaHub owns in Postgres — the `directory` column on `projects`,
  `sessions`, `terminals` and `jobs` — is rewritten by `DirectoryMove` itself,
  inside one transaction. This module handles the state that lives OUTSIDE
  that transaction and outside OrcaHub entirely, keyed by the project's path:

    * **Claude's per-directory history/memory dir** — `~/.claude/projects/<slug>`
      on the project's own node, where `<slug>` is the working directory with
      every non-alphanumeric char replaced by `-`
      (`OrcaHub.AgentMemory.slugify/1`). After a move the old slug directory is
      orphaned: `--resume` finds no history and
      `OrcaHub.AgentMemory.claude_memory_dir/2` points at an empty path. It is
      renamed to the destination slug.
    * **The memory service's `project_slug`** — memories are namespaced by a
      slug of the project directory (`OrcaHub.MCP.Tools.Memory`'s `slug/1`,
      character-for-character the same transform as `AgentMemory.slugify/1`),
      so a moved project stops recalling its own memories until every memory's
      `project.slug` is repointed via `OrcaHub.MemoryClient`.

  ## Claude's slug convention is verified, not assumed

  `AgentMemory.slugify/1` is OrcaHub's reimplementation of a convention owned
  by Claude Code, so it was checked against reality (2026-09-17, claude-code
  2.1.259) rather than trusted: for every directory under a real
  `~/.claude/projects/` that contained a session `.jsonl`, the `cwd` recorded
  in that transcript was run through the same transform and compared to the
  directory name. 34 of 34 matched, 0 mismatches — including the cases most
  likely to break a naive implementation: `_` collapses to `-`
  (`/home/zach/orca_hub` -> `-home-zach-orca-hub`), the leading `/` produces a
  leading `-`, and case is PRESERVED (`/home/zach/experiments/Ideation` ->
  `-home-zach-experiments-Ideation`, not lowercased).

  One consequence worth knowing: the transform is lossy, so two different
  paths can share a slug (`/home/zach/orca_hub` and `/home/zach/orca-hub`
  both slugify to `-home-zach-orca-hub`). A move between two such paths is
  detected and reported as "nothing to do" rather than being mistaken for a
  destination collision.

  ## Codex and pi need no migration (investigated 2026-09-17)

  Neither was given a speculative migration, because neither was found to
  break:

    * **Codex** keys nothing off the working directory. Rollouts live at
      `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl` —
      date-partitioned, with `cwd` recorded only as metadata inside the file's
      `session_meta` line. `OrcaHub.Backend.Codex` resumes through the
      app-server protocol with `thread/resume` + `threadId` and passes `cwd`
      only on a fresh `thread/start`, so a resumed thread never looks itself
      up by path.
    * **pi** DOES key its own default session store off the cwd
      (`~/.pi/agent/sessions/--home-zach-orca_hub--`, a different and also
      lossy convention: `--` + the path minus its leading `/` with `/` -> `-`,
      underscores and dots preserved, + `--`). OrcaHub never uses that store:
      `OrcaHub.Backend.Pi` always passes `--session-dir
      <project directory>/.pi_sessions/<orca session id>`, which lives INSIDE
      the project directory and is therefore physically carried along by the
      move, and is recomputed from the rewritten `directory` on the next
      spawn. The cwd-keyed directories on this host are leftovers from
      pi invocations outside OrcaHub.

  ## Contract

    * `node` — the node the filesystem move ran on (`Project.node`, resolved
      via `OrcaHub.Cluster.project_node_for/1`). ALL filesystem work happens
      THERE, via `OrcaHub.Cluster.rpc/5` — never on whichever node happens to
      be running this code, and never re-routed to a different node if that
      one is down (a project is never silently re-assigned; an unreachable
      node becomes a warning note and the memory half still runs).
    * `from` / `to` — the normalized absolute source and destination.
    * `opts` — the same keyword list `DirectoryMove.move/3` was called with.
      Only `:home_dir` (the injectable base "home" directory, same pattern as
      `OrcaHub.AgentMemory`/`OrcaHub.NodeConfig`) and `:memory_client` (the
      module implementing `list/1`/`update/2`, for tests) are read; nothing
      else is forwarded over `:erpc`, so an anonymous fun in `opts` — e.g.
      `DirectoryMove`'s own `:rewrite_fun` — never crosses a node boundary.

  Returns `{:ok, notes}` where `notes` is a list of human-readable strings
  describing what was ACTUALLY done; they are merged into the move result's
  `:side_effects`. Anything that went wrong is a note too, prefixed
  `WARNING:` — the move and the database rewrite have already succeeded by
  the time this runs, so nothing here may fail the operation.

  Partial success is the normal case: the Claude rename and the memory
  migration are independent, each is individually guarded, and neither can
  prevent the other from running. `apply/4` never raises.
  """

  require Logger

  alias OrcaHub.AgentMemory
  alias OrcaHub.Cluster
  alias OrcaHub.MemoryClient

  # A rename of one directory to a sibling of itself; the generous part of
  # this budget is the erpc round trip, not the syscall.
  @fs_timeout 15_000

  # The memory service caps `per_page` at 200.
  @memory_page_size 200

  # Bounds the drain loop below at 200 * 100 = 20_000 memories for one
  # project. Far beyond any real project (the largest here has ~320), but a
  # loop that re-reads page 1 forever must have a hard stop.
  @memory_max_pages 100

  @doc """
  Runs every post-move side effect, best effort.

  See the moduledoc for the contract. Always returns `{:ok, notes}`.
  """
  @spec apply(node(), String.t(), String.t(), keyword()) :: {:ok, [String.t()]}
  def apply(node, from, to, opts \\ []) do
    notes =
      guarded("Claude history/memory directory", fn -> rename_claude_dir(node, from, to, opts) end) ++
        guarded("memory-service project slug", fn -> migrate_memories(from, to, opts) end)

    {:ok, notes}
  end

  # -------------------------------------------------------------------
  # Claude's ~/.claude/projects/<slug> directory
  # -------------------------------------------------------------------

  defp rename_claude_dir(node, from, to, opts) do
    args = [from, to, Keyword.take(opts, [:home_dir])]

    case Cluster.rpc(node, __MODULE__, :rename_claude_project_dir, args, @fs_timeout) do
      {:ok, :renamed, src, dst} ->
        ["Renamed Claude's history/memory directory #{src} -> #{dst}#{on_node(node)}."]

      {:ok, :same_slug, src} ->
        [
          "Claude's history/memory directory needed no change: #{from} and #{to} share the " <>
            "slug directory #{src}#{on_node(node)}."
        ]

      {:ok, :no_source, _src} ->
        # The overwhelmingly common case for a project that has never been
        # driven by Claude on that node. Not worth a note at all.
        []

      {:ok, :destination_exists, src, dst} ->
        [
          "WARNING: Claude's history/memory directory was NOT migrated — #{dst} already " <>
            "exists#{on_node(node)}, and merging two histories could corrupt both. The old " <>
            "history is still at #{src}; move or delete one of them by hand if you want the " <>
            "pre-move history back."
        ]

      {:error, reason} ->
        [
          "WARNING: could not migrate Claude's history/memory directory (" <>
            describe(reason) <>
            "). Claude sessions in #{to} will start with no history; the old history is still " <>
            "under the slug directory for #{from}."
        ]
    end
  end

  @doc """
  Renames `~/.claude/projects/<slug(from)>` to `~/.claude/projects/<slug(to)>`.

  Exported because it is the `:erpc` entry point for `rename_claude_dir/4` —
  it is meant to run ON THE PROJECT'S NODE, so `System.user_home!/0` resolves
  to that node's home directory rather than the hub's. Never raises; every
  outcome is a plain serializable tuple.

  Not part of this module's public surface — call `apply/4`.
  """
  def rename_claude_project_dir(from, to, opts) do
    src = claude_project_dir(from, opts)
    dst = claude_project_dir(to, opts)

    cond do
      # Lossy slug: two distinct paths can map to the same directory. Checked
      # BEFORE File.exists?(dst), which would otherwise read as a collision.
      src == dst ->
        {:ok, :same_slug, src}

      not File.dir?(src) ->
        {:ok, :no_source, src}

      # Never clobber and never merge: two interleaved histories are worse
      # than one orphaned one, and File.rename/2 onto an existing directory
      # has different semantics per OS besides.
      File.exists?(dst) ->
        {:ok, :destination_exists, src, dst}

      true ->
        do_rename(src, dst)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp do_rename(src, dst) do
    # src and dst are always siblings under ~/.claude/projects, so the parent
    # exists whenever src does — mkdir_p is for the case where it somehow
    # doesn't, and its failure is reported by the rename below either way.
    _ = File.mkdir_p(Path.dirname(dst))

    case File.rename(src, dst) do
      :ok -> {:ok, :renamed, src, dst}
      {:error, reason} -> {:error, "#{src} -> #{dst}: #{format_posix(reason)}"}
    end
  end

  # `Path.dirname(claude_memory_dir/2)` rather than rebuilding the path:
  # `claude_memory_dir/2` is `~/.claude/projects/<slug>/memory`, so its parent
  # IS the slug directory, and reusing it means the slug transform and the
  # injectable home-dir resolution (explicit `:home_dir` opt, then the
  # `:agent_memory_home` app env, then `System.user_home!/0`) can never drift
  # apart from the module that reads those directories.
  defp claude_project_dir(directory, opts) do
    directory
    |> AgentMemory.claude_memory_dir(Keyword.take(opts, [:home_dir]))
    |> Path.dirname()
  end

  # -------------------------------------------------------------------
  # memory-service project slug
  # -------------------------------------------------------------------

  # `OrcaHub.MCP.Tools.Memory`'s `slug/1` (`~r/[^a-zA-Z0-9]/`) and
  # `AgentMemory.slugify/1` (`~r/[^A-Za-z0-9]/`) are character-for-character
  # the same transform, so today there is exactly ONE namespace to migrate.
  # They are nonetheless computed independently and de-duplicated here: the
  # memory tool's version is private, so this module cannot call it, and if
  # the two ever drift apart a moved project would silently keep half its
  # memories under the old slug. Whatever distinct slugs exist get migrated.
  defp slugs_for(directory) do
    Enum.uniq([
      AgentMemory.slugify(directory),
      String.replace(directory, ~r/[^a-zA-Z0-9]/, "-")
    ])
  end

  defp migrate_memories(from, to, opts) do
    client = Keyword.get(opts, :memory_client, MemoryClient)
    to_slug = AgentMemory.slugify(to)

    from
    |> slugs_for()
    |> Enum.reject(&(&1 == to_slug))
    |> Enum.flat_map(&migrate_slug(client, &1, to_slug, from, to))
  end

  defp migrate_slug(client, from_slug, to_slug, from, to) do
    result =
      drain(client, from_slug, to_slug, from, to, %{migrated: 0, failed: []}, @memory_max_pages)

    cond do
      # No memory service configured on the hub, so nothing is namespaced by
      # this path at all. Silence, not a warning.
      result[:disabled] ->
        []

      result[:exhausted] || result.list_error != nil || result.failed != [] ->
        migrated_note(result.migrated, from_slug, to_slug) ++
          failure_note(result, from, to, to_slug)

      true ->
        migrated_note(result.migrated, from_slug, to_slug)
    end
  end

  defp migrated_note(0, _from_slug, _to_slug), do: []

  defp migrated_note(count, from_slug, to_slug) do
    [
      "Repointed #{count} memory-service #{pluralize(count, "memory", "memories")} from " <>
        "project slug #{from_slug} to #{to_slug}."
    ]
  end

  defp failure_note(result, from, to, to_slug) do
    detail =
      cond do
        result[:exhausted] ->
          "more than #{@memory_max_pages * @memory_page_size} memories were still listed under " <>
            "the old slug"

        result.list_error ->
          "listing them failed (#{describe(result.list_error)})"

        true ->
          failed = result.failed

          sample =
            failed
            |> Enum.take(3)
            |> Enum.map_join("; ", fn {id, r} -> "#{id}: #{describe(r)}" end)

          "#{length(failed)} could not be updated (#{sample}" <>
            if(length(failed) > 3, do: "; …", else: "") <> ")"
      end

    [
      "WARNING: the memory-service migration for #{from} -> #{to} did not finish — #{detail}. " <>
        "Some memories are still filed under the OLD project slug and will not be recalled in " <>
        "#{to} (which now looks for #{to_slug}); re-run the move's side effects or repoint them " <>
        "by hand."
    ]
  end

  # Always re-reads PAGE ONE rather than walking pages forward. A successful
  # update sets the memory's `updated_at`, and the listing is sorted by
  # `updated_at` desc — so a migrated memory would shuffle the pagination
  # underneath a forward walk AND drop out of the `project.slug` filter at the
  # same time, silently skipping memories. Re-reading page 1 turns the work
  # into a shrinking queue instead: each pass removes what it migrated.
  # Terminates on an empty page, on a page where nothing could be migrated (no
  # progress), or on the hard page cap.
  defp drain(_client, _from_slug, _to_slug, _from, _to, acc, 0),
    do: acc |> Map.put_new(:list_error, nil) |> Map.put(:exhausted, true)

  defp drain(client, from_slug, to_slug, from, to, acc, pages_left) do
    params = %{"project_slug" => from_slug, "per_page" => @memory_page_size, "page" => 1}

    case client.list(params) do
      {:ok, %{"memories" => []}} ->
        Map.put_new(acc, :list_error, nil)

      {:ok, %{"memories" => memories}} when is_list(memories) ->
        {migrated, failed} = migrate_page(client, memories, to_slug, from, to)
        acc = %{acc | migrated: acc.migrated + migrated, failed: acc.failed ++ failed}

        # No progress on a full page means every remaining memory is failing
        # the same way; another pass would just re-fail them forever.
        if migrated == 0 do
          Map.put_new(acc, :list_error, nil)
        else
          drain(client, from_slug, to_slug, from, to, acc, pages_left - 1)
        end

      {:ok, other} ->
        Map.put(acc, :list_error, {:unexpected_response, other})

      {:error, :disabled} ->
        acc |> Map.put(:list_error, nil) |> Map.put(:disabled, true)

      {:error, reason} ->
        Map.put(acc, :list_error, reason)

      other ->
        Map.put(acc, :list_error, {:unexpected_response, other})
    end
  end

  defp migrate_page(client, memories, to_slug, from, to) do
    Enum.reduce(memories, {0, []}, fn memory, {migrated, failed} ->
      id = memory["id"]
      attrs = %{"project" => new_project(memory["project"], to_slug, from, to)}

      case safe_update(client, id, attrs) do
        {:ok, _} -> {migrated + 1, failed}
        {:error, reason} -> {migrated, failed ++ [{id, reason}]}
      end
    end)
  end

  # PATCH /v1/memories/:id shallow-merges `project` as a WHOLE object (it is
  # one of the service's `@mutable_fields`), so the existing `id`/`name` must
  # be carried over or they would be dropped.
  #
  # `name` is only rewritten when it was clearly derived from the old path's
  # basename — `OrcaHub.MCP.Tools.Memory` uses the OrcaHub project's own
  # `name` when it knows the project, and only falls back to
  # `Path.basename(directory)` when it doesn't. A directory move never renames
  # the project row, so an explicit project name must survive untouched.
  defp new_project(project, to_slug, from, to) when is_map(project) do
    project
    |> Map.put("slug", to_slug)
    |> maybe_rename(from, to)
  end

  defp new_project(_project, to_slug, _from, to),
    do: %{"name" => Path.basename(to), "slug" => to_slug}

  defp maybe_rename(%{"name" => name} = project, from, to) do
    if name == Path.basename(from), do: Map.put(project, "name", Path.basename(to)), else: project
  end

  defp maybe_rename(project, _from, to), do: Map.put(project, "name", Path.basename(to))

  defp safe_update(_client, id, _attrs) when not is_binary(id), do: {:error, {:missing_id, id}}

  defp safe_update(client, id, attrs) do
    case client.update(id, attrs) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # -------------------------------------------------------------------
  # Shared helpers
  # -------------------------------------------------------------------

  # Each side effect is independently guarded so a crash in one still leaves
  # the other's notes intact — and so `apply/4` itself can honour its
  # never-raise contract without a single outer try that would swallow the
  # successful half's work along with the failed half's.
  defp guarded(label, fun) do
    fun.()
  rescue
    e ->
      Logger.error("MoveSideEffects #{label} raised: #{Exception.message(e)}")
      ["WARNING: the #{label} migration raised and was skipped: #{Exception.message(e)}"]
  catch
    kind, reason ->
      Logger.error("MoveSideEffects #{label} failed: #{kind} #{inspect(reason)}")
      ["WARNING: the #{label} migration failed and was skipped: #{kind} #{inspect(reason)}"]
  end

  # Never re-routes to another node: an unreachable node is reported as-is.
  defp describe({:node_unavailable, n}),
    do: "node #{n} is not reachable — it was NOT re-routed to another node"

  defp describe(:node_unassigned), do: "the project has no node assigned"

  defp describe({:rpc_undef, mfa}),
    do: "the node is running an older release without #{inspect(mfa)}"

  defp describe({:unexpected_response, other}), do: "unexpected response: #{inspect(other)}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp format_posix(reason) when is_atom(reason) do
    reason |> :file.format_error() |> to_string()
  end

  defp format_posix(reason), do: inspect(reason)

  defp on_node(n) when n == node(), do: ""
  defp on_node(n), do: " on #{n}"

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
end
