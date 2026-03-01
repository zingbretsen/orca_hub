defmodule OrcaHubWeb.ProjectLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(:projects, Projects.list_projects())
     |> assign(browsing: false, browse_path: nil, browse_entries: [])}
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

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Projects.get_project!(id)
    changeset = Project.changeset(project, %{})

    socket
    |> assign(page_title: "Edit Project", project: project)
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("save", %{"project" => params}, socket) do
    save_project(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    {:ok, _} = Projects.delete_project(project)
    {:noreply, stream_delete(socket, :projects, project)}
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
    changeset = Project.changeset(project, %{"directory" => socket.assigns.browse_path})

    {:noreply,
     socket
     |> assign(browsing: false, form: to_form(changeset))}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  defp save_project(socket, :new, params) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created")
         |> push_navigate(to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_project(socket, :edit, params) do
    case Projects.update_project(socket.assigns.project, params) do
      {:ok, _project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated")
         |> push_navigate(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp browse_to(socket, path) do
    entries =
      case File.ls(path) do
        {:ok, names} ->
          names
          |> Enum.map(&Path.join(path, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.reject(fn p -> String.starts_with?(Path.basename(p), ".") end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end
end
