defmodule OrcaHub.ProcessIsolationTest do
  @moduledoc """
  The runner-facing half of ORCAHUB3-146 against real processes (the env
  marker path every `bin/test` node runs in), plus the reaper/sweeper state
  machine over a fake cgroupfs. End to end through a real SessionRunner:
  `OrcaHub.SessionRunnerTeardownTest`.
  """
  # async: false — the reap goes through the app's named ProcessIsolation
  # server and its :agent_isolation config.
  use ExUnit.Case, async: false

  alias OrcaHub.FakeCgroupfs
  alias OrcaHub.ProcessIsolation
  alias OrcaHub.ProcessIsolation.{Cgroup, Limits, Marker, Spawn}

  @moduletag :tmp_dir

  test "this node runs the marker fallback under bin/test" do
    assert %{mode: :marker} = ProcessIsolation.status()
  end

  describe "wrap/4" do
    test "the wrapper execs the CLI in place: same os_pid, marker set, oom_score_adj raised" do
      spawn = ProcessIsolation.prepare("wrap-test")
      assert spawn.leaf == nil

      {exe, args, env} =
        ProcessIsolation.wrap(
          spawn,
          "/bin/sh",
          [
            "-c",
            ~S|echo "pid=$$ adj=$(cat /proc/self/oom_score_adj) id=$ORCA_AGENT_SPAWN_ID"; exec cat|
          ],
          [{~c"SOME_VAR", ~c"kept"}]
        )

      assert exe == "/bin/sh"
      assert {~c"SOME_VAR", ~c"kept"} in env

      port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args, env: env])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert_receive {^port, {:data, line}}, 2_000
      assert line == "pid=#{os_pid} adj=500 id=#{spawn.id}\n"

      Port.close(port)
      ProcessIsolation.release(spawn, grace_ms: 0)
      assert eventually(fn -> not alive?(os_pid) end)
    end

    test "every spawn of a session gets its own id" do
      a = ProcessIsolation.prepare("same-session")
      b = ProcessIsolation.prepare("same-session")

      assert a.id != b.id
      assert String.starts_with?(a.id, "same-session-")
      ProcessIsolation.release(a, grace_ms: 0)
      ProcessIsolation.release(b, grace_ms: 0)
    end
  end

  describe "ensure_executable!/1" do
    test "raises what Port.open would for a bad CLI path", %{tmp_dir: tmp} do
      assert ProcessIsolation.ensure_executable!("/bin/sh") == :ok

      assert_raise ErlangError, ~r/enoent/, fn ->
        ProcessIsolation.ensure_executable!(Path.join(tmp, "missing"))
      end

      plain = Path.join(tmp, "not-executable")
      File.write!(plain, "#!/bin/sh\n")

      assert_raise ErlangError, ~r/eacces/, fn -> ProcessIsolation.ensure_executable!(plain) end
      assert_raise ErlangError, ~r/eacces/, fn -> ProcessIsolation.ensure_executable!(tmp) end
    end
  end

  describe "Marker" do
    test "finds a marked process and its setsid'd, reparented descendants, nothing else" do
      id = "marker-test-#{System.unique_integer([:positive])}"
      {cli, grandchild} = start_marked_tree(id)
      bystander = start_bystander()

      found = Marker.find(id)
      assert cli in found
      assert grandchild in found
      refute bystander in found
      # An id is matched exactly, never as a prefix.
      assert Marker.find(String.slice(id, 0..-3//1)) == []

      Marker.signal(found, "KILL")
      assert eventually(fn -> not alive?(cli) and not alive?(grandchild) end)
      assert alive?(bystander)
    end
  end

  describe "release/2" do
    test "SIGKILLs what the CLI left once the grace is up, and only that" do
      spawn = ProcessIsolation.prepare("release-test")
      {cli, grandchild} = start_marked_tree(spawn.id)
      bystander = start_bystander()

      ProcessIsolation.release(spawn, grace_ms: 300)
      Process.sleep(100)
      assert alive?(grandchild), "nothing is killed before the grace is up"

      assert eventually(fn -> not alive?(cli) and not alive?(grandchild) end)
      assert alive?(bystander)
    end

    test "release(nil) is a no-op" do
      assert ProcessIsolation.release(nil) == :ok
    end
  end

  test "a runner that dies without releasing (stop_session's path) still has its spawn reaped" do
    test_pid = self()

    runner =
      spawn(fn ->
        spawn = ProcessIsolation.prepare("down-test")
        send(test_pid, {:spawned, spawn})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:spawned, spawn}
    {cli, grandchild} = start_marked_tree(spawn.id)

    send(runner, :exit)
    assert eventually(fn -> not alive?(cli) and not alive?(grandchild) end, 5_000)
  end

  describe "the reaper over a cgroup tree (fake cgroupfs)" do
    setup %{tmp_dir: tmp} do
      {:ok, tree} = Cgroup.detect(FakeCgroupfs.build!(tmp))
      %{tree: tree, limits: Limits.resolve([], 1024 * 1024 * 1024)}
    end

    test "the boot sweep removes empty stale leaves, kills populated ones, and spares live ones",
         %{tree: tree, limits: limits} do
      {:ok, empty, _} = Cgroup.create_leaf(tree, "stale-empty-aaaaaaaaaaaa", limits)
      {:ok, busy, _} = Cgroup.create_leaf(tree, "stale-busy-bbbbbbbbbbbb", limits)
      FakeCgroupfs.set_populated(busy, true)

      live_id = "live-#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.register(OrcaHub.ProcessIsolation.Registry, live_id, nil)
      {:ok, live, _} = Cgroup.create_leaf(tree, live_id, limits)
      FakeCgroupfs.set_populated(live, true)

      {:ok, server} = start_reaper(tree, limits)

      refute File.exists?(empty)
      assert eventually(fn -> FakeCgroupfs.read(busy, "cgroup.kill") == "1" end)
      assert File.dir?(busy), "a populated leaf is never removed"

      # The kill took effect: the next check removes it.
      FakeCgroupfs.set_populated(busy, false)
      assert eventually(fn -> not File.exists?(busy) end)

      assert FakeCgroupfs.read(live, "cgroup.kill") == ""
      assert File.dir?(live)
      GenServer.stop(server)
    end

    test "a released spawn's leaf is killed after the grace, then removed", %{
      tree: tree,
      limits: limits
    } do
      {:ok, server} = start_reaper(tree, limits)
      {:ok, leaf, _} = Cgroup.create_leaf(tree, "rel-cccccccccccc", limits)
      FakeCgroupfs.set_populated(leaf, true)
      spawn = %Spawn{id: "rel-cccccccccccc", session_id: "rel", leaf: leaf}

      GenServer.cast(server, {:reap, spawn, 150})
      Process.sleep(50)
      assert FakeCgroupfs.read(leaf, "cgroup.kill") == ""

      assert eventually(fn -> FakeCgroupfs.read(leaf, "cgroup.kill") == "1" end)
      FakeCgroupfs.set_populated(leaf, false)
      assert eventually(fn -> not File.exists?(leaf) end)
      GenServer.stop(server)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp start_reaper(tree, limits) do
    GenServer.start(ProcessIsolation,
      name: nil,
      persist: false,
      mode: {:cgroup, tree, limits},
      sweep_interval_ms: 0
    )
  end

  # A `sh` carrying the marker, with a setsid'd grandchild that is already
  # reparented to init by the time this returns.
  defp start_marked_tree(id) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: [
          "-c",
          ~S(setsid sh -c 'sleep 300 & echo $!' </dev/null; echo "cli=$$"; exec cat)
        ],
        env: [Marker.env_entry(id)]
      ])

    output = collect(port, "")
    [_, grandchild] = Regex.run(~r/^(\d+)$/m, output)
    [_, cli] = Regex.run(~r/cli=(\d+)/, output)
    cli = String.to_integer(cli)
    grandchild = String.to_integer(grandchild)
    on_exit(fn -> Enum.each([cli, grandchild], &kill_quietly/1) end)
    {cli, grandchild}
  end

  defp collect(port, acc) do
    if acc =~ "cli=" and acc =~ ~r/^\d+$/m do
      acc
    else
      receive do
        {^port, {:data, data}} -> collect(port, acc <> data)
      after
        2_000 -> flunk("marked tree never reported its pids: #{inspect(acc)}")
      end
    end
  end

  defp start_bystander do
    {out, 0} = System.cmd("sh", ["-c", "setsid sleep 300 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()
    on_exit(fn -> kill_quietly(pid) end)
    pid
  end

  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_, after_comm] = String.split(stat, ") ", parts: 2)
        not String.starts_with?(after_comm, ["Z", "X"])

      {:error, _} ->
        false
    end
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        poll(fun, deadline)
    end
  end

  defp kill_quietly(pid) do
    System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    :ok
  end
end
