defmodule OrcaHub.TriggerExecutorSetupScriptTest do
  @moduledoc """
  End-to-end wiring of the pre-run setup script through the REAL
  `OrcaHub.TriggerExecutor` entry points — that it runs at all, that it runs
  on a REUSED session too (it is a "gather current state before this run"
  hook, not one-time provisioning), and that a failing script does not abort
  the firing.

  Drives a real `OrcaHub.SessionRunner`, same pattern/reasoning as
  `OrcaHub.TriggerExecutorTriggerIdTest` — hence `async: false` with the DB
  sandbox in shared mode.
  """

  use OrcaHub.DataCase, async: false

  import Ecto.Query

  alias OrcaHub.{Projects, Sessions, TriggerExecutor, Triggers}

  setup do
    dir = Path.join(System.tmp_dir!(), "trigger_setup_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "setup script project", directory: dir})
    %{project: project, dir: dir}
  end

  test "execute/1 runs the setup script and records it on the session", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Nightly with setup",
        prompt: "Consolidate memories",
        cron_expression: "0 3 * * *",
        project_id: project.id,
        setup_script: "echo SETUP-RAN",
        setup_timeout_seconds: 20
      })

    assert TriggerExecutor.execute(trigger.id) == :ok

    session_id = Triggers.get_trigger!(trigger.id).last_session_id
    stop_session_on_exit(session_id)

    assert [event] = setup_events(session_id)
    assert event["exit_code"] == 0
    assert event["failed"] == false
    assert event["output"] =~ "SETUP-RAN"
    assert event["script"] == "echo SETUP-RAN"
  end

  test "the setup script runs again on a REUSED session", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Reusing trigger with setup",
        prompt: "Check again",
        type: "webhook",
        project_id: project.id,
        reuse_session: true,
        setup_script: "echo SETUP-RAN",
        setup_timeout_seconds: 20
      })

    assert {:ok, session_id} = TriggerExecutor.execute_payload(trigger.id, %{"n" => 1})
    stop_session_on_exit(session_id)
    assert length(setup_events(session_id)) == 1

    # Put the session back in a reusable state so the second firing takes the
    # reuse branch instead of creating a fresh session.
    session_id |> Sessions.get_session!() |> Sessions.update_session(%{status: "idle"})

    assert {:ok, ^session_id} = TriggerExecutor.execute_payload(trigger.id, %{"n" => 2})
    assert length(setup_events(session_id)) == 2
  end

  test "a failing setup script does NOT abort the firing", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Broken setup",
        prompt: "Do the thing anyway",
        cron_expression: "0 3 * * *",
        project_id: project.id,
        setup_script: "echo cannot-reach-remote >&2; exit 1",
        setup_timeout_seconds: 20
      })

    assert TriggerExecutor.execute(trigger.id) == :ok

    reloaded = Triggers.get_trigger!(trigger.id)
    # The firing completed: the session exists and last_fired_at was bumped.
    assert reloaded.last_session_id != nil
    assert reloaded.last_fired_at != nil
    stop_session_on_exit(reloaded.last_session_id)

    assert [event] = setup_events(reloaded.last_session_id)
    assert event["exit_code"] == 1
    assert event["failed"] == true
    assert event["output"] =~ "cannot-reach-remote"
  end

  test "a trigger with no setup script records no setup event", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "No setup",
        prompt: "Do the thing",
        cron_expression: "0 3 * * *",
        project_id: project.id
      })

    assert TriggerExecutor.execute(trigger.id) == :ok

    session_id = Triggers.get_trigger!(trigger.id).last_session_id
    stop_session_on_exit(session_id)

    assert setup_events(session_id) == []
  end

  defp stop_session_on_exit(session_id) do
    on_exit(fn ->
      if OrcaHub.SessionSupervisor.session_alive?(session_id) do
        OrcaHub.SessionSupervisor.stop_session(session_id)
      end
    end)
  end

  defp setup_events(session_id) do
    from(m in Sessions.Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'subtype' = 'setup_script'", m.data),
      order_by: [asc: m.inserted_at],
      select: m.data
    )
    |> OrcaHub.Repo.all()
  end
end
