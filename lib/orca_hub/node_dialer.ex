defmodule OrcaHub.NodeDialer do
  @moduledoc """
  Hub-only GenServer that actively dials out to every `nodes` row with
  `dial: true` — the DB-backed replacement for the steady-state half of
  `CLUSTER_NODES` (libcluster's static Epmd strategy, see
  `config/runtime.exs`). `CLUSTER_NODES` remains supported as a bootstrap
  fallback; this module is what a running hub actually relies on to keep
  reaching LAN nodes it can't be dialed *into* (pod network → LAN).

  Every 5s: targets = every `nodes` row with `dial: true`, minus
  `Node.self/0` and everything already in `Node.list/0`; `Node.connect/1`
  each. Targets are re-read from the database on every tick
  (`OrcaHub.ClusterNodes.list_dial_targets/0`) — no cache to invalidate, so
  flipping the toggle in the /nodes UI takes effect within one tick, no
  restart required.

  Log hygiene is the whole reason this exists instead of just leaning on
  libcluster's static strategy: an offline node marked `dial: true` (e.g. a
  laptop that's turned off) must not produce a log line every tick forever.
  Per-target consecutive-failure counts are tracked in-process: a single
  warning on the *first* failed attempt for a target, then silence, with at
  most one repeat warning every ~5 minutes. A target going from
  unreachable/never-seen to reachable always logs at `:info` — since
  `select_targets/3` only ever offers up names NOT already in `Node.list/0`,
  every successful `Node.connect/1` here is by construction a fresh
  connection (a transition), never a no-op re-confirmation.

  `Node.connect/1` returns `:ignored` when the calling node itself isn't
  running distributed Erlang (e.g. a plain `mix phx.server` in dev without
  `--sname`/`--name`) — not a statement about the target. That can't change
  mid-run, so on the first `:ignored` this logs one warning and stops
  scheduling further ticks entirely, rather than retrying forever into the
  same wall.
  """

  use GenServer
  require Logger

  alias OrcaHub.ClusterNodes

  @tick_interval 5_000
  @repeat_interval_ticks 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{failures: %{}, stopped?: false}}
  end

  @impl true
  def handle_info(:tick, %{stopped?: true} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = tick(state)
    unless state.stopped?, do: schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)

  @doc "Runs one dial-out pass against the DB's current dial targets. Public for tests."
  def tick(state) do
    self_name = Atom.to_string(Node.self())
    connected_names = Node.list() |> Enum.map(&Atom.to_string/1) |> MapSet.new()
    targets = ClusterNodes.list_dial_targets()

    targets
    |> select_targets(self_name, connected_names)
    |> Enum.reduce(state, &dial_one/2)
  rescue
    e ->
      Logger.warning("NodeDialer: skipping tick, failed to read dial targets: #{inspect(e)}")
      state
  end

  @doc """
  Pure target selection: every dial-flagged name minus this node itself and
  anything already connected. Kept separate from `tick/1` so it's testable
  without a database or real distributed Erlang.
  """
  def select_targets(target_names, self_name, connected_names) do
    target_names
    |> Enum.reject(&(&1 == self_name))
    |> Enum.reject(&MapSet.member?(connected_names, &1))
  end

  defp dial_one(name, state) do
    case Node.connect(String.to_atom(name)) do
      true ->
        {failures, action} = record_success(state.failures, name)
        log_action(action, name)
        %{state | failures: failures}

      false ->
        {failures, action} = record_failure(state.failures, name)
        log_action(action, name)
        %{state | failures: failures}

      :ignored ->
        Logger.warning(
          "NodeDialer: Node.connect/1 was :ignored — this node is not running distributed Erlang, so dial-out is impossible. Stopping further ticks."
        )

        %{state | stopped?: true}
    end
  end

  @doc "Pure failure-count/log-action logic for a successful connect. Public for tests."
  def record_success(failures, name), do: {Map.delete(failures, name), :log_connected}

  @doc """
  Pure failure-count/log-action logic for a failed connect attempt: warns on
  the first consecutive failure, then again only every
  `#{@repeat_interval_ticks}` ticks (~5 minutes at the #{@tick_interval}ms
  tick interval), and is silent otherwise. Public for tests.
  """
  def record_failure(failures, name) do
    count = Map.get(failures, name, 0) + 1
    new_failures = Map.put(failures, name, count)

    action =
      cond do
        count == 1 -> :log_first_failure
        rem(count - 1, @repeat_interval_ticks) == 0 -> :log_repeat_failure
        true -> :quiet
      end

    {new_failures, action}
  end

  defp log_action(:log_connected, name), do: Logger.info("NodeDialer: connected to #{name}")

  defp log_action(:log_first_failure, name),
    do: Logger.warning("NodeDialer: failed to connect to #{name}")

  defp log_action(:log_repeat_failure, name),
    do: Logger.warning("NodeDialer: still unable to connect to #{name}")

  defp log_action(:quiet, _name), do: :ok
end
