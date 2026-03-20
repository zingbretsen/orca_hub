defmodule OrcaHubWeb.IssueLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    issue = HubRPC.get_issue!(id)
    issue_node = if issue.project, do: Cluster.project_node_for(issue.project), else: node()

    {:ok,
     socket
     |> assign(issue: issue, issue_node: issue_node, page_title: issue.title)}
  end

  @impl true
  def handle_event("start_session", _params, socket) do
    issue = socket.assigns.issue
    runner_node = socket.assigns.issue_node
    params = if issue.project, do: %{directory: issue.project.directory, project_id: issue.project.id}, else: %{}
    params = params |> Map.put(:issue_id, issue.id) |> Map.put(:runner_node, Atom.to_string(runner_node))

    case HubRPC.create_session(params) do
      {:ok, session} ->
        {:ok, _} = Cluster.start_session(runner_node, session.id, session)

        # Auto-send the issue as the first message
        prompt =
          if issue.description && issue.description != "" do
            "#{issue.title}\n\n#{issue.description}"
          else
            issue.title
          end

        Cluster.send_message(runner_node, session.id, prompt)

        # Update issue status to in_progress if it's open
        if issue.status == "open" do
          HubRPC.update_issue(issue, %{status: "in_progress"})
        end

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create session. Make sure the issue has a project with a directory.")}
    end
  end

  def handle_event("update_status", %{"status" => status}, socket) do
    {:ok, issue} = HubRPC.update_issue(socket.assigns.issue, %{status: status})
    {:noreply, assign(socket, issue: issue)}
  end
end
