defmodule OrcaHubWeb.SessionLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.Session

  @impl true
  def mount(_params, _session, socket) do
    sessions = Sessions.list_sessions()

    {:ok,
     socket
     |> assign(grouped_sessions: group_sessions(sessions))
     |> assign(browsing: false, browse_path: nil, browse_entries: [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Sessions", form: nil)
  end

  defp apply_action(socket, :new, params) do
    changeset = Session.changeset(%Session{}, %{"directory" => params["directory"] || ""})

    socket
    |> assign(page_title: "New Session")
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("save", %{"session" => params}, socket) do
    case Sessions.create_session(params) do
      {:ok, session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)

        {:noreply,
         socket
         |> put_flash(:info, "Session created")
         |> push_navigate(to: ~p"/sessions/#{session.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    session = Sessions.get_session!(id)
    OrcaHub.SessionSupervisor.stop_session(id)
    {:ok, _} = Sessions.archive_session(session)
    {:noreply, assign(socket, grouped_sessions: group_sessions(Sessions.list_sessions()))}
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
    changeset = Session.changeset(%Session{}, %{"directory" => socket.assigns.browse_path})

    {:noreply,
     socket
     |> assign(browsing: false, form: to_form(changeset))}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  defp group_sessions(sessions) do
    # Group sessions by directory
    groups = Enum.group_by(sessions, & &1.directory)

    # Sort directories alphabetically for hierarchy building
    dirs = groups |> Map.keys() |> Enum.sort()

    # Build hierarchy, then sort groups by most recently updated session
    build_hierarchy(dirs, groups)
    |> Enum.sort_by(fn {_dir, root_sessions, children} ->
      all_sessions = root_sessions ++ Enum.flat_map(children, fn {_, s, _} -> s end)
      all_sessions |> Enum.map(& &1.updated_at) |> Enum.max(NaiveDateTime)
    end, {:desc, NaiveDateTime})
  end

  defp build_hierarchy(dirs, groups) do
    Enum.reduce(dirs, [], fn dir, acc ->
      # Check if this dir is a subdirectory of an existing root
      parent = Enum.find(acc, fn {root, _sessions, _children} ->
        dir != root && String.starts_with?(dir, root <> "/")
      end)

      case parent do
        {root, root_sessions, children} ->
          updated = {root, root_sessions, children ++ [{dir, groups[dir], []}]}
          Enum.map(acc, fn
            {^root, _, _} -> updated
            other -> other
          end)

        nil ->
          acc ++ [{dir, groups[dir], []}]
      end
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
