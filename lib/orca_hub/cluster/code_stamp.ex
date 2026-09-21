defmodule OrcaHub.Cluster.CodeStamp do
  @moduledoc """
  What code a node is ACTUALLY running — the per-node counterpart to
  `OrcaHub.BuildInfo`.

  `OrcaHub.BuildInfo.sha/0` is a compile-time module attribute baked when
  the release image was built, and it is deliberately never pushed (see
  `OrcaHub.Cluster.BeamTransport`). That makes it a truthful answer to "what
  image did this node boot from" and a false one to "what code is this node
  running" the moment a generation is hot-loaded onto it. `/api/version`
  reported only the former, so a hot-deployed fleet read as "all confirmed
  on SHA X" while X described nobody's running code.

  This module is the other half: a small stamp written onto a node the
  instant a reconcile confirms it matches a generation, and read back by
  `/api/version` and the fleet drift view.

  ## Why `:persistent_term`, and why nothing durable

  The stamp lives in `:persistent_term` on the node it describes. Two
  properties fall out of that and both are wanted:

    * **It survives code loading.** The stamp is written after the beams
      land, and hot-loading the module that wrote it does not disturb it —
      `:persistent_term` is VM-global, not module state.
    * **It does NOT survive a restart.** A restarted node boots from its
      image and is running exactly image code again until the hub
      reconciles it. A stamp that outlived the VM would claim a generation
      the node had already lost, which is the same class of lie this whole
      module exists to remove. `CodePush`'s boot/nodeup reconcile re-stamps
      it within seconds.

  ## The remote side touches only OTP

  `record/2` and `read/1` are plain `:persistent_term` calls over `:erpc`.
  Nothing on the target has to carry THIS module — which matters precisely
  when it matters most, since the node being stamped may be running an
  image old enough to predate it. The key is a bare tuple; atoms cross
  distribution on their own.

  Writes are unconditional rather than compare-and-swap. A
  `:persistent_term.put/2` that replaces an existing key costs a global
  scan, so this would be the wrong shape for anything hot — reconciles fire
  on publish and on nodeup, which is rare enough that the simpler code
  wins.
  """

  @key {__MODULE__, :applied_generation}

  @rpc_timeout 10_000

  @type t :: %{
          generation_id: String.t(),
          base_sha: String.t(),
          dirty: boolean(),
          module_count: non_neg_integer(),
          modules_loaded: non_neg_integer(),
          apply_status: String.t(),
          applied_at: String.t(),
          verified_at: String.t(),
          reconciled_from: String.t()
        }

  @doc "The `:persistent_term` key the stamp is stored under, on every node."
  @spec key() :: term()
  def key, do: @key

  @doc "This node's stamp, or `nil` when no generation has been applied here."
  @spec local() :: t() | nil
  def local, do: :persistent_term.get(@key, nil)

  @doc false
  @spec put(t()) :: :ok
  def put(stamp) when is_map(stamp), do: :persistent_term.put(@key, stamp)

  @doc "Forgets this node's stamp. Test support; also correct after a supersede."
  @spec clear() :: boolean()
  def clear, do: :persistent_term.erase(@key)

  @doc """
  Reads `target`'s stamp.

  `{:ok, nil}` means the node answered and is running pure image code —
  materially different from `{:error, _}`, which means nobody knows.
  """
  @spec read(node()) :: {:ok, t() | nil} | {:error, term()}
  def read(target) when target == node(), do: {:ok, local()}

  def read(target) do
    {:ok, :erpc.call(target, :persistent_term, :get, [@key, nil], @rpc_timeout)}
  catch
    kind, reason -> {:error, {:unreachable, target, {kind, reason}}}
  end

  @doc """
  Stamps `target` as running the generation described by `attrs`.

  `attrs` carries the generation's identity (`:generation_id`, `:base_sha`,
  `:dirty`, `:module_count`) plus this reconcile's outcome
  (`:modules_loaded`, `:apply_status`). The two timestamps are filled in
  here and mean different things:

    * `applied_at` — when beams for this generation last actually LANDED on
      the node. Carried forward unchanged when a later reconcile finds the
      node already in sync with the same generation, because nothing was
      loaded then and claiming otherwise would misdate the node's code.
    * `verified_at` — when a reconcile last confirmed the node matches.
      Always now.
  """
  @spec record(node(), map()) :: {:ok, t()} | {:error, term()}
  def record(target, attrs) when is_atom(target) and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with {:ok, previous} <- read(target) do
      stamp =
        attrs
        |> Map.take([
          :generation_id,
          :base_sha,
          :dirty,
          :module_count,
          :modules_loaded,
          :apply_status
        ])
        |> Map.put(:applied_at, applied_at(previous, attrs, now))
        |> Map.put(:verified_at, now)
        |> Map.put(:reconciled_from, to_string(node()))

      with :ok <- write(target, stamp), do: {:ok, stamp}
    end
  end

  # Beams landing is what sets applied_at. A zero-push reconcile against the
  # SAME generation is a re-verification, so the original timestamp stands;
  # anything else (different generation, or modules actually loaded) is a
  # new application.
  defp applied_at(%{generation_id: same} = previous, %{generation_id: same} = attrs, now) do
    if Map.get(attrs, :modules_loaded, 0) > 0,
      do: now,
      else: Map.get(previous, :applied_at, now)
  end

  defp applied_at(_previous, _attrs, now), do: now

  defp write(target, stamp) when target == node() do
    put(stamp)
  end

  defp write(target, stamp) do
    :erpc.call(target, :persistent_term, :put, [@key, stamp], @rpc_timeout)
  catch
    kind, reason -> {:error, {:unreachable, target, {kind, reason}}}
  end

  @doc """
  The stamp rendered for JSON, with string keys and an explicit `source`.

  `nil` becomes an object that SAYS the node is on image code rather than
  an absent field or a defaulted sha — a consumer must never be able to
  read "no generation applied" as "applied the build sha".
  """
  @spec to_json(t() | nil) :: map()
  def to_json(nil) do
    %{
      "source" => "image",
      "detail" =>
        "no code generation has been applied on this node; it is running the code " <>
          "it booted from"
    }
  end

  def to_json(stamp) when is_map(stamp) do
    stamp
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("source", "generation")
  end
end
