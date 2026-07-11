defmodule OrcaHub.SessionRunnerProgressTest do
  @moduledoc """
  Coverage for report_progress's self-reported phase being cleared at the
  start of every new turn (backend_abstraction_spec adjacent — orchestration
  observability batch). A worker that reports `phase: "validating"` and then
  goes idle/error must not have that phase survive into its NEXT turn — an
  orchestrator peeking via search_sessions/get_session_tail would otherwise
  see a stale phase from a prior turn as if it described current work.

  Drives a REAL `SessionRunner` (via `SessionSupervisor`) with the same
  `claude_stub_noop.sh` stand-in `session_runner_lifecycle_notify_test.exs`
  uses — it just reads/discards stdin until the port closes, so the turn
  never itself completes. That's fine here: the progress fields are cleared
  synchronously at turn START (inside `start_running`, before the CLI does
  anything), so asserting right after `send_message/2` returns is sufficient.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, SessionSupervisor, Sessions}

  @claude_stub Path.expand("../support/fixtures/claude_stub_noop.sh", __DIR__)

  setup do
    Application.put_env(:orca_hub, :claude_executable, @claude_stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "progress_clear_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.stop_session(session_id)
    end
  end

  test "a stale phase from a prior turn is cleared the moment a new turn starts", %{dir: dir} do
    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        status: "idle",
        progress_phase: "validating",
        progress_note: "stale from a previous turn",
        progress_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    on_exit(fn -> stop_if_alive(session.id) end)

    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "start a new turn") == :ok

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "running"
    assert reloaded.progress_phase == nil
    assert reloaded.progress_note == nil
    assert reloaded.progress_updated_at == nil
  end

  test "a session with no prior progress starts a turn normally (no crash, still clears)", %{
    dir: dir
  } do
    {:ok, session} = Sessions.create_session(%{directory: dir, status: "ready"})
    on_exit(fn -> stop_if_alive(session.id) end)

    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "hi") == :ok

    reloaded = Sessions.get_session!(session.id)
    assert reloaded.status == "running"
    assert reloaded.progress_phase == nil
  end
end
