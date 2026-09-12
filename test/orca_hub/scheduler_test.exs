defmodule OrcaHub.SchedulerTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Projects, Scheduler, Triggers}

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "scheduler-test-#{System.unique_integer([:positive])}",
        directory: "/tmp/scheduler-test-#{System.unique_integer([:positive])}"
      })

    %{project: project}
  end

  # Regression for a latent bug ensure_triggers!/OrcaHub.MemoryReview surfaced:
  # Quantum's jobs/0 returns {name, %Quantum.Job{}} pairs (a listed map), not
  # bare job structs — a job already registered before sync_triggers/0 runs
  # used to crash it with a KeyError on `job.name`.
  test "sync_triggers/0 does not crash when a job is already registered", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "sync-triggers-regression",
        prompt: "check something",
        cron_expression: "0 3 * * *",
        project_id: project.id
      })

    # create_trigger/1 already registered the job directly (schedule_trigger/1)
    # — sync_triggers/0 must be able to delete-and-reschedule it without
    # blowing up on the {name, job} tuple shape.
    assert :ok = Scheduler.sync_triggers()

    names = Scheduler.jobs() |> Enum.map(fn {name, _job} -> name end)
    assert :"trigger_#{trigger.id}" in names
  end

  test "ORCAHUB3-80: a scheduled trigger's job runs locally, not via a random cluster node",
       %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "run-strategy-regression",
        prompt: "check something",
        cron_expression: "0 3 * * *",
        project_id: project.id
      })

    job = Scheduler.jobs() |> Map.new() |> Map.fetch!(:"trigger_#{trigger.id}")

    # Quantum's own library default (`{Random, :cluster}`) picks a node
    # uniformly at random from every libcluster-connected node — including
    # agent nodes that never run this scheduler's TaskSupervisor — so most
    # picks silently drop the job (NodeSelectorBroadcaster filters the node
    # out and logs an error, with no fallback). This scheduler only ever
    # runs on the hub, so it must always resolve to the local node.
    assert %Quantum.RunStrategy.Local{} = job.run_strategy
  end
end
