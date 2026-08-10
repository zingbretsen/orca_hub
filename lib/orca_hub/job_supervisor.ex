defmodule OrcaHub.JobSupervisor do
  @moduledoc """
  Per-node `DynamicSupervisor` for `OrcaHub.JobWatcher` processes.

  Deliberately thin: `start_job/1` is the only entry point that actually
  LAUNCHES a new detached OS process (via `OrcaHub.Jobs.Launcher`) — it's
  called exactly once, right after a job row is inserted. `attach_watcher/1`
  never launches anything; it only starts (or no-ops if one's already
  running) a watcher for a job whose process is assumed to already be
  running, detached, elsewhere — used both by `OrcaHub.JobResumer` at boot
  and by `cancel_job/1`, which needs a live watcher to hand the kill
  sequence to regardless of whether one happened to survive.
  """

  use DynamicSupervisor
  require Logger

  alias OrcaHub.{HubRPC, JobWatcher, Jobs.Launcher}

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Launch a brand-new job's detached process and start watching it. Called
  once, immediately after the job's DB row is created. Returns `{:ok, job}`
  with the row updated to `status: "running"` and its `pid`/`pgid`/
  `started_at` filled in, or `{:error, reason}` if the process couldn't
  even be launched (the row is marked `failed` in that case so it doesn't
  linger looking like it's still starting).
  """
  def start_job(job_id) do
    job = HubRPC.get_job!(job_id)

    case Launcher.launch_main(job) do
      {:ok, pid} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok, job} =
          HubRPC.update_job(job, %{
            status: "running",
            pid: pid,
            pgid: pid,
            started_at: now,
            log_path: OrcaHub.Jobs.Paths.log_path(job.id),
            sentinel_path: OrcaHub.Jobs.Paths.sentinel_path(job.id)
          })

        attach_watcher(job.id)
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("[JobSupervisor] job #{job_id} failed to launch: #{inspect(reason)}")

        HubRPC.update_job(job, %{
          status: "failed",
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
          progress_note: "Failed to launch: #{inspect(reason)}"
        })

        error
    end
  end

  @doc """
  Attach a watcher to a job whose process is assumed to already be running
  (or about to be — `start_job/1` calls this right after launch too).
  Idempotent: a no-op if a watcher is already registered for this job.
  """
  def attach_watcher(job_id) do
    if JobWatcher.alive?(job_id) do
      :ok
    else
      case DynamicSupervisor.start_child(__MODULE__, {JobWatcher, job_id: job_id}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> other
      end
    end
  end

  @doc "Cancel a job: ensure a watcher is attached, then hand it the cancel."
  def cancel_job(job_id) do
    case attach_watcher(job_id) do
      :ok -> JobWatcher.cancel(job_id)
      error -> error
    end
  end
end
