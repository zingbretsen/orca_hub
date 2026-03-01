defmodule OrcaHub.TriggersTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Triggers, Triggers.Trigger, Projects}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test Project", directory: "/tmp/test"})
    %{project: project}
  end

  defp valid_attrs(project, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Daily check",
        prompt: "Check for updates",
        cron_expression: "0 9 * * *",
        project_id: project.id
      },
      overrides
    )
  end

  describe "create_trigger/1" do
    test "creates a trigger with valid attrs", %{project: project} do
      assert {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))
      assert trigger.name == "Daily check"
      assert trigger.prompt == "Check for updates"
      assert trigger.cron_expression == "0 9 * * *"
      assert trigger.project_id == project.id
      assert trigger.enabled == true
      assert trigger.reuse_session == false
      assert trigger.archive_on_complete == false
    end

    test "fails with missing required fields", %{project: project} do
      assert {:error, changeset} = Triggers.create_trigger(%{project_id: project.id})
      assert %{name: _, prompt: _, cron_expression: _} = errors_on(changeset)
    end

    test "fails with invalid cron expression", %{project: project} do
      assert {:error, changeset} =
               Triggers.create_trigger(valid_attrs(project, %{cron_expression: "not a cron"}))

      assert %{cron_expression: ["is not a valid cron expression"]} = errors_on(changeset)
    end

    test "creates with optional boolean fields", %{project: project} do
      attrs = valid_attrs(project, %{reuse_session: true, archive_on_complete: true})
      assert {:ok, trigger} = Triggers.create_trigger(attrs)
      assert trigger.reuse_session == true
      assert trigger.archive_on_complete == true
    end
  end

  describe "update_trigger/2" do
    test "updates a trigger", %{project: project} do
      {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))
      assert {:ok, updated} = Triggers.update_trigger(trigger, %{name: "Weekly check"})
      assert updated.name == "Weekly check"
    end

    test "rejects invalid cron on update", %{project: project} do
      {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))

      assert {:error, changeset} =
               Triggers.update_trigger(trigger, %{cron_expression: "bad"})

      assert %{cron_expression: _} = errors_on(changeset)
    end

    test "can disable a trigger", %{project: project} do
      {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))
      assert {:ok, updated} = Triggers.update_trigger(trigger, %{enabled: false})
      assert updated.enabled == false
    end
  end

  describe "delete_trigger/1" do
    test "deletes a trigger", %{project: project} do
      {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))
      assert {:ok, _} = Triggers.delete_trigger(trigger)
      assert_raise Ecto.NoResultsError, fn -> Triggers.get_trigger!(trigger.id) end
    end
  end

  describe "list_triggers_for_project/1" do
    test "returns triggers for a specific project", %{project: project} do
      {:ok, project2} = Projects.create_project(%{name: "Other", directory: "/tmp/other"})

      {:ok, _t1} = Triggers.create_trigger(valid_attrs(project, %{name: "Alpha"}))
      {:ok, _t2} = Triggers.create_trigger(valid_attrs(project, %{name: "Beta"}))
      {:ok, _t3} = Triggers.create_trigger(valid_attrs(project2, %{name: "Gamma"}))

      triggers = Triggers.list_triggers_for_project(project.id)
      assert length(triggers) == 2
      assert [%{name: "Alpha"}, %{name: "Beta"}] = triggers
    end

    test "returns empty list for project with no triggers", %{project: _project} do
      {:ok, empty} = Projects.create_project(%{name: "Empty", directory: "/tmp/empty"})
      assert Triggers.list_triggers_for_project(empty.id) == []
    end
  end

  describe "list_enabled_triggers/0" do
    test "only returns enabled triggers", %{project: project} do
      {:ok, _} = Triggers.create_trigger(valid_attrs(project, %{name: "Enabled"}))

      {:ok, disabled} = Triggers.create_trigger(valid_attrs(project, %{name: "Disabled"}))
      Triggers.update_trigger(disabled, %{enabled: false})

      enabled = Triggers.list_enabled_triggers()
      assert length(enabled) == 1
      assert hd(enabled).name == "Enabled"
    end
  end

  describe "get_trigger!/1" do
    test "returns trigger with project preloaded", %{project: project} do
      {:ok, trigger} = Triggers.create_trigger(valid_attrs(project))
      fetched = Triggers.get_trigger!(trigger.id)
      assert fetched.project.id == project.id
    end
  end

  describe "change_trigger/2" do
    test "returns a changeset" do
      changeset = Triggers.change_trigger(%Trigger{})
      assert %Ecto.Changeset{} = changeset
    end
  end
end
