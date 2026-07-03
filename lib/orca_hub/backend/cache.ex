defmodule OrcaHub.Backend.Cache do
  @moduledoc """
  Tiny TTL cache (public ETS table) for node-dependent backend facts that are
  read on every render but expensive to compute — which backend CLIs are
  installed on a node, and pi's live model catalog (`pi --list-models` shells
  out and may cross the cluster via RPC).

  `get_or_run/3` is read-through: on a miss (or expired entry) it runs `fun`
  and stores the result. Failures are NOT cached — a `fun` that raises just
  propagates, so a transient RPC error doesn't poison the cache.
  """

  use GenServer

  @table :orca_backend_cache

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Fetch `key` from the cache, running `fun` and storing its result on miss/expiry."
  def get_or_run(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, value, now + ttl_ms})
        value
    end
  end

  @doc "Drop a cached entry (test helper / manual invalidation)."
  def invalidate(key), do: :ets.delete(@table, key)

  @doc "Drop everything (test helper)."
  def clear, do: :ets.delete_all_objects(@table)
end
