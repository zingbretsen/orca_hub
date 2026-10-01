defmodule OrcaHub.OneOffTriggerSweepTest do
  @moduledoc """
  One-off (`type: "once"`) triggers fire from their DB row via
  `OrcaHub.OneOffTriggerSweep`, exactly once: the executor disables the
  trigger in the same write that stamps `last_fired_at`. An overdue one-off
  (its run_at passed while the hub was down) fires late on the next sweep; a
  skipped fire (node unavailable) stays enabled for the next sweep to retry.

  Drives a REAL `OrcaHub.SessionRunner`, same pattern as
  `OrcaHub.TriggerExecutorTriggerIdTest`, so `async: false`.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{OneOffTriggerSweep, Projects, Repo, Scheduler, Sessions, Triggers}
  alias OrcaHub.Triggers.Trigger

  import Ecto.Query

  setup do
    dir = Path.join(System.tmp_dir!(), "one_off_sweep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "one-off project", directory: dir})
    %{project: project}
  end

  defp create_one_off!(project, attrs \\ %{}) do
    {:ok, trigger} =
      Triggers.create_trigger(
        Map.merge(
          %{
            name: "remind-#{System.unique_integer([:positive])}",
            prompt: "Use send_notification to remind the user.",
            type: "once",
            run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
            project_id: project.id
          },
          attrs
        )
      )

    trigger
  end

  # Simulates the run_at passing (e.g. while the hub was down) — the
  # changeset rightly refuses a past run_at on create.
  defp make_overdue!(trigger) do
    trigger
    |> Ecto.Changeset.change(run_at: ~U[2026-01-01 00:00:00Z])
    |> Repo.update!()
  end

  defp stop_sessions_for(trigger_id) do
    for s <- Sessions.list_sessions_for_trigger(trigger_id) do
      if OrcaHub.SessionSupervisor.session_alive?(s.id) do
        OrcaHub.SessionSupervisor.stop_session(s.id)
      end
    end
  end

  defp session_count(trigger_id) do
    Repo.aggregate(from(s in Sessions.Session, where: s.trigger_id == ^trigger_id), :count)
  end

  test "a not-yet-due one-off is not fired", %{project: project} do
    trigger = create_one_off!(project)

    OneOffTriggerSweep.sweep()

    reloaded = Triggers.get_trigger!(trigger.id)
    assert reloaded.enabled
    assert reloaded.last_fired_at == nil
    assert session_count(trigger.id) == 0
  end

  test "an overdue one-off fires exactly once across repeated sweeps (e.g. after a restart)",
       %{project: project} do
    trigger = project |> create_one_off!() |> make_overdue!()
    on_exit(fn -> stop_sessions_for(trigger.id) end)

    assert trigger.id in Triggers.list_due_one_off_triggers()

    OneOffTriggerSweep.sweep()
    OneOffTriggerSweep.sweep()

    reloaded = Triggers.get_trigger!(trigger.id)
    refute reloaded.enabled
    assert %DateTime{} = reloaded.last_fired_at
    assert reloaded.last_session_id
    assert session_count(trigger.id) == 1
    refute trigger.id in Triggers.list_due_one_off_triggers()
  end

  test "a one-off on an unavailable node is skipped and stays enabled for the next sweep",
       %{project: project} do
    {:ok, offline} =
      Projects.create_project(%{
        name: "one-off offline",
        directory: "/tmp/one_off_offline_#{System.unique_integer([:positive])}",
        node: "debian@totally-offline-host"
      })

    trigger = offline |> create_one_off!() |> make_overdue!()
    _ = project

    OneOffTriggerSweep.sweep()

    reloaded = Triggers.get_trigger!(trigger.id)
    assert reloaded.enabled
    assert reloaded.last_fired_at == nil
    assert session_count(trigger.id) == 0
    assert trigger.id in Triggers.list_due_one_off_triggers()
  end

  test "a one-off is never registered as a Quantum job", %{project: project} do
    trigger = create_one_off!(project)
    :ok = Scheduler.sync_triggers()

    names = Scheduler.jobs() |> Enum.map(fn {name, _job} -> name end)
    refute :"trigger_#{trigger.id}" in names
  end

  test "a scheduled trigger is NOT disabled by firing", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "cron-#{System.unique_integer([:positive])}",
        prompt: "p",
        cron_expression: "0 9 * * *",
        project_id: project.id
      })

    on_exit(fn -> stop_sessions_for(trigger.id) end)

    assert OrcaHub.TriggerExecutor.execute(trigger.id) == :ok
    reloaded = Repo.get!(Trigger, trigger.id)
    assert reloaded.enabled
    assert reloaded.last_fired_at
  end
end
