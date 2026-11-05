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

  # Collects PTY output until it matches `pattern`; returns the output.
  defp await_output(pattern, timeout \\ 2_000, acc \\ "") do
    receive do
      {:terminal_output, data} ->
        acc = acc <> data
        if acc =~ pattern, do: acc, else: await_output(pattern, timeout, acc)
    after
      timeout -> flunk("never saw #{inspect(pattern)} in output: #{inspect(acc)}")
    end
  end

  describe "resize" do
    test "a fresh start opens the pty at the row's stored size, not 0x0", %{terminal: terminal} do
      {:ok, terminal} = Terminals.update_terminal(terminal, %{cols: 132, rows: 43})
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal.id}")
      start!(terminal)
      await_output(~r/\$ /)
      # The first output is what lets the size through; give it a beat.
      Process.sleep(150)

      TerminalRunner.write(terminal.id, "stty size\n")

      assert await_output(~r/\r43 132\r\n/) =~ "43 132"
    end

    test "the last of a burst of resizes reaches the pty and the row", %{terminal: terminal} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal.id}")
      {pid, script_pid, _bash_pid} = start!(terminal)
      await_output(~r/\$ /)

      for {cols, rows} <- [{80, 24}, {90, 25}, {101, 33}],
          do: TerminalRunner.resize(terminal.id, cols, rows)

      eventually(fn -> :sys.get_state(pid).applied_size == {101, 33} end)
      TerminalRunner.write(terminal.id, "stty size\n")

      assert await_output(~r/\r33 101\r\n/) =~ "33 101"
      assert TerminalRunner.pty_slave(script_pid) =~ ~r{^/dev/pts/\d+$}

      row = Terminals.get_terminal(terminal.id)
      assert {row.cols, row.rows} == {101, 33}
    end

    test "nonsense sizes are ignored", %{terminal: terminal} do
      {pid, _script_pid, _bash_pid} = start!(terminal)

      TerminalRunner.resize(terminal.id, 0, 40)
      TerminalRunner.resize(terminal.id, 120, 100_000)

      state = :sys.get_state(pid)
      assert {state.cols, state.rows} == {120, 40}
    end
  end

  describe "idle teardown" do
    defp start_with!(terminal, opts) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          TerminalSupervisor,
          {TerminalRunner, [terminal_id: terminal.id] ++ opts}
        )

      script_pid = :sys.get_state(pid).os_pid
      bash_pid = eventually(fn -> List.first(children(script_pid)) end)
      {pid, script_pid, bash_pid}
    end

    test "with no client and no output it stops, notes why, and kills the tree",
         %{terminal: terminal} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal.id}")
      {pid, script_pid, bash_pid} = start_with!(terminal, idle_timeout_ms: 300)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}, 2_000
      assert await_output(~r/no viewer and no output/) =~ "Terminal stopped"
      assert_all_gone([script_pid, bash_pid], 1_000)
      assert Terminals.get_terminal(terminal.id).status == "stopped"
    end

    test "an attached client keeps it running; its leaving restarts the clock",
         %{terminal: terminal} do
      {pid, _script_pid, _bash_pid} = start_with!(terminal, idle_timeout_ms: 300)
      client = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, _scrollback} = TerminalRunner.attach(terminal.id, client)
      ref = Process.monitor(pid)

      refute_receive {:DOWN, ^ref, _, _, _}, 800

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}, 2_000
    end

    test "PTY output alone keeps it running", %{terminal: terminal} do
      {pid, _script_pid, bash_pid} = start_with!(terminal, idle_timeout_ms: 800)
      run_in_shell!(terminal, bash_pid, "while true; do echo tick; sleep 0.1; done")
      ref = Process.monitor(pid)

      refute_receive {:DOWN, ^ref, _, _, _}, 2_000
    end

    test "0 disables it", %{terminal: terminal} do
      {pid, _script_pid, _bash_pid} = start_with!(terminal, idle_timeout_ms: 0)
      assert :sys.get_state(pid).idle_timer == nil
    end

    test "ORCA_TERMINAL_IDLE_TIMEOUT_MINUTES (app env) is the default", %{terminal: terminal} do
      previous = Application.get_env(:orca_hub, :terminal_idle_timeout_minutes)
      Application.put_env(:orca_hub, :terminal_idle_timeout_minutes, 7)
      on_exit(fn -> Application.put_env(:orca_hub, :terminal_idle_timeout_minutes, previous) end)

      {pid, _script_pid, _bash_pid} = start!(terminal)
      assert :sys.get_state(pid).idle_timeout_ms == 7 * 60_000
    end
  end

  describe "truncate_scrollback/2" do
    test "starts the kept window after the first newline, not mid escape sequence" do
      data = "old line\n\e[01;32mprompt\e[00m$ ls\nfile\n"
      # Cut so the window opens inside "\e[01;32m".
      kept = TerminalRunner.truncate_scrollback(data, byte_size(data) - 11)

      assert kept == "file\n"
    end

    test "keeps the raw tail when no newline is near" do
      data = String.duplicate("x", 10_000)
      assert TerminalRunner.truncate_scrollback(data, 5_000) == String.duplicate("x", 5_000)
    end

    test "leaves data under the limit alone" do
      assert TerminalRunner.truncate_scrollback("abc", 10) == "abc"
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
