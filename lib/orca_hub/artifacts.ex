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
  fullscreen `/artifacts/:id`) can live-reload without a page refresh. When
  the artifact has a `session_id`, it also broadcasts `{:artifact_saved,
  artifact}` on `"session:<session_id>"` so the creator session's header
  (Artifacts button count + dropdown) can stay in sync without a remount.
  """

  import Ecto.Query

  alias OrcaHub.Artifacts.Artifact
  alias OrcaHub.Repo

  @doc """
  Create or update an artifact, keyed on `(project_id, name)` from `attrs`
  (atom-keyed map). Bumps `version` on update; leaves it at the schema
  default (1) on insert. Broadcasts `{:artifact_updated, artifact}` on
  `"artifact:<artifact_id>"`, and `{:artifact_saved, artifact}` on
  `"session:<session_id>"` when `attrs` has a `session_id`, after a
  successful save.
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

  Preserves the reserved `"_user_state"` key (user-ticked checkbox/input
  state — see `merge_user_state/2`) when `data` doesn't mention it, so an
  agent's routine `update_artifact_data` calls don't silently wipe out
  whatever the user has persisted. Passing `"_user_state"` explicitly (e.g.
  `%{"_user_state" => %{}}` to reset it) always wins — there's no dedicated
  reset tool, this is that path.
  """
  def update_artifact_data(%Artifact{} = artifact, data) when is_map(data) do
    artifact
    |> Artifact.changeset(%{data: preserve_user_state(artifact, data)})
    |> Repo.update()
    |> broadcast_data_update()
  end

  defp preserve_user_state(artifact, data) do
    if Map.has_key?(data, "_user_state") do
      data
    else
      case Map.get(artifact.data || %{}, "_user_state") do
        nil -> data
        user_state -> Map.put(data, "_user_state", user_state)
      end
    end
  end

  @doc """
  Atomically shallow-merges `patch` (a flat map) into an artifact's
  `data["_user_state"]` — the reserved key user-state persistence lives at
  (e.g. checkbox ticks in an agent-authored HTML artifact, written through
  via `orca.setState`/`[data-orca-persist]`). Done in ONE `UPDATE` statement
  (`jsonb_set`/`||` in Postgres, not a Repo.get→merge→Repo.update round
  trip) so two viewers ticking different boxes at nearly the same moment
  can't clobber each other.

  A `nil` value in `patch` deletes that key (via `jsonb_strip_nulls`, which
  only strips at the top level of `_user_state` — it can't reach into
  `data`'s other keys or into nested values, since patch is documented as
  flat).

  Does NOT bump `version` (same rationale as `update_artifact_data/2`) and
  reuses `{:artifact_data_updated, artifact}` on `"artifact:<artifact_id>"`
  — no new message type, no reload, just a `postMessage` to any open
  viewer.

  State is shared per artifact, not per user — there's no users table (auth
  is Authelia at the ingress), so every open viewer of the same artifact
  reads/writes the same `_user_state`. Renaming an artifact (a different
  `(project_id, name)` row) loses it. Stale keys left behind when an agent
  drops a checklist item are harmless clutter, not bugs.
  """
  def merge_user_state(%Artifact{id: id}, patch), do: merge_user_state(id, patch)

  def merge_user_state(id, patch) when is_binary(id) and is_map(patch) do
    query =
      from a in Artifact,
        where: a.id == ^id,
        update: [
          set: [
            data:
              fragment(
                """
                jsonb_set(
                  coalesce(?, '{}'::jsonb),
                  '{_user_state}',
                  jsonb_strip_nulls(coalesce(? -> '_user_state', '{}'::jsonb) || ?),
                  true
                )
                """,
                a.data,
                a.data,
                type(^patch, :map)
              )
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} ->
        case get_artifact(id) do
          nil -> {:error, :not_found}
          artifact -> broadcast_data_update({:ok, artifact})
        end

      {0, _} ->
        {:error, :not_found}
    end
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

    if artifact.session_id do
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{artifact.session_id}",
        {:artifact_saved, artifact}
      )
    end

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
