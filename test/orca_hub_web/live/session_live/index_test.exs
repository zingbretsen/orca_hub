defmodule OrcaHubWeb.SessionLive.IndexTest do
  @moduledoc """
  Backend picker coverage (backend_abstraction_spec.md §7/§9/§12.2/§12.5). The
  new-session form's `<select>` (index.html.heex ~292) is conditionally
  rendered off `OrcaHub.Backend.available/0`'s length — Phase 1 (Claude only)
  kept it hidden; Phase 2 registers Codex, so `available/0` now returns
  multiple entries and the picker becomes visible automatically (no template
  change needed); the pi adapter adds a third entry. As of the orca-mcp
  bridge (§12.5), all three backends are `mcp: true`, so the orchestrator
  toggle shows for all three. Asserts: the picker is shown, the default
  submit (no explicit backend selection) still creates a "claude" session,
  and the model list / orchestrator toggle scope correctly per backend.
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

    # Three backends registered (Claude + Codex + pi) — the picker is visible.
    assert html =~ "Backend"
    assert html =~ "Codex"
    assert html =~ "Pi"

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

  test "new-session form shows the orchestrator (MCP-dependent) toggle for mcp:true backends", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Claude (default): mcp: true -> shown.
    assert html =~ "Orchestrator mode"

    # Codex: also mcp: true -> still shown.
    html =
      view
      |> form("form", session: %{"backend" => "codex"})
      |> render_change()

    assert html =~ "Orchestrator mode"
  end

  # orca-mcp bridge (spec §12.5): priv/pi/orca-mcp.ts registers orca's MCP
  # tools via pi.registerTool, so pi flipped to mcp: true — no longer the
  # outlier that hid this toggle.
  test "new-session form shows the orchestrator toggle for pi (mcp: true, orca-mcp bridge)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/sessions/new")

    html =
      view
      |> form("form", session: %{"backend" => "pi"})
      |> render_change()

    assert html =~ "Orchestrator mode"
  end

  test "new-session form scopes the model datalist to pi's live catalog when selected", %{
    conn: conn
  } do
    stub = Path.expand("../../../support/fixtures/pi_stub_list_models.sh", __DIR__)
    previous = Application.get_env(:orca_hub, :pi_executable)
    Application.put_env(:orca_hub, :pi_executable, stub)
    OrcaHub.Backend.Cache.clear()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:orca_hub, :pi_executable, previous),
        else: Application.delete_env(:orca_hub, :pi_executable)

      OrcaHub.Backend.Cache.clear()
    end)

    {:ok, view, _html} = live(conn, ~p"/sessions/new")

    html =
      view
      |> form("form", session: %{"backend" => "pi"})
      |> render_change()

    assert html =~ "glm-5p2 (fireworks)"
    refute html =~ "Opus 4.8"
    refute html =~ "GPT-5 Codex"
  end
end
