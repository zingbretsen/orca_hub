defmodule OrcaHub.Issues do
  @moduledoc """
  Minimal context for issues.

  The full Issues feature was removed in `3ebb3fe` (UI, routes, session
  linkage, and this context were all deleted); the `issues` table and
  `sessions.issue_id` column were deliberately left in place. This module
  reintroduces just enough of the original `OrcaHub.Issues` to back the
  `file_feature_request` MCP tool and a minimal read-only browsing UI —
  create, fetch, list-open-for-project, list-all, and append a note. No
  project/session association management, no closing/reopening workflow —
  that's UI territory that stays removed.
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
end
