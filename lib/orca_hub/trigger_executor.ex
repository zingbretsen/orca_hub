defmodule OrcaHub.TriggerExecutor do
  require Logger
  alias OrcaHub.{Triggers, Sessions, SessionRunner}

  def execute(trigger_id) do
    trigger = Triggers.get_trigger!(trigger_id)

    unless trigger.enabled do
      Logger.info("Trigger #{trigger_id} is disabled, skipping")
      :ok
    else
      Logger.info("Firing trigger #{trigger.name} (#{trigger_id})")

      session_id = resolve_session(trigger)

      Triggers.update_trigger(trigger, %{
        last_fired_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_session_id: session_id
      })

      unless OrcaHub.SessionSupervisor.session_alive?(session_id) do
        OrcaHub.SessionSupervisor.start_session(session_id)
      end

      SessionRunner.send_message(session_id, trigger.prompt)

      if trigger.archive_on_complete do
        subscribe_for_completion(session_id)
      end

      :ok
    end
  rescue
    e ->
      Logger.error("Trigger #{trigger_id} execution failed: #{Exception.message(e)}")
      :error
  end

  defp resolve_session(%{reuse_session: true, last_session_id: last_id} = trigger)
       when not is_nil(last_id) do
    case OrcaHub.Repo.get(Sessions.Session, last_id) do
      %{archived_at: nil, status: status} when status in ["idle", "error"] ->
        last_id

      _ ->
        create_new_session(trigger)
    end
  end

  defp resolve_session(trigger), do: create_new_session(trigger)

  defp create_new_session(%{project: project, name: name}) do
    {:ok, session} =
      Sessions.create_session(%{
        directory: project.directory,
        project_id: project.id,
        title: "Trigger: #{name}",
        status: "idle",
        triggered: true
      })

    session.id
  end

  defp subscribe_for_completion(session_id) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session_id}")
      wait_for_completion(session_id)
    end)
  end

  defp wait_for_completion(session_id) do
    receive do
      {:status, status} when status in [:idle, :error] ->
        Logger.info("Trigger session #{session_id} completed (#{status}), archiving")
        session = Sessions.get_session!(session_id)
        Sessions.archive_session(session)

      _ ->
        wait_for_completion(session_id)
    after
      :timer.hours(4) ->
        Logger.warning("Trigger session #{session_id} timed out waiting for completion")
    end
  end
end
