defmodule OrcaHubWeb.TriggerLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    trigger = HubRPC.get_trigger!(id)
    runner_node = if trigger.project, do: Cluster.project_node_for(trigger.project), else: node()

    {:ok,
     socket
     |> assign(
       page_title: trigger.name,
       trigger: trigger,
       runner_node: runner_node
     )
     |> load_sessions()}
  end

  @impl true
  def handle_event("fire_trigger", _params, socket) do
    id = socket.assigns.trigger.id

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      OrcaHub.TriggerExecutor.execute(id)
    end)

    {:noreply, put_flash(socket, :info, "Trigger fired")}
  end

  def handle_event("toggle_trigger", _params, socket) do
    trigger = socket.assigns.trigger
    {:ok, trigger} = HubRPC.update_trigger(trigger, %{enabled: !trigger.enabled})

    {:noreply, assign(socket, trigger: trigger)}
  end

  def handle_event("delete_trigger", _params, socket) do
    {:ok, _} = HubRPC.delete_trigger(socket.assigns.trigger)

    {:noreply,
     socket
     |> put_flash(:info, "Trigger deleted")
     |> push_navigate(to: ~p"/triggers")}
  end

  def handle_event("rotate_session", _params, socket) do
    trigger = socket.assigns.trigger
    {:ok, trigger} = HubRPC.update_trigger(trigger, %{last_session_id: nil})

    {:noreply,
     socket
     |> assign(trigger: trigger)
     |> put_flash(:info, "Session rotated — the next firing will start a fresh session.")}
  end

  defp load_sessions(socket) do
    sessions = HubRPC.list_sessions_for_trigger(socket.assigns.trigger.id)
    assign(socket, sessions: sessions)
  end

  def webhook_url(trigger), do: OrcaHubWeb.TriggerLive.Index.webhook_url(trigger)

  def rotate_disabled_reason(%{reuse_session: false}), do: "Only reused sessions can be rotated."

  def rotate_disabled_reason(%{last_session_id: nil}),
    do: "No session to rotate from yet — this trigger hasn't fired."

  def rotate_disabled_reason(_trigger), do: nil
end
