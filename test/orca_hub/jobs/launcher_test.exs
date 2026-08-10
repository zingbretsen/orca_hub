defmodule OrcaHub.Jobs.LauncherTest do
  @moduledoc """
  Exercises `OrcaHub.Jobs.Launcher` against REAL detached OS processes (no
  mocking) — automates the same manual proof done by hand while designing
  the Jobs subsystem: pid == pgid == sid, the wrapper survives this test
  process never touching it again, and the sentinel captures the real exit
  code (clean and non-zero).
  """

  # DataCase (not plain ExUnit.Case) so OrcaHub.NodePolicy.scrub_session_env?/0
  # — consulted by Launcher's job_env/0 — has a real Sandbox-checked-out DB
  # connection to query against instead of noisily failing open every call.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Jobs.{Launcher, Paths}

  defp fake_job(id, command, verify_command \\ nil) do
    %{
      id: id,
      directory: System.tmp_dir!(),
      command: command,
      verify_command: verify_command
    }
  end

  defp unique_id, do: "launcher-test-#{System.unique_integer([:positive])}"

  defp cleanup(id) do
    [
      Paths.cmd_script_path(id),
      Paths.wrapper_script_path(id),
      Paths.log_path(id),
      Paths.sentinel_path(id),
      Paths.pid_path(id),
      Paths.sentinel_path(id) <> ".tmp",
      Paths.verify_cmd_script_path(id),
      Paths.verify_wrapper_script_path(id),
      Paths.verify_log_path(id),
      Paths.verify_sentinel_path(id),
      Paths.verify_pid_path(id),
      Paths.verify_sentinel_path(id) <> ".tmp"
    ]
    |> Enum.each(&File.rm/1)
  end

  describe "launch_main/1" do
    test "runs the command detached, writes the log, and captures a clean exit code" do
      id = unique_id()
      on_exit(fn -> cleanup(id) end)

      job = fake_job(id, "echo hello-from-job; exit 0")
      assert {:ok, pid} = Launcher.launch_main(job)
      assert is_integer(pid)

      wait_until(fn -> File.exists?(Paths.sentinel_path(id)) end)

      assert File.read!(Paths.sentinel_path(id)) == "0"
      assert File.read!(Paths.log_path(id)) =~ "hello-from-job"
    end

    test "pid is its own process group AND session leader (setsid, no fork)" do
      id = unique_id()
      on_exit(fn -> cleanup(id) end)

      job = fake_job(id, "sleep 2")
      assert {:ok, pid} = Launcher.launch_main(job)

      {out, 0} = System.cmd("ps", ["-o", "pid=,pgid=,sid=", "-p", to_string(pid)])
      [pid_str, pgid_str, sid_str] = out |> String.trim() |> String.split(~r/\s+/)

      assert pid_str == to_string(pid)
      assert pgid_str == to_string(pid)
      assert sid_str == to_string(pid)
    end

    test "captures a non-zero exit code" do
      id = unique_id()
      on_exit(fn -> cleanup(id) end)

      job = fake_job(id, "exit 17")
      assert {:ok, _pid} = Launcher.launch_main(job)

      wait_until(fn -> File.exists?(Paths.sentinel_path(id)) end)
      assert File.read!(Paths.sentinel_path(id)) == "17"
    end

    test "survives sending TERM to the negative pgid killing the whole group" do
      id = unique_id()
      on_exit(fn -> cleanup(id) end)

      job = fake_job(id, "sleep 30 & wait")
      assert {:ok, pid} = Launcher.launch_main(job)
      assert File.exists?("/proc/#{pid}")

      System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
      wait_until(fn -> not File.exists?("/proc/#{pid}") end)

      refute File.exists?("/proc/#{pid}")
      # The group-kill kills the wrapper before it can write the sentinel —
      # this is the exact reason OrcaHub.JobWatcher doesn't wait on a
      # sentinel to finalize a cancel/timeout.
      refute File.exists?(Paths.sentinel_path(id))
    end
  end

  describe "launch_verify/1" do
    test "runs verify_command against its own log/sentinel, distinct from the main phase's" do
      id = unique_id()
      on_exit(fn -> cleanup(id) end)

      job = fake_job(id, "exit 0", "echo verified; exit 0")
      assert {:ok, _pid} = Launcher.launch_verify(job)

      wait_until(fn -> File.exists?(Paths.verify_sentinel_path(id)) end)

      assert File.read!(Paths.verify_sentinel_path(id)) == "0"
      assert File.read!(Paths.verify_log_path(id)) =~ "verified"
      refute File.exists?(Paths.sentinel_path(id))
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
