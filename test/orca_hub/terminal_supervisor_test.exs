defmodule OrcaHub.TerminalSupervisorTest do
  @moduledoc """
  Stop against a ghost, liveness, and the boot sweep.

  Before the fix, Stop on a terminal whose runner was gone (a node restart)
  returned `{:error, :not_found}`, the LiveViews ignored it, and the row
  read `"running"` forever: nothing reconciled terminals at boot either.
  """
  # async: false — real runners under the shared TerminalSupervisor, and the
  # sweep reads every row of this node.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{TerminalSupervisor, TerminalSweep, Terminals}

  setup do
    dir = Path.join(System.tmp_dir!(), "terminal_sup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp terminal!(dir, attrs) do
    {:ok, terminal} =
      Terminals.create_terminal(Map.merge(%{name: "sup-test", directory: dir}, attrs))

    on_exit(fn -> TerminalSupervisor.stop_terminal(terminal.id) end)
    terminal
  end

  defp here, do: Atom.to_string(node())

  describe "stop_terminal/1 with no live runner" do
    test "reconciles a ghost running row to stopped and broadcasts it", %{dir: dir} do
      terminal = terminal!(dir, %{status: "running", runner_node: here()})
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "terminals")

      assert {:ok, :reconciled} = TerminalSupervisor.stop_terminal(terminal.id)

      assert Terminals.get_terminal(terminal.id).status == "stopped"
      terminal_id = terminal.id
      assert_receive {^terminal_id, {:terminal_status, :stopped}}
    end

    test "leaves an already-stopped row alone", %{dir: dir} do
      terminal = terminal!(dir, %{status: "dead", runner_node: here()})

      assert {:ok, :not_running} = TerminalSupervisor.stop_terminal(terminal.id)
      assert Terminals.get_terminal(terminal.id).status == "dead"
    end

    test "refuses to touch another node's row", %{dir: dir} do
      terminal = terminal!(dir, %{status: "running", runner_node: "orca@some-other-node"})

      assert {:error, {:wrong_node, "orca@some-other-node"}} =
               TerminalSupervisor.stop_terminal(terminal.id)

      assert Terminals.get_terminal(terminal.id).status == "running"
    end
  end

  describe "TerminalSweep.sweep/0" do
    test "marks this node's ghost running rows dead and nothing else", %{dir: dir} do
      ghost = terminal!(dir, %{status: "running", runner_node: here()})
      remote = terminal!(dir, %{status: "running", runner_node: "orca@some-other-node"})
      stopped = terminal!(dir, %{status: "stopped", runner_node: here()})

      marked = TerminalSweep.sweep()

      assert ghost.id in marked
      refute remote.id in marked
      assert Terminals.get_terminal(ghost.id).status == "dead"
      assert Terminals.get_terminal(remote.id).status == "running"
      assert Terminals.get_terminal(stopped.id).status == "stopped"
    end
  end

  describe "with a real runner" do
    if System.find_executable("script") && match?({:unix, :linux}, :os.type()) do
      test "the sweep never marks a terminal whose runner is alive", %{dir: dir} do
        terminal = terminal!(dir, %{})
        {:ok, _pid} = TerminalSupervisor.start_terminal(terminal.id)

        refute terminal.id in TerminalSweep.sweep()
        assert Terminals.get_terminal(terminal.id).status == "running"
      end

      # Suspending the Registry partitions holds the dead runner's entry in
      # place, the window the bare Registry.lookup/2 used to answer yes in.
      test "terminal_alive?/1 is false once stop_terminal/1 returns, before the Registry drops the entry",
           %{dir: dir} do
        terminal = terminal!(dir, %{})
        {:ok, pid} = TerminalSupervisor.start_terminal(terminal.id)

        partitions = registry_partitions()
        Enum.each(partitions, &:sys.suspend/1)

        try do
          assert :ok = TerminalSupervisor.stop_terminal(terminal.id)
          refute Process.alive?(pid)
          assert [{^pid, _}] = Registry.lookup(OrcaHub.TerminalRegistry, terminal.id)
          refute TerminalSupervisor.terminal_alive?(terminal.id)
        after
          Enum.each(partitions, &:sys.resume/1)
        end
      end
    end
  end

  defp registry_partitions do
    OrcaHub.TerminalRegistry
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end
