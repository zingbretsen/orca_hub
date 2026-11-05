defmodule OrcaHubWeb.TriggerLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHubWeb.TriggerLive.Index

  # Sessions listed per page. A trigger that fires every few minutes spawns
  # thousands of sessions over its life; listing them all made this page
  # ~1 MB of HTML and ~130 ms at 1,025 sessions. "Show older" pages back
  # through the rest.
  @sessions_page_size 50

  @doc false
  def sessions_page_size, do: @sessions_page_size

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    trigger = HubRPC.get_trigger!(id)
    runner_node = if trigger.project, do: Cluster.project_node_for(trigger.project), else: node()

    {:ok,
     socket
     |> assign(
       page_title: trigger.name,
       trigger: trigger,
       runner_node: runner_node,
       sessions: [],
       sessions_cursor: nil,
       sessions_has_more: false,
       sessions_total: HubRPC.count_sessions_for_trigger(trigger.id)
     )
     |> load_sessions_page()}
  end

  @impl true
  def handle_event("load_older_sessions", _params, socket) do
    {:noreply, load_sessions_page(socket)}
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

  # Appends the next page (newest first) to @sessions. LiveView change-tracks
  # the table's comprehension per entry, so a click sends only the new rows.
  defp load_sessions_page(socket) do
    page =
      HubRPC.list_sessions_for_trigger_page(socket.assigns.trigger.id,
        limit: @sessions_page_size,
        before: socket.assigns.sessions_cursor
      )

    assign(socket,
      sessions: socket.assigns.sessions ++ page.sessions,
      sessions_cursor: page.cursor || socket.assigns.sessions_cursor,
      sessions_has_more: page.has_more
    )
  end

  def webhook_url(trigger), do: OrcaHubWeb.TriggerLive.Index.webhook_url(trigger)

  @doc "Whether this trigger restricts anything — nil/[] on both lists means it doesn't."
  def tool_policy_set?(trigger),
    do: trigger.tool_allowlist not in [nil, []] or trigger.tool_denylist not in [nil, []]

  @doc "Whether this trigger has a non-blank setup script."
  def setup_script_set?(trigger), do: OrcaHub.Triggers.SetupScript.configured?(trigger)

  def rotate_disabled_reason(%{reuse_session: false}), do: "Only reused sessions can be rotated."

  def rotate_disabled_reason(%{last_session_id: nil}),
    do: "No session to rotate from yet — this trigger hasn't fired."

  def rotate_disabled_reason(_trigger), do: nil
end
