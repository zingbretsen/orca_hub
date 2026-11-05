defmodule OrcaHub.SessionSupervisorTest do
  @moduledoc """
  Coverage for the cleanup-on-stop fix (backend_abstraction_spec.md §10 Q5
  addendum). `stop_session/1` terminates the runner via
  `DynamicSupervisor.terminate_child/2`, which sends a raw exit signal —
  since `SessionRunner` (a `:gen_statem`) never traps exits, its
  `terminate/3` callback (which normally runs `backend.cleanup_session/1`)
  never fires on this path. `stop_session/1` now calls `cleanup_session/1`
  directly after the child is confirmed terminated.

  Historical note: this used to assert a filesystem side effect — Codex's
  per-session `CODEX_HOME` directory being removed on an explicit stop. That
  directory no longer exists (2026-07 migration to `-c` config overrides over
  the real `~/.codex` home — see `OrcaHub.Backend.Codex`); `cleanup_session/1`
  is a no-op for every current backend, so the first two tests below now just
  assert `stop_session/1` completes cleanly regardless.
  """

  # async: false — starts a real SessionRunner (GenStatem) child under the
  # shared OrcaHub.SessionSupervisor, which needs the DB sandbox in SHARED
  # mode to read the session back in init/1 (see codex_stub_integration_test.exs
  # for the same pattern).
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, SessionSupervisor, Sessions}

  @stub_script Path.expand("../support/fixtures/codex_stub_app_server.py", __DIR__)

  setup do
    refute is_nil(System.find_executable("python3")),
           "python3 not found — required to run the codex app-server stub fixture"

    Application.put_env(:orca_hub, :codex_executable, @stub_script)
    on_exit(fn -> Application.delete_env(:orca_hub, :codex_executable) end)

    dir = Path.join(System.tmp_dir!(), "stop_cleanup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "codex",
        model: nil,
        code_exec: false,
        orchestrator: false
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id) do
        SessionSupervisor.stop_session(session.id)
      end
    end)

    {:ok, session: session, dir: dir}
  end

  test "stop_session/1 completes cleanly for a Codex session even though it bypasses SessionRunner.terminate/3",
       %{session: session} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    assert wait_until(fn -> SessionRunner.get_state(session.id).status != :ready end),
           "expected the turn to actually open the port before stopping"

    assert SessionSupervisor.stop_session(session.id) == :ok
    refute SessionSupervisor.session_alive?(session.id)
  end

  test "stop_session/1 is still a no-op-safe cleanup for Claude sessions (cleanup_session/1 is :ok)",
       %{dir: dir} do
    {:ok, claude_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        model: nil,
        code_exec: false,
        orchestrator: false
      })

    assert {:ok, _pid} = SessionSupervisor.start_session(claude_session.id)
    assert SessionSupervisor.stop_session(claude_session.id) == :ok
    refute SessionSupervisor.session_alive?(claude_session.id)
  end

  # Under full-suite load the Registry partition handled the dead runner's
  # EXIT after stop_session/1 returned, so a bare Registry.lookup/2 still saw
  # it and api_run_controller_test's `refute session_alive?` flaked.
  # Suspending the partitions holds that stale entry in place deterministically.
  test "session_alive?/1 is false once stop_session/1 returns, even before the Registry drops the entry",
       %{dir: dir} do
    {:ok, claude_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        model: nil,
        code_exec: false,
        orchestrator: false
      })

    assert {:ok, pid} = SessionSupervisor.start_session(claude_session.id)

    partitions = registry_partitions()
    Enum.each(partitions, &:sys.suspend/1)

    try do
      assert SessionSupervisor.stop_session(claude_session.id) == :ok
      refute Process.alive?(pid)
      assert [{^pid, _}] = Registry.lookup(OrcaHub.SessionRegistry, claude_session.id)
      refute SessionSupervisor.session_alive?(claude_session.id)
    after
      Enum.each(partitions, &:sys.resume/1)
    end
  end

  defp registry_partitions do
    OrcaHub.SessionRegistry
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
