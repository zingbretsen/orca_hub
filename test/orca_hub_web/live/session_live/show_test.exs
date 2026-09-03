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
  import Ecto.Query

  alias OrcaHub.{Repo, SessionSupervisor, Sessions}
  alias OrcaHub.Sessions.Message

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

      assert html =~ "Fable 5.1"
      assert html =~ "Opus 4.8"
      assert html =~ "Sonnet 5"
      assert html =~ "Haiku 4.5"
      refute html =~ "GPT-5"
    end

    test "Codex session offers only Codex models", %{conn: conn, codex_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "GPT-5.6 Sol"
      refute html =~ "Opus 4.8"
      refute html =~ "Fable 5.1"
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

  # The commit panel's `git log --all --grep` can take tens of seconds in a
  # large repo (>20s on a loaded agent node in production, which used to 500
  # the page via an uncaught {:erpc, :timeout}), so it's fetched with
  # start_async and must never be on the critical path of first paint.
  describe "commit panel — loaded asynchronously" do
    setup %{claude_session: session} do
      dir = session.directory
      git = fn args -> System.cmd("git", args, cd: dir, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "-q"])
      {_, 0} = git.(["config", "user.email", "test@example.com"])
      {_, 0} = git.(["config", "user.name", "Test"])
      File.write!(Path.join(dir, "committed.txt"), "hi")
      {_, 0} = git.(["add", "committed.txt"])

      {_, 0} =
        git.(["commit", "-q", "-m", "Async panel subject\n\nOrcaHub-Session: #{session.id}"])

      :ok
    end

    test "mount renders before the commits are fetched, then they fill in", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      # First paint didn't wait for git...
      refute html =~ ~s(title="Commits")

      # ...and the panel appears once the async fetch lands.
      assert render_async(view) =~ ~s(title="Commits")

      assert view |> element(~s(button[title="Commits"])) |> render_click() =~
               "Async panel subject"
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

    test "shows a node's model on its secondary metadata line; omits it when nil", %{
      conn: conn,
      claude_session: root,
      child: child,
      archived_grandchild: leaf
    } do
      {:ok, child} = Sessions.update_session(child, %{model: "claude-opus-4-8"})
      assert is_nil(root.model)
      assert is_nil(leaf.model)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{child.id}?view=tree")

      assert has_element?(
               view,
               "#session-node-#{child.id} div",
               "claude-opus-4-8"
             )

      # `leaf` (archived_grandchild) has no children of its own, so its node's
      # DOM subtree is self-contained — unlike checking against an ancestor
      # (root/child), whose subtree structurally nests every descendant's
      # markup and would trivially "contain" this text regardless of whether
      # the assertion logic were correct.
      refute has_element?(view, "#session-node-#{leaf.id} div", "claude-opus-4-8")
    end

    test "shows backend, runner node, and archived status on the secondary metadata line", %{
      conn: conn,
      archived_grandchild: leaf
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{leaf.id}?view=tree")

      # `leaf` has no children of its own — see the self-contained-subtree
      # note above — so its metadata line is safe to select uniquely.
      meta_line =
        view
        |> element("#session-node-#{leaf.id} div.text-base-content\\/50")
        |> render()

      assert meta_line =~ "claude"
      assert meta_line =~ OrcaHub.Cluster.node_name(leaf.runner_node)
      assert meta_line =~ "archived"
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

  describe "Tree view — subagents disclosure gate (upfront ids_with_subagents query, not the lazy per-node fetch)" do
    setup %{claude_session: root} do
      dir =
        Path.join(System.tmp_dir!(), "tree_subagents_gate_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, with_subagents} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Has Subagents"
        })

      {:ok, _} =
        Sessions.create_message(%{
          session_id: with_subagents.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "toolu_gate_1",
                  "name" => "Agent",
                  "input" => %{"subagent_type" => "explore", "description" => "look around"}
                }
              ]
            }
          }
        })

      {:ok, without_subagents} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "No Subagents"
        })

      on_exit(fn ->
        Enum.each([with_subagents.id, without_subagents.id], fn id ->
          if SessionSupervisor.session_alive?(id), do: SessionSupervisor.stop_session(id)
        end)
      end)

      %{with_subagents: with_subagents, without_subagents: without_subagents}
    end

    test "renders the Subagents disclosure only on the node that actually has one", %{
      conn: conn,
      claude_session: root,
      with_subagents: with_subagents,
      without_subagents: without_subagents
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      assert has_element?(view, "#session-node-#{with_subagents.id} summary", "Subagents")
      refute has_element?(view, "#session-node-#{without_subagents.id} summary", "Subagents")
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

      # Collapsed per-node summary line renders counts up front...
      assert has_element?(view, "#session-node-#{root.id} summary", "2 sent")
      assert has_element?(view, "#session-node-#{sibling.id} summary", "2 received")

      # ...and the full chip list — inside a closed <details>, so still
      # present in the rendered HTML even though not visually expanded — has
      # the count-folded chip and is reachable without a page interaction.
      assert html =~ "×2"
      assert has_element?(view, "#session-node-#{root.id} button", sibling.title)
      assert has_element?(view, "#session-node-#{sibling.id} button", root.title)
    end

    test "renders a distinct kind tag for a handoff edge but not a plain message edge", %{
      conn: conn,
      claude_session: root
    } do
      dir = Path.join(System.tmp_dir!(), "tree_edges_kind_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, sibling} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Handoff Target"
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(sibling.id),
          do: SessionSupervisor.stop_session(sibling.id)
      end)

      {:ok, _} =
        Sessions.create_session_interaction(%{
          sender_session_id: root.id,
          recipient_session_id: sibling.id,
          kind: "handoff"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      assert has_element?(view, "#session-node-#{root.id} button", "handoff")
      assert has_element?(view, "#session-node-#{sibling.id} button", "handoff")
    end

    test "a plain message edge renders no kind tag", %{conn: conn, claude_session: root} do
      dir =
        Path.join(System.tmp_dir!(), "tree_edges_no_kind_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, sibling} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node()),
          parent_session_id: root.id,
          title: "Message Target"
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

      {:ok, view, _html} = live(conn, ~p"/sessions/#{root.id}?view=tree")

      refute has_element?(view, "#session-node-#{root.id} button", "message")
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

  describe "windowed message feed" do
    defp feed_text_msg(text) do
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    end

    defp feed_insert_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      message
    end

    defp feed_seed(session, count) do
      base = ~N[2026-01-01 00:00:00.000000]

      for i <- 1..count,
          do:
            feed_insert_at(session, feed_text_msg("msg#{i}"), NaiveDateTime.add(base, i, :second))
    end

    test "loads only the last @window_size messages, not the whole history", %{
      conn: conn,
      claude_session: session
    } do
      window_size = OrcaHubWeb.SessionLive.Show.window_size()
      feed_seed(session, window_size + 5)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert length(assigns.messages) == window_size
      assert assigns.has_more_messages
      # Oldest-first: the tail of the seeded history is what's loaded.
      assert List.first(assigns.messages)["message"]["content"] |> hd() |> Map.get("text") ==
               "msg6"

      assert List.last(assigns.messages)["message"]["content"] |> hd() |> Map.get("text") ==
               "msg#{window_size + 5}"
    end

    test "has_more_messages is false when the whole history fits in one window", %{
      conn: conn,
      claude_session: session
    } do
      feed_seed(session, 3)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      refute assigns.has_more_messages
      assert length(assigns.messages) == 3
    end

    test "load_older_messages commits another page ahead of what's loaded, without disturbing the tail",
         %{conn: conn, claude_session: session} do
      window_size = OrcaHubWeb.SessionLive.Show.window_size()
      feed_seed(session, window_size + 5)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert length(:sys.get_state(view.pid).socket.assigns.messages) == window_size

      render_hook(view, "load_older_messages", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert length(assigns.messages) == window_size + 5
      refute assigns.has_more_messages

      # Nothing at the tail moved — only older messages were prepended.
      assert List.last(assigns.messages)["message"]["content"] |> hd() |> Map.get("text") ==
               "msg#{window_size + 5}"

      assert List.first(assigns.messages)["message"]["content"] |> hd() |> Map.get("text") ==
               "msg1"
    end

    test "a live {:event, ...} broadcast still appends to the loaded window normally", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:event, feed_text_msg("live reply")}
      )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert List.last(assigns.messages)["message"]["content"] |> hd() |> Map.get("text") ==
               "live reply"
    end

    test "a live subagent reply whose parent tool_use fell outside the window still renders somewhere",
         %{conn: conn, claude_session: session} do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      # The subagent-spawning tool_use — inserted first, then pushed out of
      # the window by window_size+5 younger top-level messages below.
      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_orphan_parent",
              "name" => "Agent",
              "input" => %{"description" => "investigate the flake"}
            }
          ]
        }
      }

      feed_insert_at(session, parent, base)

      for i <- 1..(window_size + 5),
          do: feed_insert_at(session, feed_text_msg("noise#{i}"), NaiveDateTime.add(base, i))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Parent tool_use is confirmed out of the loaded window.
      assigns = :sys.get_state(view.pid).socket.assigns

      refute Enum.any?(assigns.messages, fn m ->
               m["message"]["content"]
               |> List.wrap()
               |> Enum.any?(&(is_map(&1) && &1["id"] == "toolu_orphan_parent"))
             end)

      # A live final reply from that subagent arrives mid-turn.
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{session.id}",
        {:event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "toolu_orphan_parent",
           "message" => %{"content" => [%{"type" => "text", "text" => "orphaned final reply"}]}
         }}
      )

      html = render(view)
      assert html =~ "orphaned final reply"
    end

    test "a live-pulled ancestor doesn't get duplicated once 'load older messages' reaches its real DB position",
         %{conn: conn, claude_session: session} do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_orphan_parent2",
              "name" => "Agent",
              "input" => %{"description" => "investigate the other flake"}
            }
          ]
        }
      }

      feed_insert_at(session, parent, base)

      for i <- 1..(window_size + 5),
          do: feed_insert_at(session, feed_text_msg("noise#{i}"), NaiveDateTime.add(base, i))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      live_reply = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_orphan_parent2",
        "message" => %{"content" => [%{"type" => "text", "text" => "orphaned final reply 2"}]}
      }

      # A real SessionRunner event is always PERSISTED before it's broadcast
      # (see session_runner.ex's persist_message/stamp — the invariant
      # commit_older_page's reconcile_pulled_ancestors/3 relies on) — mirror
      # that ordering here rather than only broadcasting.
      feed_insert_at(session, live_reply, NaiveDateTime.add(base, window_size + 6))

      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session.id}", {:event, live_reply})

      assert MapSet.member?(
               :sys.get_state(view.pid).socket.assigns.live_pulled_ancestor_ids,
               "toolu_orphan_parent2"
             )

      # Scroll all the way back — the older page(s) now reach the ancestor's
      # real (older-than-everything) DB row.
      render_hook(view, "load_older_messages", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      refute assigns.has_more_messages
      refute MapSet.member?(assigns.live_pulled_ancestor_ids, "toolu_orphan_parent2")

      ancestor_occurrences =
        Enum.count(assigns.messages, fn m ->
          m["message"]["content"]
          |> List.wrap()
          |> Enum.any?(&(is_map(&1) && &1["id"] == "toolu_orphan_parent2"))
        end)

      assert ancestor_occurrences == 1
      assert render(view) |> String.split("orphaned final reply 2") |> length() == 2
    end

    test "a subagent block straddling the mount boundary keeps its PRE-mount descendants too, once scrolled back to",
         %{conn: conn, claude_session: session} do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_straddle",
              "name" => "Agent",
              "input" => %{"description" => "gather context"}
            }
          ]
        }
      }

      feed_insert_at(session, parent, base)

      # This descendant is persisted BEFORE the LiveView ever mounts — never
      # streamed over PubSub during this view's lifetime, and (since its
      # parent tool_use is about to be pushed out of the window below) never
      # loaded by the initial windowed fetch either. The only chance it ever
      # gets rendered is a later "load older messages" reaching it directly.
      pre_mount_child = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_straddle",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "pre-mount context gathering"}]
        }
      }

      feed_insert_at(session, pre_mount_child, NaiveDateTime.add(base, 1))

      for i <- 1..(window_size + 5),
          do: feed_insert_at(session, feed_text_msg("noise#{i}"), NaiveDateTime.add(base, i + 1))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Confirm it's genuinely missing pre-scroll-back — not already covered
      # by the initial window some other way.
      refute render(view) =~ "pre-mount context gathering"

      live_reply = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_straddle",
        "message" => %{"content" => [%{"type" => "text", "text" => "live final reply"}]}
      }

      feed_insert_at(session, live_reply, NaiveDateTime.add(base, window_size + 7))
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session.id}", {:event, live_reply})

      html = render(view)
      assert html =~ "live final reply"
      refute html =~ "pre-mount context gathering"

      render_hook(view, "load_older_messages", %{})

      html = render(view)
      assert html =~ "pre-mount context gathering"
      assert html =~ "live final reply"
      assert html |> String.split("live final reply") |> length() == 2
      assert html |> String.split("pre-mount context gathering") |> length() == 2
    end

    test "a live descendant that arrives AFTER the background prefetch buffered its page still survives scroll-back",
         %{conn: conn, claude_session: session} do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_stale_buffer",
              "name" => "Agent",
              "input" => %{"description" => "long-running task"}
            }
          ]
        }
      }

      feed_insert_at(session, parent, base)

      for i <- 1..(window_size + 5),
          do: feed_insert_at(session, feed_text_msg("noise#{i}"), NaiveDateTime.add(base, i))

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Force the background prefetch (normally @prefetch_delay_ms after
      # mount) to fire NOW, deterministically — this buffers a page that
      # already contains "toolu_stale_buffer"'s row but, since nothing has
      # streamed in for it yet, none of its descendants.
      send(view.pid, :prefetch_older_messages)
      assert :sys.get_state(view.pid).socket.assigns.buffered_older_page != nil

      # A live descendant arrives only NOW — strictly after the buffer was
      # fetched, strictly before the user scrolls back to it.
      live_reply = %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_stale_buffer",
        "message" => %{"content" => [%{"type" => "text", "text" => "reply after stale buffer"}]}
      }

      feed_insert_at(session, live_reply, NaiveDateTime.add(base, window_size + 6))
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session.id}", {:event, live_reply})

      assert MapSet.member?(
               :sys.get_state(view.pid).socket.assigns.live_pulled_ancestor_ids,
               "toolu_stale_buffer"
             )

      render_hook(view, "load_older_messages", %{})

      html = render(view)
      assert html =~ "reply after stale buffer"
      assert html |> String.split("reply after stale buffer") |> length() == 2
    end
  end

  describe "derived state survives outside the loaded window" do
    defp derived_text_msg(text) do
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    end

    defp derived_insert_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      message
    end

    defp derived_noise(session, base, count) do
      for i <- 1..count,
          do:
            derived_insert_at(
              session,
              derived_text_msg("noise#{i}"),
              NaiveDateTime.add(base, i, :second)
            )
    end

    test "plan_mode is :planning even though EnterPlanMode is outside the window", %{
      conn: conn,
      claude_session: session
    } do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      enter = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "name" => "EnterPlanMode"}]}
      }

      derived_insert_at(session, enter, base)
      derived_noise(session, base, window_size + 10)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert length(assigns.messages) == window_size
      assert assigns.plan_mode == :planning
    end

    test "todos reflect the last TodoWrite even though it's outside the window", %{
      conn: conn,
      claude_session: session
    } do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      todo_write = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "TodoWrite",
              "input" => %{"todos" => [%{"content" => "ship it", "status" => "pending"}]}
            }
          ]
        }
      }

      derived_insert_at(session, todo_write, base)
      derived_noise(session, base, window_size + 10)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.todos == [%{"content" => "ship it", "status" => "pending"}]
    end

    test "a pending AskUserQuestion opens the wizard even though it's outside the window", %{
      conn: conn,
      claude_session: session
    } do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      ask = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ]
        }
      }

      derived_insert_at(session, ask, base)
      derived_noise(session, base, window_size + 10)
      {:ok, _} = Sessions.update_session(session, %{status: "waiting"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert %{tool_use_id: "aq1"} = assigns.pending_questions
      assert assigns.aq_open
    end

    test "context_percent reflects the last pi_session_stats even outside the window", %{
      conn: conn,
      pi_session: session
    } do
      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      stats = %{"type" => "pi_session_stats", "context_usage" => %{"percent" => 77.4}}
      derived_insert_at(session, stats, base)
      derived_noise(session, base, window_size + 10)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.context_percent == 77.4
      assert html =~ "77.4%"
    end

    # ORCAHUB3-60: after the init sweep, pending pi dialogs with no live runner are cleared
    # (they are genuinely dead - pi's process and 10-minute timer died). Tests using pending
    # dialogs must ensure the runner is already alive to avoid the sweep clearing them.
    test "pending_ui_request (pi extension-UI dialog) survives outside the window", %{
      conn: conn,
      pi_session: session
    } do
      # Start the runner first so the init sweep doesn't clear the pending dialog
      {:ok, _runner} = SessionSupervisor.start_session(session.id)

      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      request = %{"type" => "pi_ui_request", "id" => "req1", "method" => "select"}
      derived_insert_at(session, request, base)
      derived_noise(session, base, window_size + 10)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.pending_ui_request["id"] == "req1"
    end

    # Regression (ORCAHUB3-30-class bug): `phx-value-value` on a <button>
    # is silently clobbered to "" by Phoenix LiveView's client-side
    # extractMeta, which always captures the element's native `.value` DOM
    # property (empty string by default, absent an explicit `value=` HTML
    # attribute) AFTER reading phx-value-* attrs — overwriting whatever
    # phx-value-value set moments earlier. That made every pi option-select
    # click send answer: "" instead of the chosen option, and the
    # force-command guard's Confirm button send confirmed: false regardless
    # of the click. The fix is a native `value=` HTML attribute instead of
    # `phx-value-value` — verified here against the actual rendered HTML,
    # since a render_click/render_submit simulation bypasses the browser JS
    # entirely and would not catch this class of bug.
    # ORCAHUB3-60: pending dialogs with no live runner are cleared by the init sweep.
    # Start runner first to avoid the sweep clearing the dialog so the buttons render.
    test "option-select buttons use a native value attribute, not phx-value-value", %{
      conn: conn,
      pi_session: session
    } do
      {:ok, _runner} = SessionSupervisor.start_session(session.id)

      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      request = %{
        "type" => "pi_ui_request",
        "id" => "req2",
        "method" => "select",
        "title" => "Pick one",
        "options" => ["Alpha — first", "Beta — second"]
      }

      derived_insert_at(session, request, base)
      derived_noise(session, base, window_size + 10)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ ~s(phx-value-value=)
      assert html =~ ~s(value="Alpha — first")
      assert html =~ ~s(value="Beta — second")
    end

    # ORCAHUB3-60: pending dialogs with no live runner are cleared by the init sweep.
    # Start runner first to avoid the sweep clearing the dialog so the buttons render.
    test "the force-command guard's Confirm button uses a native value attribute, not phx-value-value",
         %{conn: conn, pi_session: session} do
      {:ok, _runner} = SessionSupervisor.start_session(session.id)

      base = ~N[2026-01-01 00:00:00.000000]
      window_size = OrcaHubWeb.SessionLive.Show.window_size()

      request = %{
        "type" => "pi_ui_request",
        "id" => "req3",
        "method" => "confirm",
        "title" => "Run dangerous command?"
      }

      derived_insert_at(session, request, base)
      derived_noise(session, base, window_size + 10)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ ~s(phx-value-value=)
      assert html =~ ~s(value="true")
    end
  end

  # tts_rewrite_spec.md §5 (Option A): autoplay is driven by an explicit id
  # from the server, never a client-side DOM scan — these pin that the right
  # id gets pushed (or withheld) server-side.
  describe "read-aloud (TTS) autoplay" do
    defp insert_assistant_text(session, id, text) do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "id" => id,
            "message" => %{"content" => [%{"type" => "text", "text" => text}]}
          }
        })
    end

    test "pushes the newest assistant-text message's id when a turn goes idle with autoplay on",
         %{conn: conn, claude_session: session} do
      insert_assistant_text(session, "msg-1", "hello there")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_hook(view, "tts_autoplay_init", %{"enabled" => true})

      send(view.pid, {:status, :idle})

      assert_push_event(view, "tts-autoplay", %{message_id: "msg-1"})
    end

    test "pushes nothing when autoplay is off", %{conn: conn, claude_session: session} do
      insert_assistant_text(session, "msg-1", "hello there")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      send(view.pid, {:status, :idle})

      refute_push_event(view, "tts-autoplay", %{message_id: "msg-1"})
    end

    test "skips a tool-only final message — nothing to read, so no autoplay target", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "id" => "msg-1",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}}
              ]
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_hook(view, "tts_autoplay_init", %{"enabled" => true})

      send(view.pid, {:status, :idle})

      refute_push_event(view, "tts-autoplay", %{message_id: "msg-1"})
    end

    test "finds the newest TEXT message even when a later tool-only message came after it", %{
      conn: conn,
      claude_session: session
    } do
      insert_assistant_text(session, "msg-1", "hello there")

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "id" => "msg-2",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}}
              ]
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_hook(view, "tts_autoplay_init", %{"enabled" => true})

      send(view.pid, {:status, :idle})

      assert_push_event(view, "tts-autoplay", %{message_id: "msg-1"})
    end

    test "tts_autoplay_init hydrates :tts_autoplay from the client's localStorage on connect " <>
           "(the assign itself still defaults to false on every mount)",
         %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute :sys.get_state(view.pid).socket.assigns.tts_autoplay

      render_hook(view, "tts_autoplay_init", %{"enabled" => true})
      assert :sys.get_state(view.pid).socket.assigns.tts_autoplay
    end

    test "toggling autoplay pushes the new value back to the client for localStorage persistence",
         %{conn: conn, claude_session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      view |> element("button[phx-click='toggle_tts']") |> render_click()

      assert_push_event(view, "tts_autoplay_persisted", %{enabled: true})
    end

    test "the ORCA_API_TOKEN for /api/tts is pushed once connected, never rendered into the page",
         %{conn: conn, claude_session: session} do
      Application.put_env(:orca_hub, :api_token, "tts-test-token")
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ "tts-test-token"
      assert_push_event(view, "tts-config", %{api_token: "tts-test-token"})
    end
  end

  describe "project autocomplete (\"##\" mention)" do
    test "value carries the full project_id and the RAW node name, so start_session can target it directly",
         %{conn: conn, claude_session: session} do
      dir =
        Path.join(System.tmp_dir!(), "show_project_mention_#{System.unique_integer([:positive])}")

      unique_name = "mention-target-#{System.unique_integer([:positive])}"

      {:ok, project} =
        OrcaHub.Projects.create_project(%{name: unique_name, directory: dir, node: "orca@debian"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_hook(view, "autocomplete", %{"type" => "project", "query" => unique_name})

      expected_value = "##" <> unique_name <> " (project_id: #{project.id}, node: orca@debian)"

      assert_push_event(view, "autocomplete_results", %{
        items: [%{value: ^expected_value, label: ^unique_name, type: "project"}],
        type: "project"
      })
    end

    test "omits the node clause when the project has no node set", %{
      conn: conn,
      claude_session: session
    } do
      dir =
        Path.join(
          System.tmp_dir!(),
          "show_project_mention_nil_node_#{System.unique_integer([:positive])}"
        )

      unique_name = "mention-nilnode-#{System.unique_integer([:positive])}"

      {:ok, project} = OrcaHub.Projects.create_project(%{name: unique_name, directory: dir})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_hook(view, "autocomplete", %{"type" => "project", "query" => unique_name})

      expected_value = "##" <> unique_name <> " (project_id: #{project.id})"

      assert_push_event(view, "autocomplete_results", %{
        items: [%{value: ^expected_value}],
        type: "project"
      })
    end
  end

  describe "mobile 'More actions' opener button" do
    test "opener button exists on the page", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Verify the opener button exists (mobile-only, sm:hidden means hidden on desktop)
      assert has_element?(view, ~s|button[phx-click="open_mobile_actions"]|)
    end

    test "closes when toggle_mcp_modal is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens another modal
      render_click(view, "toggle_mcp_modal")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when toggle_heartbeat_modal is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens another modal
      render_click(view, "toggle_heartbeat_modal")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when toggle_file_browser is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens a panel
      render_click(view, "toggle_file_browser")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when toggle_todos is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens a panel
      render_click(view, "toggle_todos")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when toggle_commits is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens a panel
      render_click(view, "toggle_commits")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when toggle_artifacts is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a control that opens a panel
      render_click(view, "toggle_artifacts")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when compact_session is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a one-shot action
      render_click(view, "compact_session")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when stop_session is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a one-shot action
      render_click(view, "stop_session")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "closes when archive is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a one-shot action - archive navigates to /sessions with undo param
      # The modal closes in the handler before navigation happens
      # Since render_click returns {:error, redirect} on navigation, we need to verify
      # the redirect happens (which implies the handler completed and closed the modal)
      {:error, {:live_redirect, %{to: path}}} = render_click(view, "archive")

      # Verify the redirect went to /sessions with undo param
      assert path =~ "/sessions?undo="
    end

    test "closes when unarchive is clicked", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a one-shot action
      render_click(view, "unarchive")

      # The modal should now be closed
      refute has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "stays open when toggle_orchestrator is clicked (boolean switch)", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a pure boolean switch
      render_click(view, "toggle_orchestrator")

      # The modal should stay open
      assert has_element?(view, ~s|#session-mobile-actions[open]|)
    end

    test "stays open when toggle_plan_mode is clicked (boolean switch)", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Open the mobile actions modal
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions[open]|)

      # Click a pure boolean switch
      render_click(view, "toggle_plan_mode")

      # The modal should stay open
      assert has_element?(view, ~s|#session-mobile-actions[open]|)
    end
  end

  describe "orchestrator parentage (ORCAHUB3-50)" do
    test "no parent is stated plainly, not just omitted", %{conn: conn, claude_session: session} do
      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "Parent:"
      assert html =~ "none"
    end

    test "shows the parent's title, linking to its session page", %{
      conn: conn,
      claude_session: session,
      codex_session: parent
    } do
      {:ok, parent} = Sessions.update_session(parent, %{title: "Orchestrator Prime"})
      {:ok, session} = Sessions.update_session(session, %{parent_session_id: parent.id})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "Orchestrator Prime"
      assert html =~ ~s(href="/sessions/#{parent.id}")
    end

    test "detach button appears (desktop + mobile) only when a parent is set", %{
      conn: conn,
      claude_session: session,
      codex_session: parent
    } do
      {:ok, _no_parent_view, html} = live(conn, ~p"/sessions/#{session.id}")
      refute html =~ ~s(phx-click="detach_from_orchestrator")

      {:ok, session} = Sessions.update_session(session, %{parent_session_id: parent.id})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Desktop button
      assert has_element?(view, ~s|button[phx-click="detach_from_orchestrator"][data-confirm]|)
      # Mobile "More actions" surface duplicates the same action
      render_click(view, "open_mobile_actions")

      assert has_element?(
               view,
               ~s|#session-mobile-actions button[phx-click="detach_from_orchestrator"]|
             )
    end

    test "attach button is present (desktop + mobile) regardless of current parent", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, ~s|button[phx-click="open_attach_modal"]|)
      render_click(view, "open_mobile_actions")
      assert has_element?(view, ~s|#session-mobile-actions button[phx-click="open_attach_modal"]|)
    end

    test "detaching clears the parent and flashes which orchestrator it left", %{
      conn: conn,
      claude_session: session,
      codex_session: parent
    } do
      {:ok, parent} = Sessions.update_session(parent, %{title: "Old Orchestrator"})
      {:ok, session} = Sessions.update_session(session, %{parent_session_id: parent.id})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert has_element?(view, ~s|button[phx-click="detach_from_orchestrator"]|)

      html = render_click(view, "detach_from_orchestrator")

      refute html =~ ~s(phx-click="detach_from_orchestrator")
      assert html =~ "Detached from Old Orchestrator"
      assert html =~ "Parent:"
      assert html =~ "none"
    end

    test "detaching an already-parentless session is an idempotent success", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      html = render_click(view, "detach_from_orchestrator")

      assert html =~ "Parent:"
      assert html =~ "none"
    end

    test "attaching to a candidate sets the parent and flashes success", %{
      conn: conn,
      claude_session: session,
      codex_session: candidate
    } do
      {:ok, candidate} = Sessions.update_session(candidate, %{title: "New Orchestrator"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_attach_modal")
      assert has_element?(view, "form[phx-change=\"filter_attach_candidates\"]")
      assert has_element?(view, ~s|button[phx-click="attach_to_parent"]|)

      html = render_click(view, "attach_to_parent", %{"parent_id" => candidate.id})

      assert html =~ "Attached to New Orchestrator"
      assert html =~ ~s(href="/sessions/#{candidate.id}")
    end

    test "re-parenting an already-parented session is allowed and says which parent it moved from",
         %{
           conn: conn,
           claude_session: session,
           codex_session: old_parent,
           pi_session: new_parent
         } do
      {:ok, old_parent} = Sessions.update_session(old_parent, %{title: "Old Boss"})
      {:ok, new_parent} = Sessions.update_session(new_parent, %{title: "New Boss"})
      {:ok, session} = Sessions.update_session(session, %{parent_session_id: old_parent.id})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      html = render_click(view, "attach_to_parent", %{"parent_id" => new_parent.id})

      assert html =~ "Re-parented from Old Boss to New Boss"
      assert html =~ ~s(href="/sessions/#{new_parent.id}")
    end

    test "attaching over a would-be cycle shows a readable flash instead of crashing", %{
      conn: conn,
      claude_session: ancestor,
      codex_session: descendant
    } do
      {:ok, descendant} =
        Sessions.update_session(descendant, %{parent_session_id: ancestor.id})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ancestor.id}")

      # ancestor attaching to its own descendant would create a cycle
      html = render_click(view, "attach_to_parent", %{"parent_id" => descendant.id})

      assert html =~ "Failed to attach"
      assert html =~ "cycle"
      # The view survived — still rendering, not crashed
      assert has_element?(view, ~s|button[phx-click="open_attach_modal"]|)
    end

    test "attaching a session to itself shows a readable flash instead of crashing", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      html = render_click(view, "attach_to_parent", %{"parent_id" => session.id})

      assert html =~ "Failed to attach"
      assert has_element?(view, ~s|button[phx-click="open_attach_modal"]|)
    end

    test "attach candidate list excludes the session itself", %{
      conn: conn,
      claude_session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      render_click(view, "open_attach_modal")
      html = render(view)

      refute html =~ ~s(phx-value-parent_id="#{session.id}")
    end

    test "filtering the attach candidate list narrows results", %{
      conn: conn,
      claude_session: session,
      codex_session: candidate
    } do
      {:ok, _candidate} = Sessions.update_session(candidate, %{title: "Findable Orchestrator"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      render_click(view, "open_attach_modal")

      html =
        view
        |> form("form[phx-change=\"filter_attach_candidates\"]", %{"query" => "nonexistent-xyz"})
        |> render_change()

      refute html =~ "Findable Orchestrator"

      html =
        view
        |> form("form[phx-change=\"filter_attach_candidates\"]", %{"query" => "Findable"})
        |> render_change()

      assert html =~ "Findable Orchestrator"
    end

    test "parentage_changed broadcast on the child's own topic refreshes the display live", %{
      conn: conn,
      claude_session: session,
      codex_session: parent
    } do
      {:ok, parent} = Sessions.update_session(parent, %{title: "Live Orchestrator"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Simulate the broadcast Sessions.attach_session/3 sends, independent of
      # this LiveView's own optimistic update — proves the subscription path.
      {:ok, _} = Sessions.attach_session(session.id, parent.id)

      html = render(view)
      assert html =~ "Live Orchestrator"
    end
  end
end
