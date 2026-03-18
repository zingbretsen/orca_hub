defmodule OrcaHub.TerminalSupervisor do
  use DynamicSupervisor

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

  def stop_terminal(terminal_id) do
    case Registry.lookup(OrcaHub.TerminalRegistry, terminal_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def terminal_alive?(terminal_id) do
    Registry.lookup(OrcaHub.TerminalRegistry, terminal_id) != []
  end
end
