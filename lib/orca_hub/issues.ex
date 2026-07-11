defmodule OrcaHub.Issues do
  @moduledoc """
  Minimal context for issues.

  The full Issues feature was removed in `3ebb3fe` (UI, routes, session
  linkage, and this context were all deleted); the `issues` table and
  `sessions.issue_id` column were deliberately left in place. This module
  reintroduces just enough of the original `OrcaHub.Issues` to back the
  `file_feature_request` MCP tool and a minimal browsing UI — create,
  fetch, list-open-for-project, list-all, append a note, and close/reopen.
  No project/session association management beyond that — the rest of the
  original feature stays removed.
  """

  import Ecto.Query
  alias OrcaHub.{Issues.Issue, Repo}

  def create_issue(attrs) do
    %Issue{}
    |> Issue.changeset(attrs)
    |> Repo.insert()
  end

  def get_issue(id), do: Repo.get(Issue, id)

  def get_issue!(id), do: Repo.get!(Issue, id)

  @doc "Non-closed issues for a project, most recently filed first."
  def list_open_issues_for_project(project_id) do
    Repo.all(
      from i in Issue,
        where: i.project_id == ^project_id and i.status != "closed",
        order_by: [desc: i.inserted_at]
    )
  end

  @doc "Every issue for a project regardless of status, most recently filed first."
  def list_issues_for_project(project_id) do
    Repo.all(
      from i in Issue,
        where: i.project_id == ^project_id,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc "Every issue, open first, newest first within each group."
  def list_issues do
    Repo.all(
      from i in Issue,
        order_by: [desc: fragment("? = 'open'", i.status), desc: i.inserted_at]
    )
  end

  def update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end

  @doc "Appends `note` to an issue's append-only `notes` field, separated by a blank line."
  def append_note(%Issue{} = issue, note) do
    updated =
      case issue.notes do
        nil -> note
        "" -> note
        existing -> existing <> "\n\n" <> note
      end

    update_issue(issue, %{notes: updated})
  end

  @doc "Transitions an issue to closed status."
  def close_issue(%Issue{} = issue), do: update_issue(issue, %{status: "closed"})

  @doc "Transitions a closed issue back to open status."
  def reopen_issue(%Issue{} = issue), do: update_issue(issue, %{status: "open"})
end
