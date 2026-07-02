defmodule OrcaHub.SessionSupervisorTest do
  @moduledoc """
  Coverage for the cleanup-on-stop fix (backend_abstraction_spec.md §10 Q5
  addendum). `stop_session/1` terminates the runner via
  `DynamicSupervisor.terminate_child/2`, which sends a raw exit signal —
  since `SessionRunner` (a `:gen_statem`) never traps exits, its
  `terminate/3` callback (which normally runs `backend.cleanup_session/1`)
  never fires on this path. `stop_session/1` now calls `cleanup_session/1`
  directly after the child is confirmed terminated, so Codex's per-session
  `CODEX_HOME` directory is still removed on an explicit stop.
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

  test "stop_session/1 removes Codex's CODEX_HOME even though it bypasses SessionRunner.terminate/3",
       %{session: session, dir: dir} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    codex_home = Path.join([dir, ".codex_home", session.id])

    # prepare_session/1 materializes CODEX_HOME on spawn — wait for the turn
    # to actually open the port (real filesystem side effect, not something
    # get_state's in-memory status alone proves).
    assert wait_until(fn -> File.dir?(codex_home) end),
           "expected #{codex_home} to be created by Backend.Codex.prepare_session/1"

    assert SessionSupervisor.stop_session(session.id) == :ok

    refute SessionSupervisor.session_alive?(session.id)
    refute File.dir?(codex_home), "expected #{codex_home} to be removed by cleanup_session/1"
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
