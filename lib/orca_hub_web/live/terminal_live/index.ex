defmodule OrcaHubWeb.TerminalLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Terminals}
  alias OrcaHub.Terminals.Terminal
  alias OrcaHubWeb.NodeFilter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "terminals")
    end

    {:ok, reload_terminals(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Terminals", show_form: false)
  end

  defp apply_action(socket, :new, params) do
    attrs =
      case params do
        %{"project_id" => project_id} -> %{project_id: project_id}
        _ -> %{}
      end

    changeset = Terminals.change_terminal(%Terminal{}, attrs)

    socket
    |> assign(
      page_title: "New Terminal",
      show_form: true,
      terminal_form: to_form(changeset)
    )
  end

  @impl true
  def handle_event("validate_terminal", %{"terminal" => params}, socket) do
    changeset = Terminals.change_terminal(%Terminal{}, params)
    {:noreply, assign(socket, terminal_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_terminal", %{"terminal" => params}, socket) do
    params = apply_project_defaults(params)
    runner_node = resolve_runner_node(params["runner_node"])

    case Cluster.create_terminal(runner_node, params) do
      {:ok, _terminal} ->
        {:noreply,
         socket
         |> reload_terminals()
         |> assign(show_form: false)
         |> push_patch(to: ~p"/terminals")}

      {:error, changeset} ->
        {:noreply, assign(socket, terminal_form: to_form(changeset))}
    end
  end

  def handle_event("start_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())

    case Cluster.start_terminal(n, id) do
      {:ok, _pid} ->
        {:noreply, reload_terminals(socket)}

      {:error, {:already_started, _}} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())
    Cluster.stop_terminal(n, id)
    {:noreply, reload_terminals(socket)}
  end

  def handle_event("delete_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())
    terminal = Enum.find(socket.assigns.terminals, &(&1.id == id))

    if terminal do
      if terminal.status == "running" do
        Cluster.stop_terminal(n, id)
      end

      Cluster.delete_terminal(n, terminal)
    end

    {:noreply, reload_terminals(socket)}
  end

  def handle_event("pin", %{"id" => id}, socket) do
    case find_terminal(socket, id) do
      nil ->
        {:noreply, socket}

      terminal ->
        {:ok, _} = HubRPC.pin_terminal(terminal)
        {:noreply, reload_terminals(socket)}
    end
  end

  def handle_event("unpin", %{"id" => id}, socket) do
    case find_terminal(socket, id) do
      nil ->
        {:noreply, socket}

      terminal ->
        {:ok, _} = HubRPC.unpin_terminal(terminal)
        {:noreply, reload_terminals(socket)}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false)
     |> push_patch(to: ~p"/terminals")}
  end

  def reload_for_node_filter(socket), do: {:noreply, reload_terminals(socket)}

  @impl true
  def handle_info({_terminal_id, _payload}, socket) do
    {:noreply, reload_terminals(socket)}
  end

  defp apply_project_defaults(%{"project_id" => project_id} = params)
       when project_id not in [nil, ""] do
    project = HubRPC.get_project!(project_id)
    project_node = Cluster.project_node_for(project)

    params
    |> then(fn p ->
      if (p["directory"] || "") == "", do: Map.put(p, "directory", project.directory), else: p
    end)
    |> Map.put("runner_node", Atom.to_string(project_node))
  end

  defp apply_project_defaults(params), do: params

  defp resolve_runner_node(rn) when rn in [nil, ""], do: node()
  defp resolve_runner_node(rn), do: String.to_existing_atom(rn)

  defp find_terminal(socket, id), do: Enum.find(socket.assigns.terminals, &(&1.id == id))

  defp reload_terminals(socket) do
    tagged_terminals =
      Cluster.list_terminals() |> NodeFilter.filter_tagged(socket.assigns.node_filter)

    node_map = Cluster.build_node_map(tagged_terminals)
    terminals = Enum.map(tagged_terminals, fn {_node, terminal} -> terminal end)

    {pinned, rest} = Enum.split_with(terminals, & &1.pinned_at)

    assign(socket,
      terminals: terminals,
      pinned_terminals: Enum.sort_by(pinned, & &1.pinned_at, {:desc, DateTime}),
      grouped_terminals: build_groups(rest),
      node_map: node_map,
      node_names: Cluster.node_names(node_map)
    )
  end

  defp build_groups(terminals) do
    terminals
    |> Enum.group_by(& &1.project)
    |> Enum.sort_by(
      fn {_project, [most_recent | _]} -> most_recent.updated_at end,
      {:desc, NaiveDateTime}
    )
    |> Enum.map(fn
      {nil, rows} ->
        %{
          key: "unassigned",
          label: "Unassigned",
          rows: rows,
          icon: "hero-folder-micro"
        }

      {project, rows} ->
        %{
          key: "project-#{project.id}",
          label: project.name,
          rows: rows,
          icon: "hero-code-bracket-micro",
          navigate: ~p"/projects/#{project.id}"
        }
    end)
  end

  defp terminal_status_color("running"), do: "background-color: #22c55e"
  defp terminal_status_color("stopped"), do: "background-color: #a3a3a3"
  defp terminal_status_color("dead"), do: "background-color: #ef4444"
end
