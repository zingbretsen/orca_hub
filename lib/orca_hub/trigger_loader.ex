defmodule OrcaHub.TriggerLoader do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :sync)
    {:ok, []}
  end

  @impl true
  def handle_info(:sync, state) do
    OrcaHub.Scheduler.sync_triggers()
    {:noreply, state}
  end
end
