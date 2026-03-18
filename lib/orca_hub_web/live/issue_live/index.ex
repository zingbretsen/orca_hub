defmodule OrcaHubWeb.IssueLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Issues.Issue
  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(_params, _session, socket) do
    tagged_issues = Cluster.list_issues(exclude_closed: true)
    node_map = Cluster.build_node_map(tagged_issues)
    issues = Enum.map(tagged_issues, fn {_node, issue} -> issue end)
    tagged_projects = Cluster.list_projects()
    projects = Enum.map(tagged_projects, fn {_node, project} -> project end)
    clustered = length(Node.list()) > 0

    {:ok,
     socket
     |> assign(show_closed: false, node_map: node_map, clustered: clustered)
     |> stream(:issues, issues)
     |> assign(projects: projects)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Issues", form: nil, issue: nil)
  end

  defp apply_action(socket, :new, params) do
    attrs = case params do
      %{"project_id" => project_id} -> %{project_id: project_id}
      _ -> %{}
    end
    changeset = Issue.changeset(%Issue{}, attrs)

    socket
    |> assign(page_title: "New Issue", issue: nil)
    |> assign(form: to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    issue = HubRPC.get_issue!(id)
    changeset = Issue.changeset(issue, %{})

    socket
    |> assign(page_title: "Edit Issue", issue: issue)
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("save", %{"issue" => params}, socket) do
    save_issue(socket, socket.assigns.live_action, params)
  end

  def handle_event("toggle_closed", _params, socket) do
    show_closed = !socket.assigns.show_closed
    tagged_issues = Cluster.list_issues(exclude_closed: !show_closed)
    node_map = Cluster.build_node_map(tagged_issues)
    issues = Enum.map(tagged_issues, fn {_node, issue} -> issue end)

    {:noreply,
     socket
     |> assign(show_closed: show_closed, node_map: node_map)
     |> stream(:issues, issues, reset: true)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    issue = HubRPC.get_issue!(id)
    {:ok, _} = HubRPC.call(OrcaHub.Issues, :delete_issue, [issue])
    {:noreply, stream_delete(socket, :issues, issue)}
  end

  defp save_issue(socket, :new, params) do
    case HubRPC.call(OrcaHub.Issues, :create_issue, [params]) do
      {:ok, issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues/#{issue.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_issue(socket, :edit, params) do
    issue = socket.assigns.issue

    case HubRPC.update_issue(issue, params) do
      {:ok, issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues/#{issue.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
