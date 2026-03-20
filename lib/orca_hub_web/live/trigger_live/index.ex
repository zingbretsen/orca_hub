defmodule OrcaHubWeb.TriggerLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Triggers}
  alias OrcaHub.Triggers.Trigger
  alias OrcaHubWeb.NodeFilter

  @impl true
  def mount(_params, _session, socket) do
    node_filter = socket.assigns.node_filter
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(node_filter)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    tagged_triggers = Cluster.list_triggers() |> NodeFilter.filter_tagged(node_filter)
    node_map = Cluster.build_node_map(tagged_triggers)
    triggers = Enum.map(tagged_triggers, fn {_node, trigger} -> trigger end)
    clustered = length(Node.list()) > 0

    {:ok,
     socket
     |> assign(
       projects: projects,
       triggers: triggers,
       node_map: node_map,
       clustered: clustered,
       show_trigger_form: false,
       editing_trigger: nil,
       trigger_type: "scheduled",
       schedule_mode: "daily",
       trigger_form: to_form(Triggers.change_trigger(%Trigger{}))
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Triggers", show_trigger_form: false, editing_trigger: nil)
  end

  defp apply_action(socket, :new, params) do
    attrs =
      case params do
        %{"project_id" => project_id} -> %{project_id: project_id}
        _ -> %{}
      end

    changeset = Triggers.change_trigger(%Trigger{}, attrs)

    socket
    |> assign(
      page_title: "New Trigger",
      show_trigger_form: true,
      editing_trigger: nil,
      trigger_type: "scheduled",
      schedule_mode: "daily",
      trigger_form: to_form(changeset)
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    trigger = HubRPC.get_trigger!(id)
    changeset = Triggers.change_trigger(trigger)

    socket
    |> assign(
      page_title: "Edit Trigger",
      show_trigger_form: true,
      editing_trigger: trigger,
      trigger_type: trigger.type,
      schedule_mode: detect_schedule_mode(trigger.cron_expression),
      trigger_form: to_form(changeset)
    )
  end

  @impl true
  def handle_event("set_trigger_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, trigger_type: type)}
  end

  def handle_event("set_schedule_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, schedule_mode: mode)}
  end

  def handle_event("validate_trigger", %{"trigger" => params}, socket) do
    trigger = socket.assigns.editing_trigger || %Trigger{}
    params = Map.put(params, "type", socket.assigns.trigger_type)
    changeset = Triggers.change_trigger(trigger, params)
    {:noreply, assign(socket, trigger_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    params = Map.put(params, "type", socket.assigns.trigger_type)

    params =
      if socket.assigns.trigger_type == "scheduled" do
        maybe_build_cron(params, socket.assigns.schedule_mode)
      else
        params
      end

    result =
      case socket.assigns.editing_trigger do
        nil -> HubRPC.create_trigger(params)
        trigger -> HubRPC.update_trigger(trigger, params)
      end

    case result do
      {:ok, _} ->
        tagged_triggers = Cluster.list_triggers()
        node_map = Cluster.build_node_map(tagged_triggers)
        triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)

        {:noreply,
         socket
         |> assign(triggers: triggers, node_map: node_map, show_trigger_form: false, editing_trigger: nil)
         |> push_patch(to: ~p"/triggers")}

      {:error, changeset} ->
        {:noreply, assign(socket, trigger_form: to_form(changeset))}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.delete_trigger(trigger)

    tagged_triggers = Cluster.list_triggers()
    node_map = Cluster.build_node_map(tagged_triggers)
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)
    {:noreply, assign(socket, triggers: triggers, node_map: node_map)}
  end

  def handle_event("toggle_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.update_trigger(trigger, %{enabled: !trigger.enabled})

    tagged_triggers = Cluster.list_triggers()
    node_map = Cluster.build_node_map(tagged_triggers)
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)
    {:noreply, assign(socket, triggers: triggers, node_map: node_map)}
  end

  def handle_event("fire_trigger", %{"id" => id}, socket) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      OrcaHub.TriggerExecutor.execute(id)
    end)

    {:noreply, put_flash(socket, :info, "Trigger fired")}
  end

  def handle_event("cancel_trigger", _params, socket) do
    {:noreply,
     socket
     |> assign(show_trigger_form: false, editing_trigger: nil)
     |> push_patch(to: ~p"/triggers")}
  end

  def reload_for_node_filter(socket) do
    node_filter = socket.assigns.node_filter
    tagged_triggers = Cluster.list_triggers() |> NodeFilter.filter_tagged(node_filter)
    node_map = Cluster.build_node_map(tagged_triggers)
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(node_filter)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    {:noreply, assign(socket, triggers: triggers, node_map: node_map, projects: projects)}
  end

  defp maybe_build_cron(params, "hourly") do
    minute = params["schedule_minute"] || "0"
    Map.put(params, "cron_expression", "#{minute} * * * *")
  end

  defp maybe_build_cron(params, "daily") do
    minute = params["schedule_minute"] || "0"
    hour = params["schedule_hour"] || "9"
    Map.put(params, "cron_expression", "#{minute} #{hour} * * *")
  end

  defp maybe_build_cron(params, "weekly") do
    minute = params["schedule_minute"] || "0"
    hour = params["schedule_hour"] || "9"
    day = params["schedule_day"] || "1"
    Map.put(params, "cron_expression", "#{minute} #{hour} * * #{day}")
  end

  defp maybe_build_cron(params, _custom), do: params

  defp detect_schedule_mode(cron) when is_binary(cron) do
    case String.split(cron) do
      [_m, "*", "*", "*", "*"] -> "hourly"
      [_m, _h, "*", "*", "*"] -> "daily"
      [_m, _h, "*", "*", _d] -> "weekly"
      _ -> "custom"
    end
  end

  defp detect_schedule_mode(_), do: "daily"

  def webhook_url(trigger) do
    OrcaHubWeb.Endpoint.url() <> "/api/webhooks/#{trigger.webhook_secret}"
  end

  def hours_options do
    Enum.map(0..23, fn h ->
      label =
        cond do
          h == 0 -> "12 AM"
          h < 12 -> "#{h} AM"
          h == 12 -> "12 PM"
          true -> "#{h - 12} PM"
        end

      {label, h}
    end)
  end
end
