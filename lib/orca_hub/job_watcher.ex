defmodule OrcaHub.JobWatcher do
  @moduledoc """
  Disposable, per-job GenServer that OBSERVES (never supervises) a detached
  job process — see `OrcaHub.Jobs` moduledoc for the full subsystem design
  and `OrcaHub.Jobs.Launcher` for how the process itself is launched.

  Every poll tick re-fetches the job row fresh from the DB (via `HubRPC`)
  rather than caching phase/paths/progress-declaration in GenServer state —
  this is what lets `update_job_progress_metric` re-declare a job's
  progress metric mid-flight with zero IPC to this process: the next tick
  just sees the new columns. GenServer state holds only bookkeeping this
  process itself owns (the poll timer ref, and an in-progress kill's target
  terminal status).

  On each tick, in priority order:

    1. Sentinel present at the path relevant to the job's CURRENT status
       (main sentinel while `running`, verify sentinel while `verifying`)?
       Finalize (or advance to `verifying`) from its exit code.
    2. `timeout_seconds` exceeded (measured from `started_at`, covering the
       main command AND any verify phase together — there's no separate
       verify-phase clock)? Begin a kill (see below).
    3. Process no longer alive (`/proc/<pid>` gone) with NO sentinel ever
       having appeared? The process was killed out-of-band (OOM, host
       restart onto a jobs dir that wasn't actually durable, `kill -9` by
       something else) — finalize as failed/verification_failed with a
       diagnostic note in `progress_note`, per `OrcaHub.JobResumer`'s same
       reasoning for a job discovered dead at boot.
    4. Otherwise: sample the declared progress metric (`OrcaHub.Jobs.Progress`)
       and reschedule.

  ## Cancel/timeout — empirically confirmed, not just reasoned about

  Signaling the negative pgid (`kill -TERM -<pgid>`) kills the wrapper
  script itself along with the job, which means the wrapper's own
  sentinel-write step never runs. So a cancelled/timed-out job's sentinel
  is NOT expected to appear — finalization here is driven by confirming the
  process is gone after TERM-then-KILL-after-grace, not by waiting on a
  sentinel a group-kill actively prevents from being written.
  """

  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, Jobs.Launcher, Jobs.Paths, Jobs.Progress}

  @default_poll_interval_ms 5_000
  @default_kill_grace_ms 5_000
  @confirm_kill_delay_ms 1_000

  defp poll_interval_ms,
    do: Application.get_env(:orca_hub, :job_poll_interval_ms, @default_poll_interval_ms)

  defp kill_grace_ms,
    do: Application.get_env(:orca_hub, :job_kill_grace_ms, @default_kill_grace_ms)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :job_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: via(job_id))
  end

  def via(job_id), do: {:via, Registry, {OrcaHub.JobRegistry, job_id}}

  def alive?(job_id), do: Registry.lookup(OrcaHub.JobRegistry, job_id) != []

  @doc "Begin cancelling `job_id`'s running process — asynchronous, see moduledoc."
  def cancel(job_id) do
    if alive?(job_id) do
      GenServer.cast(via(job_id), :cancel)
      :ok
    else
      {:error, :not_running}
    end
  end

  @impl true
  def init(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    send(self(), :poll)
    {:ok, %{job_id: job_id, poll_timer: nil, killing: nil, kill_timer: nil}}
  end

  @impl true
  def handle_cast(:cancel, %{killing: nil} = state) do
    guarded("cancel", state, fn ->
      case HubRPC.get_job(state.job_id) do
        %{status: status} = job when status in ["running", "verifying"] ->
          {:noreply, begin_kill(job, state, "cancelled")}

        _other ->
          {:stop, :normal, state}
      end
    end)
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, state) do
    cancel_timer(state.poll_timer)
    state = %{state | poll_timer: nil}

    guarded("poll", state, fn ->
      case HubRPC.get_job(state.job_id) do
        nil ->
          {:stop, :normal, state}

        %{status: status} when status not in ["running", "verifying"] ->
          {:stop, :normal, state}

        job ->
          tick(job, state)
      end
    end)
  end

  def handle_info(:force_kill, state) do
    guarded("force_kill", state, fn ->
      case HubRPC.get_job(state.job_id) do
        %{status: status} = job when status in ["running", "verifying"] ->
          signal(job.pgid, "KILL")
          Process.send_after(self(), :confirm_kill, @confirm_kill_delay_ms)
          {:noreply, state}

        _other ->
          {:stop, :normal, state}
      end
    end)
  end

  def handle_info(:confirm_kill, state) do
    guarded("confirm_kill", state, fn ->
      case HubRPC.get_job(state.job_id) do
        %{status: status} = job when status in ["running", "verifying"] ->
          finalize(job, state.killing, %{})
          {:stop, :normal, state}

        _other ->
          {:stop, :normal, state}
      end
    end)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.poll_timer)
    cancel_timer(state.kill_timer)
    :ok
  end

  # ── Tick ────────────────────────────────────────────────────────────

  defp tick(job, %{killing: killing} = state) when not is_nil(killing) do
    if File.exists?(Paths.relevant_sentinel_path(job)) do
      cancel_timer(state.kill_timer)
      finalize(job, killing, %{})
      {:stop, :normal, state}
    else
      {:noreply, schedule_poll(state)}
    end
  end

  defp tick(job, state) do
    cond do
      File.exists?(Paths.relevant_sentinel_path(job)) ->
        handle_exit(job, state)

      timed_out?(job) ->
        {:noreply, begin_kill(job, state, "timed_out")}

      not pid_alive?(job.pid) ->
        finalize_crashed(job, state)

      true ->
        sample_progress(job)
        {:noreply, schedule_poll(state)}
    end
  end

  # ── Normal exit handling ───────────────────────────────────────────

  defp handle_exit(%{status: "running"} = job, state) do
    code = read_sentinel_code(Paths.sentinel_path(job.id))

    cond do
      code == 0 and present?(job.verify_command) ->
        {:noreply, advance_to_verify(job, state)}

      code == 0 ->
        finalize(job, "succeeded", %{exit_code: code})
        {:stop, :normal, state}

      true ->
        finalize(job, "failed", %{exit_code: code})
        {:stop, :normal, state}
    end
  end

  defp handle_exit(%{status: "verifying"} = job, state) do
    code = read_sentinel_code(Paths.verify_sentinel_path(job.id))

    if code == 0 do
      finalize(job, "succeeded", %{verify_exit_code: code})
    else
      finalize(job, "verification_failed", %{verify_exit_code: code})
    end

    {:stop, :normal, state}
  end

  defp advance_to_verify(job, state) do
    case Launcher.launch_verify(job) do
      {:ok, pid} ->
        {:ok, job} =
          HubRPC.update_job(job, %{
            status: "verifying",
            exit_code: 0,
            pid: pid,
            pgid: pid
          })

        Logger.info(
          "[JobWatcher] job #{job.id} main command succeeded, launched verify (pid #{pid})"
        )

        schedule_poll(state)

      {:error, reason} ->
        Logger.error(
          "[JobWatcher] job #{job.id} failed to launch verify command: #{inspect(reason)}"
        )

        finalize(job, "failed", %{
          exit_code: 0,
          progress_note:
            "main command succeeded but verify_command failed to launch: #{inspect(reason)}"
        })

        state
    end
  end

  defp finalize_crashed(job, state) do
    status = if job.status == "verifying", do: "verification_failed", else: "failed"

    note =
      "Process (pid #{inspect(job.pid)}) disappeared without writing an exit sentinel — " <>
        "likely OOM-killed, killed out-of-band, or the host restarted onto a jobs " <>
        "directory that wasn't actually durable for this node (see OrcaHub.Jobs.Paths)."

    finalize(job, status, %{progress_note: note})
    {:stop, :normal, state}
  end

  # ── Cancel / timeout ────────────────────────────────────────────────

  defp begin_kill(job, state, terminal_status) do
    signal(job.pgid, "TERM")
    cancel_timer(state.kill_timer)
    timer = Process.send_after(self(), :force_kill, kill_grace_ms())
    %{state | killing: terminal_status, kill_timer: timer}
  end

  defp signal(nil, _sig), do: :ok

  defp signal(pgid, sig) when is_integer(pgid) do
    System.cmd("kill", ["-#{sig}", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # ── Progress sampling ───────────────────────────────────────────────

  defp sample_progress(job) do
    case Progress.sample(job) do
      {:ok, attrs} -> HubRPC.update_job(job, attrs)
      :unchanged -> :ok
    end
  end

  # ── Shared finalize/broadcast ───────────────────────────────────────

  defp finalize(job, status, extra_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.merge(%{status: status, finished_at: now}, extra_attrs)

    case HubRPC.update_job(job, attrs) do
      {:ok, updated} ->
        Logger.info("[JobWatcher] job #{updated.id} finished: #{status}")
        broadcast_finished(updated)

      {:error, changeset} ->
        Logger.error(
          "[JobWatcher] job #{job.id} failed to persist final status #{status}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp broadcast_finished(job) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, topic(job.id), {:job_finished, job.id, job.status})
  end

  @doc "PubSub topic for a job's lifecycle events."
  def topic(job_id), do: "job:#{job_id}"

  # ── Helpers ─────────────────────────────────────────────────────────

  defp timed_out?(%{timeout_seconds: nil}), do: false

  defp timed_out?(%{timeout_seconds: secs, started_at: %DateTime{} = started_at}) do
    DateTime.diff(DateTime.utc_now(), started_at) > secs
  end

  defp timed_out?(_job), do: false

  defp pid_alive?(pid) when is_integer(pid), do: File.exists?("/proc/#{pid}")
  defp pid_alive?(_pid), do: true

  defp present?(str), do: is_binary(str) and String.trim(str) != ""

  defp read_sentinel_code(path) do
    case File.read(path) do
      {:ok, content} ->
        case content |> String.trim() |> Integer.parse() do
          {code, _rest} -> code
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp schedule_poll(state) do
    %{state | poll_timer: Process.send_after(self(), :poll, poll_interval_ms())}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # A transient DB/erpc hiccup (pool exhaustion under heavy concurrent load,
  # a momentary hub blip on an agent node) reaching ANY of this GenServer's
  # handlers must not silently crash it — the alternative is an orphaned
  # running/verifying job nobody is polling (and, mid-cancel, one stuck
  # half-signaled) until the next restart's JobResumer sweep. Falls back to
  # rescheduling a normal poll, which re-derives everything from fresh DB
  # state on its next tick regardless of which handler actually failed.
  defp guarded(label, state, fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "[JobWatcher] job #{state.job_id} #{label} raised, retrying next tick: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:noreply, schedule_poll(state)}
  catch
    kind, reason ->
      Logger.warning(
        "[JobWatcher] job #{state.job_id} #{label} #{kind}, retrying next tick: #{inspect(reason)}"
      )

      {:noreply, schedule_poll(state)}
  end
end
