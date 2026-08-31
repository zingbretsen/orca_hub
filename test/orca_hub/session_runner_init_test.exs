defmodule OrcaHub.SessionRunnerInitTest do
  @moduledoc """
  Coverage for the cold-start fix in perf_session_load.md item 1a:
  `SessionRunner.init/1` used to pull a session's ENTIRE message history
  into memory just to decide `:ready` vs `:idle` and (rarely) reconstruct
  `pending_questions` — the dominant cost of a cold mount for a long
  session (264-330ms one-time tax on a 4,000+-message session). It now
  loads only a bounded tail (`@init_history_window`, see
  `init_history_window/0`).

  `init/1` is called directly here (not via `SessionSupervisor.start_session/1`)
  since it's a plain public function once GenStatem's `callback_mode` is
  `:state_functions` — no live port/CLI subprocess needed to exercise it.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{AskUserQuestion, SessionRunner, Sessions}
  alias OrcaHub.Sessions.Message

  @init_history_window SessionRunner.init_history_window()

  setup do
    dir = Path.join(System.tmp_dir!(), "runner_init_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} = Sessions.create_session(%{directory: dir, backend: "claude"})

    {:ok, session: session}
  end

  defp feed_text_msg(text) do
    %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp feed_insert_at(session, data, inserted_at) do
    {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    message
  end

  defp feed_seed(session, count) do
    base = ~N[2026-01-01 00:00:00.000000]

    for i <- 1..count,
        do: feed_insert_at(session, feed_text_msg("msg#{i}"), NaiveDateTime.add(base, i, :second))
  end

  test "loads only a bounded tail, not the full history, for a long session", %{session: session} do
    total = @init_history_window + 200
    feed_seed(session, total)

    {:ok, :idle, data} = SessionRunner.init(session_id: session.id, session_data: session)

    assert length(data.messages) == @init_history_window

    # The bounded tail is the MOST RECENT messages (oldest-first within the
    # window) — never a random/arbitrary slice.
    assert List.first(data.messages)["message"]["content"] |> hd() |> Map.get("text") ==
             "msg#{total - @init_history_window + 1}"

    assert List.last(data.messages)["message"]["content"] |> hd() |> Map.get("text") ==
             "msg#{total}"
  end

  test "a session with fewer messages than the window loads them all", %{session: session} do
    feed_seed(session, 3)

    {:ok, :idle, data} = SessionRunner.init(session_id: session.id, session_data: session)

    assert length(data.messages) == 3
  end

  test "a session with no messages starts :ready with an empty tail", %{session: session} do
    {:ok, :ready, data} = SessionRunner.init(session_id: session.id, session_data: session)

    assert data.messages == []
  end

  test "reconstructs a pending AskUserQuestion from the bounded tail when persisted 'waiting'", %{
    session: session
  } do
    feed_seed(session, @init_history_window - 1)

    question_msg = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu-1",
            "name" => "AskUserQuestion",
            "input" => %{
              "questions" => [
                %{
                  "header" => "Proceed?",
                  "question" => "Deploy now?",
                  "options" => [%{"label" => "Yes"}]
                }
              ]
            }
          }
        ]
      }
    }

    feed_insert_at(session, question_msg, ~N[2026-01-02 00:00:00.000000])

    {:ok, session} = Sessions.update_session(session, %{status: "waiting"})

    {:ok, :idle, data} = SessionRunner.init(session_id: session.id, session_data: session)

    assert %{tool_use_id: "tu-1"} = data.pending_questions
    assert data.pending_questions == AskUserQuestion.pending_questions(data.messages)
  end

  # ORCAHUB3-60: init sweep clears orphaned pi dialogs after runner restart
  describe "init sweep for pi dialogs" do
    test "clears orphaned pi_ui_request events that have no matching pi_ui_response", %{
      session: session
    } do
      # Change session to pi backend
      {:ok, session} = Sessions.update_session(session, %{backend: "pi"})

      # Add pi_ui_request events that would be orphaned after a runner restart
      request1 = %{
        "type" => "pi_ui_request",
        "id" => "orphan-1",
        "method" => "input",
        "title" => "Orphaned 1",
        "message" => "Question 1?"
      }

      request2 = %{
        "type" => "pi_ui_request",
        "id" => "orphan-2",
        "method" => "select",
        "title" => "Orphaned 2",
        "message" => "Question 2?",
        "options" => ["A", "B"]
      }

      # Insert them at different times
      base = ~N[2026-01-01 00:00:00.000000]
      feed_insert_at(session, request1, base)
      feed_insert_at(session, request2, NaiveDateTime.add(base, 1, :second))

      # Verify they are pending before init
      assert Sessions.pending_pi_ui_request(session.id)["id"] == "orphan-2"

      # Run init - this should persist stale resolutions for both orphaned dialogs
      {:ok, :idle, _data} = SessionRunner.init(session_id: session.id, session_data: session)

      # After init sweep, both requests should be cleared
      assert Sessions.pending_pi_ui_request(session.id) == nil

      # Verify the stale resolution events were persisted
      assert Sessions.create_message(%{
               session_id: session.id,
               data: %{
                 "type" => "pi_ui_response",
                 "id" => "orphan-1",
                 "resolution" => "stale"
               }
             })

      assert Sessions.create_message(%{
               session_id: session.id,
               data: %{
                 "type" => "pi_ui_response",
                 "id" => "orphan-2",
                 "resolution" => "stale"
               }
             })
    end

    test "does not persist stale resolution for answered dialogs", %{session: session} do
      # Change session to pi backend
      {:ok, session} = Sessions.update_session(session, %{backend: "pi"})

      base = ~N[2026-01-01 00:00:00.000000]

      # Add an answered dialog
      request = %{
        "type" => "pi_ui_request",
        "id" => "answered",
        "method" => "input",
        "title" => "Answered",
        "message" => "Q?"
      }

      response = %{
        "type" => "pi_ui_response",
        "id" => "answered",
        "value" => "yes"
      }

      feed_insert_at(session, request, base)
      feed_insert_at(session, response, NaiveDateTime.add(base, 1, :second))

      # Add an orphaned dialog
      orphan = %{
        "type" => "pi_ui_request",
        "id" => "orphan",
        "method" => "input",
        "title" => "Orphan",
        "message" => "Q?"
      }

      feed_insert_at(session, orphan, NaiveDateTime.add(base, 2, :second))

      # Run init - should only clear the orphan, not touch the answered one
      {:ok, :idle, _data} = SessionRunner.init(session_id: session.id, session_data: session)

      # The answered dialog should remain answered
      assert Sessions.pending_pi_ui_request(session.id) == nil

      # Verify the orphan was cleared
      assert Sessions.create_message(%{
               session_id: session.id,
               data: %{
                 "type" => "pi_ui_response",
                 "id" => "orphan",
                 "resolution" => "stale"
               }
             })
    end
  end
end
