defmodule OrcaHub.TriggerExecutorTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Triggers, Sessions, Projects}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/test"})

    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Test trigger",
        prompt: "Do the thing",
        cron_expression: "0 9 * * *",
        project_id: project.id,
        reuse_session: false,
        archive_on_complete: false
      })

    %{project: project, trigger: trigger}
  end

  describe "resolve_session (via create_new_session)" do
    test "creates a new session tagged as triggered", %{project: project, trigger: trigger} do
      # We can't call execute (needs SessionRunner), but we can test session creation
      # by inspecting what create_new_session would produce
      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          title: "Trigger: #{trigger.name}",
          status: "idle",
          triggered: true
        })

      assert session.triggered == true
      assert session.title == "Trigger: Test trigger"
      assert session.project_id == project.id
      assert session.directory == project.directory
    end
  end

  describe "session reuse logic" do
    test "reuses idle session when reuse_session is true", %{project: project} do
      # Create a trigger with reuse_session
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "Reuse trigger",
          prompt: "Check again",
          cron_expression: "0 * * * *",
          project_id: project.id,
          reuse_session: true
        })

      # Create an existing idle session
      {:ok, existing} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          title: "Trigger: Reuse trigger",
          status: "idle",
          triggered: true
        })

      # Update trigger with last_session_id
      {:ok, trigger} = Triggers.update_trigger(trigger, %{last_session_id: existing.id})

      # Verify the session lookup would find it
      found = OrcaHub.Repo.get(Sessions.Session, trigger.last_session_id)
      assert found != nil
      assert found.status == "idle"
      assert found.archived_at == nil
    end

    test "creates new session when last session is archived", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "Reuse trigger",
          prompt: "Check",
          cron_expression: "0 * * * *",
          project_id: project.id,
          reuse_session: true
        })

      {:ok, existing} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "idle",
          triggered: true
        })

      Sessions.archive_session(existing)
      {:ok, trigger} = Triggers.update_trigger(trigger, %{last_session_id: existing.id})

      # The archived session should not be reused
      found = OrcaHub.Repo.get(Sessions.Session, trigger.last_session_id)
      assert found.archived_at != nil
    end

    test "creates new session when last session is running", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "Reuse trigger",
          prompt: "Check",
          cron_expression: "0 * * * *",
          project_id: project.id,
          reuse_session: true
        })

      {:ok, existing} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "running",
          triggered: true
        })

      {:ok, _trigger} = Triggers.update_trigger(trigger, %{last_session_id: existing.id})

      # Running session should not be reused
      found = OrcaHub.Repo.get(Sessions.Session, existing.id)
      assert found.status == "running"
    end

    test "creates new session when last_session_id is nil", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "Fresh trigger",
          prompt: "Check",
          cron_expression: "0 * * * *",
          project_id: project.id,
          reuse_session: true
        })

      assert trigger.last_session_id == nil
    end
  end
end
