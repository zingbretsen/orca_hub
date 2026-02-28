defmodule OrcaHubWeb.IssueLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Issues
  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.Session

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    issue = Issues.get_issue!(id)

    {:ok,
     socket
     |> assign(issue: issue, page_title: issue.title)
     |> assign(session_form: nil)}
  end

  @impl true
  def handle_event("start_session", _params, socket) do
    issue = socket.assigns.issue
    defaults = if issue.project, do: %{directory: issue.project.directory}, else: %{}
    changeset = Session.changeset(%Session{}, defaults)

    {:noreply, assign(socket, session_form: to_form(changeset))}
  end

  def handle_event("cancel_session", _params, socket) do
    {:noreply, assign(socket, session_form: nil)}
  end

  def handle_event("create_session", %{"session" => params}, socket) do
    issue = socket.assigns.issue
    params = Map.put(params, "issue_id", issue.id)

    case Sessions.create_session(params) do
      {:ok, session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)

        # Auto-send the issue as the first message
        prompt =
          if issue.description && issue.description != "" do
            "#{issue.title}\n\n#{issue.description}"
          else
            issue.title
          end

        OrcaHub.SessionRunner.send_message(session.id, prompt)

        # Update issue status to in_progress if it's open
        if issue.status == "open" do
          Issues.update_issue(issue, %{status: "in_progress"})
        end

        {:noreply,
         socket
         |> put_flash(:info, "Session started")
         |> push_navigate(to: ~p"/sessions/#{session.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, session_form: to_form(changeset))}
    end
  end

  def handle_event("update_status", %{"status" => status}, socket) do
    {:ok, issue} = Issues.update_issue(socket.assigns.issue, %{status: status})
    {:noreply, assign(socket, issue: issue)}
  end
end
