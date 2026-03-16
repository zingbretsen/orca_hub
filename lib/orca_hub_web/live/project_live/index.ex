defmodule OrcaHubWeb.ProjectLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project
  alias OrcaHub.{Cluster, ClaudeImport}

  @impl true
  def mount(_params, _session, socket) do
    tagged_projects = Cluster.list_projects()
    node_map = Cluster.build_node_map(tagged_projects)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    clustered = length(Node.list()) > 0

    {:ok,
     socket
     |> stream(:projects, projects)
     |> assign(
       node_map: node_map,
       clustered: clustered,
       browsing: false,
       browse_path: nil,
       browse_entries: [],
       browse_show_hidden: false,
       importing: false
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Projects", form: nil, project: nil, cluster_nodes: [], target_node: node())
  end

  defp apply_action(socket, :new, _params) do
    changeset = Project.changeset(%Project{}, %{})

    socket
    |> assign(page_title: "New Project", project: nil)
    |> assign(cluster_nodes: Cluster.nodes())
    |> assign(target_node: node())
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("import_sessions", _params, socket) do
    pid = self()

    Task.start(fn ->
      result = ClaudeImport.import_all(verbose: true)
      send(pid, {:import_done, result})
    end)

    {:noreply, assign(socket, importing: true)}
  end

  def handle_event("save", %{"project" => params}, socket) do
    save_project(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    project = Cluster.get_project!(node, id)
    {:ok, _} = Cluster.rpc(node, Projects, :delete_project, [project])
    {:noreply, stream_delete(socket, :projects, project)}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    project = socket.assigns.project || %Project{}

    target_node =
      case params["target_node"] do
        nil -> socket.assigns.target_node
        "" -> socket.assigns.target_node
        n -> String.to_existing_atom(n)
      end

    changeset = Project.changeset(project, Map.delete(params, "target_node"))
    {:noreply, assign(socket, form: to_form(changeset), target_node: target_node)}
  end

  def handle_event("browse", _params, socket) do
    target = browse_target_node(socket)
    home = Cluster.rpc(target, System, :user_home!, [])
    {:noreply, browse_to(socket, home)}
  end

  def handle_event("browse_navigate", %{"path" => path}, socket) do
    {:noreply, browse_to(socket, path)}
  end

  def handle_event("browse_up", _params, socket) do
    parent = Path.dirname(socket.assigns.browse_path)
    {:noreply, browse_to(socket, parent)}
  end

  def handle_event("browse_select", _params, socket) do
    project = socket.assigns.project || %Project{}
    path = socket.assigns.browse_path
    existing_params = socket.assigns.form.source.params || %{}
    current_name = existing_params["name"]

    name = if current_name in [nil, ""], do: Path.basename(path), else: current_name
    changeset = Project.changeset(project, %{"directory" => path, "name" => name})

    {:noreply,
     socket
     |> assign(browsing: false, form: to_form(changeset))}
  end

  def handle_event("browse_go", %{"path" => path}, socket) do
    path = String.trim(path)
    target = browse_target_node(socket)

    expanded =
      if String.starts_with?(path, "~") do
        home = Cluster.rpc(target, System, :user_home!, [])
        String.replace_prefix(path, "~", home)
      else
        path
      end

    if Cluster.rpc(target, File, :dir?, [expanded]) do
      {:noreply, browse_to(socket, expanded)}
    else
      {:noreply, assign(socket, browse_path: expanded)}
    end
  end

  def handle_event("browse_toggle_hidden", _params, socket) do
    show_hidden = !socket.assigns.browse_show_hidden
    {:noreply, socket |> assign(browse_show_hidden: show_hidden) |> browse_to(socket.assigns.browse_path)}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  @impl true
  def handle_info({:import_done, result}, socket) do
    flash =
      "Imported #{result.sessions_imported} sessions, skipped #{result.sessions_skipped}, created #{result.projects_created} projects."

    tagged_projects = Cluster.list_projects()
    node_map = Cluster.build_node_map(tagged_projects)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    {:noreply,
     socket
     |> assign(importing: false, node_map: node_map)
     |> stream(:projects, projects, reset: true)
     |> put_flash(:info, flash)}
  end

  defp save_project(socket, :new, params) do
    target_node = socket.assigns.target_node
    clean_params = Map.delete(params, "target_node")

    case Cluster.rpc(target_node, Projects, :create_project, [clean_params]) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp browse_to(socket, path) do
    show_hidden = socket.assigns[:browse_show_hidden] || false
    target = browse_target_node(socket)

    entries =
      case Cluster.rpc(target, File, :ls, [path]) do
        {:ok, names} ->
          full_paths = Enum.map(names, &Path.join(path, &1))

          # Single RPC call to filter directories (instead of N calls)
          dirs = Cluster.rpc(target, Enum, :filter, [full_paths, &File.dir?/1])

          dirs
          |> then(fn dirs ->
            if show_hidden, do: dirs, else: Enum.reject(dirs, fn p -> String.starts_with?(Path.basename(p), ".") end)
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end

  defp browse_target_node(socket) do
    socket.assigns[:target_node] || node()
  end
end
