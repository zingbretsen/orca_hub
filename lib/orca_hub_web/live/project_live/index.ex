defmodule OrcaHubWeb.ProjectLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects.Project
  alias OrcaHub.{Cluster, HubRPC, ClaudeImport}
  alias OrcaHubWeb.NodeFilter

  @impl true
  def mount(_params, _session, socket) do
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(socket.assigns.node_filter)
    node_map = Cluster.build_node_map(tagged_projects)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    clustered = length(Node.list()) > 0

    socket =
      socket
      |> stream(:projects, projects)
      |> assign(
        node_map: node_map,
        clustered: clustered,
        browsing: false,
        browse_path: nil,
        browse_entries: [],
        browse_show_hidden: false,
        importing: false,
        git_statuses: %{}
      )

    if connected?(socket) do
      fetch_all_git_statuses(tagged_projects)
    end

    {:ok, socket}
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
    project = HubRPC.get_project!(id)
    {:ok, _} = HubRPC.delete_project(project)
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

  def handle_event("git_pull", %{"id" => id}, socket) do
    run_git_sync(socket, id, :pull)
  end

  def handle_event("git_push", %{"id" => id}, socket) do
    run_git_sync(socket, id, :push)
  end

  def handle_event("git_pull_push", %{"id" => id}, socket) do
    run_git_sync(socket, id, :pull_push)
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

  def reload_for_node_filter(socket) do
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(socket.assigns.node_filter)
    node_map = Cluster.build_node_map(tagged_projects)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    {:noreply,
     socket
     |> assign(node_map: node_map)
     |> stream(:projects, projects, reset: true)}
  end

  @impl true
  def handle_info({:git_status, project_id, status}, socket) do
    git_statuses = Map.put(socket.assigns.git_statuses, project_id, status)
    {:noreply, assign(socket, git_statuses: git_statuses)}
  end

  def handle_info({:git_sync_done, project_id, result}, socket) do
    socket =
      case result do
        {:ok, output} ->
          put_flash(socket, :info, "Sync complete: #{output}")

        {:error, output} ->
          put_flash(socket, :error, "Sync failed: #{output}")
      end

    # Re-fetch status for this project
    target_node = Map.get(socket.assigns.node_map, project_id, node())
    fetch_git_status(target_node, project_id)

    {:noreply, socket}
  end

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
    clean_params =
      params
      |> Map.delete("target_node")
      |> Map.put("node", Atom.to_string(target_node))

    case HubRPC.create_project(clean_params) do
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

  defp fetch_all_git_statuses(tagged_projects) do
    pid = self()

    for {target_node, project} <- tagged_projects do
      Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
        status = Cluster.rpc(target_node, Projects, :git_status, [project])
        send(pid, {:git_status, project.id, status})
      end)
    end
  end

  defp fetch_git_status(target_node, project_id) do
    pid = self()

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      project = Cluster.rpc(target_node, Projects, :get_project!, [project_id])
      status = Cluster.rpc(target_node, Projects, :git_status, [project])
      send(pid, {:git_status, project_id, status})
    end)
  end

  defp run_git_sync(socket, id, action) do
    pid = self()
    target_node = Map.get(socket.assigns.node_map, id, node())
    git_statuses = Map.put(socket.assigns.git_statuses, id, :syncing)

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      project = Cluster.rpc(target_node, Projects, :get_project!, [id])

      result =
        case action do
          :pull ->
            Cluster.rpc(target_node, Projects, :git_pull, [project])

          :push ->
            Cluster.rpc(target_node, Projects, :git_push, [project])

          :pull_push ->
            case Cluster.rpc(target_node, Projects, :git_pull, [project]) do
              {:ok, pull_output} ->
                case Cluster.rpc(target_node, Projects, :git_push, [project]) do
                  {:ok, push_output} -> {:ok, "pull: #{pull_output}, push: #{push_output}"}
                  {:error, push_err} -> {:error, "pull ok, push failed: #{push_err}"}
                end

              {:error, _} = err ->
                err
            end
        end

      send(pid, {:git_sync_done, id, result})
    end)

    {:noreply, assign(socket, git_statuses: git_statuses)}
  end
end
