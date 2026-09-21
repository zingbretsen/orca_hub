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
