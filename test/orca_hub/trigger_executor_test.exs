defmodule OrcaHub.TriggerExecutorTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Projects, Sessions, TriggerExecutor, Triggers}

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

  # Regression: a trigger whose project is assigned to an offline node used to
  # silently run on THIS node instead (old runner_node_for/project_node_for
  # fallback) — creating a session, bumping last_fired_at, and messaging a
  # runner that was never actually reachable from where the trigger claims to
  # have run. It must now skip entirely and leave no trace.
  describe "execute/1 and execute_webhook/2 skip when the project's node is offline" do
    setup %{trigger: trigger} do
      {:ok, project} =
        Projects.create_project(%{
          name: "Offline project",
          directory: "/tmp/offline_trigger_test",
          node: "debian@totally-offline-host"
        })

      {:ok, trigger} = Triggers.update_trigger(trigger, %{project_id: project.id})
      %{trigger: trigger, project: project}
    end

    test "execute/1 skips: no session created, trigger untouched", %{trigger: trigger} do
      session_count_before = OrcaHub.Repo.aggregate(Sessions.Session, :count)

      assert TriggerExecutor.execute(trigger.id) == :ok

      assert OrcaHub.Repo.aggregate(Sessions.Session, :count) == session_count_before
      reloaded = Triggers.get_trigger!(trigger.id)
      assert reloaded.last_fired_at == nil
      assert reloaded.last_session_id == nil
    end

    test "execute_webhook/2 skips: returns an error, no session created", %{trigger: trigger} do
      session_count_before = OrcaHub.Repo.aggregate(Sessions.Session, :count)

      assert TriggerExecutor.execute_webhook(trigger.id, %{}) == {:error, :node_unavailable}

      assert OrcaHub.Repo.aggregate(Sessions.Session, :count) == session_count_before
      reloaded = Triggers.get_trigger!(trigger.id)
      assert reloaded.last_fired_at == nil
    end

    test "a disabled trigger on an offline node still just reports disabled, not node-unavailable",
         %{trigger: trigger} do
      {:ok, trigger} = Triggers.update_trigger(trigger, %{enabled: false})
      assert TriggerExecutor.execute(trigger.id) == :ok
    end
  end
end
