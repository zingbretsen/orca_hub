defmodule OrcaHub.OSProcessTest do
  @moduledoc """
  `OrcaHub.OSProcess` against real processes, plus the callers that used to
  exec an external `kill` with a negative pid (ORCAHUB3-150). `async: false`
  because `OrcaHub.FakeKill` rewrites the OS-global `PATH`.
  """

  use ExUnit.Case, async: false

  alias OrcaHub.{FakeKill, OSProcess}
  alias OrcaHub.MCP.Tools.Artifacts, as: ArtifactsTool

  # Above every host's pid_max (4194304), so no such group can ever exist.
  @no_such_pgid 1_073_741_823

  describe "signal_group/2 guards" do
    test "refuses anything but an integer pgid > 1" do
      for pgid <- [nil, 0, 1, -1, -5, -1_997_685, "1234", 12.0, :pgid] do
        assert OSProcess.signal_group(pgid, "TERM") == {:error, {:invalid_pid, pgid}}
      end
    end

    test "accepts only allow-listed signal names" do
      for sig <- ["STOP", "SIGTERM", "9", "-1", :TERM, nil, ~s(TERM" -- "-1)] do
        assert OSProcess.signal_group(@no_such_pgid, sig) == {:error, {:invalid_signal, sig}}
      end
    end

    test "refuses the BEAM's own process group" do
      assert OSProcess.signal_group(own_pgid(), "0") == {:error, :own_process}
    end

    test "a group that does not exist is an error, not a silent :ok" do
      assert {:error, {:kill_failed, 1, _msg}} = OSProcess.signal_group(@no_such_pgid, "0")
    end
  end

  describe "signal_group/2 against a real process group" do
    test "TERM reaches every member; a bystander group is untouched" do
      {target, pgid} = start_group!("sleep 300 & sleep 300 & echo started; wait")
      {bystander, bystander_pgid} = start_group!("sleep 300 & echo started; wait")
      members = group_members(pgid)
      assert length(members) == 3, "expected sh + 2 sleeps, got #{inspect(members)}"
      assert OSProcess.group_alive?(pgid)

      assert OSProcess.signal_group(pgid, "TERM") == :ok

      assert eventually(fn -> not OSProcess.group_alive?(pgid) end)
      assert Enum.all?(members, &(not OSProcess.alive?(&1)))
      assert_receive {^target, {:exit_status, _}}, 1_000
      assert OSProcess.group_alive?(bystander_pgid)

      assert OSProcess.signal_group(bystander_pgid, "KILL") == :ok
      assert_receive {^bystander, {:exit_status, _}}, 1_000
    end

    test "never execs an external kill" do
      log = FakeKill.install!()
      {port, pgid} = start_group!("sleep 300 & echo started; wait")

      assert OSProcess.signal_group(pgid, "KILL") == :ok
      assert_receive {^port, {:exit_status, _}}, 1_000
      assert FakeKill.invocations(log) == []
    end
  end

  describe "signal_pids/2" do
    test "signals each pid, refuses the whole call on one bad pid" do
      {port, pid} = start_group!("echo started; exec sleep 300")

      assert OSProcess.signal_pids([pid, 1], "KILL") == {:error, {:invalid_pid, 1}}
      assert OSProcess.alive?(pid)

      own = String.to_integer(System.pid())
      assert OSProcess.signal_pids([pid, own], "KILL") == {:error, :own_process}

      assert OSProcess.signal_pids([pid], "KILL") == :ok
      assert_receive {^port, {:exit_status, _}}, 1_000
    end
  end

  describe "alive?/1" do
    test "a zombie (exited, never reaped) is not alive" do
      # `exec sleep` replaces the shell, so nothing reaps the child. It must
      # exit AFTER the exec: a child that is already done when the shell
      # reaches `exec` gets reaped by the shell itself.
      {port, _pgid, line} = start_group_line!("sleep 0.2 & echo $!; exec sleep 300")
      zombie = String.to_integer(line)
      assert eventually(fn -> stat_state(zombie) == "Z" end)

      refute OSProcess.alive?(zombie)
      assert File.exists?("/proc/#{zombie}")
      Port.close(port)
    end

    test "is false for a non-pid" do
      refute OSProcess.alive?(nil)
      refute OSProcess.alive?(0)
      refute OSProcess.alive?(@no_such_pgid)
    end
  end

  describe "callers never exec an external kill" do
    test "ORCAHUB3-150: run_bounded's timeout kills the process tree without exec'ing an external kill" do
      log = FakeKill.install!()

      pidfile =
        Path.join(System.tmp_dir!(), "os_process_test_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(pidfile) end)

      assert ArtifactsTool.run_bounded(
               "sh",
               ["-c", "sh -c 'echo $$ > #{pidfile}; sleep 20' & wait"],
               200
             ) == {:error, "playwright timed out after 200ms"}

      grandchild = pidfile |> File.read!() |> String.trim() |> String.to_integer()

      on_exit(fn ->
        System.cmd("/bin/sh", [
          "-c",
          ~s(kill -s KILL "$1" 2>/dev/null; exit 0),
          "sh",
          "#{grandchild}"
        ])
      end)

      assert FakeKill.invocations(log) == []
      assert eventually(fn -> not File.exists?("/proc/#{grandchild}") end)
    end
  end

  # A Port child leads its own session and group (erl_child_setup setsid()s
  # it), so its os_pid is a disposable pgid. Waits for the script's first
  # line so the backgrounded members exist before the test looks.
  defp start_group!(script) do
    {port, pgid, _first_line} = start_group_line!(script)
    {port, pgid}
  end

  defp start_group_line!(script) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", script]])

    {:os_pid, pgid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/sh", ["-c", ~s(kill -s KILL -- "-$1" 2>/dev/null; exit 0), "sh", "#{pgid}"])
    end)

    assert_receive {^port, {:data, line}}, 2_000
    {port, pgid, String.trim(line)}
  end

  # Every pid (zombies included) whose pgrp is `pgid`, straight from /proc.
  defp group_members(pgid) do
    for entry <- File.ls!("/proc"),
        {pid, ""} <- [Integer.parse(entry)],
        match?([_state, _ppid, ^pgid | _], stat_fields(entry)),
        do: pid
  end

  # From ps, not /proc/self, so the test does not share the helper's source.
  defp own_pgid do
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", System.pid()])
    out |> String.trim() |> String.to_integer()
  end

  # `[state, ppid, pgrp, ...]`, numbers as integers. Split at the LAST `)`.
  defp stat_fields(entry) do
    with {:ok, contents} <- File.read("/proc/#{entry}/stat"),
         [rest | _] <- contents |> String.split(")") |> Enum.reverse() do
      [state | numbers] = String.split(rest)
      [state | Enum.map(Enum.take(numbers, 2), &String.to_integer/1)]
    else
      _ -> []
    end
  end

  defp stat_state(pid), do: pid |> stat_fields() |> List.first()

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end
end
