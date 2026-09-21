defmodule OrcaHub.Deploys.LeaseReaper do
  @moduledoc """
  Releases a deploy lease when its job finishes — the completion half of
  `.context/deploy-jobs-design.md` §2.2, which deliberately has NO renewer
  process (one would die with the very `systemctl restart` it exists to
  survive).

  Hub-only, for the same reason `OrcaHub.MemoryExtractionSweep` is: the
  lease table lives on the hub and releasing a lease is a pure DB write
  regardless of which node the job ran on, so there is exactly one reaper
  for the whole cluster rather than one per node.

  ## Two mechanisms, because one of them is guaranteed to be missing

  1. **Broadcast-driven release.** `OrcaHub.JobWatcher` already broadcasts
     `{:job_finished, job_id, status}` on `"job:<id>"`. This process
     subscribes to that topic for every deploy job it learns about and
     calls `OrcaHub.Deploys.Leases.release_for_job/1` when it fires.

     It learns about jobs through a cluster-wide `"deploys"` broadcast that
     `OrcaHub.Deploys` emits at launch — PubSub rather than a direct call
     so a deploy started ON AN AGENT NODE still reaches this hub-only
     process without the deploy layer needing to know where the hub is.
     On subscribing it immediately re-checks the job's status, which closes
     the race where a very short job finished before the subscription
     landed.

  2. **Boot sweep**, because mechanism 1 is exactly what a deploy destroys:
     `deploy-orca-hub.sh` restarts this hub at step 7, so this process dies
     mid-deploy and comes back with an empty subscription set while the
     real deploy is still running in `user.slice`. The sweep reconciles
     every unreleased lease against its job, and — just as importantly —
     RE-SUBSCRIBES to the still-running ones so their eventual completion
     is still released promptly.

  ## The one case it refuses to fix

  An **expired** lease whose job is still non-terminal
  (`:lease_expired_job_running`) is neither released nor stolen. The job is
  demonstrably alive; releasing would hand the target to a second deploy
  while the first is still writing to it. That is the case a pure-TTL design
  gets wrong, and the whole reason the job cross-check exists. It is logged
  as a warning and surfaced through `OrcaHub.Deploys.in_flight/1`; a human
  renews or cancels.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Deploys, HubRPC}

  # Long enough for OrcaHub.JobResumer (30s) to be irrelevant either way:
  # the sweep only RELEASES already-terminal jobs and re-subscribes to live
  # ones, so it is correct whether or not watchers have re-attached yet.
  @boot_sweep_delay_ms 15_000

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Subscribe to `job_id`'s completion and release its lease immediately if
  it has already finished. Synchronous, so a caller (or a test) knows the
  subscription is in place before the job can finish.
  """
  def watch(server \\ __MODULE__, job_id) do
    GenServer.call(server, {:watch, job_id})
  end

  @doc """
  Run the reconciliation sweep now, returning
  `%{released: [...], expired_job_running: [...], in_flight: [...]}` (lists
  of `{target, job_id}`). Public so callers and tests do not have to wait
  out the boot delay.
  """
  def sweep(server \\ __MODULE__) do
    GenServer.call(server, :sweep, 30_000)
  end

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, Deploys.topic())

    case Keyword.get(opts, :boot_sweep_delay_ms, @boot_sweep_delay_ms) do
      nil -> :ok
      delay -> Process.send_after(self(), :boot_sweep, delay)
    end

    {:ok, %{watched: MapSet.new()}}
  end

  @impl true
  def handle_call({:watch, job_id}, _from, state) do
    {:reply, :ok, do_watch(job_id, state)}
  end

  def handle_call(:sweep, _from, state) do
    {report, state} = guarded(:sweep, state, fn -> do_sweep(state) end)
    {:reply, report, state}
  end

  @impl true
  def handle_info({:deploy_lease_acquired, job_id, _lease_id, target}, state) do
    Logger.info("[LeaseReaper] watching deploy job #{job_id} (#{target})")
    {_result, state} = guarded(:watch, state, fn -> {:ok, do_watch(job_id, state)} end)
    {:noreply, state}
  end

  def handle_info({:job_finished, job_id, status}, state) do
    {_result, state} =
      guarded(:job_finished, state, fn ->
        release(job_id, status)
        {:ok, unwatch(job_id, state)}
      end)

    {:noreply, state}
  end

  def handle_info(:boot_sweep, state) do
    {_result, state} = guarded(:boot_sweep, state, fn -> do_sweep(state) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────────────────

  # Subscribe FIRST, then look at the status — the other order has a window
  # in which a job finishing between the read and the subscribe is missed
  # entirely, and nothing would release its lease until the next boot.
  defp do_watch(job_id, state) do
    state =
      if MapSet.member?(state.watched, job_id) do
        state
      else
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, Deploys.job_topic(job_id))
        %{state | watched: MapSet.put(state.watched, job_id)}
      end

    case HubRPC.get_job(job_id) do
      %{status: status} when status not in ["running", "verifying"] ->
        release(job_id, status)
        unwatch(job_id, state)

      _ ->
        state
    end
  end

  defp unwatch(job_id, state) do
    if MapSet.member?(state.watched, job_id) do
      Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, Deploys.job_topic(job_id))
      %{state | watched: MapSet.delete(state.watched, job_id)}
    else
      state
    end
  end

  defp release(job_id, status) do
    case HubRPC.release_deploy_lease_for_job(job_id) do
      {:ok, []} ->
        :ok

      {:ok, leases} ->
        Logger.info(
          "[LeaseReaper] job #{job_id} finished (#{status}) — released " <>
            "#{length(leases)} deploy lease(s): #{Enum.map_join(leases, ", ", & &1.target)}"
        )

      other ->
        Logger.warning("[LeaseReaper] job #{job_id}: release returned #{inspect(other)}")
    end
  end

  defp do_sweep(state) do
    entries = Deploys.in_flight()

    report = %{released: [], expired_job_running: [], in_flight: []}

    {report, state} =
      Enum.reduce(entries, {report, state}, fn entry, {report, state} ->
        sweep_entry(entry, report, state)
      end)

    report = Map.new(report, fn {k, v} -> {k, Enum.reverse(v)} end)

    if report.released != [] or report.expired_job_running != [] do
      Logger.info("[LeaseReaper] sweep: #{inspect(report)}")
    end

    {report, state}
  end

  # `:stale_lease` (live lease, terminal job) and `:expired` (expired lease,
  # terminal/unknown job) are both provably done — release. `:in_flight`
  # gets a subscription so its completion still releases promptly after a
  # restart wiped the old one. `:lease_expired_job_running` is refused.
  defp sweep_entry(%{state: :in_flight} = entry, report, state) do
    state = if entry.job, do: do_watch(entry.job.id, state), else: state
    {%{report | in_flight: [key(entry) | report.in_flight]}, state}
  end

  defp sweep_entry(%{state: :lease_expired_job_running} = entry, report, state) do
    Logger.warning(
      "[LeaseReaper] #{entry.target}: lease #{entry.lease.id} EXPIRED but job " <>
        "#{entry.lease.job_id} is still #{entry.job && entry.job.status} — refusing to " <>
        "release or steal it (design §2.2). Cancel the job or renew the lease."
    )

    {%{report | expired_job_running: [key(entry) | report.expired_job_running]}, state}
  end

  defp sweep_entry(entry, report, state) do
    HubRPC.release_deploy_lease(entry.lease.id, entry.lease.job_id)
    state = if entry.job, do: unwatch(entry.job.id, state), else: state
    {%{report | released: [key(entry) | report.released]}, state}
  end

  defp key(entry), do: {entry.target, entry.lease.job_id}

  # A transient DB/erpc hiccup must never take this process down: the hub
  # would come back with an empty subscription set and every in-flight
  # deploy's lease would then sit unreleased until the next boot sweep.
  # Returns `{result, state}`; on failure the state is handed back unchanged.
  defp guarded(label, state, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[LeaseReaper] #{label} raised: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {{:error, :failed}, state}
  catch
    kind, reason ->
      Logger.warning("[LeaseReaper] #{label} #{kind}: #{inspect(reason)}")
      {{:error, :failed}, state}
  end
end
