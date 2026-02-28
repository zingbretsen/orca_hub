defmodule OrcaHub.Issues do
  import Ecto.Query
  alias OrcaHub.{Repo, Issues.Issue}

  def list_issues do
    Repo.all(from i in Issue, order_by: [desc: i.inserted_at], preload: [:project])
  end

  def list_issues_for_project(project_id) do
    Repo.all(from i in Issue, where: i.project_id == ^project_id, order_by: [desc: i.inserted_at])
  end

  def get_issue!(id), do: Repo.get!(Issue, id) |> Repo.preload([:sessions, :project])

  def create_issue(attrs) do
    %Issue{}
    |> Issue.changeset(attrs)
    |> Repo.insert()
  end

  def update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end

  def delete_issue(%Issue{} = issue), do: Repo.delete(issue)
end
