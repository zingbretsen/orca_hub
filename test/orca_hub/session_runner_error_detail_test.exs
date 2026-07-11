defmodule OrcaHub.SessionRunnerErrorDetailTest do
  @moduledoc """
  Regression coverage for feedback item 2 (orchestrator-feedback-2026-07-10):
  a `start_session` call with a bad model alias ("sonnet-5") was accepted,
  the CLI died ~2s later, and `search_sessions` showed only `status: "error"`
  with nothing to explain why. `SessionRunner` now persists a concise
  `error_detail` on the session whenever it lands in `:error`, and clears it
  on the next successful run.

  These drive the GenStatem `running/3` callback directly (a plain public
  function under `callback_mode: :state_functions`) against a REAL DB-backed
  session — no live port/process needed, since a fabricated `:info`
  `{port, {:exit_status, code}}` message just needs `data.port` to match the
  message's port for the callback to accept it (see
  `StreamingRunnerTest`'s `flag_data/1` for the same pattern).
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, Sessions}

  defp base_data(session, overrides) do
    Map.merge(
      %{
        session_id: session.id,
        directory: session.directory,
        port: :fake_port,
        engine: :one_shot,
        pending_prompts: [],
        pending_questions: nil,
        buffer: "",
        error_output: "",
        messages: [],
        first_prompt: "hi"
      },
      overrides
    )
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "err_detail_test_#{System.unique_integer([:positive])}")

    {:ok, session} =
      Sessions.create_session(%{directory: dir, status: "running", title: "already-titled"})

    {:ok, session: session}
  end

  test "a non-zero one-shot exit persists the CLI's output as error_detail, truncated", %{
    session: session
  } do
    data = base_data(session, %{error_output: "Error: model not found: sonnet-5\n"})

    assert {:next_state, :error, _new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

    updated = Sessions.get_session!(session.id)
    assert updated.status == "error"
    assert updated.error_detail == "Error: model not found: sonnet-5"
  end

  test "a clean (code 0) exit clears any stale error_detail", %{session: session} do
    {:ok, _} = Sessions.update_session(session, %{status: "error", error_detail: "boom"})

    data = base_data(session, %{error_output: ""})

    assert {:next_state, :idle, _new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

    updated = Sessions.get_session!(session.id)
    assert updated.status == "idle"
    assert updated.error_detail == nil
  end

  test "a non-zero exit with no captured output leaves error_detail nil (nothing to report)", %{
    session: session
  } do
    data = base_data(session, %{error_output: "", buffer: ""})

    assert {:next_state, :error, _new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

    updated = Sessions.get_session!(session.id)
    assert updated.status == "error"
    assert updated.error_detail == nil
  end

  # The rescue_turn_start spawn-failure path (open_port/spawn_spec raising
  # before a port ever opens) needs a fully-populated runner `data` struct to
  # exercise safely — that's covered against a REAL SessionRunner in
  # `OrcaHub.Backend.CodexStubIntegrationTest`'s "a spawn failure lands as a
  # cli_error card instead of crashing the runner" test.
end
