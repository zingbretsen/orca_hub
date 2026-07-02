defmodule OrcaHubWeb.SessionLive.IndexTest do
  @moduledoc """
  Minimal Phase 1 coverage (backend_abstraction_spec.md §7/§9): the backend
  picker is invisible with only one backend registered
  (`OrcaHub.Backend.available/0` returns a single entry), so this just
  asserts the new-session form still creates a session and that it defaults
  to backend "claude".
  """

  # async: false — "save" starts a real SessionRunner (GenStatem) child under
  # the shared OrcaHub.SessionSupervisor; that process needs the DB sandbox
  # in shared mode to read the session back in init/1, not per-test :manual
  # ownership (see Ecto.Adapters.SQL.Sandbox docs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  test "new-session form creates a session with backend \"claude\"", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(%{name: "Phase 1 Project", directory: "/tmp/backend-phase-1"})

    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Single-backend Phase 1: no visible backend picker.
    refute html =~ "Backend"

    {:ok, _view, _html} =
      view
      |> form("form", session: %{"directory" => project.directory, "project_id" => project.id})
      |> render_submit()
      |> follow_redirect(conn)

    session =
      OrcaHub.Sessions.list_sessions(:all)
      |> Enum.find(&(&1.directory == project.directory))

    assert session
    assert session.backend == "claude"
  end
end
