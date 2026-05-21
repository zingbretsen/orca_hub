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

    node_filter = socket.assigns.node_filter
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(node_filter)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    tagged_terminals = Cluster.list_terminals() |> NodeFilter.filter_tagged(node_filter)
    node_map = Cluster.build_node_map(tagged_terminals)
    terminals = Enum.map(tagged_terminals, fn {_node, terminal} -> terminal end)

    {:ok,
     socket
     |> assign(
       projects: projects,
       terminals: terminals,
       node_map: node_map,
       clustered: Node.list() != [],
       show_form: false,
       terminal_form: to_form(Terminals.change_terminal(%Terminal{}))
     )}
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
    # Route DB creation to the runner node so the record lands in the right DB
    runner_node = resolve_runner_node(params["runner_node"])

    case Cluster.create_terminal(runner_node, params) do
      {:ok, _terminal} ->
        {:noreply,
         socket
         |> refresh_terminals()
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
        {:noreply, refresh_terminals(socket)}

      {:error, {:already_started, _}} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())
    Cluster.stop_terminal(n, id)
    {:noreply, refresh_terminals(socket)}
  end

  def handle_event("delete_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())

    # Use already-loaded terminal from the list to avoid cross-DB lookup issues
    terminal = Enum.find(socket.assigns.terminals, &(&1.id == id))

    if terminal do
      # Stop if running
      if terminal.status == "running" do
        Cluster.stop_terminal(n, id)
      end

      Cluster.delete_terminal(n, terminal)
    end

    {:noreply, refresh_terminals(socket)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false)
     |> push_patch(to: ~p"/terminals")}
  end

  def reload_for_node_filter(socket), do: {:noreply, refresh_terminals(socket)}

  @impl true
  def handle_info({_terminal_id, _payload}, socket) do
    {:noreply, refresh_terminals(socket)}
  end

  # Default directory and runner_node from the selected project if not set
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

  defp group_by_project(terminals) do
    terminals
    |> Enum.group_by(& &1.project)
    |> Enum.sort_by(fn {project, _} -> if project, do: project.name, else: "zzz" end)
  end

  defp refresh_terminals(socket) do
    tagged_terminals =
      Cluster.list_terminals() |> NodeFilter.filter_tagged(socket.assigns.node_filter)

    node_map = Cluster.build_node_map(tagged_terminals)
    terminals = Enum.map(tagged_terminals, fn {_node, terminal} -> terminal end)
    assign(socket, terminals: terminals, node_map: node_map)
  end
end
