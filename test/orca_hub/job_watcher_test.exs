defmodule OrcaHub.JobWatcherTest do
  @moduledoc """
  Drives `OrcaHub.JobWatcher` through its full lifecycle against REAL
  detached processes and the real DB — no mocked ports. Poll/kill-grace
  intervals are fast in `config/test.exs` (100ms/300ms) so this stays
  quick despite being end-to-end.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{HubRPC, JobSupervisor, JobWatcher, Jobs}
  alias OrcaHub.Jobs.Paths

  defp job_attrs(overrides) do
    Map.merge(
      %{directory: System.tmp_dir!(), runner_node: Atom.to_string(node())},
      overrides
    )
  end

  defp start_job!(overrides) do
    {:ok, job} = Jobs.create_job(job_attrs(overrides))
    {:ok, started} = JobSupervisor.start_job(job.id)
    started
  end

  defp wait_for_status(job_id, statuses, tries \\ 100) do
    job = HubRPC.get_job(job_id)

    cond do
      job.status in statuses ->
        job

      tries <= 0 ->
        flunk("job #{job_id} never reached #{inspect(statuses)}, stuck at #{job.status}")

      true ->
        Process.sleep(50)
        wait_for_status(job_id, statuses, tries - 1)
    end
  end

  defp cleanup(job_id) do
    [
      Paths.cmd_script_path(job_id),
      Paths.wrapper_script_path(job_id),
      Paths.log_path(job_id),
      Paths.sentinel_path(job_id),
      Paths.pid_path(job_id),
      Paths.verify_cmd_script_path(job_id),
      Paths.verify_wrapper_script_path(job_id),
      Paths.verify_log_path(job_id),
      Paths.verify_sentinel_path(job_id),
      Paths.verify_pid_path(job_id)
    ]
    |> Enum.each(&File.rm/1)
  end

  describe "main command only" do
    test "succeeds and captures the log" do
      job = start_job!(%{command: "echo main-only-ok; exit 0"})
      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "succeeded"
      assert final.exit_code == 0
      assert File.read!(Paths.log_path(job.id)) =~ "main-only-ok"
      refute JobWatcher.alive?(job.id)
    end

    test "a non-zero exit is reported as failed" do
      job = start_job!(%{command: "exit 5"})
      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "failed"
      assert final.exit_code == 5
    end
  end

  describe "verify phase" do
    test "runs after a successful main command and can itself succeed" do
      job =
        start_job!(%{
          command: "exit 0",
          verify_command: "echo verify-ok; exit 0"
        })

      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(succeeded verification_failed failed))
      assert final.status == "succeeded"
      assert final.exit_code == 0
      assert final.verify_exit_code == 0
      assert File.read!(Paths.verify_log_path(job.id)) =~ "verify-ok"
    end

    test "a failing verify_command lands on verification_failed, not failed" do
      job = start_job!(%{command: "exit 0", verify_command: "exit 9"})
      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(succeeded verification_failed failed))
      assert final.status == "verification_failed"
      assert final.exit_code == 0
      assert final.verify_exit_code == 9
    end

    test "is skipped entirely when the main command fails" do
      job = start_job!(%{command: "exit 3", verify_command: "echo should-not-run; exit 0"})
      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(succeeded verification_failed failed))
      assert final.status == "failed"
      assert final.exit_code == 3
      assert final.verify_exit_code == nil
      refute File.exists?(Paths.verify_sentinel_path(job.id))
    end
  end

  describe "cancel_job" do
    test "kills a running job and reports cancelled" do
      job = start_job!(%{command: "sleep 30"})
      on_exit(fn -> cleanup(job.id) end)

      assert :ok = JobSupervisor.cancel_job(job.id)

      final = wait_for_status(job.id, ~w(cancelled succeeded failed))
      assert final.status == "cancelled"
      refute File.exists?("/proc/#{job.pid}")
    end

    test "is a no-op-ish success on an already-terminal job (nothing left to kill)" do
      job = start_job!(%{command: "exit 0"})
      on_exit(fn -> cleanup(job.id) end)
      wait_for_status(job.id, ~w(succeeded failed))

      # attach_watcher will start a fresh watcher that immediately sees the
      # terminal status and stops itself before ever processing the cancel —
      # should not raise, and status stays as it was.
      JobSupervisor.cancel_job(job.id)
      Process.sleep(150)
      assert HubRPC.get_job(job.id).status == "succeeded"
    end
  end

  describe "timeout" do
    test "a job that outlives timeout_seconds is killed and marked timed_out" do
      job = start_job!(%{command: "sleep 30", timeout_seconds: 1})
      on_exit(fn -> cleanup(job.id) end)

      final = wait_for_status(job.id, ~w(timed_out succeeded failed))
      assert final.status == "timed_out"
      refute File.exists?("/proc/#{job.pid}")
    end
  end

  describe "crash detection (pid gone, no sentinel)" do
    test "finalizes as failed with a diagnostic note when the process is killed out-of-band" do
      job = start_job!(%{command: "sleep 30"})
      on_exit(fn -> cleanup(job.id) end)

      # Kill just the tracked pid directly (not via pgid) to simulate an
      # out-of-band kill (OOM, `kill -9` by something else) that the
      # wrapper never gets a chance to react to.
      System.cmd("kill", ["-9", to_string(job.pid)], stderr_to_stdout: true)

      final = wait_for_status(job.id, ~w(failed succeeded))
      assert final.status == "failed"
      assert final.exit_code == nil
      assert final.progress_note =~ "disappeared without writing an exit sentinel"
    end
  end

  describe "progress sampling" do
    test "file_bytes metric is sampled and written back to the job row" do
      path =
        Path.join(System.tmp_dir!(), "job-watcher-progress-#{System.unique_integer([:positive])}")

      File.write!(path, String.duplicate("x", 500))
      on_exit(fn -> File.rm(path) end)

      job =
        start_job!(%{
          command: "sleep 1",
          progress_kind: "file_bytes",
          progress_path: path,
          progress_expect_bytes: 1000
        })

      on_exit(fn -> cleanup(job.id) end)

      updated =
        Enum.reduce_while(1..40, nil, fn _, _ ->
          case HubRPC.get_job(job.id) do
            %{progress_value: v} = j when not is_nil(v) ->
              {:halt, j}

            _ ->
              Process.sleep(50)
              {:cont, nil}
          end
        end)

      refute is_nil(updated)
      assert updated.progress_value == 500.0
      assert updated.progress_total == 1000.0
      assert %DateTime{} = updated.progress_updated_at

      wait_for_status(job.id, ~w(succeeded failed))
    end
  end

  describe "watcher death mid-flight — a fresh attach re-derives correct final state" do
    test "killing the live JobWatcher process doesn't strand the job: re-attaching finishes it correctly" do
      job = start_job!(%{command: "sleep 1; exit 0"})
      on_exit(fn -> cleanup(job.id) end)

      # Give the watcher time to land back in its idle receive-loop (between
      # poll ticks) before killing it, so the kill doesn't land mid-DB-call
      # and corrupt the test's shared Sandbox connection — a sharp edge of
      # Ecto Sandbox's :shared mode, not something JobWatcher itself needs
      # to account for (a real node death has no such connection to corrupt).
      Process.sleep(300)
      [{watcher_pid, _}] = Registry.lookup(OrcaHub.JobRegistry, job.id)
      Process.exit(watcher_pid, :kill)
      wait_until(fn -> not JobWatcher.alive?(job.id) end)
      refute JobWatcher.alive?(job.id)

      # The detached OS process was never touched by the watcher dying —
      # only re-attach a fresh watcher, mirroring what JobResumer does.
      assert :ok = JobSupervisor.attach_watcher(job.id)

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "succeeded"
      assert final.exit_code == 0
    end
  end

  describe "JobResumer.resume_jobs/0 — cold-boot reconciliation" do
    test "case 1: process still alive, no sentinel yet — re-attaches and finishes normally" do
      {:ok, job} = Jobs.create_job(job_attrs(%{command: "sleep 1; exit 0", status: "running"}))
      {:ok, pid} = OrcaHub.Jobs.Launcher.launch_main(job)

      {:ok, job} =
        HubRPC.update_job(job, %{
          pid: pid,
          pgid: pid,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      on_exit(fn -> cleanup(job.id) end)
      refute JobWatcher.alive?(job.id)

      OrcaHub.JobResumer.resume_jobs()
      wait_until(fn -> JobWatcher.alive?(job.id) end)
      assert JobWatcher.alive?(job.id)

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "succeeded"
      assert final.exit_code == 0
    end

    test "case 2: process already finished, sentinel already written — finalizes from it directly" do
      {:ok, job} = Jobs.create_job(job_attrs(%{command: "exit 0", status: "running"}))
      {:ok, pid} = OrcaHub.Jobs.Launcher.launch_main(job)

      {:ok, job} =
        HubRPC.update_job(job, %{
          pid: pid,
          pgid: pid,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      on_exit(fn -> cleanup(job.id) end)

      # Let the process finish and write its sentinel completely unwatched —
      # no watcher has ever existed for this job.
      wait_until(fn -> File.exists?(Paths.sentinel_path(job.id)) end)
      refute JobWatcher.alive?(job.id)

      OrcaHub.JobResumer.resume_jobs()

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "succeeded"
      assert final.exit_code == 0
    end

    test "case 3: process gone, no sentinel ever appeared — marks failed with a diagnostic note" do
      {:ok, job} = Jobs.create_job(job_attrs(%{command: "sleep 30", status: "running"}))
      {:ok, pid} = OrcaHub.Jobs.Launcher.launch_main(job)

      {:ok, job} =
        HubRPC.update_job(job, %{
          pid: pid,
          pgid: pid,
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      on_exit(fn -> cleanup(job.id) end)

      # Kill the tracked pid directly (out-of-band, not via pgid) so the
      # wrapper never gets a chance to write a sentinel — simulates an
      # OOM/host-level kill that happened while nobody was watching.
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      wait_until(fn -> not File.exists?("/proc/#{pid}") end)
      refute File.exists?(Paths.sentinel_path(job.id))

      OrcaHub.JobResumer.resume_jobs()

      final = wait_for_status(job.id, ~w(failed succeeded))
      assert final.status == "failed"
      assert final.exit_code == nil
      assert final.progress_note =~ "disappeared without writing an exit sentinel"
    end
  end

  defp wait_until(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries <= 0 do
        flunk("condition not met in time")
      else
        Process.sleep(50)
        wait_until(fun, tries - 1)
      end
    end
  end
end
