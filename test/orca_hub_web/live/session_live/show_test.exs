defmodule OrcaHubWeb.SessionLive.ShowTest do
  @moduledoc """
  Capability-gated chrome coverage (backend_abstraction_spec.md §7/§9,
  Phase 3 + pi §12.2/§12.5): the usage nav link, plan-mode badges/review
  card, and the AskUserQuestion modal are present for a Claude session and
  absent for a Codex/pi one; the MCP toggles (orchestrator + servers modal)
  are present for all three backends (`mcp: true`, as of the orca-mcp bridge
  §12.5 — pi is no longer the `mcp: false` outlier); the model switcher only
  offers the session's own backend's models.

  Sessions here are freshly created (no message history), so `SessionRunner`
  boots straight into `:ready` and never opens a port for a page visit alone
  (see `session_runner.ex` init/1) — no real `claude`/`codex`/`pi` executable
  or stub is needed to render the show page.
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

    # runner_node stamped explicitly, matching every real session-creation
    # path (session_live/index.ex, project_live/show.ex, etc.) — a bare nil
    # runner_node is only ever transient (pre-first-run) or legacy/archived
    # data in production, never how these fixtures are meant to represent a
    # normal, locally-runnable session.
    {:ok, claude_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        code_exec: false,
        orchestrator: false,
        runner_node: Atom.to_string(node())
      })

    {:ok, codex_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "codex",
        code_exec: false,
        orchestrator: false,
        runner_node: Atom.to_string(node())
      })

    {:ok, pi_session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "pi",
        code_exec: false,
        orchestrator: false,
        runner_node: Atom.to_string(node())
      })

    on_exit(fn ->
      Enum.each([claude_session.id, codex_session.id, pi_session.id], fn id ->
        if SessionSupervisor.session_alive?(id), do: SessionSupervisor.stop_session(id)
      end)
    end)

    {:ok, claude_session: claude_session, codex_session: codex_session, pi_session: pi_session}
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

    test "absent for a pi session (capabilities.usage == false)", %{
      conn: conn,
      pi_session: session
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

    test "shown for pi", %{conn: conn, pi_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "Agent backend"
      assert html =~ "Pi"
    end
  end

  describe "progress badge (report_progress)" do
    test "absent when no progress has been reported", %{conn: conn, claude_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ "badge-outline"
    end

    test "shown with the reported phase as a tooltip-bearing badge", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, _} =
        Sessions.update_session(session, %{
          progress_phase: "implementing",
          progress_note: "writing the migration"
        })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "badge-outline"
      assert html =~ "implementing"
      assert html =~ "writing the migration"
    end

    test "updates live when a {:progress, ...} PubSub event arrives", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute render(view) =~ "badge-outline"

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:progress, "validating", "running the suite"}
      )

      html = render(view)
      assert html =~ "badge-outline"
      assert html =~ "validating"
    end
  end

  describe "model switcher — scoped per backend" do
    test "Claude session offers only Claude models", %{conn: conn, claude_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "Fable 5"
      assert html =~ "Opus 4.8"
      assert html =~ "Sonnet 5"
      assert html =~ "Haiku 4.5"
      refute html =~ "GPT-5"
    end

    test "Codex session offers only Codex models", %{conn: conn, codex_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "GPT-5.6 Sol"
      refute html =~ "Opus 4.8"
      refute html =~ "Fable 5"
      refute html =~ "Haiku 4.5"
    end

    test "pi session offers the LIVE `pi --list-models` catalog, not other backends' models", %{
      conn: conn,
      pi_session: session
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

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "glm-5p2 (fireworks)"
      assert html =~ "kimi-k2p6 (fireworks)"
      refute html =~ "Opus 4.8"
      refute html =~ "GPT-5.6 Sol"
    end

    test "all three backends still offer free-text custom model entry", %{
      conn: conn,
      claude_session: claude_session,
      codex_session: codex_session,
      pi_session: pi_session
    } do
      {:ok, _view, claude_html} = live(conn, ~p"/sessions/#{claude_session.id}")
      {:ok, _view, codex_html} = live(conn, ~p"/sessions/#{codex_session.id}")
      {:ok, _view, pi_html} = live(conn, ~p"/sessions/#{pi_session.id}")

      assert claude_html =~ "passthrough model id"
      assert codex_html =~ "passthrough model id"
      assert pi_html =~ "passthrough model id"
    end
  end

  describe "MCP toggles — present for all three (mcp: true for Claude, Codex, and pi)" do
    test "orchestrator toggle button shown for Claude", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_orchestrator']")
    end

    test "orchestrator toggle button shown for Codex", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, "button[phx-click='toggle_orchestrator']")
    end

    # orca-mcp bridge (spec §12.5): priv/pi/orca-mcp.ts registers orca's MCP
    # tools via pi.registerTool, so pi is no longer the mcp: false outlier —
    # the orchestrator/code_exec toggles and MCP-servers modal (gated purely
    # on @capabilities.mcp in show.html.heex, no pi-specific markup) show for
    # pi exactly like Claude/Codex.
    test "orchestrator toggle button shown for pi", %{conn: conn, pi_session: session} do
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

    test "MCP servers modal button shown for pi", %{conn: conn, pi_session: session} do
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

    test "capabilities assign reflects ask_user_question: true for pi ('pi backend groundwork' — pi's own question tool + extension-UI reply loop)",
         %{
           conn: conn,
           pi_session: session
         } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.ask_user_question
    end
  end

  describe "session_stats capability — pi-only, distinct from usage" do
    test "Claude session has session_stats: false", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.capabilities.session_stats
    end

    test "Codex session has session_stats: false", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.capabilities.session_stats
    end

    test "pi session has session_stats: true", %{conn: conn, pi_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.session_stats
    end
  end

  # spec §12.8 — header context-window meter + "Compact now". Both are gated
  # on @capabilities.session_stats && @context_percent (the meter's presence
  # covers the compact button too — it lives in the meter's own dropdown).
  # A seeded pi_session_stats message pushes the runner past :ready into
  # :idle (list_messages != []), same as any other pre-seeded history.
  describe "context meter — session_stats capability (spec §12.8)" do
    defp seed_pi_session_stats(session_id, percent) do
      {:ok, _msg} =
        Sessions.create_message(%{
          session_id: session_id,
          data: %{
            "type" => "pi_session_stats",
            "tokens" => %{"total" => 200},
            "cost" => 0.001,
            "context_usage" => %{
              "tokens" => 200,
              "contextWindow" => 128_000,
              "percent" => percent
            }
          }
        })
    end

    test "renders the meter (with its % text) once a pi_session_stats message is in history", %{
      conn: conn,
      pi_session: session
    } do
      seed_pi_session_stats(session.id, 42.3)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      # "Context window:" is the header meter's own title text — a distinct
      # marker from MessageComponents' pre-existing, backend-agnostic inline
      # feed line ("42.3% context", no "window"), which ALSO renders for this
      # same seeded message regardless of capability gating (spec §12.3) —
      # asserting on the bare "42.3%" substring would pass for either.
      assert html =~ "Context window:"
      assert html =~ "42.3%"
      assert :sys.get_state(view.pid).socket.assigns.context_percent == 42.3
    end

    test "hidden (nil) for a pi session with no session-stats history yet", %{
      conn: conn,
      pi_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert is_nil(:sys.get_state(view.pid).socket.assigns.context_percent)
    end

    test "hidden for Claude (session_stats: false) even with the same message seeded", %{
      conn: conn,
      claude_session: session
    } do
      seed_pi_session_stats(session.id, 42.3)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      # The @context_percent assign is set regardless of backend (reconstructed
      # purely from message history) — only the header meter's RENDERING is
      # capability-gated. The bare "42.3%" text still appears via the
      # pre-existing backend-agnostic inline feed line (spec §12.3), so assert
      # on the meter's own distinguishing marker instead.
      refute html =~ "Context window:"
      assert :sys.get_state(view.pid).socket.assigns.context_percent == 42.3
    end

    test "the compact_session button follows the meter's own presence (absent for Claude)", %{
      conn: conn,
      claude_session: session
    } do
      seed_pi_session_stats(session.id, 42.3)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ "compact_session"
    end

    test "the compact_session button is present for pi once stats have arrived", %{
      conn: conn,
      pi_session: session
    } do
      seed_pi_session_stats(session.id, 10)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "compact_session"
      assert has_element?(view, "button[phx-click='compact_session']")
    end

    test "color threshold: >=85% renders the error progress class", %{
      conn: conn,
      pi_session: session
    } do
      seed_pi_session_stats(session.id, 90)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "progress-error"
    end

    test "color threshold: >=60% and <85% renders the warning progress class", %{
      conn: conn,
      pi_session: session
    } do
      seed_pi_session_stats(session.id, 70)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")
      assert html =~ "progress-warning"
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

    test "pi session has plan_mode: true (spec §12.4 — orca-plan.ts extension)", %{
      conn: conn,
      pi_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode
    end
  end

  describe "plan_mode_toggle capability — pi-only user-facing toggle (spec §12.4)" do
    test "Claude session has plan_mode_toggle: false (model-initiated, no user toggle)", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode_toggle
    end

    test "Codex session has plan_mode_toggle: false", %{conn: conn, codex_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode_toggle
    end

    test "pi session has plan_mode_toggle: true", %{conn: conn, pi_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode_toggle
    end

    test "the header toggle button renders only for pi", %{
      conn: conn,
      claude_session: claude_session,
      pi_session: pi_session
    } do
      {:ok, _view, claude_html} = live(conn, ~p"/sessions/#{claude_session.id}")
      refute claude_html =~ "toggle_plan_mode"

      {:ok, _view, pi_html} = live(conn, ~p"/sessions/#{pi_session.id}")
      assert pi_html =~ "toggle_plan_mode"
    end
  end

  describe "abandoned-session cleanup (delayed, viewer-guarded)" do
    alias OrcaHubWeb.SessionLive.Show

    test "archives an unviewed, empty, unarchived session", %{claude_session: session} do
      assert Show.abandoned_cleanup(session.id, node()) == :archived
      refute is_nil(Sessions.get_session!(session.id).archived_at)
    end

    test "keeps a session someone is still viewing", %{claude_session: session} do
      {:ok, _} = Registry.register(OrcaHub.SessionViewersRegistry, session.id, %{})

      assert Show.abandoned_cleanup(session.id, node()) == :kept
      assert is_nil(Sessions.get_session!(session.id).archived_at)
    end

    test "keeps a session that has messages", %{claude_session: session} do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{"type" => "user", "message" => %{"role" => "user", "content" => "hi"}}
        })

      assert Show.abandoned_cleanup(session.id, node()) == :kept
      assert is_nil(Sessions.get_session!(session.id).archived_at)
    end
  end

  describe "Cluster.send_message runner restart" do
    test "returns {:error, {:not_started, _}} instead of crashing when the runner can't start" do
      # A directory whose parent is a regular file makes runner init's
      # mkdir_p fail — the pre-fix behavior was a GenError :noproc crash
      # from send_message after the silent start failure.
      file = Path.join(System.tmp_dir!(), "not_a_dir_#{System.unique_integer([:positive])}")
      File.write!(file, "")
      on_exit(fn -> File.rm(file) end)

      {:ok, session} = Sessions.create_session(%{directory: Path.join(file, "sub")})

      assert {:error, {:not_started, %File.Error{}}} =
               OrcaHub.Cluster.send_message(node(), session.id, "hello")
    end
  end

  # Regression for the real incident: a session's runner_node pointed at an
  # offline agent; mounting /sessions/:id on a different node used to fall
  # back to `node()` and silently start (and crash) a local SessionRunner
  # for a directory that doesn't exist on this node. Mount must now treat
  # the assigned node as unavailable and never touch SessionSupervisor
  # locally for it.
  describe "mount with an offline/unassigned runner_node (incident regression)" do
    test "session assigned to a node not in the cluster: no local runner started, no crash", %{
      conn: conn
    } do
      dir = Path.join(System.tmp_dir!(), "offline_node_#{System.unique_integer([:positive])}")

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: "debian@totally-offline-host"
        })

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute SessionSupervisor.session_alive?(session.id)
      assert html =~ "not currently connected"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.node_unavailable == {:node_unavailable, :"debian@totally-offline-host"}
      assert assigns.session_node == :"debian@totally-offline-host"
    end

    test "session with nil runner_node (legacy/unassigned): treated as unassigned, no local start",
         %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "unassigned_node_#{System.unique_integer([:positive])}")

      {:ok, session} = Sessions.create_session(%{directory: dir, backend: "claude"})
      {:ok, session} = Sessions.update_session(session, %{runner_node: nil})

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute SessionSupervisor.session_alive?(session.id)
      assert html =~ "no assigned node"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.node_unavailable == :node_unassigned
      assert assigns.session_node == nil
    end

    test "session assigned to the local node still starts a runner as before", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "local_node_#{System.unique_integer([:positive])}")

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(session.id),
          do: SessionSupervisor.stop_session(session.id)
      end)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert SessionSupervisor.session_alive?(session.id)
      refute html =~ "not currently connected"

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.node_unavailable == nil
    end
  end

  describe "in-session backend switcher" do
    test "dropdown lists every registered backend", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for {value, _label} <- OrcaHub.Backend.available() do
        assert has_element?(view, "button[phx-click='set_backend'][phx-value-backend='#{value}']")
      end
    end

    test "switching persists the backend and drops the native resume id + model", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, _} =
        Sessions.update_session(session, %{claude_session_id: "native-abc", model: "opus"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("button[phx-click='set_backend'][phx-value-backend='codex']")
      |> render_click()

      updated = Sessions.get_session!(session.id)
      assert updated.backend == "codex"
      assert updated.claude_session_id == nil
      assert updated.model == nil
    end

    test "switching re-derives capabilities and re-scopes the model picker", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode

      html =
        view
        |> element("button[phx-click='set_backend'][phx-value-backend='codex']")
        |> render_click()

      refute :sys.get_state(view.pid).socket.assigns.capabilities.plan_mode
      assert html =~ "GPT-5.6 Sol"
      refute html =~ "Opus 4.8"
    end

    test "selecting the current backend is a no-op", %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view
      |> element("button[phx-click='set_backend'][phx-value-backend='claude']")
      |> render_click()

      assert Sessions.get_session!(session.id).backend == "claude"
    end
  end

  describe "Conversation/Tree view toggle" do
    test "defaults to conversation view, with both toggle options rendered", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "Conversation"
      assert html =~ "Tree"
      assert has_element?(view, "#message-feed")
      refute has_element?(view, "#session-tree-root")
    end

    test "?view=tree patches to the tree view without discarding conversation state", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "user",
            "message" => %{
              "role" => "user",
              "content" => [%{"type" => "text", "text" => "hello there"}]
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_patch(view, ~p"/sessions/#{session.id}?view=tree")

      refute has_element?(view, "#message-feed")
      assert has_element?(view, "#session-tree-root")
      assert has_element?(view, "#session-node-#{session.id}")

      # Conversation state (the seeded message) was never dropped from
      # @messages — switching back renders it immediately, no refetch.
      html = render_patch(view, ~p"/sessions/#{session.id}?view=conversation")
      assert html =~ "hello there"
    end
  end

  describe "Tree view — membership and highlighting" do
    setup %{claude_session: root} do
      dir = Path.join(System.tmp_dir!(), "tree_view_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, child} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Child Worker"
        })

      {:ok, archived_grandchild} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: child.id,
          title: "Archived Grandchild"
        })

      {:ok, archived_grandchild} = Sessions.archive_session(archived_grandchild)

      on_exit(fn ->
        Enum.each([child.id, archived_grandchild.id], fn id ->
          if SessionSupervisor.session_alive?(id), do: SessionSupervisor.stop_session(id)
        end)
      end)

      %{child: child, archived_grandchild: archived_grandchild}
    end

    test "shows the whole tree — ancestors and descendants, archived included — with the current node highlighted",
         %{conn: conn, claude_session: root, child: child, archived_grandchild: archived} do
      {:ok, view, html} = live(conn, ~p"/sessions/#{child.id}?view=tree")

      assert html =~ (root.title || root.directory)
      assert html =~ child.title
      assert html =~ archived.title

      # Nested structurally: grandchild under child under root.
      assert has_element?(
               view,
               "#session-node-#{root.id} #session-node-#{child.id} #session-node-#{archived.id}"
             )

      # Only the session the page was mounted for is marked "you are here".
      assert has_element?(view, "#session-node-#{child.id}.outline-primary")
      refute has_element?(view, "#session-node-#{root.id}.outline-primary")
    end

    test "a lone session with no parent and no children renders as a single node, no crash", %{
      conn: conn,
      claude_session: root,
      child: child
    } do
      # `child` has its own child (archived_grandchild) but `root`'s OTHER
      # child, if it had none, would be the trivial case — use a brand new
      # unrelated session instead so this test is truly parent-and-child-free.
      {:ok, lone} =
        Sessions.create_session(%{
          directory: root.directory,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      {:ok, view, html} = live(conn, ~p"/sessions/#{lone.id}?view=tree")

      assert html =~ (lone.title || lone.directory)
      assert has_element?(view, "#session-node-#{lone.id}")
      refute has_element?(view, "#session-node-#{child.id}")
    end

    test "subagent invocations are fetched lazily on first toggle", %{
      conn: conn,
      claude_session: root,
      archived_grandchild: leaf
    } do
      # A leaf (no descendants of its own) — otherwise the CSS descendant
      # selector below would also match a nested child's own "Subagents"
      # summary, since it lives inside this node's DOM subtree too.
      {:ok, _} =
        Sessions.create_message(%{
          session_id: leaf.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_show_tree_1",
                  "name" => "Agent",
                  "input" => %{"subagent_type" => "explore", "description" => "Find the bug"}
                }
              ]
            }
          }
        })

      {:ok, view, html} = live(conn, ~p"/sessions/#{root.id}?view=tree")
      refute html =~ "Find the bug"

      html =
        view
        |> element("#session-node-#{leaf.id} summary", "Subagents")
        |> render_click()

      assert html =~ "explore"
      assert html =~ "Find the bug"
    end
  end

  describe "Tree view — message-edge chips" do
    test "renders chips from seeded session_interactions, with a count for repeats", %{
      conn: conn,
      claude_session: root
    } do
      dir = Path.join(System.tmp_dir!(), "tree_edges_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, sibling} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Sibling Worker"
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(sibling.id),
          do: SessionSupervisor.stop_session(sibling.id)
      end)

      {:ok, _} =
        Sessions.create_session_interaction(%{
          sender_session_id: root.id,
          recipient_session_id: sibling.id
        })

      {:ok, _} =
        Sessions.create_session_interaction(%{
          sender_session_id: root.id,
          recipient_session_id: sibling.id
        })

      {:ok, view, html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      assert html =~ "×2"
      assert has_element?(view, "#session-node-#{root.id} button", sibling.title)
      assert has_element?(view, "#session-node-#{sibling.id} button", root.title)
    end
  end

  describe "Tree view — compose (message a session from its tree node)" do
    setup %{claude_session: root} do
      dir = Path.join(System.tmp_dir!(), "tree_compose_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Target Child"
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(target.id),
          do: SessionSupervisor.stop_session(target.id)
      end)

      %{target: target}
    end

    defp user_message_texts(session_id) do
      session_id
      |> Sessions.list_messages()
      |> Enum.filter(&(&1.data["type"] == "user"))
      |> Enum.map(fn m ->
        m.data |> get_in(["message", "content"]) |> List.first() |> Map.get("text")
      end)
    end

    test "direct send delivers the text straight to the target session's own feed", %{
      conn: conn,
      claude_session: root,
      target: target
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      view |> element("button[phx-value-id='#{target.id}']") |> render_click()
      assert has_element?(view, "button.btn-active", "Send directly")

      view
      |> form("form[phx-submit='send_tree_compose']", %{"text" => "please look at the build"})
      |> render_submit()

      assert "please look at the build" in user_message_texts(target.id)
      assert user_message_texts(root.id) == []
    end

    test "relay mode sends the phrased nudge to the CURRENT session instead of the target", %{
      conn: conn,
      claude_session: root,
      target: target
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      view |> element("button[phx-value-id='#{target.id}']") |> render_click()

      view
      |> element("button[phx-value-mode='relay']")
      |> render_click()

      view
      |> form("form[phx-submit='send_tree_compose']", %{"text" => "check on the deploy"})
      |> render_submit()

      expected =
        "Please message session #{target.id} (#{target.title}) about the following: check on the deploy"

      assert expected in user_message_texts(root.id)
      assert user_message_texts(target.id) == []
    end
  end
end
