defmodule OrcaHub.Dashboard do
  @moduledoc """
  Hub-side queries behind `OrcaHubWeb.DashboardLive`, reached through
  `OrcaHub.HubRPC` (the hub owns the DB).

  The dashboard shows per-status session counts and the 8 most recently
  updated sessions. It used to load every unarchived session (with its
  project) to count them and keep 8. These return the counts as grouped
  rows and the recent list with a LIMIT.

  Both cover the same sessions as `OrcaHub.Sessions.list_sessions(:all)`:
  unarchived, `kind == "session"`, and not under a soft-deleted project.
  """

  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Session

  @doc """
  Session counts as `[{runner_node, status, count}]`, one row per pair.
  `runner_node` is the raw column value (possibly `nil`), so the caller can
  name each node once and apply the node filter.
  """
  def session_counts do
    Repo.all(
      from [s, _p] in listed_sessions(),
        group_by: [s.runner_node, s.status],
        select: {s.runner_node, s.status, count(s.id)}
    )
  end

  @doc """
  The `limit` most recently updated sessions, project preloaded.
  `runner_nodes` is `:all` or the list of `runner_node` values to keep.
  """
  def recent_sessions(limit, runner_nodes \\ :all) do
    query =
      from [s, p] in listed_sessions(),
        order_by: [desc: s.updated_at],
        limit: ^limit,
        preload: [project: p]

    query =
      case runner_nodes do
        :all -> query
        nodes when is_list(nodes) -> from(s in query, where: s.runner_node in ^nodes)
      end

    Repo.all(query)
  end

  defp listed_sessions do
    from s in Session,
      left_join: p in assoc(s, :project),
      where: is_nil(s.archived_at) and s.kind == "session",
      where: is_nil(s.project_id) or is_nil(p.deleted_at)
  end
end
