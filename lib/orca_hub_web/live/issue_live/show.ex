defmodule OrcaHubWeb.IssueLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, Issues, Sessions}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {issue_node, issue} = find_issue!(id)

    {:ok,
     socket
     |> assign(issue: issue, issue_node: issue_node, page_title: issue.title)}
  end

  @impl true
  def handle_event("start_session", _params, socket) do
    issue = socket.assigns.issue
    node = socket.assigns.issue_node
    params = if issue.project, do: %{directory: issue.project.directory, project_id: issue.project.id}, else: %{}
    params = Map.put(params, :issue_id, issue.id)

    case Cluster.rpc(node, Sessions, :create_session, [params]) do
      {:ok, session} ->
        {:ok, _} = Cluster.rpc(node, OrcaHub.SessionSupervisor, :start_session, [session.id])

        # Auto-send the issue as the first message
        prompt =
          if issue.description && issue.description != "" do
            "#{issue.title}\n\n#{issue.description}"
          else
            issue.title
          end

        Cluster.rpc(node, OrcaHub.SessionRunner, :send_message, [session.id, prompt])

        # Update issue status to in_progress if it's open
        if issue.status == "open" do
          Cluster.rpc(node, Issues, :update_issue, [issue, %{status: "in_progress"}])
        end

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create session. Make sure the issue has a project with a directory.")}
    end
  end

  def handle_event("update_status", %{"status" => status}, socket) do
    node = socket.assigns.issue_node
    {:ok, issue} = Cluster.rpc(node, Issues, :update_issue, [socket.assigns.issue, %{status: status}])
    {:noreply, assign(socket, issue: issue)}
  end

  defp find_issue!(id) do
    case OrcaHub.Repo.get(OrcaHub.Issues.Issue, id) do
      nil ->
        Cluster.fan_out(Issues, :list_issues)
        |> Enum.find(fn {_node, i} -> i.id == id end)
        |> case do
          nil -> raise Ecto.NoResultsError, queryable: OrcaHub.Issues.Issue
          {found_node, _i} -> {found_node, Cluster.get_issue!(found_node, id)}
        end

      _issue ->
        {node(), Issues.get_issue!(id)}
    end
  end
end
