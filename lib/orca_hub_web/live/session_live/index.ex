defmodule OrcaHubWeb.SessionLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Projects, Sessions}
  alias OrcaHub.Sessions.Session

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_projects()
    filter = :manual

    {:ok,
     socket
     |> assign(
       projects: projects,
       session_filter: filter,
       grouped_sessions: group_sessions(Sessions.list_sessions(filter), projects),
       browsing: false,
       browse_path: nil,
       browse_entries: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Sessions", form: nil)
  end

  defp apply_action(socket, :new, params) do
    initial =
      case params["project_id"] do
        nil -> %{}
        id ->
          project = Projects.get_project!(id)
          %{"project_id" => id, "directory" => project.directory}
      end

    changeset = Session.changeset(%Session{}, initial)

    socket
    |> assign(page_title: "New Session")
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("save", %{"session" => params}, socket) do
    case Sessions.create_session(params) do
      {:ok, session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("create_for_project", %{"project-id" => project_id}, socket) do
    project = Projects.get_project!(project_id)
    params = %{"project_id" => project_id, "directory" => project.directory}

    case Sessions.create_session(params) do
      {:ok, session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)
    sessions = Sessions.list_sessions(filter)

    {:noreply,
     assign(socket,
       session_filter: filter,
       grouped_sessions: group_sessions(sessions, socket.assigns.projects)
     )}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    session = Sessions.get_session!(id)
    OrcaHub.SessionSupervisor.stop_session(id)
    {:ok, _} = Sessions.archive_session(session)
    filter = socket.assigns.session_filter
    {:noreply, assign(socket, grouped_sessions: group_sessions(Sessions.list_sessions(filter), socket.assigns.projects))}
  end

  def handle_event("validate", %{"session" => params}, socket) do
    # When project changes, update directory to project's directory
    form_params =
      case params["project_id"] do
        "" -> params
        nil -> params
        project_id ->
          project = Projects.get_project!(project_id)
          Map.put(params, "directory", project.directory)
      end

    changeset = Session.changeset(%Session{}, form_params)
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
    current = socket.assigns.form.params || %{}
    params = Map.put(current, "directory", socket.assigns.browse_path)
    changeset = Session.changeset(%Session{}, params)

    {:noreply,
     socket
     |> assign(browsing: false, form: to_form(changeset))}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  defp group_sessions(sessions, projects) do
    # Group sessions by project (nil project grouped separately)
    groups = Enum.group_by(sessions, & &1.project)

    # Add empty groups for projects with no sessions
    all_groups =
      Enum.reduce(projects, groups, fn project, acc ->
        if Enum.any?(acc, fn {p, _} -> p && p.id == project.id end) do
          acc
        else
          Map.put(acc, project, [])
        end
      end)

    # Sort: projects with most recent session first, empty projects last, unassigned at end
    all_groups
    |> Enum.sort_by(fn
      {nil, _} -> {2, ~N[0000-01-01 00:00:00]}
      {_project, []} -> {1, ~N[0000-01-01 00:00:00]}
      {_project, sessions} -> {0, sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)}
    end, fn
      {g1, _}, {g2, _} when g1 != g2 -> g1 <= g2
      {_, date_a}, {_, date_b} -> NaiveDateTime.compare(date_a, date_b) != :lt
    end)
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
