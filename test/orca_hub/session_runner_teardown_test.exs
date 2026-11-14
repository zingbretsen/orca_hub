defmodule OrcaHub.SessionRunnerTeardownTest do
  @moduledoc """
  ORCAHUB3-146: tearing a session down must take the agent CLI's whole
  process tree with it, not just close the port.

  Drives a real `SessionRunner` against `claude_stub_spawns_children.sh`,
  which leaves behind the three kinds of descendant a real CLI does: a plain
  `&` child, a setsid'd one (Claude's Bash tool starts every shell that
  way), and an orphan that is already reparented to init before teardown
  begins. On 2026-10-11 two orphaned `cargo test` trees outlived both idle
  teardown and archive on gb10 and stalled the node for 11 hours.

  `bin/test` never runs in a delegated cgroup, so this exercises the
  no-delegation path: the one k3s pods, dev boxes and every host whose
  systemd unit predates delegation get.
  """

  # async: false — a real SessionRunner under the shared SessionSupervisor
  # needs the DB sandbox in shared mode, and :claude_executable is global.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, Sessions, SessionSupervisor}

  @stub Path.expand("../support/fixtures/claude_stub_spawns_children.sh", __DIR__)
  @kinds ~w(cli bg setsid orphan)

  setup do
    Application.put_env(:orca_hub, :claude_executable, @stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "teardown-146-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # A red run must not leave 300 s sleeps behind: kill whatever the stub
    # recorded, whether or not teardown got to it first.
    on_exit(fn ->
      dir |> recorded_pids() |> Map.values() |> Enum.each(&kill_quietly/1)
      File.rm_rf(dir)
    end)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        streaming: true,
        runner_node: Atom.to_string(node())
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id) do
        SessionSupervisor.stop_session(session.id)
      end
    end)

    {:ok, session: session, dir: dir}
  end

  test "ORCAHUB3-146: stopping a session kills every process its CLI started, setsid'd and reparented ones included",
       %{session: session, dir: dir} do
    {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert :ok = SessionRunner.send_message(session.id, "start some background work")

    pids = await_descendants(dir)
    assert Enum.all?(Map.values(pids), &alive?/1), "stub descendants should be running"

    # A process the BEAM itself started (the shape of a start_job job) is not
    # the CLI's, and must outlive the session.
    bystander = start_bystander()

    # The stop/archive path: DynamicSupervisor.terminate_child/2, which never
    # reaches SessionRunner.terminate/3.
    assert :ok = SessionSupervisor.stop_session(session.id)

    assert_all_dead(pids)
    assert alive?(bystander), "a process the CLI did not start must survive teardown"
  end

  test "a warm CLI's background work survives between turns, and evict_warm reaps it",
       %{session: session, dir: dir} do
    File.touch!(Path.join(dir, "orca-stub-turns"))
    {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert :ok = SessionRunner.send_message(session.id, "start some background work")

    pids = await_descendants(dir)
    assert wait_until(fn -> SessionRunner.get_state(session.id).status == :idle end)

    # Warm and idle is not torn down: `run_in_background` work has to keep
    # running across turns. Well past the test reap grace (200 ms).
    Process.sleep(600)
    assert Enum.all?(Map.values(pids), &alive?/1), "a warm CLI's children must not be reaped"

    # The WarmPool LRU path (teardown_port/1, shared with idle teardown,
    # rebake, the kill-switch downgrade and a backend switch).
    assert :ok = SessionRunner.evict_warm(session.id)

    assert_all_dead(pids)
    assert SessionSupervisor.session_alive?(session.id)
  end

  test "a one-shot CLI that exits on its own has its leftovers reaped", %{
    session: session,
    dir: dir
  } do
    {:ok, session} = Sessions.update_session(session, %{streaming: false})
    File.touch!(Path.join(dir, "orca-stub-exit"))
    {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert :ok = SessionRunner.send_message(session.id, "start some background work")

    pids = await_descendants(dir)
    assert_all_dead(pids)
  end

  # ORCAHUB3-139's kill-and-respawn: the interrupted CLI's spawn is reaped
  # while its replacement is already running for the same session, so the
  # reap must be per spawn, never per session.
  test "reaping an interrupted one-shot CLI never touches the CLI that replaces it", %{
    session: session,
    dir: dir
  } do
    {:ok, session} = Sessions.update_session(session, %{streaming: false})
    {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert :ok = SessionRunner.send_message(session.id, "first turn")
    first = await_descendants(dir)
    on_exit(fn -> first |> Map.values() |> Enum.each(&kill_quietly/1) end)

    # Mid-turn message: SIGINT, the CLI exits, and the runner auto-resumes on
    # a fresh port whose stub overwrites every pid file.
    assert :ok = SessionRunner.send_message(session.id, "sent mid-turn")

    assert wait_until(
             fn ->
               now = recorded_pids(dir)
               Enum.all?(@kinds, fn kind -> now[kind] not in [nil, first[kind]] end)
             end,
             10_000
           ),
           "expected the respawned CLI to record a fresh set of descendants"

    second = recorded_pids(dir)

    assert_all_dead(first)
    Process.sleep(600)
    assert Enum.all?(Map.values(second), &alive?/1), "the replacement CLI's tree must survive"
  end

  # ── ORCAHUB3-153: a CLI that ignores an interrupt is stopped by force ──
  # Each test writes its own stub CLI into the session dir. The streaming
  # one answers the first stdin line (Claude's warm-up turn), then reads and
  # ignores everything, interrupts included. The one-shot one ignores SIGINT.
  describe "forced stop after an ignored interrupt" do
    setup %{dir: dir} do
      Application.put_env(:orca_hub, :interrupt_force_stop_ms, 300)
      on_exit(fn -> Application.delete_env(:orca_hub, :interrupt_force_stop_ms) end)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
      {:ok, dir: dir}
    end

    test "ORCAHUB3-153: a streaming turn that ignores the stop button ends in error",
         %{session: session, dir: dir} do
      use_stub(dir, :answers_warmup_only)
      {:ok, _pid} = SessionSupervisor.start_session(session.id)
      assert :ok = SessionRunner.send_message(session.id, "a turn that hangs")
      assert wait_until(fn -> stub_reads?(dir, 2) end), "the real turn never reached the stub"

      assert :ok = SessionRunner.interrupt(session.id)
      session_id = session.id
      assert_receive {^session_id, {:status, :error}}, 5_000

      errored = Sessions.get_session!(session.id)
      assert errored.status == "error"
      assert errored.error_detail =~ "stopped the agent CLI by force"
      assert assert_all_dead(%{"cli" => stub_pid(dir)}) == :ok
    end

    test "ORCAHUB3-153: a message that interrupted an ignoring CLI is re-sent after the forced stop",
         %{session: session, dir: dir} do
      use_stub(dir, :answers_warmup_only)
      {:ok, _pid} = SessionSupervisor.start_session(session.id)
      assert :ok = SessionRunner.send_message(session.id, "a turn that hangs")
      assert wait_until(fn -> stub_reads?(dir, 2) end), "the real turn never reached the stub"
      first_cli = stub_pid(dir)

      assert :ok = SessionRunner.send_message(session.id, "the urgent correction")
      session_id = session.id
      assert_receive {^session_id, {:status, :error}}, 5_000

      assert wait_until(fn ->
               Sessions.list_messages(session.id)
               |> Enum.any?(fn m ->
                 text = inspect(m.data)
                 text =~ "stopped the agent CLI by force" and text =~ "the urgent correction"
               end)
             end),
             "the interrupting message was never re-sent"

      assert wait_until(fn -> Sessions.get_session!(session.id).status == "running" end)
      assert assert_all_dead(%{"cli" => first_cli}) == :ok

      assert Enum.any?(
               Sessions.list_messages(session.id),
               &(&1.data["type"] == "cli_error" and
                   &1.data["message"] =~ "stopped the agent CLI by force")
             )
    end

    test "ORCAHUB3-153: a one-shot CLI that ignores SIGINT is killed", %{
      session: session,
      dir: dir
    } do
      {:ok, session} = Sessions.update_session(session, %{streaming: false})
      use_stub(dir, :ignores_sigint)
      {:ok, _pid} = SessionSupervisor.start_session(session.id)
      assert :ok = SessionRunner.send_message(session.id, "a turn that hangs")
      assert wait_until(fn -> stub_pid(dir) != nil end)

      assert :ok = SessionRunner.interrupt(session.id)
      session_id = session.id
      assert_receive {^session_id, {:status, :error}}, 5_000

      assert Sessions.get_session!(session.id).error_detail =~ "stopped the agent CLI by force"
    end

    test "ORCAHUB3-153: a deadline left over from an earlier turn does not stop the next one",
         %{session: session, dir: dir} do
      # The plain noop stub: SIGINT ends it, so the interrupt is obeyed.
      {:ok, session} = Sessions.update_session(session, %{streaming: false})
      use_stub(dir, :obeys_sigint)
      {:ok, _pid} = SessionSupervisor.start_session(session.id)
      assert :ok = SessionRunner.send_message(session.id, "first turn")
      assert wait_until(fn -> stub_pid(dir) != nil end)

      assert :ok = SessionRunner.interrupt(session.id)
      session_id = session.id
      assert_receive {^session_id, {:status, ended}} when ended in [:idle, :error], 5_000
      File.rm!(Path.join(dir, "orca-stub-cli"))

      assert :ok = SessionRunner.send_message(session.id, "second turn")
      assert wait_until(fn -> stub_pid(dir) != nil end)
      second_cli = stub_pid(dir)

      # Well past the first turn's 300 ms deadline.
      Process.sleep(800)
      assert alive?(second_cli), "the first turn's deadline killed the second turn's CLI"
      assert Sessions.get_session!(session.id).status == "running"
    end
  end

  # The stub records its pid in orca-stub-cli and appends one line to
  # orca-stub-reads per stdin line it reads (until it stops reading lines).
  defp use_stub(dir, mode) do
    body =
      case mode do
        :answers_warmup_only ->
          """
          IFS= read -r _line
          echo x >> "$PWD/orca-stub-reads"
          printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"stub-153"}'
          while IFS= read -r _line; do echo x >> "$PWD/orca-stub-reads"; done
          """

        :ignores_sigint ->
          "trap '' INT\nexec cat >/dev/null\n"

        :obeys_sigint ->
          "exec cat >/dev/null\n"
      end

    path = Path.join(dir, "claude-stub-153.sh")
    File.write!(path, "#!/bin/sh\necho $$ > \"$PWD/orca-stub-cli\"\n" <> body)
    File.chmod!(path, 0o755)
    Application.put_env(:orca_hub, :claude_executable, path)
  end

  defp stub_pid(dir) do
    with {:ok, body} <- File.read(Path.join(dir, "orca-stub-cli")),
         {pid, _} <- Integer.parse(String.trim(body)) do
      pid
    else
      _ -> nil
    end
  end

  defp stub_reads?(dir, count) do
    case File.read(Path.join(dir, "orca-stub-reads")) do
      {:ok, body} -> length(String.split(body, "\n", trim: true)) >= count
      _ -> false
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        poll_until(fun, deadline)
    end
  end

  defp await_descendants(dir, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_descendants(dir, deadline)
  end

  defp poll_descendants(dir, deadline) do
    pids = recorded_pids(dir)

    cond do
      map_size(pids) == length(@kinds) ->
        pids

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the stub only recorded #{inspect(Map.keys(pids))} of #{inspect(@kinds)}")

      true ->
        Process.sleep(25)
        poll_descendants(dir, deadline)
    end
  end

  defp recorded_pids(dir) do
    for kind <- @kinds,
        {:ok, body} <- [File.read(Path.join([dir, "orca-stub-pids", kind]))],
        {pid, _} <- [Integer.parse(String.trim(body))],
        into: %{},
        do: {kind, pid}
  end

  # Generous on purpose: the reap waits out a grace period first, and a
  # loaded full-suite run is slow to schedule.
  defp assert_all_dead(pids, timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_dead(pids, deadline)
  end

  defp poll_dead(pids, deadline) do
    survivors = for {kind, pid} <- pids, alive?(pid), do: {kind, pid}

    cond do
      survivors == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("still running after teardown: #{inspect(survivors)}")

      true ->
        Process.sleep(50)
        poll_dead(pids, deadline)
    end
  end

  # Alive means a /proc entry that is not a zombie: a SIGKILLed orphan sits
  # as a zombie until init reaps it, and that counts as dead here.
  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_, after_comm] = String.split(stat, ") ", parts: 2)
        not String.starts_with?(after_comm, ["Z", "X"])

      {:error, _} ->
        false
    end
  end

  # setsid'd from the BEAM, like OrcaHub.Jobs.Launcher, and detached from
  # the port (`&` + exit) so closing it later can't take the sleep with it.
  defp start_bystander do
    {out, 0} = System.cmd("sh", ["-c", "setsid sleep 300 >/dev/null 2>&1 & echo $!"])
    {pid, _} = Integer.parse(String.trim(out))
    on_exit(fn -> kill_quietly(pid) end)
    pid
  end

  defp kill_quietly(pid) when is_integer(pid) and pid > 1 do
    System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    :ok
  end
end
