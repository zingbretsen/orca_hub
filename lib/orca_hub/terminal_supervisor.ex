defmodule OrcaHub.TerminalSupervisor do
  @moduledoc """
  DynamicSupervisor for `TerminalRunner` processes.

  Every function here acts on THIS node only; `OrcaHub.Cluster` routes a
  call to the terminal's own `runner_node` and never re-routes it.
  """

  use DynamicSupervisor

  require Logger

  alias OrcaHub.{HubRPC, TerminalRunner}

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_terminal(terminal_id) do
    spec = {OrcaHub.TerminalRunner, terminal_id: terminal_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Stops the terminal's runner, which kills its shell's process tree (see
  `OrcaHub.TerminalRunner`). Synchronous: the row is updated when this
  returns.

  With no live runner here (the node restarted, the runner was killed), a
  row still reading `"running"` is a ghost: it is reconciled to `"stopped"`
  and the status is broadcast, instead of the Stop silently doing nothing.

  Returns `:ok` (a runner was stopped), `{:ok, :reconciled}` (no runner; a
  ghost `"running"` row was fixed), `{:ok, :not_running}` (nothing to do) or
  `{:error, reason}`.
  """
  def stop_terminal(terminal_id) do
    case lookup(terminal_id) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok -> :ok
          # It exited between the lookup and the terminate.
          {:error, :not_found} -> reconcile_not_running(terminal_id, "stopped")
        end

      :error ->
        reconcile_not_running(terminal_id, "stopped")
    end
  end

  @doc """
  Whether a runner for `terminal_id` is alive on this node. Checks the pid,
  not just the Registry entry: Registry drops a dead pid's entry
  asynchronously, so right after a runner exits the bare lookup still
  answers yes (the same race df230c6 fixed for sessions).
  """
  def terminal_alive?(terminal_id), do: match?({:ok, _pid}, lookup(terminal_id))

  @doc "The subset of `terminal_ids` with a live runner on this node."
  def alive_terminal_ids(terminal_ids) when is_list(terminal_ids) do
    Enum.filter(terminal_ids, &terminal_alive?/1)
  end

  @doc """
  Marks a row still reading `"running"` as `status` (`"stopped"` or
  `"dead"`) and broadcasts it, when this node owns the row and has no live
  runner for it. The write is conditional on the row still reading
  `"running"`, so it never clobbers a concurrent exit or stop. Used by
  `stop_terminal/1` and the boot sweep (`OrcaHub.TerminalSweep`).
  """
  def reconcile_not_running(terminal_id, status) do
    case HubRPC.get_terminal(terminal_id) do
      nil ->
        {:ok, :not_running}

      terminal ->
        cond do
          not owned_here?(terminal) ->
            {:error, {:wrong_node, terminal.runner_node}}

          terminal.status == "running" and not terminal_alive?(terminal_id) ->
            if HubRPC.reconcile_terminal_status(terminal_id, "running", status) > 0 do
              Logger.info("Terminal #{terminal_id}: no live runner, row marked #{status}")
              TerminalRunner.broadcast(terminal_id, {:terminal_status, status_atom(status)})
              {:ok, :reconciled}
            else
              {:ok, :not_running}
            end

          true ->
            {:ok, :not_running}
        end
    end
  end

  # A nil runner_node is a terminal never started anywhere (see
  # Cluster.runner_node_for/1), which any node may claim.
  defp owned_here?(%{runner_node: rn}) when rn in [nil, ""], do: true
  defp owned_here?(%{runner_node: rn}), do: rn == Atom.to_string(node())

  defp status_atom("stopped"), do: :stopped
  defp status_atom("dead"), do: :dead

  defp lookup(terminal_id) do
    case Registry.lookup(OrcaHub.TerminalRegistry, terminal_id) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end
end
