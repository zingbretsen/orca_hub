defmodule OrcaHub.ClusterNodes do
  @moduledoc """
  Context for the `nodes` table — every Erlang node that has ever connected
  to the cluster (or been referenced by a session/project's node field), for
  the /nodes UI.

  Named `ClusterNodes` (not `Nodes`) to stay clear of Elixir's built-in
  `Node`/`Node.list()`, which this module's rows are derived from.

  This module talks to the database directly and therefore only runs on the
  hub. Callers on any node must go through `OrcaHub.HubRPC`. Rows are
  written by `OrcaHub.ClusterNodeTracker` (hub-only GenServer).
  """

  import Ecto.Query

  alias OrcaHub.ClusterNodes.ClusterNode
  alias OrcaHub.Projects.Project
  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Session

  def list_nodes do
    Repo.all(from n in ClusterNode, order_by: [desc: n.last_connected_at])
  end

  def get_node!(id), do: Repo.get!(ClusterNode, id)

  def get_by_name(name) when is_binary(name), do: Repo.get_by(ClusterNode, name: name)

  @doc """
  Generic attribute update for a `nodes` row — currently used for the
  `isolated`/`scrub_session_env` toggles (see `OrcaHub.NodePolicy`) and the
  `default_backend`/`default_model` fields (see
  `OrcaHub.Sessions.create_session/1`). Deliberately NOT used by
  `upsert_seen`/`touch_last_connected`/`backfill_node`'s conflict-update
  paths, which only ever `on_conflict: [set: [...]]` an explicit field list —
  so a node reconnecting never resets an operator-set `isolated`/
  `scrub_session_env` flag, or an operator-set default backend/model, back to
  blank.
  """
  def update_node(%ClusterNode{} = node, attrs) do
    node |> ClusterNode.changeset(attrs) |> Repo.update()
  end

  @doc """
  Insert or update the row for `name`, bumping `last_connected_at` to now
  and refreshing `display_name`. On first insert, `first_connected_at` is
  also set to now and preserved on every later call. Used for `:nodeup` and
  the initial-membership sweep on tracker boot.
  """
  def upsert_seen(name, display_name) when is_binary(name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ClusterNode{}
    |> ClusterNode.changeset(%{
      name: name,
      display_name: display_name,
      first_connected_at: now,
      last_connected_at: now
    })
    |> Repo.insert(
      on_conflict: [set: [display_name: display_name, last_connected_at: now, updated_at: now]],
      conflict_target: :name,
      returning: true
    )
  end

  @doc """
  Bumps `last_connected_at` to now without touching `display_name` — used on
  `:nodedown` so the row reflects when we last confirmed the node was still
  connected, without overwriting a good display name with whatever
  best-effort hostname fallback we can derive after it has already
  disconnected.
  """
  def touch_last_connected(name) when is_binary(name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_by_name(name) do
      nil -> upsert_seen(name, name)
      node -> node |> ClusterNode.changeset(%{last_connected_at: now}) |> Repo.update()
    end
  end

  @doc """
  Inserts a row for `name` only if one doesn't already exist — leaves
  `first_connected_at`/`last_connected_at` unset since we don't actually
  know when (or whether) this node was ever live, only that a session or
  project references it. Never overwrites an existing row.
  """
  def backfill_node(name, display_name) when is_binary(name) do
    %ClusterNode{}
    |> ClusterNode.changeset(%{name: name, display_name: display_name})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :name)
  end

  @doc "Distinct `sessions.runner_node` / `projects.node` values in use."
  def distinct_session_and_project_node_names do
    session_nodes =
      Repo.all(
        from s in Session,
          where: not is_nil(s.runner_node) and s.runner_node != "",
          distinct: true,
          select: s.runner_node
      )

    project_nodes =
      Repo.all(
        from p in Project,
          where: not is_nil(p.node) and p.node != "",
          distinct: true,
          select: p.node
      )

    Enum.uniq(session_nodes ++ project_nodes)
  end

  def count_sessions_for_node(name) when is_binary(name) do
    Repo.one(from s in Session, where: s.runner_node == ^name, select: count(s.id))
  end

  def count_projects_for_node(name) when is_binary(name) do
    Repo.one(
      from p in Project, where: p.node == ^name and is_nil(p.deleted_at), select: count(p.id)
    )
  end
end
