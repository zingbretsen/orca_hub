defmodule OrcaHubWeb.SessionLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Projects, Sessions, Cluster}
  alias OrcaHub.Sessions.Session

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    projects = Cluster.list_projects()
    filter = :manual

    tagged_sessions = Cluster.list_sessions(filter)
    node_map = Cluster.build_node_map(tagged_sessions)
    project_node_map = Map.new(projects, fn {n, p} -> {p.id, n} end)
    clustered = length(Node.list()) > 0

    {:ok,
     socket
     |> assign(
       projects: projects,
       session_filter: filter,
       grouped_sessions: group_sessions(tagged_sessions, projects, clustered),
       node_map: node_map,
       project_node_map: project_node_map,
       clustered: clustered,
       browsing: false,
       browse_path: nil,
       browse_entries: [],
       browse_show_hidden: false,
       undo_archive_session: nil,
       undo_archive_timer: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket = assign(socket, page_title: "Sessions", form: nil)

    case params["undo"] do
      nil -> socket
      id -> schedule_undo_archive(socket, id)
    end
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
    |> assign(cluster_nodes: Cluster.nodes())
  end

  @impl true
  def handle_event("save", %{"session" => params}, socket) do
    target_node = params |> Map.get("target_node", Atom.to_string(node())) |> String.to_existing_atom()
    session_params = Map.delete(params, "target_node")

    case Cluster.rpc(target_node, Sessions, :create_session, [session_params]) do
      {:ok, session} ->
        Cluster.start_session(target_node, session.id)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("create_for_project", %{"project-id" => project_id}, socket) do
    target_node = Map.get(socket.assigns.project_node_map, project_id, node())
    project = Cluster.get_project!(target_node, project_id)
    params = %{"project_id" => project_id, "directory" => project.directory}

    case Cluster.rpc(target_node, Sessions, :create_session, [params]) do
      {:ok, session} ->
        Cluster.start_session(target_node, session.id)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)
    tagged_sessions = Cluster.list_sessions(filter)
    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = socket.assigns.clustered

    {:noreply,
     assign(socket,
       session_filter: filter,
       grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
       node_map: node_map
     )}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    session = Cluster.get_session!(node, id)
    Cluster.stop_session(node, id)
    {:ok, _} = Cluster.archive_session(node, session)
    filter = socket.assigns.session_filter
    tagged_sessions = Cluster.list_sessions(filter)
    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = socket.assigns.clustered

    socket =
      socket
      |> assign(
        grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
        node_map: node_map
      )
      |> schedule_undo_archive(id)

    {:noreply, socket}
  end

  def handle_event("undo_archive", _params, socket) do
    if session_id = socket.assigns.undo_archive_session do
      node = Map.get(socket.assigns.node_map, session_id, node())
      session = Cluster.get_session!(node, session_id)
      Cluster.unarchive_session(node, session)
      filter = socket.assigns.session_filter
      tagged_sessions = Cluster.list_sessions(filter)
      node_map = Cluster.build_node_map(tagged_sessions)
      clustered = socket.assigns.clustered

      {:noreply,
       socket
       |> cancel_undo_timer()
       |> assign(undo_archive_session: nil)
       |> assign(
         grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
         node_map: node_map
       )}
    else
      {:noreply, socket}
    end
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
  def handle_info(:clear_undo_archive, socket) do
    {:noreply, assign(socket, undo_archive_session: nil, undo_archive_timer: nil)}
  end

  def handle_info({_session_id, _payload}, socket) do
    filter = socket.assigns.session_filter
    tagged_sessions = Cluster.list_sessions(filter)
    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = length(Node.list()) > 0

    {:noreply,
     assign(socket,
       grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
       node_map: node_map,
       clustered: clustered
     )}
  end

  defp schedule_undo_archive(socket, session_id) do
    socket = cancel_undo_timer(socket)
    timer = Process.send_after(self(), :clear_undo_archive, 5000)
    assign(socket, undo_archive_session: session_id, undo_archive_timer: timer)
  end

  defp cancel_undo_timer(socket) do
    if ref = socket.assigns.undo_archive_timer do
      Process.cancel_timer(ref)
    end

    assign(socket, undo_archive_timer: nil)
  end

  defp group_sessions(tagged_sessions, tagged_projects, clustered) do
    # Extract sessions from {node, session} tuples
    sessions = Enum.map(tagged_sessions, fn {_node, session} -> session end)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    if clustered do
      # In cluster mode, group by {node_name, project}
      # First, build a map of session_id -> node_name
      session_node_names =
        Map.new(tagged_sessions, fn {node, session} ->
          {session.id, Cluster.node_name(node)}
        end)

      # Group sessions by {node_name, project}
      groups =
        Enum.group_by(sessions, fn session ->
          node_name = Map.get(session_node_names, session.id, Cluster.node_name(node()))
          {node_name, session.project}
        end)

      # Sort: projects with most recent session first, empty projects last, unassigned at end
      groups
      |> Enum.sort_by(fn
        {{_node_name, nil}, _} -> {2, ~N[0000-01-01 00:00:00]}
        {{_node_name, _project}, []} -> {1, ~N[0000-01-01 00:00:00]}
        {{_node_name, _project}, sessions} -> {0, sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)}
      end, fn
        {g1, _}, {g2, _} when g1 != g2 -> g1 <= g2
        {_, date_a}, {_, date_b} -> NaiveDateTime.compare(date_a, date_b) != :lt
      end)
    else
      # Single-node mode: group by project only (original behavior)
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

      # Wrap keys in {nil, project} for consistent template format
      all_groups
      |> Enum.map(fn {project, sessions} -> {{nil, project}, sessions} end)
      |> Enum.sort_by(fn
        {{_, nil}, _} -> {2, ~N[0000-01-01 00:00:00]}
        {{_, _project}, []} -> {1, ~N[0000-01-01 00:00:00]}
        {{_, _project}, sessions} -> {0, sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)}
      end, fn
        {g1, _}, {g2, _} when g1 != g2 -> g1 <= g2
        {_, date_a}, {_, date_b} -> NaiveDateTime.compare(date_a, date_b) != :lt
      end)
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
