defmodule OrcaHubWeb.DashboardLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHubWeb.NodeFilter

  @recent_limit 8
  # Session status/title changes arrive in bursts (every turn start and end,
  # across every session); one reload covers a whole burst.
  @sessions_reload_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok,
     socket
     |> assign(page_title: "Dashboard", sessions_reload_timer: nil)
     |> load_data()}
  end

  defp load_data(socket) do
    socket
    |> load_sessions_data()
    |> load_projects_and_triggers()
  end

  # Grouped counts plus a LIMIT query, instead of every unarchived session.
  defp load_sessions_data(socket) do
    node_filter = socket.assigns[:node_filter] || :all
    counts = HubRPC.dashboard_session_counts()

    # One display name per distinct runner_node, not one per session.
    names =
      counts
      |> Enum.map(fn {runner_node, _status, _count} -> runner_node end)
      |> Enum.uniq()
      |> Map.new(&{&1, node_name_for(&1)})

    summary = session_summary(counts, names, node_filter)

    recent_sessions =
      HubRPC.dashboard_recent_sessions(@recent_limit, recent_runner_nodes(names, node_filter))

    clustered = Node.list() != []

    assign(socket,
      running_count: summary.running,
      idle_count: summary.idle,
      error_count: summary.error,
      total_sessions: summary.total,
      recent_sessions: recent_sessions,
      clustered: clustered,
      cluster_nodes: if(clustered, do: Cluster.node_info(), else: []),
      node_session_counts: if(clustered, do: summary.per_node, else: [])
    )
  end

  defp load_projects_and_triggers(socket) do
    node_filter = socket.assigns[:node_filter] || :all
    tagged_projects = Cluster.list_projects() |> NodeFilter.filter_tagged(node_filter)
    tagged_triggers = Cluster.list_triggers() |> NodeFilter.filter_tagged(node_filter)
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)

    assign(socket,
      project_count: length(tagged_projects),
      trigger_count: length(triggers),
      enabled_triggers: Enum.count(triggers, & &1.enabled)
    )
  end

  @doc false
  # Folds `[{runner_node, status, count}]` rows into the dashboard's numbers,
  # keeping only nodes the filter selects. `names` maps each runner_node to
  # its display name. Public for testing the node-filter semantics, which a
  # single-node test cluster cannot reach through the page.
  def session_summary(counts, names, node_filter) do
    rows =
      Enum.filter(counts, fn {runner_node, _status, _count} ->
        NodeFilter.node_selected?(node_filter, Map.fetch!(names, runner_node))
      end)

    count = fn status ->
      rows
      |> Enum.map(fn
        {_rn, ^status, c} -> c
        _ -> 0
      end)
      |> Enum.sum()
    end

    per_node =
      rows
      |> Enum.group_by(fn {runner_node, _s, _c} -> Map.fetch!(names, runner_node) end)
      |> Enum.map(fn {name, node_rows} -> {name, total(node_rows)} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    %{
      running: count.("running"),
      idle: count.("idle"),
      error: count.("error"),
      total: total(rows),
      per_node: per_node
    }
  end

  defp total(rows), do: rows |> Enum.map(fn {_rn, _s, c} -> c end) |> Enum.sum()

  # NodeFilter.filter_tagged/2's naming: a session's runner_node when set,
  # otherwise its tagged node, which for a session is nil.
  defp node_name_for(runner_node) when is_binary(runner_node) and runner_node != "",
    do: Cluster.node_name(runner_node)

  defp node_name_for(_runner_node), do: Cluster.node_name(nil)

  defp recent_runner_nodes(_names, :all), do: :all

  defp recent_runner_nodes(names, node_filter) do
    for {runner_node, name} <- names,
        is_binary(runner_node),
        NodeFilter.node_selected?(node_filter, name),
        do: runner_node
  end

  def reload_for_node_filter(socket), do: {:noreply, load_data(socket)}

  # The "sessions" topic carries every agent event of every session. Only
  # status and title changes alter what this page shows.
  @impl true
  def handle_info({_session_id, {tag, _}}, socket) when tag in [:status, :title_updated] do
    {:noreply, schedule_sessions_reload(socket)}
  end

  def handle_info(:reload_sessions, socket) do
    {:noreply, socket |> assign(sessions_reload_timer: nil) |> load_sessions_data()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_sessions_reload(%{assigns: %{sessions_reload_timer: nil}} = socket) do
    timer = Process.send_after(self(), :reload_sessions, @sessions_reload_ms)
    assign(socket, sessions_reload_timer: timer)
  end

  defp schedule_sessions_reload(socket), do: socket

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
end
