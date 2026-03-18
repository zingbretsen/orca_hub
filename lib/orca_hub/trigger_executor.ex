defmodule OrcaHub.TriggerExecutor do
  require Logger
  alias OrcaHub.{Cluster, HubRPC}

  def execute(trigger_id) do
    trigger = HubRPC.get_trigger!(trigger_id)

    unless trigger.enabled do
      Logger.info("Trigger #{trigger_id} is disabled, skipping")
      :ok
    else
      Logger.info("Firing trigger #{trigger.name} (#{trigger_id})")

      session_id = resolve_session(trigger)
      runner_node = runner_node_for(trigger)

      HubRPC.update_trigger(trigger, %{
        last_fired_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_session_id: session_id
      })

      unless Cluster.session_alive?(runner_node, session_id) do
        Cluster.start_session(runner_node, session_id)
      end

      Cluster.send_message(runner_node, session_id, build_prompt(trigger))

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

  def execute_webhook(trigger_id, payload) do
    trigger = HubRPC.get_trigger!(trigger_id)

    unless trigger.enabled do
      Logger.info("Webhook trigger #{trigger_id} is disabled, skipping")
      :ok
    else
      Logger.info("Firing webhook trigger #{trigger.name} (#{trigger_id})")

      session_id = resolve_session(trigger)
      runner_node = runner_node_for(trigger)

      HubRPC.update_trigger(trigger, %{
        last_fired_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_session_id: session_id
      })

      unless Cluster.session_alive?(runner_node, session_id) do
        Cluster.start_session(runner_node, session_id)
      end

      prompt = build_prompt(trigger, payload)
      Cluster.send_message(runner_node, session_id, prompt)

      if trigger.archive_on_complete do
        subscribe_for_completion(session_id)
      end

      {:ok, session_id}
    end
  rescue
    e ->
      Logger.error("Webhook trigger #{trigger_id} execution failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp build_prompt(trigger), do: trigger.prompt

  defp build_prompt(trigger, payload) do
    payload_str = if is_binary(payload), do: payload, else: Jason.encode!(payload, pretty: true)
    "#{trigger.prompt}\n\nWebhook payload:\n```json\n#{payload_str}\n```"
  end

  defp resolve_session(%{reuse_session: true, last_session_id: last_id} = trigger)
       when not is_nil(last_id) do
    case HubRPC.get_session(last_id) do
      %{archived_at: nil, status: status} when status in ["ready", "idle", "error"] ->
        last_id

      _ ->
        create_new_session(trigger)
    end
  end

  defp resolve_session(trigger), do: create_new_session(trigger)

  defp create_new_session(%{project: project, name: name}) do
    runner_node = Cluster.project_node_for(project)

    {:ok, session} =
      HubRPC.create_session(%{
        directory: project.directory,
        project_id: project.id,
        title: "Trigger: #{name}",
        status: "ready",
        triggered: true,
        runner_node: Atom.to_string(runner_node)
      })

    session.id
  end

  defp runner_node_for(%{project: project}) when not is_nil(project) do
    Cluster.project_node_for(project)
  end

  defp runner_node_for(_), do: node()

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
        session = HubRPC.get_session!(session_id)
        HubRPC.archive_session(session)

      _ ->
        wait_for_completion(session_id)
    after
      :timer.hours(4) ->
        Logger.warning("Trigger session #{session_id} timed out waiting for completion")
    end
  end
end
