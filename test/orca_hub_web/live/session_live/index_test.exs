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

  test "new-session form scopes the model datalist to the selected backend", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Defaults to Claude's model list before any backend selection.
    assert html =~ "Opus 4.8"
    refute html =~ "GPT-5"

    html =
      view
      |> form("form", session: %{"backend" => "codex"})
      |> render_change()

    assert html =~ "GPT-5 Codex"
    refute html =~ "Opus 4.8"
  end

  test "new-session form shows the orchestrator (MCP-dependent) toggle for both backends", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Claude (default): mcp: true -> shown.
    assert html =~ "Orchestrator mode"

    # Codex: also mcp: true -> still shown (spec §7's mcp: false gating is
    # wiring for a future backend like pi; both current backends show it).
    html =
      view
      |> form("form", session: %{"backend" => "codex"})
      |> render_change()

    assert html =~ "Orchestrator mode"
  end
end
