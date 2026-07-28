defmodule OrcaHub.A2ATasksTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{A2ATasks, Projects, Sessions}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/a2a-tasks-test"})

    {:ok, session} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    %{project: project, session: session}
  end

  defp insert_assistant_message(session, text) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })

    :ok
  end

  defp preloaded(task), do: A2ATasks.get_task(task.id)

  describe "create_task/1, get_task/1, update_task/2" do
    test "round-trips a task", %{session: session} do
      assert {:ok, task} = A2ATasks.create_task(%{session_id: session.id, timeout_seconds: 60})
      assert task.status == "submitted"
      assert task.timeout_seconds == 60

      fetched = A2ATasks.get_task(task.id)
      assert fetched.id == task.id
      assert fetched.session.id == session.id

      assert {:ok, updated} = A2ATasks.update_task(task, %{status: "working"})
      assert updated.status == "working"
    end

    test "get_task/1 returns nil for a missing id" do
      assert A2ATasks.get_task(Ecto.UUID.generate()) == nil
    end

    test "create_task/1 requires a session_id" do
      assert {:error, changeset} = A2ATasks.create_task(%{})
      assert "can't be blank" in errors_on(changeset).session_id
    end
  end

  describe "terminal_status?/1" do
    test "true for completed/failed/canceled" do
      assert A2ATasks.terminal_status?("completed")
      assert A2ATasks.terminal_status?("failed")
      assert A2ATasks.terminal_status?("canceled")
    end

    test "false for submitted/working" do
      refute A2ATasks.terminal_status?("submitted")
      refute A2ATasks.terminal_status?("working")
    end
  end

  describe "advance/1" do
    test "already-terminal tasks are returned unchanged", %{session: session} do
      {:ok, task} =
        A2ATasks.create_task(%{session_id: session.id, status: "completed", result_text: "done"})

      loaded = preloaded(task)
      assert {:ok, ^loaded} = A2ATasks.advance(loaded)
    end

    test "session running/compacting/waiting moves the task to working", %{session: session} do
      for status <- ~w(running compacting waiting) do
        {:ok, session} = Sessions.update_session(session, %{status: status})
        {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

        assert {:ok, %{status: "working"}} = A2ATasks.advance(preloaded(task))
      end
    end

    test "session error moves the task to failed with the last assistant text", %{
      session: session
    } do
      insert_assistant_message(session, "something went wrong")
      {:ok, session} = Sessions.update_session(session, %{status: "error"})
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

      assert {:ok, advanced} = A2ATasks.advance(preloaded(task))
      assert advanced.status == "failed"
      assert advanced.error == "session errored"
      assert advanced.result_text == "something went wrong"
    end

    test "session idle with a new reply completes the task", %{session: session} do
      insert_assistant_message(session, "hello there")
      {:ok, session} = Sessions.update_session(session, %{status: "idle"})
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

      assert {:ok, advanced} = A2ATasks.advance(preloaded(task))
      assert advanced.status == "completed"
      assert advanced.result_text == "hello there"
    end

    test "stale-reply guard: session already idle from a PRIOR turn stays working until a new message lands",
         %{session: session} do
      insert_assistant_message(session, "old reply from a previous turn")
      baseline = Sessions.count_messages(session.id)
      {:ok, session} = Sessions.update_session(session, %{status: "idle"})

      {:ok, task} =
        A2ATasks.create_task(%{session_id: session.id, baseline_message_count: baseline})

      assert {:ok, %{status: "working"}} = A2ATasks.advance(preloaded(task))

      insert_assistant_message(session, "new reply for this task")

      assert {:ok, advanced} = A2ATasks.advance(preloaded(task))
      assert advanced.status == "completed"
      assert advanced.result_text == "new reply for this task"
    end

    test "a task with baseline 0 on a session with prior history is unaffected (no regression)",
         %{session: session} do
      insert_assistant_message(session, "hello there")
      {:ok, session} = Sessions.update_session(session, %{status: "idle"})
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

      assert {:ok, advanced} = A2ATasks.advance(preloaded(task))
      assert advanced.status == "completed"
      assert advanced.result_text == "hello there"
    end

    test "other session statuses (e.g. \"ready\") leave the task's current state alone", %{
      session: session
    } do
      assert session.status == "ready"
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

      assert {:ok, %{status: "submitted"}} = A2ATasks.advance(preloaded(task))
    end

    test "timeout fails the task even if the session is still nominally in progress", %{
      session: session
    } do
      {:ok, session} = Sessions.update_session(session, %{status: "running"})
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id, timeout_seconds: 1})

      past =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-10, :second)
        |> NaiveDateTime.truncate(:second)

      task = OrcaHub.Repo.update!(Ecto.Changeset.change(task, inserted_at: past))

      assert {:ok, advanced} = A2ATasks.advance(preloaded(task))
      assert advanced.status == "failed"
      assert advanced.error == "timed out after 1s"
    end
  end
end
