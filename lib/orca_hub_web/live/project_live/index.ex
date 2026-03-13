defmodule OrcaHubWeb.ProjectLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project
  alias OrcaHub.ClaudeImport

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(:projects, Projects.list_projects())
     |> assign(browsing: false, browse_path: nil, browse_entries: [], browse_show_hidden: false, importing: false)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Projects", form: nil, project: nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Project.changeset(%Project{}, %{})

    socket
    |> assign(page_title: "New Project", project: nil)
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
    project = Projects.get_project!(id)
    {:ok, _} = Projects.delete_project(project)
    {:noreply, stream_delete(socket, :projects, project)}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    project = socket.assigns.project || %Project{}
    changeset = Project.changeset(project, params)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("browse", _params, socket) do
    home = System.user_home!()
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
    expanded = if String.starts_with?(path, "~"), do: Path.expand(path), else: path

    if File.dir?(expanded) do
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

    {:noreply,
     socket
     |> assign(importing: false)
     |> stream(:projects, Projects.list_projects(), reset: true)
     |> put_flash(:info, flash)}
  end

  defp save_project(socket, :new, params) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp browse_to(socket, path) do
    show_hidden = socket.assigns[:browse_show_hidden] || false

    entries =
      case File.ls(path) do
        {:ok, names} ->
          names
          |> Enum.map(&Path.join(path, &1))
          |> Enum.filter(&File.dir?/1)
          |> then(fn dirs ->
            if show_hidden, do: dirs, else: Enum.reject(dirs, fn p -> String.starts_with?(Path.basename(p), ".") end)
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end
end
