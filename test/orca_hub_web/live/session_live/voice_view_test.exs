defmodule OrcaHubWeb.SessionLive.VoiceViewTest do
  @moduledoc """
  The session page's half of the phone voice view (ORCAHUB3-113 phase C),
  as rendered by `SessionLive.Show`: the `#voice-view` hook element and the
  server-known facts it carries (status, C1 suppression, the turn's start and
  activity), the content markers in the live feed, and the big Clear/Send in
  the composer form (C2).

  What the view LOOKS like (one message, large; the textarea filling the
  screen) is CSS keyed on <html> attributes the hooks set, and the state
  rules are node-checked (`OrcaHubWeb.VoiceViewCheckTest`); neither is
  visible to LiveViewTest. These pin the markup contract both depend on.

  Same fixture posture as `OrcaHubWeb.SessionLive.ShowTest`: fresh sessions
  boot their runner straight into `:ready` and never open a port.
  """

  # async: false — a real SessionRunner under the shared supervisor, as in
  # show_test.exs.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{SessionHeartbeat, SessionSupervisor, Sessions}
  alias OrcaHub.Voice.Dictation

  setup do
    dir = Path.join(System.tmp_dir!(), "voice_view_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        code_exec: false,
        orchestrator: false,
        runner_node: Atom.to_string(node())
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    {:ok, session: session, dir: dir}
  end

  defp attr(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp event(data), do: {:event, data}

  defp user(id, text, ts \\ ~N[2026-10-02 12:00:00]) do
    %{
      "type" => "user",
      "uuid" => id,
      "timestamp" => ts,
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp assistant(id, content),
    do: %{"type" => "assistant", "uuid" => id, "message" => %{"content" => content}}

  describe "#voice-view" do
    test "is the VoiceView hook, hidden unless voice-view, with its contract attributes", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, ~s(#voice-view[phx-hook="VoiceView"]))
      class = attr(view, "#voice-view", "class")
      assert class =~ "hidden"
      assert class =~ "voice-view:contents"

      assert attr(view, "#voice-view", "data-session-status") in ["ready", "idle"]
      assert attr(view, "#voice-view", "data-voice-suppressed") == "false"
      # Idle: no turn running, so no turn start.
      assert attr(view, "#voice-view", "data-turn-started-at") == nil
    end

    test "sits directly in the chat column, ahead of the feed (display: contents ordering)", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, ~s([data-resize-panel="left"] > #voice-view))
      assert has_element?(view, ~s([data-resize-panel="left"] > #message-feed))
    end

    test "carries the two EMPTY phx-update=ignore containers the TTS rail writes into", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      for id <- ~w(voice-held voice-rail) do
        assert has_element?(view, ~s(#voice-view ##{id}[phx-update="ignore"]))
        html = view |> element("##{id}") |> render()
        inner = html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id} > *") |> Enum.count()
        assert inner == 0, "##{id} must be empty: #{html}"
      end
    end

    test "the pager is hook-owned (phx-update=ignore): prev, label, next, and a hidden Live", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      assert has_element?(view, ~s(#voice-view #voice-pager[phx-update="ignore"]))
      assert has_element?(view, ~s(#voice-pager [data-voice-pager-row][hidden]))
      assert has_element?(view, ~s(#voice-pager [data-voice-pager-label]))

      for action <- ~w(prev next live) do
        assert has_element?(view, ~s(#voice-pager button[data-voice-view-action="#{action}"]))
      end

      assert has_element?(view, ~s(#voice-pager button[data-voice-view-action="live"][hidden]))
    end

    test "is not rendered in the tree view (no feed, no composer to restyle)", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}?view=tree")
      refute has_element?(view, "#voice-view")
    end
  end

  describe "content markers on the live page" do
    test "top-level bubbles are marked, a subagent's are not", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(view.pid, event(user("u1", "review the deploy")))

      send(
        view.pid,
        event(
          assistant("a1", [
            %{"type" => "text", "text" => "spawning a reviewer"},
            %{"type" => "tool_use", "id" => "agent1", "name" => "Agent", "input" => %{}}
          ])
        )
      )

      send(
        view.pid,
        event(
          Map.put(
            assistant("sa1", [%{"type" => "text", "text" => "subagent finding"}]),
            "parent_tool_use_id",
            "agent1"
          )
        )
      )

      send(view.pid, event(assistant("a2", [%{"type" => "text", "text" => "all good"}])))

      html = render(view)
      assert html =~ "subagent finding"

      marked =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#message-feed [data-voice-content]")
        |> Enum.map(
          &{LazyHTML.attribute(&1, "data-voice-content"),
           LazyHTML.attribute(&1, "data-voice-msg")}
        )

      assert marked == [
               {["user"], ["u1"]},
               {["assistant"], ["a1"]},
               {["assistant"], ["a2"]}
             ]
    end
  end

  describe "the agent working (D5)" do
    test "running: the status, the turn's start, and the dictating strip", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      refute has_element?(view, "[data-voice-agent-strip]")

      send(view.pid, event(user("u1", "check gb10", ~N[2026-10-02 12:00:00])))

      send(
        view.pid,
        event(
          assistant("a1", [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "Bash",
              "input" => %{"command" => "ls"}
            }
          ])
        )
      )

      send(view.pid, {:status, :running})
      _ = render(view)

      assert attr(view, "#voice-view", "data-session-status") == "running"

      assert attr(view, "#voice-view", "data-turn-started-at") ==
               to_string(DateTime.to_unix(~U[2026-10-02 12:00:00Z], :millisecond))

      strip = view |> element("[data-voice-agent-strip]") |> render()
      assert strip =~ "Agent working"
      assert strip =~ ", Bash"
      assert strip =~ "1 tool"
      assert strip =~ ~s(id="voice-strip-elapsed")
      assert strip =~ "voice-dictating:flex"

      send(view.pid, {:status, :idle})
      _ = render(view)
      refute has_element?(view, "[data-voice-agent-strip]")
      assert attr(view, "#voice-view", "data-turn-started-at") == nil
    end

    test "#voice-activity follows the turn: done ones checked, the running one first-class", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(view.pid, event(user("u1", "go")))

      send(
        view.pid,
        event(
          assistant("a1", [
            %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "Read",
              "input" => %{"file_path" => "scripts/deploy.sh"}
            }
          ])
        )
      )

      send(
        view.pid,
        event(%{
          "type" => "user",
          "uuid" => "r1",
          "message" => %{
            "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "x"}]
          }
        })
      )

      send(
        view.pid,
        event(
          assistant("a2", [
            %{
              "type" => "tool_use",
              "id" => "t2",
              "name" => "Bash",
              "input" => %{"command" => "ssh gb10 journalctl -u orca-hub"}
            }
          ])
        )
      )

      send(view.pid, {:status, :running})
      _ = render(view)

      assert has_element?(view, ~s(#voice-view #voice-activity))
      assert attr(view, "#voice-activity", "class") =~ "voice-working:block"

      assert has_element?(
               view,
               ~s(#voice-activity [data-voice-activity-item][data-done="true"]),
               "scripts/deploy.sh"
             )

      assert has_element?(
               view,
               ~s(#voice-activity [data-voice-activity-item][data-done="false"]),
               "ssh gb10 journalctl"
             )

      assert has_element?(view, "#voice-activity", "2 tools so far")
      assert has_element?(view, ~s(#voice-activity #voice-activity-elapsed[phx-update="ignore"]))

      # The result for t2 lands: it is checked, and a new turn would reset.
      send(
        view.pid,
        event(%{
          "type" => "user",
          "uuid" => "r2",
          "message" => %{
            "content" => [%{"type" => "tool_result", "tool_use_id" => "t2", "content" => "y"}]
          }
        })
      )

      _ = render(view)
      refute has_element?(view, ~s(#voice-activity [data-done="false"]))

      send(view.pid, event(user("u2", "next thing")))
      _ = render(view)
      assert has_element?(view, "#voice-activity", "No tools yet")
    end
  end

  describe "suppression (C1): a tap-answer surface shows the normal page" do
    test "node unavailable", %{conn: conn, dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: "debian@totally-offline-host"
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"
    end

    test "plan review", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      assert attr(view, "#voice-view", "data-voice-suppressed") == "false"

      send(view.pid, event(assistant("p1", [%{"type" => "tool_use", "name" => "ExitPlanMode"}])))
      _ = render(view)

      assert render(view) =~ "Plan Review"
      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"

      render_click(view, "reject_plan", %{})
      assert attr(view, "#voice-view", "data-voice-suppressed") == "false"
    end

    test "a pending pi dialog, and back once it is answered", %{conn: conn, dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "pi",
          code_exec: false,
          orchestrator: false,
          runner_node: Atom.to_string(node())
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(session.id),
          do: SessionSupervisor.stop_session(session.id)
      end)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(
        view.pid,
        event(%{
          "type" => "pi_ui_request",
          "id" => "req1",
          "method" => "confirm",
          "title" => "Ok?"
        })
      )

      _ = render(view)
      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"

      send(view.pid, event(%{"type" => "pi_ui_response", "id" => "req1", "confirmed" => true}))
      _ = render(view)
      assert attr(view, "#voice-view", "data-voice-suppressed") == "false"
    end

    test "a Claude AskUserQuestion while waiting", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(
        view.pid,
        event(
          assistant("q1", [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ])
        )
      )

      send(view.pid, {:status, :waiting})
      _ = render(view)

      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"
    end

    # The two `waiting`s (W4 correction, voice_mode_spec.md §8.5.5). A Claude
    # question ENDS the turn: once its wizard is dismissed, C1 lifts and the
    # view must be the reply (Play, no clock), not "working".
    test "a Claude AskUserQuestion's waiting is NOT a running turn", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(view.pid, event(user("u1", "pick one", ~N[2026-10-02 12:00:00])))

      send(
        view.pid,
        event(
          assistant("q1", [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ])
        )
      )

      send(view.pid, {:status, :waiting})
      _ = render(view)

      assert attr(view, "#voice-view", "data-session-status") == "waiting"
      assert attr(view, "#voice-view", "data-turn-running") == "false"
      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"

      render_click(view, "aq_cancel", %{})

      assert attr(view, "#voice-view", "data-voice-suppressed") == "false"
      assert attr(view, "#voice-view", "data-turn-running") == "false"
      assert attr(view, "#voice-view", "data-turn-started-at") == nil
      refute has_element?(view, "[data-voice-agent-strip]")
    end

    # ...while a pi dialog is overlaid on a turn still in flight.
    test "a pi dialog's waiting IS a running turn", %{conn: conn, dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "pi",
          code_exec: false,
          orchestrator: false,
          runner_node: Atom.to_string(node())
        })

      on_exit(fn ->
        if SessionSupervisor.session_alive?(session.id),
          do: SessionSupervisor.stop_session(session.id)
      end)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      send(view.pid, event(user("u1", "deploy it", ~N[2026-10-02 12:00:00])))
      send(view.pid, {:status, :running})
      _ = render(view)
      assert attr(view, "#voice-view", "data-turn-running") == "true"

      send(
        view.pid,
        event(%{
          "type" => "pi_ui_request",
          "id" => "req1",
          "method" => "confirm",
          "title" => "Ok?"
        })
      )

      send(view.pid, {:status, :waiting})
      _ = render(view)

      assert attr(view, "#voice-view", "data-session-status") == "waiting"
      assert attr(view, "#voice-view", "data-turn-running") == "true"
      assert attr(view, "#voice-view", "data-voice-suppressed") == "true"

      assert attr(view, "#voice-view", "data-turn-started-at") ==
               to_string(DateTime.to_unix(~U[2026-10-02 12:00:00Z], :millisecond))

      assert has_element?(view, "[data-voice-agent-strip]")
    end

    test "voice_turn_running?/2: running/compacting always, waiting only mid-turn" do
      running? = &OrcaHubWeb.SessionLive.Show.voice_turn_running?/2

      for backend <- ["claude", "pi", "codex", nil] do
        assert running?.(:running, backend)
        assert running?.(:compacting, backend)

        for status <- [:idle, :ready, :error] do
          refute running?.(status, backend)
        end
      end

      refute running?.(:waiting, "claude")
      # A missing backend means Claude, as everywhere else.
      refute running?.(:waiting, nil)
      assert running?.(:waiting, "pi")
    end

    test "voice_view_suppressed?/1 mirrors each surface's own render condition" do
      base = %{
        node_unavailable: nil,
        capabilities: %{plan_mode: true, ask_user_question: true},
        plan_mode: false,
        pending_ui_request: nil,
        status: :idle,
        aq_open: false,
        pending_questions: nil
      }

      sup? = &OrcaHubWeb.SessionLive.Show.voice_view_suppressed?/1

      refute sup?.(base)
      assert sup?.(%{base | node_unavailable: :node_unassigned})
      assert sup?.(%{base | plan_mode: :review})
      refute sup?.(%{base | plan_mode: :planning})
      assert sup?.(%{base | pending_ui_request: %{"id" => "r"}})

      asking = %{base | status: :waiting, aq_open: true, pending_questions: %{questions: []}}
      assert sup?.(asking)
      # The wizard only shows while waiting AND open: a stale pending question
      # with the modal closed is not on screen, so it hides nothing.
      refute sup?.(%{asking | aq_open: false})
      refute sup?.(%{asking | status: :running})

      # A backend without the capability never renders the surface at all.
      no_caps = %{base | capabilities: %{plan_mode: false, ask_user_question: false}}
      refute sup?.(%{no_caps | plan_mode: :review})
      refute sup?.(%{no_caps | pending_ui_request: %{"id" => "r"}})
    end
  end

  describe "the big Clear and Send (C2)" do
    test "both sit INSIDE the composer form, after the small Send", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      form = ~s(form[data-voice-composer-for="#{session.id}"])

      assert has_element?(
               view,
               ~s(#{form} button[data-voice-view-send][type="submit"][name="voice_dictated"][value="true"])
             )

      assert has_element?(view, ~s(#{form} button[data-voice-view-clear][type="button"]))

      # The bar hook's requestSubmit() target stays the ONE hidden submitter.
      html = render(view)
      assert html |> String.split("data-voice-dictated-submit") |> length() == 2
      refute view |> element("[data-voice-view-send]") |> render() =~ "data-voice-dictated-submit"

      # Form order: the small Send first (the default button), the big one after.
      [before_big | _] = String.split(html, "data-voice-view-send")
      assert before_big =~ ~r/<button[^>]*type="submit"[^>]*>\s*Send\s*<\/button>/
    end

    test "Clear asks the Voice hook to cancel, through the whitelisted window event", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      clear = view |> element("[data-voice-view-clear]") |> render()

      assert clear =~ "orca:voice-action"
      assert clear =~ "cancel"
    end

    test "Send submits as dictated: the agent gets the dictation note", %{
      conn: conn,
      session: session
    } do
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Same `:queue` observation point as show_test.exs's voice-submit test.
      {:ok, _} = Sessions.update_session(session, %{status: "running"})

      on_exit(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      end)

      view
      |> form(~s(form[data-voice-composer-for="#{session.id}"]), %{"prompt" => "poll the version"})
      |> put_submitter("button[data-voice-view-send]")
      |> render_submit()

      assert_push_event(view, "clear-prompt", %{})
      assert %{messages: [%{text: queued}]} = SessionHeartbeat.peek_message_queue(session.id)
      assert queued == Dictation.prefix("poll the version")
    end
  end
end
