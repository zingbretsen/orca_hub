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

  alias OrcaHub.{ClusterNodes, Projects, Sessions}

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
      |> form("form[phx-submit=save]",
        session: %{"directory" => project.directory, "project_id" => project.id}
      )
      |> render_submit()
      |> follow_redirect(conn)

    session =
      OrcaHub.Sessions.list_sessions(:all)
      |> Enum.find(&(&1.directory == project.directory))

    assert session
    assert session.backend == "claude"
  end

  test "new-session form preselects the target node's configured backend/model default", %{
    conn: conn
  } do
    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "this-node")

    {:ok, _} =
      ClusterNodes.update_node(n, %{default_backend: "claude", default_model: "claude-sonnet-5-5"})

    {:ok, _view, html} = live(conn, ~p"/sessions/new")

    assert html =~ ~s(value="claude-sonnet-5-5")
  end

  test "new-session form scopes the model datalist to the selected backend", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sessions/new")

    # Defaults to Claude's model list before any backend selection.
    assert html =~ "Opus 5.5"
    refute html =~ "GPT-5"

    html =
      view
      |> form("form[phx-submit=save]", session: %{"backend" => "codex"})
      |> render_change()

    assert html =~ "GPT-5.6 Sol"
    refute html =~ "Opus 5.5"
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
      |> form("form[phx-submit=save]", session: %{"backend" => "codex"})
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
      |> form("form[phx-submit=save]", session: %{"backend" => "pi"})
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
      |> form("form[phx-submit=save]", session: %{"backend" => "pi"})
      |> render_change()

    assert html =~ "glm-5p2 (fireworks)"
    refute html =~ "Opus 5.5"
    refute html =~ "GPT-5.6 Sol"
  end

  # ORCAHUB3-60: `/sessions` marks a session that is blocked on an unanswered
  # question, so a human can spot a stalled worker without opening it. A pi
  # dialog carries its question text in the tooltip. A Claude AskUserQuestion
  # carries a hint on how it is answered (a normal message, not the dialog
  # path).
  describe "pending-question indicator" do
    setup do
      dir = Path.join(System.tmp_dir!(), "orca-idx-pq-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, project} = Projects.create_project(%{name: "Pending Questions", directory: dir})

      %{dir: dir, project: project}
    end

    defp pq_session(%{dir: dir, project: project}, attrs) do
      {:ok, session} =
        Sessions.create_session(Map.merge(%{directory: dir, project_id: project.id}, attrs))

      session
    end

    defp open_dialog(session, title) do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "pi_ui_request",
            "id" => "dlg-1",
            "method" => "input",
            "title" => title
          }
        })
    end

    defp indicator(session), do: "#pending-question-#{session.id}"

    test "marks a pi session blocked on a dialog, with the question in the tooltip", ctx do
      pi = pq_session(ctx, %{title: "Pi Worker", backend: "pi", status: "waiting"})
      open_dialog(pi, "Proceed with the migration?")
      busy = pq_session(ctx, %{title: "Busy Worker", backend: "pi", status: "running"})

      {:ok, view, _html} = live(ctx.conn, ~p"/sessions")

      assert has_element?(view, indicator(pi))
      assert render(element(view, indicator(pi))) =~ "Proceed with the migration?"
      refute has_element?(view, indicator(busy))
    end

    test "marks a claude session waiting on an AskUserQuestion, saying how it is answered",
         ctx do
      claude = pq_session(ctx, %{title: "Claude Worker", backend: "claude", status: "waiting"})

      {:ok, view, _html} = live(ctx.conn, ~p"/sessions")

      assert has_element?(view, indicator(claude))
      assert render(element(view, indicator(claude))) =~ "AskUserQuestion"
    end

    test "appears when a running pi session blocks on a dialog, and clears when it resolves",
         ctx do
      pi = pq_session(ctx, %{title: "Pi Worker", backend: "pi", status: "running"})

      {:ok, view, _html} = live(ctx.conn, ~p"/sessions")
      refute has_element?(view, indicator(pi))

      # What SessionRunner does when the dialog opens: persist the request,
      # then the "waiting" status, then broadcast it on the aggregate topic.
      open_dialog(pi, "Which branch?")
      {:ok, pi} = Sessions.update_session(pi, %{status: "waiting"})
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {pi.id, {:status, :waiting}})

      assert render(element(view, indicator(pi))) =~ "Which branch?"

      {:ok, _} =
        Sessions.create_message(%{
          session_id: pi.id,
          data: %{"type" => "pi_ui_response", "id" => "dlg-1", "answer" => %{"value" => "main"}}
        })

      {:ok, pi} = Sessions.update_session(pi, %{status: "running"})
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {pi.id, {:status, :running}})

      render(view)
      refute has_element?(view, indicator(pi))
    end
  end
end
