defmodule OrcaHub.TriggerExecutorTriggerIdTest do
  @moduledoc """
  Confirms `TriggerExecutor.create_new_session/1` stamps the new session's
  `trigger_id` — the link `OrcaHubWeb.TriggerLive.Show` uses to list every
  session a trigger has ever spawned (`triggers.last_session_id` only ever
  points at the MOST RECENT one).

  Drives a REAL `OrcaHub.SessionRunner` (same reasoning/pattern as
  `OrcaHub.EmailInbox.SessionReuseIntegrationTest`), so `async: false` with
  the DB sandbox in shared mode.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Projects, Sessions, TriggerExecutor, Triggers}

  setup do
    dir = Path.join(System.tmp_dir!(), "trigger_id_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "trigger id project", directory: dir})
    %{project: project}
  end

  test "execute/1 stamps the new session's trigger_id", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Stamp trigger",
        prompt: "Do the thing",
        cron_expression: "0 9 * * *",
        project_id: project.id
      })

    assert TriggerExecutor.execute(trigger.id) == :ok

    reloaded_trigger = Triggers.get_trigger!(trigger.id)
    session = Sessions.get_session!(reloaded_trigger.last_session_id)

    on_exit(fn ->
      if OrcaHub.SessionSupervisor.session_alive?(session.id) do
        OrcaHub.SessionSupervisor.stop_session(session.id)
      end
    end)

    assert session.trigger_id == trigger.id
  end

  test "execute_payload/2 stamps the new session's trigger_id", %{project: project} do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Stamp webhook trigger",
        prompt: "Do the thing",
        type: "webhook",
        project_id: project.id
      })

    assert {:ok, session_id} = TriggerExecutor.execute_payload(trigger.id, %{"hello" => "world"})

    on_exit(fn ->
      if OrcaHub.SessionSupervisor.session_alive?(session_id) do
        OrcaHub.SessionSupervisor.stop_session(session_id)
      end
    end)

    session = Sessions.get_session!(session_id)
    assert session.trigger_id == trigger.id
  end
end
