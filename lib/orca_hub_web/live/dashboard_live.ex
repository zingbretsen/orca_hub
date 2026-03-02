defmodule OrcaHubWeb.DashboardLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Sessions, Projects, Issues, Triggers, Feedback}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback_requests")
    end

    {:ok, assign(socket, page_title: "Dashboard") |> load_data()}
  end

  defp load_data(socket) do
    sessions = Sessions.list_sessions(:all)
    running = Enum.count(sessions, &(&1.status == "running"))
    idle = Enum.count(sessions, &(&1.status == "idle"))
    errored = Enum.count(sessions, &(&1.status == "error"))
    feedback_requests = Feedback.list_pending_requests()
    open_issues = Issues.list_issues() |> Enum.count(&(&1.status != "closed"))
    projects = Projects.list_projects()
    triggers = Triggers.list_triggers()
    enabled_triggers = Enum.count(triggers, & &1.enabled)
    recent_sessions = Enum.take(sessions, 8)

    assign(socket,
      running_count: running,
      idle_count: idle,
      error_count: errored,
      total_sessions: length(sessions),
      feedback_count: length(feedback_requests),
      open_issues: open_issues,
      project_count: length(projects),
      trigger_count: length(triggers),
      enabled_triggers: enabled_triggers,
      recent_sessions: recent_sessions
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
