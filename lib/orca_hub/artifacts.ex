defmodule OrcaHub.Artifacts do
  @moduledoc """
  Context for agent-generated artifacts — rich HTML/SVG/markdown documents
  persisted per project and rendered client-side in a sandboxed iframe
  (`sandbox="allow-scripts"`, deliberately never `allow-same-origin`, so an
  artifact's script never touches cookies/auth/the parent DOM). Rendering
  agent-authored markup server-side (e.g. as HEEx) would be arbitrary code
  execution against the app's own origin — the sandboxed-iframe boundary is
  the whole point, not an implementation detail.

  Storage is this table, not disk — an artifact should outlive the session
  that created it. `save_artifact/1` is an upsert keyed on `(project_id,
  name)`: saving under a name that already exists in the project updates
  that row in place and bumps `version` (rather than creating a second
  artifact), so an agent iterating on the same UI across turns/sessions
  just keeps calling `save_artifact` with the same name.

  Every successful save broadcasts `{:artifact_updated, artifact}` on
  `"artifact:<artifact_id>"` so any open viewer (session split panel,
  fullscreen `/artifacts/:id`) can live-reload without a page refresh.
  """

  import Ecto.Query

  alias OrcaHub.Artifacts.Artifact
  alias OrcaHub.Repo

  @doc """
  Create or update an artifact, keyed on `(project_id, name)` from `attrs`
  (atom-keyed map). Bumps `version` on update; leaves it at the schema
  default (1) on insert. Broadcasts `{:artifact_updated, artifact}` on
  `"artifact:<artifact_id>"` after a successful save.
  """
  def save_artifact(attrs) do
    project_id = Map.get(attrs, :project_id)
    name = Map.get(attrs, :name)

    existing =
      if project_id && name, do: Repo.get_by(Artifact, project_id: project_id, name: name)

    existing
    |> case do
      nil ->
        %Artifact{}
        |> Artifact.changeset(attrs)
        |> Repo.insert()

      artifact ->
        attrs
        |> Map.put(:version, artifact.version + 1)
        |> then(&Artifact.changeset(artifact, &1))
        |> Repo.update()
    end
    |> broadcast_on_save()
  end

  @doc """
  Replace an artifact's `data` map in place — backs the `update_artifact_data`
  MCP tool, the live-data channel that lets an agent ship a dashboard's HTML
  once and then push fresh numbers into it on a later turn/session.

  Deliberately does NOT bump `version` (unlike `save_artifact/1`): version is
  what busts the iframe's `?v=` cache param and forces a reload, which is
  exactly what a live-data update is trying to avoid. Broadcasts
  `{:artifact_data_updated, artifact}` — a distinct message from
  `save_artifact/1`'s `{:artifact_updated, ...}` — on `"artifact:<artifact_id>"`
  so a viewer can tell a live-data push (forward via `postMessage`, no reload)
  apart from a content/version change (reload the iframe).
  """
  def update_artifact_data(%Artifact{} = artifact, data) when is_map(data) do
    artifact
    |> Artifact.changeset(%{data: data})
    |> Repo.update()
    |> broadcast_data_update()
  end

  def get_artifact(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> Repo.get(Artifact, id)
      :error -> nil
    end
  end

  def get_artifact_by_name(project_id, name),
    do: Repo.get_by(Artifact, project_id: project_id, name: name)

  @doc "Every artifact for a project, most recently updated first."
  def list_artifacts_for_project(project_id) do
    Repo.all(
      from a in Artifact,
        where: a.project_id == ^project_id,
        order_by: [desc: a.updated_at]
    )
  end

  @doc "Every artifact created by a given session, most recently updated first."
  def list_artifacts_for_session(session_id) do
    Repo.all(
      from a in Artifact,
        where: a.session_id == ^session_id,
        order_by: [desc: a.updated_at]
    )
  end

  def delete_artifact(%Artifact{} = artifact), do: Repo.delete(artifact)

  defp broadcast_on_save({:ok, artifact} = result) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "artifact:#{artifact.id}",
      {:artifact_updated, artifact}
    )

    result
  end

  defp broadcast_on_save(error), do: error

  defp broadcast_data_update({:ok, artifact} = result) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "artifact:#{artifact.id}",
      {:artifact_data_updated, artifact}
    )

    result
  end

  defp broadcast_data_update(error), do: error
end
