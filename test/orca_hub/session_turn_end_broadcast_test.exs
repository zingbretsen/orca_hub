defmodule OrcaHub.SessionTurnEndBroadcastTest do
  @moduledoc """
  The hub-side half of orca-watch DESIGN.md D6: a genuine SessionRunner
  `running -> idle|error` transition ALWAYS broadcasts a `turn_end` event on
  the `session_events` channel — independent of `ORCA_NOTIFY_ON_FINISH`,
  which now gates only the Gotify wire.

  Asserted here rather than in `SessionEventsChannelTest` because the
  interesting part is the RUNNER's transition, not the socket: these tests
  drive `SessionRunner.running/3` directly against a DB-backed session (no
  live port), the same pattern `SessionFinishNotificationTest` uses, and
  subscribe to the endpoint topic the channel forwards from.

  Both wires share ONE suppression predicate
  (`SessionRunner.turn_end_push_eligible?/2`), so the child /
  memory_extraction / archived cases below are also what keeps the Gotify
  path from drifting away from the channel path.
  """
  # async: false — the delivery runs on a TaskSupervisor child (shared
  # sandbox), and the Gotify + notify-on-finish seams are global app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, Sessions}

  @endpoint OrcaHubWeb.Endpoint
  @stub OrcaHub.SessionTurnEndBroadcastStub

  setup do
    # Gotify is configured but OFF by default here: the channel broadcast
    # must fire anyway, which is the whole point of D6.
    Application.delete_env(:orca_hub, :notify_on_finish)
    Application.put_env(:orca_hub, :gotify_token, "test-token")
    Application.put_env(:orca_hub, :gotify_url, "https://gotify.example.com")
    Application.put_env(:orca_hub, :gotify_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:orca_hub, :gotify_token)
      Application.delete_env(:orca_hub, :gotify_url)
      Application.delete_env(:orca_hub, :gotify_req_options)
      Application.delete_env(:orca_hub, :notify_on_finish)
    end)

    Req.Test.set_req_test_to_shared()
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:gotify, Jason.decode!(raw)})
      Req.Test.json(conn, %{"id" => 1})
    end)

    dir = Path.join(System.tmp_dir!(), "turn_end_bcast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    @endpoint.subscribe("session_events:all")

    {:ok, dir: dir}
  end

  defp base_data(session, overrides) do
    Map.merge(
      %{
        session_id: session.id,
        directory: session.directory,
        port: :fake_port,
        engine: :one_shot,
        pending_prompts: [],
        pending_questions: nil,
        buffer: "",
        error_output: "",
        messages: [],
        first_prompt: "hi"
      },
      overrides
    )
  end

  defp assistant_message(session_id, text) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })
  end

  defp finish(session, data \\ %{}, exit_status \\ 0) do
    SessionRunner.running(
      :info,
      {:fake_port, {:exit_status, exit_status}},
      base_data(session, data)
    )
  end

  defp refute_turn_end do
    refute_receive %Phoenix.Socket.Broadcast{event: "turn_end"}, 400
  end

  defp refute_gotify do
    refute_receive {:gotify, _}, 400
  end

  describe "running -> idle" do
    test "broadcasts turn_end with the five contract fields", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "All three migrations applied cleanly.")

      assert {:next_state, :idle, _} = finish(session)

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", payload: payload}, 2000

      assert %{
               session_id: session_id,
               session_title: "the worker",
               status: "idle",
               excerpt: "All three migrations applied cleanly.",
               occurred_at: occurred_at
             } = payload

      assert session_id == session.id
      assert {:ok, _, _} = DateTime.from_iso8601(occurred_at)
    end

    test "also broadcasts on the per-session topic", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      @endpoint.subscribe("session_events:#{session.id}")
      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} = finish(session)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "session_events:" <> topic_id,
                       event: "turn_end"
                     },
                     2000

      # Both topics carry it; at least one of the two received here is the
      # per-session one.
      assert topic_id in ["all", session.id]

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", topic: other_topic}, 2000
      assert other_topic != "session_events:" <> topic_id
    end

    test "fires with ORCA_NOTIFY_ON_FINISH unset — and sends no Gotify", %{dir: dir} do
      refute SessionRunner.finish_notifications_enabled?()

      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "quiet"})

      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} = finish(session)

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end"}, 2000
      refute_gotify()
    end

    test "with the flag ON, both wires fire and carry the same excerpt", %{dir: dir} do
      Application.put_env(:orca_hub, :notify_on_finish, true)

      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "Shipped it.")

      assert {:next_state, :idle, _} = finish(session)

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", payload: payload}, 2000
      assert_receive {:gotify, body}, 2000

      assert body["extras"]["orca"]["excerpt"] == payload.excerpt
      assert body["extras"]["orca"]["session_id"] == payload.session_id
      assert body["extras"]["orca"]["session_title"] == payload.session_title
      assert body["extras"]["orca"]["status"] == payload.status
    end

    test "an untitled session falls back to a truncation of the first prompt", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir, status: "running"})
      assistant_message(session.id, "ok")

      assert {:next_state, :idle, _} =
               finish(session, %{first_prompt: "Fix the flaky triggers test\nand report back"})

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", payload: payload}, 2000
      assert payload.session_title == "Fix the flaky triggers test"
    end

    test "a turn with no assistant text carries an empty excerpt, never nil", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "silent"})

      assert {:next_state, :idle, _} = finish(session)

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", payload: payload}, 2000
      assert payload.excerpt == ""
    end
  end

  describe "running -> error" do
    test "broadcasts status \"error\"", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "Attempting the migration…")

      assert {:next_state, :error, _} =
               finish(session, %{error_output: "boom: something broke\n"}, 1)

      assert_receive %Phoenix.Socket.Broadcast{event: "turn_end", payload: payload}, 2000
      assert payload.status == "error"
      assert payload.excerpt == "Attempting the migration…"
    end
  end

  describe "suppression — one predicate, both wires" do
    test "a child session never broadcasts", %{dir: dir} do
      {:ok, parent} =
        Sessions.create_session(%{directory: dir, status: "idle", title: "the orchestrator"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "worker 7",
          parent_session_id: parent.id
        })

      assistant_message(session.id, "migration written")

      assert {:next_state, :idle, _} = finish(session)

      refute_turn_end()
    end

    test "a memory_extraction session never broadcasts", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "memory extraction",
          kind: "memory_extraction"
        })

      assistant_message(session.id, "extracted two memories")

      assert {:next_state, :idle, _} = finish(session)

      refute_turn_end()
    end

    test "an archived session never broadcasts", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "archived one"})

      {:ok, _} = Sessions.archive_session(session, extract_memories: false)
      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} = finish(session)

      refute_turn_end()
    end

    test "an unanswered AskUserQuestion (\"waiting\") is not a turn end", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "asking"})

      assistant_message(session.id, "which one?")

      assert {:next_state, :idle, _} =
               finish(session, %{pending_questions: [%{"question" => "which?"}]})

      refute_turn_end()
    end
  end

  describe "turn_end_push_eligible?/2" do
    test "is the single predicate both wires consult" do
      root = %{id: "a", kind: nil, parent_session_id: nil, archived_at: nil}

      assert SessionRunner.turn_end_push_eligible?(root, :idle)
      assert SessionRunner.turn_end_push_eligible?(root, :error)
      refute SessionRunner.turn_end_push_eligible?(root, nil)

      refute SessionRunner.turn_end_push_eligible?(%{root | kind: "memory_extraction"}, :idle)
      refute SessionRunner.turn_end_push_eligible?(%{root | parent_session_id: "b"}, :idle)

      refute SessionRunner.turn_end_push_eligible?(
               %{root | archived_at: DateTime.utc_now()},
               :idle
             )

      # A self-referential parent_session_id is a root, not a child.
      assert SessionRunner.turn_end_push_eligible?(%{root | parent_session_id: "a"}, :idle)
    end
  end
end
