defmodule OrcaHub.MCP.CodeExec.BindingStore do
  @moduledoc """
  Per-session Elixir variable binding store for `run_elixir` — makes
  variables assigned in one eval visible in the next, like a REPL/notebook,
  instead of every eval starting from an empty binding.

  Keyed by `orca_session_id` (falling back to the MCP `session_id` when nil —
  see `OrcaHub.MCP.CodeExec.run/3`), NOT the MCP session id, because the
  Claude CLI re-handshakes MCP per turn so MCP session ids don't survive a
  turn boundary while `orca_session_id` does.

  Concurrency: two concurrent evals for the same key are last-write-wins —
  whichever `put/2` lands second simply overwrites the other. Access is
  otherwise serialized through this GenServer (get/put/reset are calls).

  Entries idle longer than `:ttl_ms` (default 24h) are evicted on a periodic
  sweep so the store can't grow forever. `get/1` and `put/2` both refresh a
  key's last-touched timestamp.
  """

  use GenServer

  @default_ttl_ms 24 * 60 * 60 * 1000
  @default_sweep_interval_ms 60 * 60 * 1000

  @doc """
  Starts the store. Pass `name: nil` (tests only) to start an unnamed,
  independently addressed instance instead of registering the default name.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Fetch the stored binding for `key` (default `[]` if absent)."
  def get(key, server \\ __MODULE__), do: GenServer.call(server, {:get, key})

  @doc "Store `binding` for `key`, touching its last-used timestamp."
  def put(key, binding, server \\ __MODULE__), do: GenServer.call(server, {:put, key, binding})

  @doc "Clear the stored binding for `key`."
  def reset(key, server \\ __MODULE__), do: GenServer.call(server, {:reset, key})

  @doc "Force an immediate TTL sweep. Production relies on the periodic tick; tests use this to avoid waiting on the real clock."
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    schedule_sweep(sweep_interval_ms)
    {:ok, %{entries: %{}, ttl_ms: ttl_ms, sweep_interval_ms: sweep_interval_ms}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case Map.get(state.entries, key) do
      nil ->
        {:reply, [], state}

      %{binding: binding} ->
        {:reply, binding, %{state | entries: touch(state.entries, key, binding)}}
    end
  end

  def handle_call({:put, key, binding}, _from, state) do
    {:reply, :ok, %{state | entries: touch(state.entries, key, binding)}}
  end

  def handle_call({:reset, key}, _from, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, %{state | entries: sweep_expired(state.entries, state.ttl_ms)}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, %{state | entries: sweep_expired(state.entries, state.ttl_ms)}}
  end

  defp touch(entries, key, binding) do
    Map.put(entries, key, %{binding: binding, touched_at: System.monotonic_time(:millisecond)})
  end

  defp sweep_expired(entries, ttl_ms) do
    now = System.monotonic_time(:millisecond)
    entries |> Enum.filter(fn {_key, %{touched_at: t}} -> now - t <= ttl_ms end) |> Map.new()
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)
end
