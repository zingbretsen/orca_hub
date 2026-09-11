defmodule OrcaHub.TriggerLoader do
  @moduledoc """
  Loads enabled scheduled triggers into the Quantum scheduler on boot.

  Also idempotently ensures the two automated memory-review-pass triggers
  exist/are current (`OrcaHub.MemoryReview.ensure_triggers!/0`) BEFORE
  syncing into the scheduler, so a freshly created or just-updated trigger
  is scheduled the same boot — see that module's moduledoc. Hub-only, like
  this whole GenServer (only started in `OrcaHub.Application.hub_children/1`
  — an agent node has no DB to write a trigger row into).
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :sync)
    {:ok, []}
  end

  @impl true
  def handle_info(:sync, state) do
    OrcaHub.MemoryReview.ensure_triggers!()
    OrcaHub.Scheduler.sync_triggers()
    {:noreply, state}
  end
end
