defmodule OrcaHubWeb.SessionApiController do
  @moduledoc """
  Read-only session listing/lookup for external HTTP clients (docs/api.md) —
  first consumer is a Wear OS watch companion app. Sits behind the same
  `:api_authed` pipeline (static bearer token) as the Agent Runs API; no new
  auth mechanism.

  Deliberately thin: all querying is done by `OrcaHub.Sessions.list_sessions/1`
  and `OrcaHub.HubRPC.get_session/1` — this module only projects the result
  down to the compact fields a battery/bandwidth-constrained client needs
  (see `render_session/1`), it never reimplements the query itself.
  """

  use OrcaHubWeb, :controller

  alias OrcaHub.HubRPC

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions
  # ---------------------------------------------------------------------

  # list_sessions/1's `:all` filter is the base query (non-archived, and a
  # nil-or-non-deleted project) — status/project_id are applied here rather
  # than added as new filter atoms on that shared context function, since
  # they're specific to this compact projection, not a general session-list
  # concern.
  def index(conn, params) do
    sessions =
      HubRPC.list_sessions(:all)
      |> filter_by_status(params["status"])
      |> filter_by_project_id(params["project_id"])
      |> Enum.map(&render_session/1)

    json(conn, %{sessions: sessions})
  end

  defp filter_by_status(sessions, nil), do: sessions
  defp filter_by_status(sessions, ""), do: sessions

  defp filter_by_status(sessions, status),
    do: Enum.filter(sessions, &(&1.status == status))

  defp filter_by_project_id(sessions, nil), do: sessions
  defp filter_by_project_id(sessions, ""), do: sessions

  defp filter_by_project_id(sessions, project_id),
    do: Enum.filter(sessions, &(&1.project_id == project_id))

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions/:id
  # ---------------------------------------------------------------------

  # Same posture as ApiRunController.show/2: a malformed id and a
  # well-formed-but-nonexistent id both just mean "no such session" — never
  # let a bad UUID reach Ecto and surface as a raw CastError (see CLAUDE.md's
  # "Common issues" — this failure mode has bitten the codebase before).
  def show(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      :error -> not_found(conn)
      {:ok, _} -> do_show(conn, id)
    end
  end

  defp do_show(conn, id) do
    case HubRPC.get_session(id) do
      nil -> not_found(conn)
      session -> json(conn, render_session(session))
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "session not found"})

  # ---------------------------------------------------------------------
  # Response shaping — compact projection, not the full session struct
  # ---------------------------------------------------------------------

  defp render_session(session) do
    %{
      id: session.id,
      status: session.status,
      title: session.title,
      progress_phase: session.progress_phase,
      progress_note: session.progress_note,
      last_activity_at: iso8601(session.updated_at),
      directory: session.directory,
      project_id: session.project_id,
      project_name: session.project && session.project.name
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
