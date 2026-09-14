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

  # ORCAHUB3-83: this test previously asserted `error_detail == nil` here
  # ("nothing to report"). That WAS the defect — a user staring at a red
  # `error` badge with an empty tooltip and no explanation anywhere. The
  # runner still knows the exit code, the backend and the engine even when
  # the CLI wrote nothing, so it now synthesizes a line from those.
  test "a non-zero exit with no captured output still explains itself", %{session: session} do
    data =
      base_data(session, %{
        error_output: "",
        buffer: "",
        backend: OrcaHub.Backend.Claude,
        engine: :one_shot
      })

    assert {:next_state, :error, _new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 137}}, data)

    updated = Sessions.get_session!(session.id)
    assert updated.status == "error"
    refute is_nil(updated.error_detail)
    assert updated.error_detail =~ "without writing anything"
    assert updated.error_detail =~ "exit code: 137"
    assert updated.error_detail =~ "backend: claude"
    assert updated.error_detail =~ "engine: one_shot"
  end

  test "the synthesized detail also lands in the feed as a cli_error card", %{session: session} do
    data = base_data(session, %{error_output: "", buffer: "", backend: OrcaHub.Backend.Claude})

    assert {:next_state, :error, new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

    card = Enum.find(new_data.messages, &(&1["type"] == "cli_error"))
    refute is_nil(card), "expected a cli_error card even with no CLI output"
    assert card["exit_code"] == 1
    assert card["message"] =~ "without writing anything"
  end

  test "a missing backend/engine never crashes the synthesizer", %{session: session} do
    data = base_data(session, %{error_output: "", buffer: ""}) |> Map.drop([:engine])

    assert {:next_state, :error, _new_data} =
             SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

    updated = Sessions.get_session!(session.id)
    assert updated.error_detail =~ "exit code: 1"
    refute updated.error_detail =~ "backend:"
  end

  describe "streaming result-event errors (result_event_error_detail/2)" do
    test "prefers the event's own error text when it has one" do
      detail =
        SessionRunner.result_event_error_detail(
          %{"is_error" => true, "subtype" => "error_during_execution", "result" => "Boom: 429"},
          %{backend: OrcaHub.Backend.Pi, engine: :streaming, error_output: "", buffer: ""}
        )

      assert detail == "Boom: 429"
    end

    test "falls back to the subtype, backend and buffered output when it has none" do
      detail =
        SessionRunner.result_event_error_detail(
          %{"is_error" => true, "subtype" => "error_max_turns"},
          %{
            backend: OrcaHub.Backend.Pi,
            engine: :streaming,
            error_output: "warning: credential file unreadable\n",
            buffer: ""
          }
        )

      assert detail =~ "failed turn with no error message"
      assert detail =~ "subtype: error_max_turns"
      assert detail =~ "backend: pi"
      assert detail =~ "engine: streaming"
      assert detail =~ "credential file unreadable"
    end

    test "says so explicitly when there was no output at all to fall back on" do
      detail =
        SessionRunner.result_event_error_detail(
          %{"is_error" => true},
          %{backend: OrcaHub.Backend.Codex, engine: :streaming, error_output: "", buffer: ""}
        )

      assert detail =~ "No CLI output was captured."
      assert detail =~ "backend: codex"
    end

    test "a non-string result field is inspected rather than crashing" do
      detail =
        SessionRunner.result_event_error_detail(
          %{"is_error" => true, "result" => %{"code" => 500}},
          %{backend: OrcaHub.Backend.Codex, engine: :streaming, error_output: "", buffer: ""}
        )

      assert detail =~ "500"
    end

    test "the synthesized detail is still capped at the 1000-byte column limit" do
      detail =
        SessionRunner.result_event_error_detail(
          %{"is_error" => true, "result" => String.duplicate("x", 5_000)},
          %{backend: OrcaHub.Backend.Pi, engine: :streaming, error_output: "", buffer: ""}
        )

      assert byte_size(detail) <= 1000 + byte_size("…[truncated]")
      assert String.ends_with?(detail, "…[truncated]")
    end
  end

  describe "a failing streaming WARM-UP turn (the ORCAHUB3-83 incident)" do
    # Session 179cdd7f ("Trigger: Keene Activities") went to `error` with a
    # NULL error_detail. Diagnosed root cause: its `claude_session_id` pointed
    # at a transcript the Claude CLI had already garbage-collected (default
    # `cleanupPeriodDays: 30`), so `--resume` failed instantly — on the HIDDEN
    # warm-up turn. The CLI delivered exactly three port messages:
    #
    #   1. stderr: "No conversation found with session ID: …"
    #   2. stdout: {"type":"result","subtype":"error_during_execution",
    #               "is_error":true,"errors":[<same line>]}
    #   3. exit_status 1
    #
    # (2) used to collapse to :warmup_done regardless of `is_error`, which
    # flushed the queued real prompt into the dying process AND wiped the
    # `error_output` captured from (1) — so by the time (3) arrived there was
    # nothing left to persist. This drives all three through the real
    # callback.
    defp warmup_data(session) do
      %{
        session_id: session.id,
        directory: session.directory,
        port: :fake_port,
        framing: :ndjson,
        backend: OrcaHub.Backend.Claude,
        engine: :streaming,
        buffer: "",
        error_output: "",
        messages: [],
        first_prompt: "hi",
        claude_session_id: "fa7cfb6c-e173-4671-a13b-81146e2be1a8",
        warming_up: true,
        turn_result: nil,
        interrupting: false,
        pending_rebake: false,
        pending_prompts: ["the user's real prompt"],
        pending_questions: nil,
        backend_state: %{},
        turn_started_at: DateTime.utc_now()
      }
    end

    @stderr_line "No conversation found with session ID: fa7cfb6c-e173-4671-a13b-81146e2be1a8\n"

    @result_frame Jason.encode!(%{
                    "type" => "result",
                    "subtype" => "error_during_execution",
                    "duration_ms" => 0,
                    "is_error" => true,
                    "errors" => [
                      "No conversation found with session ID: fa7cfb6c-e173-4671-a13b-81146e2be1a8"
                    ]
                  }) <> "\n"

    test "errors out with the CLI's own reason instead of a NULL detail", %{session: session} do
      data = warmup_data(session)

      # (1) the stderr line lands in error_output, still warming up.
      assert {:keep_state, data} =
               SessionRunner.running(:info, {:fake_port, {:data, @stderr_line}}, data)

      assert data.error_output =~ "No conversation found"
      assert data.warming_up

      # (2) the is_error result is a REAL failure, not a completed warm-up.
      assert {:next_state, :error, data} =
               SessionRunner.running(:info, {:fake_port, {:data, @result_frame}}, data)

      refute data.warming_up

      updated = Sessions.get_session!(session.id)
      assert updated.status == "error"
      assert updated.error_detail =~ "No conversation found with session ID"

      # ...and the feed explains itself too — every other event of a warm-up
      # turn is suppressed, so without this card the user sees their own
      # message and then nothing.
      card = Enum.find(data.messages, &(&1["type"] == "cli_error"))
      refute is_nil(card)
      assert card["message"] =~ "No conversation found with session ID"
    end

    test "does not flush the user's queued prompt into the dying process", %{session: session} do
      data = warmup_data(session)

      assert {:keep_state, data} =
               SessionRunner.running(:info, {:fake_port, {:data, @stderr_line}}, data)

      assert {:next_state, :error, data} =
               SessionRunner.running(:info, {:fake_port, {:data, @result_frame}}, data)

      assert data.pending_prompts == []
      # ...and the warm port is gone, so the next message cold-starts rather
      # than writing into a process that is already on its way out.
      assert data.port == nil
    end

    test "a CLEAN warm-up result still just flushes the queue as before", %{session: session} do
      # A real `cat` port so the flush is observable: the queued real prompt
      # must still reach stdin unchanged when the warm-up turn SUCCEEDS.
      port = Port.open({:spawn, "cat"}, [:binary])
      data = %{warmup_data(session) | port: port}

      frame = Jason.encode!(%{"type" => "result", "subtype" => "success"}) <> "\n"

      assert {:keep_state, data} = SessionRunner.running(:info, {port, {:data, frame}}, data)

      assert_receive {^port, {:data, echoed}}, 1000
      assert echoed =~ "the user's real prompt"
      refute data.warming_up
      assert data.pending_prompts == []

      Port.close(port)
      assert Sessions.get_session!(session.id).status == "running"
    end
  end

  # The rescue_turn_start spawn-failure path (open_port/spawn_spec raising
  # before a port ever opens) needs a fully-populated runner `data` struct to
  # exercise safely — that's covered against a REAL SessionRunner in
  # `OrcaHub.Backend.CodexStubIntegrationTest`'s "a spawn failure lands as a
  # cli_error card instead of crashing the runner" test.
end
