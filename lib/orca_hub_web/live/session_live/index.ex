defmodule OrcaHubWeb.SessionLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Projects, SessionHeartbeat}
  alias OrcaHub.Sessions.Session
  alias OrcaHubWeb.NodeFilter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    projects = Cluster.list_projects()
    filter = :manual

    heartbeat_session_ids = get_heartbeat_session_ids()
    tagged_sessions = Cluster.list_sessions(filter)
    filtered_sessions = NodeFilter.filter_tagged(tagged_sessions, socket.assigns.node_filter)
    filtered_sessions = filter_by_heartbeat(filtered_sessions, filter, heartbeat_session_ids)
    filtered_projects = NodeFilter.filter_tagged(projects, socket.assigns.node_filter)
    node_map = Cluster.build_node_map(filtered_sessions)
    project_node_map = Map.new(filtered_projects, fn {n, p} -> {p.id, n} end)
    clustered = Node.list() != []

    {:ok,
     socket
     |> assign(
       projects: filtered_projects,
       session_filter: filter,
       grouped_sessions: group_sessions(filtered_sessions, filtered_projects, clustered),
       node_map: node_map,
       project_node_map: project_node_map,
       clustered: clustered,
       browsing: false,
       browse_path: nil,
       browse_entries: [],
       browse_show_hidden: false,
       undo_archive_session: nil,
       undo_archive_timer: nil,
       heartbeat_session_ids: heartbeat_session_ids,
       selected_sessions: MapSet.new()
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
        nil ->
          %{}

        id ->
          project = Projects.get_project!(id)
          %{"project_id" => id, "directory" => project.directory}
      end

    # Preselect the target node's configured backend/model default (see
    # OrcaHub.Sessions moduledoc) so the picker shows what the session will
    # actually get, rather than always opening on the schema's bare "claude"
    # default. `initial`'s own keys always win (there's no overlap today,
    # but explicit request params should take precedence over a guess).
    initial = Map.merge(node_default_attrs(node()), initial)

    changeset = Session.changeset(%Session{}, initial)

    socket
    |> assign(page_title: "New Session")
    |> assign(form: to_form(changeset))
    |> assign(cluster_nodes: Cluster.nodes())
    |> assign(selected_target_node: Atom.to_string(node()))
  end

  @impl true
  def handle_event("save", %{"session" => params}, socket) do
    target_node =
      params |> Map.get("target_node", Atom.to_string(node())) |> String.to_existing_atom()

    session_params =
      params
      |> Map.delete("target_node")
      |> Map.put("runner_node", Atom.to_string(target_node))

    case HubRPC.create_session(session_params) do
      {:ok, session} ->
        Cluster.start_session(target_node, session.id, session)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("create_for_project", %{"project-id" => project_id}, socket) do
    target_node = Map.get(socket.assigns.project_node_map, project_id, node())
    project = HubRPC.get_project!(project_id)

    params = %{
      "project_id" => project_id,
      "directory" => project.directory,
      "runner_node" => Atom.to_string(target_node)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        Cluster.start_session(target_node, session.id, session)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event(
        "create_for_worktree",
        %{"project-id" => project_id, "directory" => directory},
        socket
      ) do
    target_node = Map.get(socket.assigns.project_node_map, project_id, node())

    params = %{
      "project_id" => project_id,
      "directory" => directory,
      "runner_node" => Atom.to_string(target_node)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        Cluster.start_session(target_node, session.id, session)
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)
    heartbeat_session_ids = get_heartbeat_session_ids()

    tagged_sessions =
      Cluster.list_sessions(filter)
      |> NodeFilter.filter_tagged(socket.assigns.node_filter)
      |> filter_by_heartbeat(filter, heartbeat_session_ids)

    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = socket.assigns.clustered

    {:noreply,
     assign(socket,
       session_filter: filter,
       grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
       node_map: node_map,
       heartbeat_session_ids: heartbeat_session_ids,
       selected_sessions: MapSet.new()
     )}
  end

  def handle_event("stop_session", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    Cluster.stop_session(node, id)
    {:noreply, socket}
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
        "" ->
          params

        nil ->
          params

        project_id ->
          project = Projects.get_project!(project_id)
          Map.put(params, "directory", project.directory)
      end

    changeset = Session.changeset(%Session{}, form_params)

    {:noreply,
     socket
     |> assign(form: to_form(changeset))
     |> assign(selected_target_node: params["target_node"])}
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

    {:noreply,
     socket |> assign(browse_show_hidden: show_hidden) |> browse_to(socket.assigns.browse_path)}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  def handle_event("toggle_session", %{"id" => id}, socket) do
    selected = socket.assigns.selected_sessions

    new_selected =
      if MapSet.member?(selected, id) do
        MapSet.delete(selected, id)
      else
        MapSet.put(selected, id)
      end

    {:noreply, assign(socket, selected_sessions: new_selected)}
  end

  def handle_event("toggle_all_sessions", _params, socket) do
    all_session_ids = get_all_session_ids(socket.assigns.grouped_sessions)
    selected = socket.assigns.selected_sessions

    new_selected =
      if MapSet.size(selected) == length(all_session_ids) do
        MapSet.new()
      else
        MapSet.new(all_session_ids)
      end

    {:noreply, assign(socket, selected_sessions: new_selected)}
  end

  def handle_event("toggle_group_sessions", %{"project-id" => project_id, "node" => node}, socket) do
    group_ids = group_session_ids(socket.assigns.grouped_sessions, project_id, node)
    selected = socket.assigns.selected_sessions

    all_selected? = group_ids != [] and Enum.all?(group_ids, &MapSet.member?(selected, &1))

    new_selected =
      if all_selected? do
        Enum.reduce(group_ids, selected, &MapSet.delete(&2, &1))
      else
        Enum.reduce(group_ids, selected, &MapSet.put(&2, &1))
      end

    {:noreply, assign(socket, selected_sessions: new_selected)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_sessions: MapSet.new())}
  end

  def handle_event("archive_selected", _params, socket) do
    selected = socket.assigns.selected_sessions
    node_map = socket.assigns.node_map

    for session_id <- selected do
      node = Map.get(node_map, session_id, node())
      session = Cluster.get_session!(node, session_id)
      Cluster.stop_session(node, session_id)
      Cluster.archive_session(node, session)
    end

    filter = socket.assigns.session_filter
    tagged_sessions = Cluster.list_sessions(filter)
    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = socket.assigns.clustered

    {:noreply,
     socket
     |> assign(
       grouped_sessions: group_sessions(tagged_sessions, socket.assigns.projects, clustered),
       node_map: node_map,
       selected_sessions: MapSet.new()
     )
     |> put_flash(:info, "Archived #{MapSet.size(selected)} session(s)")}
  end

  @impl true
  def handle_info(:clear_undo_archive, socket) do
    {:noreply, assign(socket, undo_archive_session: nil, undo_archive_timer: nil)}
  end

  def handle_info({_session_id, _payload}, socket) do
    {:noreply, reload_session_data(socket)}
  end

  # New-session form's currently-selected backend, for scoping the model
  # datalist and the MCP-dependent toggles (backend_abstraction_spec.md §7).
  # Blank/nil (form not yet touched, or the backend picker is hidden behind
  # a single-entry `available/0`) falls back to the changeset default.
  defp selected_backend(form) do
    case form[:backend].value do
      v when v in [nil, ""] -> "claude"
      v -> v
    end
  end

  # Node-configured backend/model default (see `OrcaHub.Sessions` moduledoc)
  # as `"backend"`/`"model"` form-param keys, for preselecting the new-session
  # picker. Only used at initial mount — the picker doesn't re-derive this on
  # a subsequent target-node change within the same open form.
  defp node_default_attrs(target_node) do
    case HubRPC.get_node_by_name(Atom.to_string(target_node)) do
      nil ->
        %{}

      node ->
        %{}
        |> maybe_put_default("backend", node.default_backend)
        |> maybe_put_default("model", node.default_model)
    end
  end

  defp maybe_put_default(map, _key, nil), do: map
  defp maybe_put_default(map, key, value), do: Map.put(map, key, value)

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

  def reload_for_node_filter(socket), do: {:noreply, reload_session_data(socket)}

  defp reload_session_data(socket) do
    filter = socket.assigns.session_filter
    heartbeat_session_ids = get_heartbeat_session_ids()
    projects = Cluster.list_projects() |> NodeFilter.filter_tagged(socket.assigns.node_filter)

    tagged_sessions =
      Cluster.list_sessions(filter)
      |> NodeFilter.filter_tagged(socket.assigns.node_filter)
      |> filter_by_heartbeat(filter, heartbeat_session_ids)

    node_map = Cluster.build_node_map(tagged_sessions)
    clustered = Node.list() != []

    assign(socket,
      projects: projects,
      grouped_sessions: group_sessions(tagged_sessions, projects, clustered),
      node_map: node_map,
      clustered: clustered,
      heartbeat_session_ids: heartbeat_session_ids
    )
  end

  defp group_sessions(tagged_sessions, tagged_projects, clustered) do
    # Extract sessions from {node, session} tuples
    sessions = Enum.map(tagged_sessions, fn {_node, session} -> session end)
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)

    if clustered do
      # In cluster mode, group by {node_name, project}
      # First, build a map of session_id -> node_name
      # Use session.runner_node directly to preserve disconnected node identity
      session_node_names =
        Map.new(tagged_sessions, fn {_node, session} ->
          {session.id, Cluster.node_name(session.runner_node || node())}
        end)

      # Group sessions by {node_name, project}
      groups =
        Enum.group_by(sessions, fn session ->
          node_name = Map.get(session_node_names, session.id, Cluster.node_name(node()))
          {node_name, session.project}
        end)

      # Sort: projects with most recent session first, empty projects last, unassigned at end
      groups
      |> Enum.sort_by(
        fn
          {{_node_name, nil}, _} ->
            {2, ~N[0000-01-01 00:00:00]}

          {{_node_name, _project}, []} ->
            {1, ~N[0000-01-01 00:00:00]}

          {{_node_name, _project}, sessions} ->
            {0, sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)}
        end,
        fn
          {g1, _}, {g2, _} when g1 != g2 -> g1 <= g2
          {_, date_a}, {_, date_b} -> NaiveDateTime.compare(date_a, date_b) != :lt
        end
      )
      |> Enum.map(fn {{node_name, project}, sessions} ->
        {main_sessions, worktree_groups} = split_worktree_sessions(project, sessions)
        {{node_name, project}, main_sessions, worktree_groups}
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
      |> Enum.sort_by(
        fn
          {{_, nil}, _} ->
            {2, ~N[0000-01-01 00:00:00]}

          {{_, _project}, []} ->
            {1, ~N[0000-01-01 00:00:00]}

          {{_, _project}, sessions} ->
            {0, sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)}
        end,
        fn
          {g1, _}, {g2, _} when g1 != g2 -> g1 <= g2
          {_, date_a}, {_, date_b} -> NaiveDateTime.compare(date_a, date_b) != :lt
        end
      )
      |> Enum.map(fn {{node_name, project}, sessions} ->
        {main_sessions, worktree_groups} = split_worktree_sessions(project, sessions)
        {{node_name, project}, main_sessions, worktree_groups}
      end)
    end
  end

  # No worktree sub-grouping for unassigned sessions
  defp split_worktree_sessions(nil, sessions), do: {order_with_children(sessions), []}

  defp split_worktree_sessions(project, sessions) do
    project_dir = Path.expand(project.directory)

    {main, worktree} =
      Enum.split_with(sessions, fn session ->
        Path.expand(session.directory) == project_dir
      end)

    main = order_with_children(main)

    worktree_groups =
      if worktree == [] do
        []
      else
        # Look up git worktrees for branch name display
        worktrees = Projects.git_worktree_list(project)
        worktree_map = Map.new(worktrees, fn wt -> {Path.expand(wt[:path]), wt} end)

        worktree
        |> Enum.group_by(& &1.directory)
        |> Enum.map(fn {dir, dir_sessions} ->
          wt_info = worktree_map[Path.expand(dir)]
          label = if wt_info, do: wt_info[:branch], else: Path.basename(dir)
          {dir, label, order_with_children(dir_sessions)}
        end)
        |> Enum.sort_by(
          fn {_dir, _label, dir_sessions} ->
            dir_sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)
          end,
          {:desc, NaiveDateTime}
        )
      end

    {main, worktree_groups}
  end

  # Reorder a flat list of sessions so that orchestrator-spawned children render
  # directly beneath their parent. A child whose parent is NOT in this same list
  # (e.g. filtered out, or in a different group) stays at the top level. Children
  # are kept in the list so selection/bulk-archive still includes them.
  defp order_with_children(sessions) do
    ids = MapSet.new(sessions, & &1.id)

    {children, tops} =
      Enum.split_with(sessions, fn s ->
        s.parent_session_id && MapSet.member?(ids, s.parent_session_id)
      end)

    children_by_parent = Enum.group_by(children, & &1.parent_session_id)

    Enum.flat_map(tops, fn parent ->
      [parent | Map.get(children_by_parent, parent.id, [])]
    end)
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
            if show_hidden,
              do: dirs,
              else: Enum.reject(dirs, fn p -> String.starts_with?(Path.basename(p), ".") end)
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end

  defp get_heartbeat_session_ids do
    SessionHeartbeat.list_all()
    |> Enum.map(fn {session_id, _info} -> session_id end)
    |> MapSet.new()
  end

  defp filter_by_heartbeat(tagged_sessions, :heartbeat, heartbeat_session_ids) do
    Enum.filter(tagged_sessions, fn {_node, session} ->
      MapSet.member?(heartbeat_session_ids, session.id)
    end)
  end

  defp filter_by_heartbeat(tagged_sessions, _other_filter, _heartbeat_session_ids) do
    tagged_sessions
  end

  defp get_all_session_ids(grouped_sessions) do
    Enum.flat_map(grouped_sessions, fn {{_node_name, _project}, main_sessions, worktree_groups} ->
      main_ids = Enum.map(main_sessions, & &1.id)

      worktree_ids =
        Enum.flat_map(worktree_groups, fn {_dir, _label, sessions} ->
          Enum.map(sessions, & &1.id)
        end)

      main_ids ++ worktree_ids
    end)
  end

  def time_ago(datetime) do
    now = DateTime.utc_now()

    datetime =
      if is_struct(datetime, NaiveDateTime),
        do: DateTime.from_naive!(datetime, "Etc/UTC"),
        else: datetime

    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  def full_timestamp(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp group_session_ids(grouped_sessions, project_id, node) do
    Enum.find_value(grouped_sessions, [], fn {{node_name, project}, main, worktrees} ->
      matches_project? =
        case project do
          nil -> project_id == "unassigned"
          %{id: id} -> id == project_id
        end

      matches_node? = (node_name || "local") == node

      if matches_project? and matches_node? do
        main_ids = Enum.map(main, & &1.id)
        wt_ids = Enum.flat_map(worktrees, fn {_d, _b, s} -> Enum.map(s, & &1.id) end)
        main_ids ++ wt_ids
      else
        false
      end
    end)
  end
end
