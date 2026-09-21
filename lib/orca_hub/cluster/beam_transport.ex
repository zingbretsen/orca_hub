defmodule OrcaHub.Cluster.BeamTransport do
  @moduledoc """
  The reconciler's view of `OrcaHub.Cluster.CodeSync`: a thin delegation
  layer plus the node-interrogation helpers that are not CodeSync's job.

  `OrcaHub.Cluster.CodePush` calls this module rather than CodeSync
  directly for two reasons that are worth keeping distinct.

  ## 1. The ERTS question is different at reconcile time

  `CodeSync.compatible?/1` — and therefore `CodeSync.push/3`'s built-in
  gate — compares the LOCAL node's ERTS against the target's. At push time
  that is exactly right: the beams were just compiled here, so "here vs
  there" is the real compatibility question.

  At reconcile time it is the wrong question. The beams come from a STORED
  generation, compiled on a machine that may no longer be connected, on a
  toolchain the hub itself may no longer be running (the hub gets redeployed
  on a new image while a generation sits in the database). The question is
  "GENERATION vs target", and the hub's own ERTS is not part of it.

  So `CodePush` checks `erts_version/1` against the generation's recorded
  version itself, and then calls `push/3` with `allow_erts_mismatch: true`
  — not to weaken the gate but because the gate it would otherwise apply is
  comparing the wrong pair. Skipping the local check without having done
  the generation check first would be a genuine hole; the two go together.

  ## 2. `built_at/1` has to mean the IMAGE, not the loaded code

  `OrcaHub.BuildInfo` is excluded from every push, so a node that has been
  hot-loaded still reports the timestamp its IMAGE was built with. That is
  precisely the quantity the no-downgrade check needs — "was this node's
  image built after the generation was published?" — and it only stays true
  for as long as `BuildInfo` remains unpushable. `excluded_modules/0` and
  this function are two ends of the same invariant: if `BuildInfo` ever
  became pushable, a generation could forge the evidence used to decide
  whether to apply it.
  """

  alias OrcaHub.Cluster.CodeSync

  # CodeSync excludes OrcaHub.BuildInfo itself; sanitize/1 re-applies it on
  # the DB-loaded path (entries rebuilt from stored rows never passed
  # through load_beams/1) and additionally sinks CodePush, which is not
  # CodeSync's business to know about.
  @excluded [OrcaHub.BuildInfo]
  @load_last [OrcaHub.Cluster.CodeSync, OrcaHub.Cluster.CodePush]
  @rpc_timeout 15_000

  @type entry :: CodeSync.entry()

  defdelegate load_beams(ebin_dir), to: CodeSync
  defdelegate compatible?(target), to: CodeSync
  defdelegate drift(entries, target), to: CodeSync
  defdelegate drift(entries, target, opts), to: CodeSync
  defdelegate push(entries, target, opts), to: CodeSync

  @doc """
  Renders one of CodeSync's error tuples as an operator-readable line.

  Prefer this over `inspect/1` anywhere a CodeSync error reaches a human —
  `{:erts_mismatch, _, _}` and `{:unreachable, _, _}` both have real prose.
  """
  defdelegate describe_error(reason), to: CodeSync

  @doc """
  Compares two ERTS version strings, exactly. Reused rather than
  re-implemented so the reconciler's generation-vs-target check applies
  literally the same bar as CodeSync's local-vs-target one.
  """
  defdelegate erts_verdict(expected, actual), to: CodeSync

  @doc "The ERTS version string running on `target`."
  @spec erts_version(node) :: {:ok, String.t()} | {:error, term}
  def erts_version(target) when target == node(),
    do: {:ok, List.to_string(:erlang.system_info(:version))}

  def erts_version(target) do
    with {:ok, v} <- rpc(target, :erlang, :system_info, [:version]), do: {:ok, List.to_string(v)}
  end

  @doc """
  When `target`'s image was built, per `OrcaHub.BuildInfo.built_at/0`.

  `{:error, reason}` when the node is unreachable or reports something
  unparseable — never a defaulted timestamp. A caller has to decide for
  itself what an unknown build time means; silently substituting one would
  make the no-downgrade check lie in whichever direction the default
  happened to fall.
  """
  @spec built_at(node) :: {:ok, DateTime.t()} | {:error, term}
  def built_at(target) do
    case rpc(target, OrcaHub.BuildInfo, :built_at, []) do
      {:ok, raw} when is_binary(raw) ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, reason} -> {:error, {:unparseable_built_at, raw, reason}}
        end

      {:ok, other} ->
        {:error, {:unparseable_built_at, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc "The git SHA `target`'s image was built from, per `OrcaHub.BuildInfo`."
  @spec sha(node) :: {:ok, String.t()} | {:error, term}
  def sha(target) do
    with {:ok, raw} <- rpc(target, OrcaHub.BuildInfo, :sha, []), do: {:ok, to_string(raw)}
  end

  @doc """
  Every `:orca_hub` module `target` could currently execute.

  Two sources, unioned, because neither alone is complete:

    * the application's declared module list (`:application.get_key/2`) —
      cheap and authoritative for what the node's IMAGE contains, but blind
      to anything a previous generation hot-loaded;
    * loaded modules under the `OrcaHub` namespace (`:code.all_loaded/0`) —
      catches exactly that case, i.e. a module introduced by generation N
      and deleted from source by generation N+1, which appears in no `.app`
      file anywhere yet is still resident and still callable.

  That second case is the entire reason orphan detection exists, so
  dropping the `all_loaded` call to save a round trip would remove the only
  thing the cheap source cannot see.

  The namespace filter is applied HERE rather than on the target, because
  shipping an anonymous function to a node whose code version we are
  actively unsure of is precisely the situation to avoid.
  """
  @spec resident_modules(node) :: {:ok, MapSet.t(module)} | {:error, term}
  def resident_modules(target) do
    with {:ok, declared} <- declared_modules(target),
         {:ok, loaded} <- loaded_orca_modules(target) do
      {:ok, MapSet.union(MapSet.new(declared), MapSet.new(loaded))}
    end
  end

  defp declared_modules(target) do
    case rpc(target, :application, :get_key, [:orca_hub, :modules]) do
      {:ok, {:ok, mods}} when is_list(mods) -> {:ok, mods}
      # `:undefined` means the app isn't loaded there — not an error, just
      # nothing to declare. The all_loaded half still applies.
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp loaded_orca_modules(target) do
    with {:ok, loaded} <- rpc(target, :code, :all_loaded, []) do
      {:ok, for({mod, path} <- loaded, orca_module?(mod), beam_backed?(path), do: mod)}
    end
  end

  # Only code that came from a BEAM ARTIFACT counts as resident for orphan
  # purposes — a real `.beam` on disk, or the `generation://….beam` path a
  # previous reconcile loaded under.
  #
  # `:code.all_loaded/0` reports an EMPTY path for anything compiled in
  # memory: a `.exs` script, a module built at runtime by `Code.compile_*`,
  # an ExUnit test module. None of that was ever part of a generation, so
  # none of it is ours to unload — and the consequence of getting this wrong
  # is not theoretical. Without this filter the orphan set swept up the very
  # test module driving the purge and unloaded it mid-run, because a test
  # module is `Elixir.OrcaHub.…`, is resident, and appears in no generation.
  # Anything holding those three properties in production would be purged
  # just as happily.
  # `:preloaded` / `:cover_compiled` arrive as atoms rather than paths and
  # fall through to the catch-all, which is the right answer for both.
  defp beam_backed?(path) when is_list(path),
    do: path |> to_string() |> String.ends_with?(".beam")

  defp beam_backed?(_path), do: false

  defp orca_module?(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir.OrcaHub." <> _ -> true
      "Elixir.OrcaHubWeb." <> _ -> true
      "Elixir.OrcaHub" -> true
      _ -> false
    end
  end

  @doc """
  Unloads `module` on `target` WITHOUT killing anything.

  The two-phase OTP removal, with `:code.soft_purge/1` on both ends and
  `:code.purge/1` nowhere:

    1. soft-purge any existing old code — `false` here means processes are
       still running it, so nothing is touched and `:wedged` comes back;
    2. `:code.delete/1`, after which no NEW call can reach the module;
    3. soft-purge again to actually drop it. `false` at this point yields
       `:deleted_not_purged`, an honest intermediate state rather than a
       failure: the module is already uncallable for new work, and its old
       code goes away on its own once the processes on it exit.

  Never `:code.purge/1`. Purging kills every process still running the old
  code, and "this module is no longer in the desired generation" is nowhere
  near a good enough reason to kill a mid-turn session runner.
  """
  @spec unload(node, module) :: {:ok, :purged | :deleted_not_purged} | {:error, :wedged | term}
  def unload(target, module) do
    with {:ok, true} <- rpc(target, :code, :soft_purge, [module]),
         {:ok, _} <- rpc(target, :code, :delete, [module]) do
      case rpc(target, :code, :soft_purge, [module]) do
        {:ok, true} -> {:ok, :purged}
        {:ok, false} -> {:ok, :deleted_not_purged}
        {:error, _} = error -> error
      end
    else
      {:ok, false} -> {:error, :wedged}
      {:error, _} = error -> error
    end
  end

  @doc """
  Drops never-pushable modules and sinks the modules that participate in
  their own push to the end of the payload. See the moduledoc.
  """
  @spec sanitize([entry]) :: [entry]
  def sanitize(entries) do
    entries
    |> Enum.reject(&(&1.module in @excluded))
    |> Enum.sort_by(fn %{module: mod} -> Enum.find_index(@load_last, &(&1 == mod)) || -1 end)
  end

  @doc "Modules that are never included in a payload."
  def excluded_modules, do: @excluded

  defp rpc(target, mod, fun, args) do
    {:ok, :erpc.call(target, mod, fun, args, @rpc_timeout)}
  catch
    kind, reason -> {:error, {:unreachable, target, {kind, reason}}}
  end
end
