defmodule OrcaHub.TerminalRunnerTest do
  @moduledoc """
  Real-PTY coverage for `OrcaHub.TerminalRunner`'s lifecycle: every stop
  path must kill the shell's whole process tree, not just close the port.

  Before the fix a stop was a bare `Port.close/1` (and, through the
  supervisor, not even that ran `terminate/2`): a shell running a
  foreground job, and every `nohup`ed job, outlived the terminal.
  """
  # async: false — the runner is started under the shared TerminalSupervisor
  # and talks to the DB from its own process (shared sandbox mode).
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{OSProcess, TerminalRunner, TerminalSupervisor, Terminals}

  unless System.find_executable("script") && match?({:unix, :linux}, :os.type()) do
    @moduletag skip: "needs util-linux script(1) and /proc"
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "terminal_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, terminal} =
      Terminals.create_terminal(%{name: "runner-test", directory: dir, shell: "/bin/bash"})

    on_exit(fn ->
      TerminalSupervisor.stop_terminal(terminal.id)
      File.rm_rf(dir)
    end)

    {:ok, terminal: terminal}
  end

  # Starts the terminal and returns `{runner_pid, script_pid, bash_pid}` once
  # bash is up under script.
  defp start!(terminal) do
    {:ok, pid} = TerminalSupervisor.start_terminal(terminal.id)
    script_pid = :sys.get_state(pid).os_pid
    bash_pid = eventually(fn -> List.first(children(script_pid)) end)
    {pid, script_pid, bash_pid}
  end

  # Types `cmd` into the shell and waits for the process it starts to show
  # up as a child of bash; returns that child's pid.
  defp run_in_shell!(terminal, bash_pid, cmd) do
    before = children(bash_pid)
    TerminalRunner.write(terminal.id, cmd <> "\n")
    eventually(fn -> List.first(children(bash_pid) -- before) end)
  end

  defp children(pid) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, text} -> text |> String.split() |> Enum.map(&String.to_integer/1)
      {:error, _} -> []
    end
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ when attempts > 0 ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      _ ->
        flunk("condition never became true")
    end
  end

  defp assert_all_gone(pids, within_ms) do
    deadline = System.monotonic_time(:millisecond) + within_ms
    wait_gone(pids, deadline)
  end

  defp wait_gone(pids, deadline) do
    alive = Enum.filter(pids, &OSProcess.alive?/1)

    cond do
      alive == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("still alive after stop: #{inspect(alive)}")

      true ->
        Process.sleep(20)
        wait_gone(pids, deadline)
    end
  end

  describe "stop kills the shell's whole process tree" do
    test "stop_terminal kills bash, its foreground job and a nohup'd job within a second",
         %{terminal: terminal} do
      {_pid, script_pid, bash_pid} = start!(terminal)

      nohup_pid = run_in_shell!(terminal, bash_pid, "nohup sleep 300 >/dev/null 2>&1 &")
      sleep_pid = run_in_shell!(terminal, bash_pid, "sleep 300")

      assert :ok = TerminalSupervisor.stop_terminal(terminal.id)

      assert_all_gone([script_pid, bash_pid, sleep_pid, nohup_pid], 1_000)
      assert Terminals.get_terminal(terminal.id).status == "stopped"
    end

    test "the row's runner_node survives a stop, so a restart stays on the same node",
         %{terminal: terminal} do
      start!(terminal)
      assert :ok = TerminalSupervisor.stop_terminal(terminal.id)

      assert Terminals.get_terminal(terminal.id).runner_node == Atom.to_string(node())
    end

    test "deleting the row stops the runner and kills its tree", %{terminal: terminal} do
      {pid, script_pid, bash_pid} = start!(terminal)
      sleep_pid = run_in_shell!(terminal, bash_pid, "sleep 300")
      ref = Process.monitor(pid)

      {:ok, _} = Terminals.delete_terminal(Terminals.get_terminal!(terminal.id))

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :deleted}}, 1_000
      assert_all_gone([script_pid, bash_pid, sleep_pid], 1_000)
    end

    test "a row deleted behind the runner's back is noticed by the row check",
         %{terminal: terminal} do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          TerminalSupervisor,
          {TerminalRunner, terminal_id: terminal.id, row_check_ms: 50}
        )

      script_pid = :sys.get_state(pid).os_pid
      bash_pid = eventually(fn -> List.first(children(script_pid)) end)
      ref = Process.monitor(pid)

      # Straight past Terminals.delete_terminal/1, so no control broadcast.
      OrcaHub.Repo.delete!(Terminals.get_terminal!(terminal.id))

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :deleted}}, 1_000
      assert_all_gone([script_pid, bash_pid], 1_000)
    end

    test "a brutally killed runner's tree is still reaped (ProcessIsolation's monitor)",
         %{terminal: terminal} do
      {pid, script_pid, bash_pid} = start!(terminal)
      sleep_pid = run_in_shell!(terminal, bash_pid, "sleep 300")

      Process.exit(pid, :kill)

      # The monitor path waits out the reaper's default grace (3 s).
      assert_all_gone([script_pid, bash_pid, sleep_pid], 6_000)
    end
  end

  describe "the shell exiting on its own" do
    test "exit marks the row dead and broadcasts exactly one terminal_exit, no stopped status",
         %{terminal: terminal} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal.id}")
      {pid, _script_pid, bash_pid} = start!(terminal)
      ref = Process.monitor(pid)

      TerminalRunner.write(terminal.id, "exit 3\n")

      assert_receive {:terminal_exit, 3}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      refute_receive {:terminal_exit, _}, 200
      refute_received {:terminal_status, :stopped}

      assert Terminals.get_terminal(terminal.id).status == "dead"
      assert_all_gone([bash_pid], 1_000)
    end
  end
end
