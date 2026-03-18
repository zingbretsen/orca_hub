defmodule OrcaHubWeb.TerminalLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Terminals}
  alias OrcaHub.Terminals.Terminal

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "terminals")
    end

    tagged_projects = Cluster.list_projects()
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    tagged_terminals = Cluster.list_terminals()
    node_map = Cluster.build_node_map(tagged_terminals)
    terminals = Enum.map(tagged_terminals, fn {_node, terminal} -> terminal end)

    {:ok,
     socket
     |> assign(
       projects: projects,
       terminals: terminals,
       node_map: node_map,
       clustered: length(Node.list()) > 0,
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
    # Default directory from project if not set
    params =
      if (params["directory"] || "") == "" do
        case params["project_id"] do
          nil -> params
          "" -> params
          project_id ->
            project = HubRPC.get_project!(project_id)
            Map.put(params, "directory", project.directory)
        end
      else
        params
      end

    case HubRPC.create_terminal(params) do
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
    terminal = HubRPC.get_terminal!(id)
    n = if terminal.runner_node, do: String.to_atom(terminal.runner_node), else: n

    case Cluster.start_terminal(n, id) do
      {:ok, _pid} -> {:noreply, refresh_terminals(socket)}
      {:error, {:already_started, _}} -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_terminal", %{"id" => id}, socket) do
    n = Map.get(socket.assigns.node_map, id, node())
    Cluster.stop_terminal(n, id)
    {:noreply, refresh_terminals(socket)}
  end

  def handle_event("delete_terminal", %{"id" => id}, socket) do
    terminal = HubRPC.get_terminal!(id)

    # Stop if running
    if terminal.status == "running" do
      n = Map.get(socket.assigns.node_map, id, node())
      Cluster.stop_terminal(n, id)
    end

    {:ok, _} = HubRPC.delete_terminal(terminal)
    {:noreply, refresh_terminals(socket)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false)
     |> push_patch(to: ~p"/terminals")}
  end

  @impl true
  def handle_info({_terminal_id, _payload}, socket) do
    {:noreply, refresh_terminals(socket)}
  end

  defp group_by_project(terminals) do
    terminals
    |> Enum.group_by(& &1.project)
    |> Enum.sort_by(fn {project, _} -> if project, do: project.name, else: "zzz" end)
  end

  defp refresh_terminals(socket) do
    tagged_terminals = Cluster.list_terminals()
    node_map = Cluster.build_node_map(tagged_terminals)
    terminals = Enum.map(tagged_terminals, fn {_node, terminal} -> terminal end)
    assign(socket, terminals: terminals, node_map: node_map)
  end
end
