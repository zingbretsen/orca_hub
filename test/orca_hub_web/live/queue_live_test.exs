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

      assert_push_event(view, "tts-autoplay", %{message_id: ^session_id})
    end

    test "pushes nothing when autoplay is off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/queue")

      session = create_idle_session_with_reply("hello there")
      session_id = session.id
      send(view.pid, {:status, :idle})

      refute_push_event(view, "tts-autoplay", %{message_id: ^session_id})
    end

    test "tts_autoplay_init hydrates :tts_autoplay from the client's localStorage on connect", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/queue")
      refute :sys.get_state(view.pid).socket.assigns.tts_autoplay

      render_hook(view, "tts_autoplay_init", %{"enabled" => true})
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
end
