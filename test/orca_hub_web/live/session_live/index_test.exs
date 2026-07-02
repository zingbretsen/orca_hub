defmodule OrcaHubWeb.SessionLive.IndexTest do
  @moduledoc """
  Backend picker coverage (backend_abstraction_spec.md §7/§9). The
  new-session form's `<select>` (index.html.heex ~292) is conditionally
  rendered off `OrcaHub.Backend.available/0`'s length — Phase 1 (Claude only)
  kept it hidden; Phase 2 registers Codex, so `available/0` now returns two
  entries and the picker becomes visible automatically (no template change
  needed). Asserts both: the picker is now shown, AND the default submit
  (no explicit backend selection) still creates a "claude" session.
  """

  # async: false — "save" starts a real SessionRunner (GenStatem) child under
  # the shared OrcaHub.SessionSupervisor; that process needs the DB sandbox
  # in shared mode to read the session back in init/1, not per-test :manual
  # ownership (see Ecto.Adapters.SQL.Sandbox docs).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Projects

  test "new-session form shows the backend picker and defaults to \"claude\"", %{conn: conn} do
    {:ok, project} =
      Projects.create_project(%{name: "Phase 2 Project", directory: "/tmp/backend-phase-2"})

    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Two backends registered (Claude + Codex) — the picker is now visible.
    assert html =~ "Backend"
    assert html =~ "Codex"

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
