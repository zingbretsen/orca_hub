defmodule OrcaHub.TriggerEndConditionsTest do
  @moduledoc """
  Calendar-style end conditions on scheduled triggers (`max_runs`,
  `ends_at`), enforced by `OrcaHub.TriggerExecutor.execute/1`: a successful
  fire bumps `run_count`, and the trigger disables itself when run_count
  reaches max_runs or its next fire would land after ends_at. Skipped fires
  (node unavailable) are not counted.

  Drives a REAL `OrcaHub.SessionRunner`, same pattern as
  `OrcaHub.TriggerExecutorTriggerIdTest`, so `async: false`.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Projects, Repo, Sessions, TriggerExecutor, Triggers}
  alias OrcaHub.Triggers.Trigger

  setup do
    dir = Path.join(System.tmp_dir!(), "trigger_ends_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "trigger ends project", directory: dir})
    %{project: project}
  end

  defp create_scheduled!(project, attrs) do
    {:ok, trigger} =
      Triggers.create_trigger(
        Map.merge(
          %{
            name: "ends-#{System.unique_integer([:positive])}",
            prompt: "p",
            cron_expression: "0 9 * * *",
            project_id: project.id
          },
          attrs
        )
      )

    on_exit(fn ->
      for s <- Sessions.list_sessions_for_trigger(trigger.id) do
        if OrcaHub.SessionSupervisor.session_alive?(s.id) do
          OrcaHub.SessionSupervisor.stop_session(s.id)
        end
      end
    end)

    trigger
  end

  defp reload(trigger), do: Repo.get!(Trigger, trigger.id)

  test "auto-disables after max_runs successful fires", %{project: project} do
    trigger = create_scheduled!(project, %{max_runs: 2})

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 1, enabled: true} = reload(trigger)

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 2, enabled: false} = reload(trigger)
    assert length(Sessions.list_sessions_for_trigger(trigger.id)) == 2
  end

  test "an ended trigger that is re-enabled is disabled again without firing",
       %{project: project} do
    trigger = create_scheduled!(project, %{max_runs: 1})
    assert TriggerExecutor.execute(trigger.id) == :ok
    {:ok, _} = Triggers.update_trigger(reload(trigger), %{enabled: true})

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 1, enabled: false} = reload(trigger)
    assert length(Sessions.list_sessions_for_trigger(trigger.id)) == 1
  end

  test "auto-disables on the last fire before ends_at", %{project: project} do
    # Fires on Jan 1 only; ends in an hour — so this fire is the last one.
    trigger =
      create_scheduled!(project, %{
        cron_expression: "0 9 1 1 *",
        ends_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 1, enabled: false} = reload(trigger)
  end

  test "stays enabled while its next fire is still before ends_at", %{project: project} do
    trigger =
      create_scheduled!(project, %{
        cron_expression: "* * * * *",
        ends_at: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
      })

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 1, enabled: true} = reload(trigger)
  end

  test "a fire after ends_at does not happen; the trigger is disabled", %{project: project} do
    trigger =
      project
      |> create_scheduled!(%{ends_at: DateTime.add(DateTime.utc_now(), 3600, :second)})
      |> Ecto.Changeset.change(ends_at: ~U[2026-01-01 00:00:00Z])
      |> Repo.update!()

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 0, enabled: false, last_fired_at: nil} = reload(trigger)
    assert Sessions.list_sessions_for_trigger(trigger.id) == []
  end

  test "skipped fires (node unavailable) are not counted" do
    {:ok, offline} =
      Projects.create_project(%{
        name: "trigger ends offline",
        directory: "/tmp/trigger_ends_offline_#{System.unique_integer([:positive])}",
        node: "debian@totally-offline-host"
      })

    trigger = create_scheduled!(offline, %{max_runs: 1})

    assert TriggerExecutor.execute(trigger.id) == :ok
    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 0, enabled: true, last_fired_at: nil} = reload(trigger)
  end

  test "a one-off counts its single run", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "once-#{System.unique_integer([:positive])}",
        prompt: "p",
        type: "once",
        run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        project_id: project.id
      })

    on_exit(fn ->
      for s <- Sessions.list_sessions_for_trigger(trigger.id),
          OrcaHub.SessionSupervisor.session_alive?(s.id),
          do: OrcaHub.SessionSupervisor.stop_session(s.id)
    end)

    assert trigger.max_runs == 1
    assert TriggerExecutor.execute(trigger.id) == :ok
    assert %{run_count: 1, max_runs: 1, enabled: false} = reload(trigger)
  end
end
