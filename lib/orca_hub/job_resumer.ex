defmodule OrcaHub.JobResumer do
  @moduledoc """
  Re-attaches `OrcaHub.JobWatcher`s to this node's own non-terminal jobs on
  boot — the job-subsystem analog of `OrcaHub.SessionResumer`, and the
  reason a job's detached OS process is allowed to outlive an OrcaHub
  restart in the first place: the process itself was never touched by the
  restart (see `OrcaHub.Jobs.Launcher`), only its watcher died with the old
  BEAM.

  Runs on every node (hub + agent), after a short boot delay, and only ever
  touches jobs whose `runner_node` is THIS node — never reassigns a job to
  a different node (mirrors the "never reassign" rule `SessionResumer`
  follows for sessions).

  For each such job, `OrcaHub.JobSupervisor.attach_watcher/1` starts a fresh
  watcher — it does NOT relaunch the process. That watcher's very first poll
  tick does the actual "what happened while nobody was watching" work
  (`OrcaHub.JobWatcher`'s tick logic already handles this generally, not as
  a resumer-specific code path):

    * sentinel already written while unwatched -> finalize from it normally
    * process still alive, no sentinel -> resume polling normally
    * process gone AND no sentinel ever appeared -> finalize failed (or
      verification_failed) with a diagnostic note, exactly as it would for
      a process that died mid-poll on a still-running node

  One-shot per boot (a single delayed check, not a repeating timer) and
  toggled by the SAME `ORCA_AUTO_RESUME` env var `SessionResumer` uses —
  there is no separate jobs-only toggle, since both exist for the identical
  reason (recover state orphaned by a restart) and an operator disabling
  one almost certainly means the other too.
  """

  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, JobSupervisor, Mode, SessionResumer}

  @initial_delay_ms 30_000
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
        resume_jobs()
        {:noreply, state}

      state.retries < @max_retries ->
        Process.send_after(self(), :check, @retry_delay_ms)
        {:noreply, %{state | retries: state.retries + 1}}

      true ->
        Logger.warning(
          "JobResumer: giving up, hub still unreachable after #{@max_retries} retries"
        )

        {:noreply, state}
    end
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

  @doc false
  def resume_jobs do
    node_name = Atom.to_string(node())
    orphans = HubRPC.list_nonterminal_jobs_for_node(node_name)

    unless orphans == [] do
      Logger.info("JobResumer: re-attaching #{length(orphans)} job watcher(s) on #{node_name}")
    end

    Enum.each(orphans, fn job ->
      case JobSupervisor.attach_watcher(job.id) do
        :ok ->
          :ok

        error ->
          Logger.warning(
            "JobResumer: failed to attach watcher for job #{job.id}: #{inspect(error)}"
          )
      end
    end)
  end
end
