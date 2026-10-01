defmodule OrcaHubWeb.TriggerLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, TriggerExecutor, Triggers}
  alias OrcaHub.Triggers.{OneOff, Trigger}
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
       ends_mode: "never",
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
      ends_mode: "never",
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
      ends_mode: detect_ends_mode(trigger),
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

  def handle_event("set_ends_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, ends_mode: mode)}
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
      |> parse_run_at_param()

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
      |> parse_run_at_param()

    params =
      if socket.assigns.trigger_type == "scheduled" do
        params
        |> maybe_build_cron(socket.assigns.schedule_mode)
        |> put_ends_params(socket.assigns.ends_mode)
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

  # A one-off's fire time is entered in a datetime-local input
  # ("2026-12-15T09:00", no zone) as LOCAL time — America/New_York, the same
  # convention as the create_one_off_trigger MCP tool (OneOff.parse_run_at/1)
  # — and converted to the UTC run_at column here. A blank or unparseable
  # value becomes a nil run_at so the changeset reports it as required.
  defp parse_run_at_param(%{"run_at_local" => local} = params) when is_binary(local) do
    run_at =
      case OneOff.parse_run_at(local) do
        {:ok, utc} -> utc
        {:error, _} -> nil
      end

    params |> Map.delete("run_at_local") |> Map.put("run_at", run_at)
  end

  defp parse_run_at_param(params), do: params

  # The "Ends" control (calendar-style): never / after N runs / on a date.
  # Only the selected mode's value survives — the other end condition is
  # cleared, so switching modes really replaces the old one. "On" a date
  # means the END of that local day (OneOff.parse_end_date/1). An
  # unparseable date or blank count falls through as nil for that field.
  defp put_ends_params(params, "after") do
    Map.merge(params, %{"max_runs" => blank_to_nil(params["max_runs"]), "ends_at" => nil})
  end

  defp put_ends_params(params, "on") do
    ends_at =
      case OneOff.parse_end_date(params["ends_on_local"] || "") do
        {:ok, utc} -> utc
        {:error, _} -> nil
      end

    params |> Map.delete("ends_on_local") |> Map.merge(%{"max_runs" => nil, "ends_at" => ends_at})
  end

  defp put_ends_params(params, _never) do
    params |> Map.delete("ends_on_local") |> Map.merge(%{"max_runs" => nil, "ends_at" => nil})
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp detect_ends_mode(%{ends_at: %DateTime{}}), do: "on"
  defp detect_ends_mode(%{max_runs: max}) when is_integer(max), do: "after"
  defp detect_ends_mode(_), do: "never"

  @doc "The date input value (local date) for a form's ends_at — empty when unset."
  def ends_on_local_value(form) do
    case form[:ends_at].value do
      %DateTime{} = ends_at -> ends_at |> OneOff.to_local() |> Calendar.strftime("%Y-%m-%d")
      _ -> ""
    end
  end

  @doc """
  "N of M runs" / "N runs" — how far a trigger is through its run budget.
  """
  def runs_text(%{run_count: count, max_runs: max}) when is_integer(max),
    do: "#{count || 0} of #{max} runs"

  def runs_text(%{run_count: count}), do: "#{count || 0} runs"

  @doc """
  The datetime-local input value (local time, minute precision) for a
  form's run_at — empty when unset.
  """
  def run_at_local_value(form) do
    case form[:run_at].value do
      %DateTime{} = run_at -> run_at |> OneOff.to_local() |> Calendar.strftime("%Y-%m-%dT%H:%M")
      _ -> ""
    end
  end

  @doc "A UTC timestamp rendered in the user's local zone, e.g. for run_at."
  def format_local(%DateTime{} = dt),
    do: dt |> OneOff.to_local() |> Calendar.strftime("%Y-%m-%d %H:%M %Z")

  def format_local(_), do: ""

  @doc """
  The status badge text for a trigger. A one-off reads "pending" until it
  fires and "fired" after (the executor disables it in the same write); a
  recurring trigger that hit an end condition reads "ended". "disabled"
  means an operator switched it off.
  """
  def status_label(%{type: "once", enabled: true}), do: "pending"
  def status_label(%{type: "once", last_fired_at: %DateTime{}}), do: "fired"
  def status_label(%{enabled: true}), do: "active"

  def status_label(trigger), do: if(ended?(trigger), do: "ended", else: "disabled")

  # A disabled trigger that stopped because an end condition was met (rather
  # than an operator switching it off): max_runs reached, ends_at passed, or
  # its last fire was the final one before ends_at.
  defp ended?(trigger) do
    TriggerExecutor.ended?(trigger, DateTime.utc_now()) or
      (match?(%DateTime{}, trigger.last_fired_at) and
         TriggerExecutor.last_fire?(trigger, trigger.last_fired_at))
  end

  def status_class(trigger) do
    case status_label(trigger) do
      "active" -> "badge-success"
      "pending" -> "badge-warning"
      "fired" -> "badge-info"
      "ended" -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  @doc """
  Options for the trigger form's backend select — blank first, meaning
  "inherit the runner node's default" (stored as nil, see `Trigger`).
  """
  def backend_options do
    [
      {"Default (node's default backend)", ""}
      | Enum.map(OrcaHub.Backend.available(), fn {id, label} -> {label, id} end)
    ]
  end

  @doc """
  Datalist suggestions for the model input, keyed on the form's current
  backend (blank = claude, the fallback default). The input itself stays
  free text: pi's list is live (`pi --list-models`, a shell-out per call), so
  it gets no suggestions here rather than one per form keystroke — pi ids are
  typed as "provider/model".
  """
  def model_suggestions(backend) when backend in [nil, "", "claude", "codex"],
    do: OrcaHub.Backend.models_for(if(backend in [nil, ""], do: nil, else: backend))

  def model_suggestions(_backend), do: []

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
