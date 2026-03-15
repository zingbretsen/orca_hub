defmodule OrcaHubWeb.DashboardLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Cluster

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback_requests")
    end

    {:ok, assign(socket, page_title: "Dashboard") |> load_data()}
  end

  defp load_data(socket) do
    tagged_sessions = Cluster.list_sessions(:all)
    sessions = Enum.map(tagged_sessions, fn {_n, s} -> s end)
    running = Enum.count(sessions, &(&1.status == "running"))
    idle = Enum.count(sessions, &(&1.status == "idle"))
    errored = Enum.count(sessions, &(&1.status == "error"))
    feedback_requests = Cluster.list_pending_feedback()
    open_issues = Cluster.list_issues() |> Enum.count(fn {_n, i} -> i.status != "closed" end)
    tagged_projects = Cluster.list_projects()
    tagged_triggers = Cluster.list_triggers()
    triggers = Enum.map(tagged_triggers, fn {_n, t} -> t end)
    enabled_triggers = Enum.count(triggers, & &1.enabled)
    recent_sessions = Enum.take(sessions, 8)

    clustered = length(Node.list()) > 0
    cluster_nodes = if clustered, do: Cluster.node_info(), else: []

    # Per-node session counts
    node_session_counts =
      if clustered do
        tagged_sessions
        |> Enum.group_by(fn {n, _s} -> n end)
        |> Enum.map(fn {n, items} -> {Cluster.node_name(n), length(items)} end)
        |> Enum.sort_by(fn {name, _} -> name end)
      else
        []
      end

    assign(socket,
      running_count: running,
      idle_count: idle,
      error_count: errored,
      total_sessions: length(sessions),
      feedback_count: length(feedback_requests),
      open_issues: open_issues,
      project_count: length(tagged_projects),
      trigger_count: length(triggers),
      enabled_triggers: enabled_triggers,
      recent_sessions: recent_sessions,
      clustered: clustered,
      cluster_nodes: cluster_nodes,
      node_session_counts: node_session_counts
    )
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, load_data(socket)}
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
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
