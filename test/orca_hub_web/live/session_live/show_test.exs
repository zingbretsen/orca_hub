defmodule OrcaHubWeb.SessionLive.ShowTest do
  @moduledoc """
  Capability-gated chrome coverage (backend_abstraction_spec.md §7/§9,
  Phase 3): the usage nav link, plan-mode badges/review card, and the
  AskUserQuestion modal are present for a Claude session and absent for a
  Codex one; the model switcher only offers the session's own backend's
  models.

  Sessions here are freshly created (no message history), so `SessionRunner`
  boots straight into `:ready` and never opens a port for a page visit alone
  (see `session_runner.ex` init/1) — no real `claude`/`codex` executable or
  stub is needed to render the show page.
  """

  # async: false — `ensure_runner_started/3` starts a real SessionRunner
  # (GenStatem) child under the shared OrcaHub.SessionSupervisor, which needs
  # the DB sandbox in SHARED mode to read the session back in init/1 (see
  # index_test.exs / codex_stub_integration_test.exs for the same pattern).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{SessionSupervisor, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "show_caps_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, claude_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        code_exec: false,
        orchestrator: false
      })

    {:ok, codex_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "codex",
        code_exec: false,
        orchestrator: false
      })

    on_exit(fn ->
      Enum.each([claude_session.id, codex_session.id], fn id ->
        if SessionSupervisor.session_alive?(id), do: SessionSupervisor.stop_session(id)
      end)
    end)

    {:ok, claude_session: claude_session, codex_session: codex_session}
  end

  describe "usage nav link" do
    test "present for a Claude session", %{conn: conn, claude_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ ~s(href="/usage")
    end

    test "absent for a Codex session (capabilities.usage == false)", %{
      conn: conn,
      codex_session: session
    } do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ ~s(href="/usage")
    end
  end

  describe "backend badge" do
    test "not shown for Claude (kept subtle — no visual churn for the default backend)", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ "Agent backend"
    end

    test "shown for Codex", %{conn: conn, codex_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "Agent backend"
      assert html =~ "Codex"
    end
  end

  describe "model switcher — scoped per backend" do
    test "Claude session offers only Claude models", %{conn: conn, claude_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "Opus 4.8"
      assert html =~ "Sonnet 4.6"
      assert html =~ "Haiku 4.5"
      refute html =~ "GPT-5"
    end

    test "Codex session offers only Codex models", %{conn: conn, codex_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "GPT-5 Codex"
      refute html =~ "Opus 4.8"
      refute html =~ "Sonnet 4.6"
      refute html =~ "Haiku 4.5"
    end

    test "both backends still offer free-text custom model entry", %{
      conn: conn,
      claude_session: claude_session,
      codex_session: codex_session
    } do
      {:ok, _view, claude_html} = live(conn, ~p"/sessions/#{claude_session.id}")
      {:ok, _view, codex_html} = live(conn, ~p"/sessions/#{codex_session.id}")

      assert claude_html =~ "passthrough model id"
      assert codex_html =~ "passthrough model id"
    end
  end

  describe "MCP toggles — present for both (mcp: true for Claude and Codex)" do
    test "orchestrator toggle button shown for Claude", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_orchestrator']")
    end

    test "orchestrator toggle button shown for Codex", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_orchestrator']")
    end

    test "MCP servers modal button shown for Claude", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_mcp_modal']")
    end

    test "MCP servers modal button shown for Codex", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_mcp_modal']")
    end
  end

  describe "AskUserQuestion modal — never initiates for a backend without the capability" do
    test "capabilities assign reflects ask_user_question: false for Codex", %{
      conn: conn,
      codex_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert view.module == OrcaHubWeb.SessionLive.Show
      refute :sys.get_state(view.pid).socket.assigns.capabilities.ask_user_question
    end

    test "capabilities assign reflects ask_user_question: true for Claude", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.ask_user_question
    end
  end

  describe "plan mode — capability assign" do
    test "Claude session has plan_mode: true", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode
    end

    test "Codex session has plan_mode: false", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode
    end
  end
end
