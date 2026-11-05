defmodule OrcaHubWeb.QueueLiveTest do
  @moduledoc """
  Read-aloud (TTS) coverage for the queue page's side of the Option A
  convergence (tts_rewrite_spec.md §5): same delegated-hook contract as
  SessionLive.Show (explicit `%{message_id: ...}` push for autoplay, a
  localStorage init/persist round-trip for the toggle, and the ORCA_API_TOKEN
  delivered once over the connected socket) — see show_test.exs's identical
  "read-aloud (TTS) autoplay" describe block for the paired coverage.
  """

  # async: false — mirrors show_test.exs: PubSub/session-status plumbing
  # crosses process boundaries, and this is a shared dev-DB worktree.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Sessions

  defp new_dir do
    dir = Path.join(System.tmp_dir!(), "queue_tts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Forces `updated_at` far into the past so this fixture always sorts FIRST
  # (`list_idle_sessions_with_last_assistant_message/0` orders ascending —
  # oldest first) regardless of whatever real rows already exist in the
  # shared dev DB this repo's tests run against (see CLAUDE.md) — otherwise
  # `hd(entries)` after a reload could be any pre-existing session, not this
  # test's fixture.
  defp create_idle_session_with_reply(text) do
    {:ok, session} =
      Sessions.create_session(%{
        directory: new_dir(),
        status: "idle",
        runner_node: Atom.to_string(node())
      })

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })

    OrcaHub.Repo.update!(Ecto.Changeset.change(session, updated_at: ~N[2000-01-01 00:00:00]))
  end

  describe "read-aloud (TTS) autoplay" do
    test "pushes the new entry's session id when the queue goes from empty to non-empty with " <>
           "autoplay on",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      # Forces the "was empty" precondition regardless of whatever else is
      # sitting in the shared dev DB's queue right now (this repo runs tests
      # against the real dev DB — see CLAUDE.md) — the transition itself
      # isn't what changed here, only the payload of the resulting push.
      :sys.replace_state(view.pid, fn state -> put_in(state.socket.assigns.entries, []) end)

      render_hook(view, "tts_autoplay_init", %{"enabled" => true})

      session = create_idle_session_with_reply("hello there")
      session_id = session.id
      send(view.pid, {:status, :idle})

      # Status reloads are coalesced (@reload_debounce_ms).
      assert_push_event(view, "tts-autoplay", %{message_id: ^session_id}, 1_000)
    end

    test "pushes nothing when autoplay is off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      session = create_idle_session_with_reply("hello there")
      session_id = session.id
      send(view.pid, {:status, :idle})

      refute_push_event(view, "tts-autoplay", %{message_id: ^session_id}, 600)
    end

    test "tts_autoplay_init hydrates :tts_autoplay from the client's localStorage on connect", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/queue")
      refute :sys.get_state(view.pid).socket.assigns.tts_autoplay

      render_hook(view, "tts_autoplay_init", %{"enabled" => true})
      assert :sys.get_state(view.pid).socket.assigns.tts_autoplay
    end

    test "tts_stream_init is accepted here too, so the autoplay hydration before it survives", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/queue")

      # app.js's ttsMountShared pushes BOTH of these on mount, in this order,
      # from the SHARED TTSMethods — /queue hosts that mixin via the TTSFeed
      # hook even though the "Speak while streaming" toggle (C3) lives only on
      # the session page. With no clause for the second one the LiveView died
      # on every connect and took the first one's state with it.
      render_hook(view, "tts_autoplay_init", %{"enabled" => true})
      render_hook(view, "tts_stream_init", %{"enabled" => true})

      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.tts_autoplay
    end

    test "toggling autoplay pushes the new value back for localStorage persistence", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/queue")

      view |> element("button[phx-click='toggle_tts']") |> render_click()

      assert_push_event(view, "tts_autoplay_persisted", %{enabled: true})
    end

    test "the ORCA_API_TOKEN for /api/tts is pushed once connected, never rendered into the page",
         %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, "queue-tts-test-token")
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      {:ok, view, html} = live(conn, ~p"/queue")

      refute html =~ "queue-tts-test-token"
      assert_push_event(view, "tts-config", %{api_token: "queue-tts-test-token"})
    end
  end

  describe "loading cost" do
    alias OrcaHub.Repo
    alias OrcaHub.Sessions.Session
    import Ecto.Query

    # A waiting session whose pending AskUserQuestion sits behind `noise`
    # later messages, sorted to the queue front like the fixture above.
    defp create_waiting_session_with_question(header, noise) do
      {:ok, session} =
        Sessions.create_session(%{
          directory: new_dir(),
          status: "waiting",
          runner_node: Atom.to_string(node())
        })

      ask = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "aq-#{session.id}",
              "name" => "AskUserQuestion",
              "input" => %{
                "questions" => [
                  %{
                    "header" => header,
                    "question" => "Pick one",
                    "options" => [%{"label" => "A"}]
                  }
                ]
              }
            }
          ]
        }
      }

      {:ok, _} = Sessions.create_message(%{session_id: session.id, data: ask})

      for k <- 1..noise do
        {:ok, _} =
          Sessions.create_message(%{
            session_id: session.id,
            data: %{
              "type" => "assistant",
              "message" => %{"content" => [%{"type" => "text", "text" => "noise #{k}"}]}
            }
          })
      end

      Repo.update!(Ecto.Changeset.change(session, updated_at: ~N[2000-01-01 00:00:00]))
    end

    # Forwards the LiveView process's own queries to the test process.
    defp forward_view_queries(view) do
      test_pid = self()
      lv_pid = view.pid
      handler_id = "queue-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:orca_hub, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == lv_pid, do: send(test_pid, {:lv_query, metadata.query, metadata.params})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp drain_view_queries(acc \\ []) do
      receive do
        {:lv_query, query, params} -> drain_view_queries([{query, params} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp queue_list_queries(queries), do: Enum.count(queries, fn {q, _} -> q =~ "LATERAL" end)

    # The targeted AskUserQuestion lookup for one session (its tool_use
    # query plus, when found, the answered check).
    defp aq_lookups(queries, session_id) do
      id = Ecto.UUID.dump!(session_id)
      Enum.count(queries, fn {q, params} -> q =~ "jsonb_array_elements" and id in params end)
    end

    test "a pending AskUserQuestion renders from the targeted lookup, cached until its " <>
           "session's status changes",
         %{conn: conn} do
      session = create_waiting_session_with_question("Which approach?", 30)

      {:ok, view, html} = live(conn, ~p"/queue")
      assert html =~ "Which approach?"
      forward_view_queries(view)

      # Another session's change: the queue reloads, our question is reused.
      send(view.pid, {Ecto.UUID.generate(), {:status, :idle}})
      Process.sleep(400)
      assert render(view) =~ "Which approach?"
      queries = drain_view_queries()
      assert queue_list_queries(queries) == 1
      assert aq_lookups(queries, session.id) == 0

      # Its own change: looked up again, once.
      send(view.pid, {:status, :waiting})
      send(view.pid, {session.id, {:status, :waiting}})
      Process.sleep(400)
      assert render(view) =~ "Which approach?"
      queries = drain_view_queries()
      assert queue_list_queries(queries) == 1
      assert aq_lookups(queries, session.id) in 1..2
    end

    test "a burst of status broadcasts reloads the queue once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")
      forward_view_queries(view)

      for _ <- 1..5 do
        id = Ecto.UUID.generate()
        send(view.pid, {:status, :idle})
        send(view.pid, {id, {:status, :idle}})
      end

      # Agent events and non-queue statuses never reload.
      send(view.pid, {Ecto.UUID.generate(), {:status, :running}})
      send(view.pid, {Ecto.UUID.generate(), {:event, %{"type" => "assistant"}}})

      Process.sleep(400)
      render(view)
      assert queue_list_queries(drain_view_queries()) == 1
    end

    test "the dead render does not write the priority reset; the connected mount does", %{
      conn: conn
    } do
      # Every idle session deferred: the reset would move the front to 0.
      from(s in Session, where: is_nil(s.archived_at) and s.status == "idle")
      |> Repo.update_all(inc: [priority: 1])

      create_idle_session_with_reply("deferred")
      |> Ecto.Changeset.change(priority: 1)
      |> Repo.update!()

      min_idle_priority = fn ->
        Repo.one(
          from s in Session,
            where: is_nil(s.archived_at) and s.status == "idle",
            select: min(s.priority)
        )
      end

      assert min_idle_priority.() >= 1

      conn |> get(~p"/queue") |> html_response(200)
      assert min_idle_priority.() >= 1

      {:ok, _view, _html} = live(conn, ~p"/queue")
      assert min_idle_priority.() == 0
    end
  end
end
