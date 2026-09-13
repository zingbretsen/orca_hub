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
    clustered = Node.list() != []

    {pinned, rest} = Enum.split_with(triggers, & &1.pinned_at)

    {:ok,
     socket
     |> assign(
       projects: projects,
       triggers: triggers,
       pinned_triggers: Enum.sort_by(pinned, & &1.pinned_at, {:desc, DateTime}),
       node_map: node_map,
       node_names: Cluster.node_names(node_map),
       clustered: clustered,
       grouped_triggers: group_by_project(rest),
       show_trigger_form: false,
       editing_trigger: nil,
       trigger_type: "scheduled",
       schedule_mode: "daily",
       show_advanced: false,
       trigger_form: to_form(Triggers.change_trigger(%Trigger{})),
       email_inboxes: HubRPC.list_email_inboxes()
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
      show_advanced: false,
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
      # Auto-open the advanced section for a trigger that already uses any of
      # it — otherwise a configured restriction/script is invisible while
      # editing, and a save that omits those inputs looks like it dropped them.
      show_advanced: advanced_configured?(trigger),
      trigger_form: to_form(changeset)
    )
  end

  @doc """
  Whether a trigger already uses any of the advanced (tool policy / setup
  script) fields — i.e. whether that form section should start expanded.
  """
  def advanced_configured?(%Trigger{} = trigger) do
    trigger.tool_allowlist not in [nil, []] or trigger.tool_denylist not in [nil, []] or
      (is_binary(trigger.setup_script) and String.trim(trigger.setup_script) != "")
  end

  def advanced_configured?(_), do: false

  @impl true
  def handle_event("set_trigger_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, trigger_type: type)}
  end

  def handle_event("set_schedule_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, schedule_mode: mode)}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, show_advanced: !socket.assigns.show_advanced)}
  end

  def handle_event("validate_trigger", %{"trigger" => params}, socket) do
    trigger = socket.assigns.editing_trigger || %Trigger{}

    params =
      params
      |> Map.put("type", socket.assigns.trigger_type)
      |> parse_sender_allowlist_param()
      |> parse_tool_list_params()

    changeset = Triggers.change_trigger(trigger, params)

    {:noreply,
     socket
     |> assign(trigger_form: to_form(changeset, action: :validate))
     |> reveal_advanced_on_error(changeset)}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    params =
      params
      |> Map.put("type", socket.assigns.trigger_type)
      |> parse_sender_allowlist_param()
      |> parse_tool_list_params()

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
        {:noreply, socket} = reload_for_node_filter(socket)

        {:noreply,
         socket
         |> assign(show_trigger_form: false, editing_trigger: nil)
         |> push_patch(to: ~p"/triggers")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(trigger_form: to_form(changeset))
         |> reveal_advanced_on_error(changeset)}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.delete_trigger(trigger)

    reload_for_node_filter(socket)
  end

  def handle_event("toggle_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.update_trigger(trigger, %{enabled: !trigger.enabled})

    reload_for_node_filter(socket)
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

  def handle_event("pin", %{"id" => id}, socket) do
    case find_trigger(socket, id) do
      nil ->
        {:noreply, socket}

      trigger ->
        {:ok, _} = HubRPC.pin_trigger(trigger)
        reload_for_node_filter(socket)
    end
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    case find_trigger(socket, id) do
      nil ->
        {:noreply, socket}

      trigger ->
        {:ok, _} = HubRPC.unpin_trigger(trigger)
        reload_for_node_filter(socket)
    end
  end

  def reload_for_node_filter(socket) do
    node_filter = socket.assigns.node_filter
    tagged_triggers = Cluster.list_triggers() |> NodeFilter.filter_tagged(node_filter)
    node_map = Cluster.build_node_map(tagged_triggers)
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(node_filter)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    {pinned, rest} = Enum.split_with(triggers, & &1.pinned_at)

    {:noreply,
     assign(socket,
       triggers: triggers,
       pinned_triggers: Enum.sort_by(pinned, & &1.pinned_at, {:desc, DateTime}),
       node_map: node_map,
       node_names: Cluster.node_names(node_map),
       projects: projects,
       grouped_triggers: group_by_project(rest)
     )}
  end

  # An error on a field inside the collapsed advanced section would otherwise
  # be invisible — expand it so the message is on screen. Only ever expands:
  # a section the operator opened by hand never snaps shut under them.
  defp reveal_advanced_on_error(socket, changeset) do
    if Enum.any?(changeset.errors, fn {field, _} ->
         field in [:tool_allowlist, :tool_denylist, :setup_script, :setup_timeout_seconds]
       end) do
      assign(socket, show_advanced: true)
    else
      socket
    end
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

  # The email-trigger form submits sender_allowlist as free text
  # (comma/space/newline separated, one address-or-domain per line reads
  # the same way); Trigger.changeset/2 casts :sender_allowlist as
  # {:array, :string}, so turn that text into a list before it gets there.
  defp parse_sender_allowlist_param(%{"sender_allowlist" => text} = params)
       when is_binary(text) do
    Map.put(params, "sender_allowlist", OrcaHubWeb.EnvAllowlistInput.parse(text))
  end

  defp parse_sender_allowlist_param(params), do: params

  # tool_allowlist/tool_denylist are submitted as free text (one raw MCP tool
  # name or `*`-glob per line reads best, but commas/spaces work the same way
  # — see OrcaHubWeb.EnvAllowlistInput.parse/1, shared with the sender
  # allow-list above). A BLANK field parses to [] and is stored as nil, which
  # OrcaHub.ToolPolicy reads as "no restriction" — the same thing [] means, so
  # an untouched or emptied field can never silently restrict a session. An
  # explicit deny-all is still spelled `*` in the deny field.
  defp parse_tool_list_params(params) do
    Enum.reduce(["tool_allowlist", "tool_denylist"], params, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, text} when is_binary(text) ->
          case OrcaHubWeb.EnvAllowlistInput.parse(text) do
            [] -> Map.put(acc, key, nil)
            entries -> Map.put(acc, key, entries)
          end

        _ ->
          acc
      end
    end)
  end

  @doc """
  Renders a tool allow/deny list back into its textarea's text form, one
  entry per line. `nil`/`[]` (no restriction) render as an empty field.
  """
  def tool_list_text(entries) when is_list(entries), do: Enum.join(entries, "\n")
  def tool_list_text(text) when is_binary(text), do: text
  def tool_list_text(_), do: ""

  defp detect_schedule_mode(cron) when is_binary(cron) do
    case String.split(cron) do
      [_m, "*", "*", "*", "*"] -> "hourly"
      [_m, _h, "*", "*", "*"] -> "daily"
      [_m, _h, "*", "*", _d] -> "weekly"
      _ -> "custom"
    end
  end

  defp detect_schedule_mode(_), do: "daily"

  # Group triggers by project, ordered by most recently active project first.
  # Triggers within each group are ordered by name for consistent display.
  defp group_by_project(triggers) do
    triggers
    |> Enum.group_by(& &1.project)
    |> Enum.sort_by(
      fn {_project, [most_recent | _]} -> most_recent.updated_at end,
      {:desc, NaiveDateTime}
    )
    |> Enum.map(fn {project, rows} ->
      %{
        key: project.id,
        label: project.name,
        rows: rows,
        icon: "hero-folder-micro",
        count: length(rows)
      }
    end)
  end

  def webhook_url(trigger) do
    OrcaHubWeb.Endpoint.url() <> "/api/webhooks/#{trigger.webhook_secret}"
  end

  defp find_trigger(socket, id), do: Enum.find(socket.assigns.triggers, &(&1.id == id))

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
