defmodule OrcaHub.OneOffTriggerSweep do
  @moduledoc """
  Fires due one-off (`type: "once"`) triggers.

  A one-off can sit months in the future (e.g. "remind me in 2.5 months"), so
  it must survive every hub restart and deploy in between. The DB row is
  therefore the ONLY source of truth: there is no in-memory Quantum job to
  lose. This GenServer polls `Triggers.list_due_one_off_triggers/1` (enabled,
  `run_at <= now`) every `@interval_ms` — and once right after boot — and
  hands each id to `OrcaHub.TriggerExecutor.execute/1`, serially.

  Exactly-once comes from the executor, not from here: a successful fire
  disables the trigger in the same write that stamps `last_fired_at`, so it
  drops out of the due set. An overdue one-off (its `run_at` passed while the
  hub was down) fires LATE on the next sweep rather than never. A fire the
  executor SKIPS because the project's node is unavailable leaves the
  trigger enabled — it is never re-routed to another node — so the next
  sweep simply retries it; the periodic poll is what makes that retry happen
  without waiting for a reboot.

  Hub-only (started in `OrcaHub.Application.hub_children/1`, like
  `OrcaHub.Scheduler`) and a single process, so two sweeps can never fire the
  same row concurrently. Gated by `config :orca_hub, :one_off_trigger_sweep_enabled`
  (off in test — the suite calls `sweep/1` directly).
  """

  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, TriggerExecutor}

  @initial_delay_ms 5_000
  @interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:orca_hub, :one_off_trigger_sweep_enabled, true) do
      Process.send_after(self(), :sweep, @initial_delay_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @interval_ms)
    {:noreply, state}
  end

  # Public so tests can drive a sweep directly instead of waiting on the timer.
  @doc false
  def sweep(now \\ DateTime.utc_now()) do
    due = HubRPC.list_due_one_off_triggers(now)

    unless due == [] do
      Logger.info("OneOffTriggerSweep: firing #{length(due)} due one-off trigger(s)")
    end

    Enum.each(due, &TriggerExecutor.execute/1)
    length(due)
  rescue
    e ->
      Logger.warning("OneOffTriggerSweep: sweep failed: #{Exception.message(e)}")
      0
  end
end
