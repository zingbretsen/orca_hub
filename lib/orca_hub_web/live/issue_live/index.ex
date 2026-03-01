defmodule OrcaHubWeb.IssueLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.Issues
  alias OrcaHub.Issues.Issue
  alias OrcaHub.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(:issues, Issues.list_issues())
     |> assign(projects: Projects.list_projects())}
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
    issue = Issues.get_issue!(id)
    changeset = Issue.changeset(issue, %{})

    socket
    |> assign(page_title: "Edit Issue", issue: issue)
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("save", %{"issue" => params}, socket) do
    save_issue(socket, socket.assigns.live_action, params)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    issue = Issues.get_issue!(id)
    {:ok, _} = Issues.delete_issue(issue)
    {:noreply, stream_delete(socket, :issues, issue)}
  end

  defp save_issue(socket, :new, params) do
    case Issues.create_issue(params) do
      {:ok, issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues/#{issue.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_issue(socket, :edit, params) do
    case Issues.update_issue(socket.assigns.issue, params) do
      {:ok, _issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
