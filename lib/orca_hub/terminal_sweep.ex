defmodule OrcaHub.TerminalSweep do
  @moduledoc """
  Marks this node's own terminal rows that read `"running"` but have no
  live `OrcaHub.TerminalRunner` as `"dead"`, once, shortly after boot.

  A node restart (deploy, crash) takes every runner with it, and their
  shells with them (systemd / the pod kills the whole cgroup), but nothing
  rewrites the rows: before this they read `"running"` forever, offered a
  Stop that hit no runner, and never offered Start.

  Rails, the same as `OrcaHub.SessionResumer` / `OrcaHub.JobResumer`:

    * own-node rows only (`runner_node == Atom.to_string(node())`); never
      another node's, even an offline one (never-reassign rule);
    * re-checks `TerminalSupervisor.terminal_alive?/1` per row, and the
      write only lands while the row still reads `"running"`;
    * waits for the hub on an agent node (bounded retries);
    * toggled by `ORCA_AUTO_RESUME` (`config :orca_hub, :auto_resume`),
      which is also what keeps it off in the test env.

  It never restarts a terminal: a shell's state (its cwd, its history, the
  program it ran) died with the node, so the user starts a fresh one.
  """

  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, Mode, SessionResumer, TerminalSupervisor}

  @initial_delay_ms 5_000
  @retry_delay_ms 15_000
  @max_retries 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if SessionResumer.enabled?() do
      Process.send_after(self(), :check, @initial_delay_ms)
    end

    {:ok, %{retries: 0}}
  end

  @impl true
  def handle_info(:check, state) do
    cond do
      hub_reachable?() ->
        sweep()
        {:noreply, state}

      state.retries < @max_retries ->
        Process.send_after(self(), :check, @retry_delay_ms)
        {:noreply, %{state | retries: state.retries + 1}}

      true ->
        Logger.warning(
          "TerminalSweep: giving up, hub still unreachable after #{@max_retries} retries"
        )

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Marks every orphaned own-node `"running"` row `"dead"`. Returns the ids it
  marked.
  """
  def sweep do
    node_name = Atom.to_string(node())

    marked =
      node_name
      |> HubRPC.list_running_terminals_for_node()
      |> Enum.reject(&TerminalSupervisor.terminal_alive?(&1.id))
      |> Enum.filter(fn terminal ->
        TerminalSupervisor.reconcile_not_running(terminal.id, "dead") == {:ok, :reconciled}
      end)
      |> Enum.map(& &1.id)

    unless marked == [] do
      Logger.info(
        "TerminalSweep: marked #{length(marked)} orphaned running terminal(s) dead on #{node_name}"
      )
    end

    marked
  rescue
    e ->
      Logger.warning("TerminalSweep: sweep failed: #{Exception.message(e)}")
      []
  end

  defp hub_reachable? do
    if Mode.hub?() do
      true
    else
      Enum.any?(Node.list(), fn n ->
        try do
          :erpc.call(n, Mode, :hub?, [], 5_000)
        catch
          _, _ -> false
        end
      end)
    end
  end
end
