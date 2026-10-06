defmodule OrcaHub.SessionHeartbeatMessageQueueTest do
  @moduledoc """
  Coverage for ORCAHUB3-29's `:queue` delivery mode: `Cluster.send_message/4`
  routes `:queue` deliveries through `SessionHeartbeat.deliver_or_queue/2`,
  which never interrupts a running turn. A message queued behind a busy
  turn is held (accumulating, not replacing, across multiple sends) and
  flushed — annotated with WHY it arrived late — once the turn ends, or
  escalated to a forced `:interrupt` delivery if the turn never ends within
  `@queue_escalate_ms` (the item-2 escape hatch: a queued message must not
  be lost behind a hung turn).

  Drives the real `OrcaHub.SessionHeartbeat` singleton GenServer end to end,
  same pattern as `SessionHeartbeatDeliveryTest` (real status broadcasts via
  `SessionRunner.running/3` called directly, no live GenStatem process
  needed for the flush half of these tests).
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Cluster, SessionHeartbeat, SessionRunner, Sessions, SessionSupervisor}

  @claude_stub Path.expand("support/fixtures/claude_stub_noop.sh", __DIR__ <> "/..")
  @pi_stub Path.expand("support/fixtures/pi_stub_rpc.py", __DIR__ <> "/..")

  setup do
    Application.put_env(:orca_hub, :claude_executable, @claude_stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "msg-queue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.stop_session(session_id)
    end
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

  defp message_text(message) do
    get_in(message.data, ["message", "content", Access.at(0), "text"])
  end

  defp wait_for_message(session_id, pattern, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_message(session_id, pattern, deadline)
  end

  defp poll_for_message(session_id, pattern, deadline) do
    match =
      session_id
      |> Sessions.list_messages()
      |> Enum.find(fn m -> (message_text(m) || "") =~ pattern end)

    cond do
      match ->
        match

      System.monotonic_time(:millisecond) > deadline ->
        nil

      true ->
        Process.sleep(25)
        poll_for_message(session_id, pattern, deadline)
    end
  end

  defp running_session(dir, overrides \\ %{}) do
    Sessions.create_session(
      Map.merge(
        %{directory: dir, status: "running", runner_node: Atom.to_string(node())},
        overrides
      )
    )
  end

  describe "Cluster.send_message/4 :queue while the session is running" do
    test "queues (does not deliver, does not touch the runner) rather than interrupting", %{
      dir: dir
    } do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} =
               Cluster.send_message(node(), session.id, "check in on this", :queue)

      assert Sessions.list_messages(session.id) == []
      refute SessionSupervisor.session_alive?(session.id)

      assert %{messages: [%{text: "check in on this"}]} =
               SessionHeartbeat.peek_message_queue(session.id)
    end

    test "a second queued message accumulates rather than replacing the first", %{dir: dir} do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "first", :queue)
      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "second", :queue)

      assert %{messages: [%{text: "first"}, %{text: "second"}]} =
               SessionHeartbeat.peek_message_queue(session.id)
    end

    test "delivers the combined, annotated batch once the turn ends", %{dir: dir} do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "first", :queue)
      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "second", :queue)

      data = base_data(session, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      message = wait_for_message(session.id, ~r/second/)
      refute is_nil(message), "expected the queued batch to be delivered at turn end"

      text = message_text(message)
      assert text =~ "queued delivery"
      assert text =~ "\"running\""
      assert text =~ "first"
      assert text =~ "second"

      assert SessionHeartbeat.peek_message_queue(session.id) == nil
    end

    test "escalates to a forced :interrupt delivery when the turn does not end in time", %{
      dir: dir
    } do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} =
               Cluster.send_message(node(), session.id, "are you stuck?", :queue)

      assert %{escalate_ref: ref} = SessionHeartbeat.peek_message_queue(session.id)

      # Simulate the escalation timer firing early instead of waiting out the
      # real @queue_escalate_ms — same "send the internal message directly"
      # pattern SessionHeartbeatDeliveryTest's fire_now/1 uses for heartbeats.
      send(SessionHeartbeat, {:queue_escalate, session.id, ref})

      message = wait_for_message(session.id, ~r/are you stuck/)
      refute is_nil(message), "expected the escalated batch to be force-delivered"

      text = message_text(message)
      assert text =~ "escalated"
      assert text =~ "did not end"

      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      # The escalation itself went through :interrupt delivery — since no
      # runner was ever alive, that means one got cold-started to receive it.
      assert SessionSupervisor.session_alive?(session.id)
    end

    test "a stale escalation ref (already flushed normally) is a no-op", %{dir: dir} do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "hello", :queue)
      assert %{escalate_ref: stale_ref} = SessionHeartbeat.peek_message_queue(session.id)

      data = base_data(session, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      assert wait_for_message(session.id, ~r/hello/)
      assert SessionHeartbeat.peek_message_queue(session.id) == nil

      # The real timer already fired-and-noop'd or is still pending — either
      # way, delivering it manually now must not re-deliver/crash. `send/2`
      # followed by any synchronous call to the same named process (from this
      # same test process) guarantees the escalate message is processed
      # first, since Erlang preserves per-sender/per-receiver message order.
      send(SessionHeartbeat, {:queue_escalate, session.id, stale_ref})
      SessionHeartbeat.peek_message_queue(session.id)

      delivered =
        session.id
        |> Sessions.list_messages()
        |> Enum.filter(fn m -> (message_text(m) || "") =~ "hello" end)

      assert length(delivered) == 1
    end
  end

  describe "Cluster.send_message/4 :queue when immediately deliverable" do
    test "delivers immediately, unqueued, when the session isn't mid-turn", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          status: "idle",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)

      assert :ok = Cluster.send_message(node(), session.id, "hi", :queue)
      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      refute is_nil(wait_for_message(session.id, ~r/hi/))
    end

    test "delivers immediately (auto-unarchive) even though the stored status looks mid-turn", %{
      dir: dir
    } do
      {:ok, session} = running_session(dir)
      {:ok, session} = Sessions.archive_session(session)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert :ok = Cluster.send_message(node(), session.id, "still there?", :queue)
      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      refute is_nil(wait_for_message(session.id, ~r/still there/))
    end

    test "delivers immediately (never queues) when the target backend advertises steering", %{
      dir: dir
    } do
      refute is_nil(System.find_executable("python3")),
             "python3 not found — required to run the pi --mode rpc stub fixture"

      Application.put_env(:orca_hub, :pi_executable, @pi_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)

      {:ok, session} = running_session(dir, %{backend: "pi"})
      on_exit(fn -> stop_if_alive(session.id) end)

      assert :ok = Cluster.send_message(node(), session.id, "steer this in", :queue)
      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      # Immediate (non-queued) delivery to a not-yet-alive target cold-starts it.
      assert SessionSupervisor.session_alive?(session.id)
    end
  end

  describe "session archived/deleted while a message is queued" do
    test "drops the queued entry and cancels its escalation timer", %{dir: dir} do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "hello?", :queue)
      assert %{} = SessionHeartbeat.peek_message_queue(session.id)

      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})

      assert wait_until(fn -> SessionHeartbeat.peek_message_queue(session.id) == nil end),
             "expected the queued entry to be dropped once the session archived"
    end
  end

  # ORCAHUB3-139: the session page lists queued messages one row each, with a
  # Remove and a Send now per row.
  describe "per-item queue controls (ORCAHUB3-139)" do
    setup %{dir: dir} do
      {:ok, session} = running_session(dir, %{backend: "claude"})
      on_exit(fn -> stop_if_alive(session.id) end)

      # Archiving drops the queue and its timer (see the archive describe).
      on_exit(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      end)

      {:ok, session: session}
    end

    defp queue!(session, texts) do
      for text <- texts do
        assert {:queued, "running"} = Cluster.send_message(node(), session.id, text, :queue)
      end

      SessionHeartbeat.list_queued_messages(session.id)
    end

    defp texts(items), do: Enum.map(items, & &1.text)

    test "each message is its own item, listed oldest first", %{session: session} do
      assert SessionHeartbeat.list_queued_messages(session.id) == []

      items = queue!(session, ["first", "second", "third"])

      assert texts(items) == ["first", "second", "third"]
      assert Enum.all?(items, &(is_binary(&1.id) and match?(%DateTime{}, &1.queued_at)))
      assert items |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
      assert Enum.all?(items, &(&1 |> Map.keys() |> Enum.sort() == [:id, :queued_at, :text]))

      # The batch-level view (get_session_tail's queued_messages) still counts.
      assert %{count: 3} = SessionHeartbeat.queued_message_state(session.id)
    end

    test "remove drops only that item and leaves the escalation anchor alone", %{
      session: session
    } do
      [first, second, third] = queue!(session, ["first", "second", "third"])
      %{escalate_ref: ref, queued_at: anchor} = SessionHeartbeat.peek_message_queue(session.id)

      assert :ok = SessionHeartbeat.remove_queued_message(session.id, second.id)

      assert SessionHeartbeat.list_queued_messages(session.id) == [first, third]

      assert %{escalate_ref: ^ref, queued_at: ^anchor} =
               SessionHeartbeat.peek_message_queue(session.id)
    end

    test "removing the oldest re-anchors the escalation on the new oldest", %{session: session} do
      [first, second] = queue!(session, ["first", "second"])
      %{escalate_ref: old_ref} = SessionHeartbeat.peek_message_queue(session.id)

      assert :ok = SessionHeartbeat.remove_queued_message(session.id, first.id)

      assert %{escalate_ref: new_ref, queued_at: anchor, messages: [^second]} =
               SessionHeartbeat.peek_message_queue(session.id)

      assert anchor == second.queued_at
      refute new_ref == old_ref

      # The superseded timer's message is a no-op: nothing is delivered and
      # the remaining message stays queued.
      send(SessionHeartbeat, {:queue_escalate, session.id, old_ref})
      assert SessionHeartbeat.list_queued_messages(session.id) == [second]
      assert Sessions.list_messages(session.id) == []
    end

    test "removing the last item deletes the batch and cancels its timer", %{session: session} do
      [only] = queue!(session, ["only one"])
      %{escalate_timer: timer} = SessionHeartbeat.peek_message_queue(session.id)
      assert is_integer(Process.read_timer(timer))

      assert :ok = SessionHeartbeat.remove_queued_message(session.id, only.id)

      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      assert SessionHeartbeat.list_queued_messages(session.id) == []
      assert SessionHeartbeat.queued_message_state(session.id) == nil
      assert Process.read_timer(timer) == false
    end

    test "send now delivers only that item, unannotated, and keeps the rest queued", %{
      session: session
    } do
      [first, second, third] = queue!(session, ["first msg", "second msg", "third msg"])

      assert :ok = SessionHeartbeat.send_queued_message_now(session.id, second.id)

      message = wait_for_message(session.id, ~r/second msg/)
      refute is_nil(message), "expected the sent-now message to be delivered"
      # A plain send: the user chose to send it now, so no late-delivery note.
      assert message_text(message) == "second msg"

      assert SessionHeartbeat.list_queued_messages(session.id) == [first, third]

      delivered = session.id |> Sessions.list_messages() |> Enum.map(&message_text/1)
      refute Enum.any?(delivered, &(&1 =~ "first msg" or &1 =~ "third msg"))
    end

    test "an id that already left the queue is :not_found for remove and send now", %{
      session: session
    } do
      [item] = queue!(session, ["flushed before the click"])

      # The turn ends first: the flush takes the whole queue.
      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      assert wait_for_message(session.id, ~r/flushed before the click/)
      assert SessionHeartbeat.peek_message_queue(session.id) == nil

      assert {:error, :not_found} = SessionHeartbeat.remove_queued_message(session.id, item.id)
      assert {:error, :not_found} = SessionHeartbeat.send_queued_message_now(session.id, item.id)

      # Exactly one delivery: the late click did not send it again.
      delivered =
        session.id
        |> Sessions.list_messages()
        |> Enum.filter(&((message_text(&1) || "") =~ "flushed before the click"))

      assert length(delivered) == 1
    end

    test "an unknown id is :not_found, with or without a queue", %{session: session} do
      assert {:error, :not_found} = SessionHeartbeat.remove_queued_message(session.id, "nope")
      assert {:error, :not_found} = SessionHeartbeat.send_queued_message_now(session.id, "nope")

      queue!(session, ["something"])
      assert {:error, :not_found} = SessionHeartbeat.remove_queued_message(session.id, "nope")
      assert {:error, :not_found} = SessionHeartbeat.send_queued_message_now(session.id, "nope")
      assert [%{text: "something"}] = SessionHeartbeat.list_queued_messages(session.id)
    end

    test "every change is broadcast on the session topic as {:message_queue, items}", %{
      session: session
    } do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")

      assert {:queued, _} = Cluster.send_message(node(), session.id, "msg-one", :queue)
      assert_receive {:message_queue, [%{text: "msg-one", id: one_id}]}

      assert {:queued, _} = Cluster.send_message(node(), session.id, "msg-two", :queue)
      assert_receive {:message_queue, [%{text: "msg-one"}, %{text: "msg-two"}]}

      assert {:queued, _} = Cluster.send_message(node(), session.id, "msg-three", :queue)
      assert_receive {:message_queue, [_, _, %{text: "msg-three"}]}

      assert :ok = SessionHeartbeat.remove_queued_message(session.id, one_id)
      assert_receive {:message_queue, [%{text: "msg-two"}, %{text: "msg-three"}] = items}

      # Same shape as list_queued_messages/1.
      assert items == SessionHeartbeat.list_queued_messages(session.id)

      # Turn end (where Stop lands too): everything still queued is flushed
      # as one message, and the list empties.
      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      assert_receive {:message_queue, []}

      message = wait_for_message(session.id, ~r/msg-three/)
      assert message_text(message) =~ "msg-two"
      assert message_text(message) =~ "queued delivery"
      refute message_text(message) =~ "msg-one"
    end

    test "send now broadcasts the remaining items", %{session: session} do
      [first, second] = queue!(session, ["first", "second"])
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")

      assert :ok = SessionHeartbeat.send_queued_message_now(session.id, first.id)
      assert_receive {:message_queue, [^second]}
    end

    test "escalation and archive both broadcast the emptied queue", %{session: session} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")

      queue!(session, ["stuck?"])
      assert_receive {:message_queue, [_]}
      %{escalate_ref: ref} = SessionHeartbeat.peek_message_queue(session.id)
      send(SessionHeartbeat, {:queue_escalate, session.id, ref})
      assert_receive {:message_queue, []}

      {:ok, _} = Sessions.update_session(Sessions.get_session!(session.id), %{status: "running"})
      queue!(session, ["archive me"])
      assert_receive {:message_queue, [%{text: "archive me"}]}

      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      assert_receive {:message_queue, []}
    end
  end

  # A hot code load swaps SessionHeartbeat's code but keeps its state, so a
  # batch queued by the pre-ORCAHUB3-139 code (plain-string messages, no
  # escalate_timer) meets the new code. It must be upgraded, not crashed on:
  # a crash restarts the singleton and loses every session's heartbeats.
  describe "a batch queued before ORCAHUB3-139 (hot-load leftover)" do
    setup %{dir: dir} do
      {:ok, session} = running_session(dir, %{backend: "claude"})
      on_exit(fn -> stop_if_alive(session.id) end)

      on_exit(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      end)

      legacy = %{
        messages: ["legacy one", "legacy two"],
        queued_status: "running",
        queued_at: DateTime.utc_now(),
        escalate_ref: make_ref()
      }

      :sys.replace_state(SessionHeartbeat, fn state ->
        put_in(state, [:message_queue, session.id], legacy)
      end)

      {:ok, session: session, legacy: legacy, pid: Process.whereis(SessionHeartbeat)}
    end

    test "is listed with stable ids, and remove/enqueue work on it", %{
      session: session,
      pid: pid
    } do
      assert [%{text: "legacy one", id: id1}, %{text: "legacy two", id: id2}] =
               SessionHeartbeat.list_queued_messages(session.id)

      assert [%{id: ^id1}, %{id: ^id2}] = SessionHeartbeat.list_queued_messages(session.id)

      assert :ok = SessionHeartbeat.remove_queued_message(session.id, id1)
      assert {:queued, _} = Cluster.send_message(node(), session.id, "new one", :queue)

      assert [%{text: "legacy two"}, %{text: "new one"}] =
               SessionHeartbeat.list_queued_messages(session.id)

      assert Process.whereis(SessionHeartbeat) == pid
    end

    test "still flushes at turn end and escalates", %{
      session: session,
      legacy: legacy,
      pid: pid
    } do
      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      message = wait_for_message(session.id, ~r/legacy two/)
      refute is_nil(message), "expected the legacy batch to flush at turn end"
      assert message_text(message) =~ "legacy one"
      assert SessionHeartbeat.peek_message_queue(session.id) == nil

      # And an untouched one whose old timer fires.
      :sys.replace_state(SessionHeartbeat, fn state ->
        put_in(state, [:message_queue, session.id], %{legacy | messages: ["legacy escalated"]})
      end)

      send(SessionHeartbeat, {:queue_escalate, session.id, legacy.escalate_ref})
      refute is_nil(wait_for_message(session.id, ~r/legacy escalated/))
      assert SessionHeartbeat.peek_message_queue(session.id) == nil
      assert Process.whereis(SessionHeartbeat) == pid
    end
  end

  # ORCAHUB3-139: Send now relies on the runner starting the next turn
  # WITHOUT a turn-end status broadcast, so the remaining items wait for that
  # next turn's end instead of flushing the moment the interrupt lands.
  describe "send now mid-turn does not flush the rest early (ORCAHUB3-139)" do
    test "streaming: the interrupt's result starts the sent message's turn with no status broadcast",
         %{dir: dir} do
      {:ok, session} = running_session(dir, %{backend: "claude"})

      on_exit(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      end)

      # What Send now left behind: "send me now" already went to the runner.
      [rest] = queue!(session, ["wait for the next turn"])
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")

      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      # The runner's state right after running/3's streaming send_message
      # clause handled the Send now: the prompt is pending and a control
      # interrupt is in flight.
      data = %{
        session_id: session.id,
        directory: session.directory,
        port: port,
        framing: :ndjson,
        backend: OrcaHub.Backend.Claude,
        engine: :streaming,
        buffer: "",
        error_output: "",
        messages: [],
        first_prompt: "hi",
        claude_session_id: Ecto.UUID.generate(),
        warming_up: false,
        turn_result: nil,
        interrupting: true,
        pending_rebake: false,
        downgrade_pending: false,
        pending_prompts: ["send me now"],
        pending_questions: nil,
        backend_state: %{},
        turn_started_at: DateTime.utc_now()
      }

      result_frame =
        Jason.encode!(%{"type" => "result", "subtype" => "error_during_execution"}) <> "\n"

      assert {:keep_state, new_data} =
               SessionRunner.running(:info, {port, {:data, result_frame}}, data)

      # The sent message went to the CLI as the next turn...
      assert new_data.pending_prompts == []
      assert_receive {^port, {:data, written}}, 1000
      assert written =~ "send me now"

      # ...and nothing told SessionHeartbeat the turn ended.
      session_id = session.id
      refute_receive {^session_id, {:status, _}}, 200
      assert SessionHeartbeat.list_queued_messages(session.id) == [rest]
    end

    test "one-shot: the interrupted CLI's exit auto-resumes with the sent message, no status broadcast",
         %{dir: dir} do
      {:ok, session} = running_session(dir, %{backend: "claude", streaming: false})
      on_exit(fn -> stop_if_alive(session.id) end)

      on_exit(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      end)

      [first, second, third] = queue!(session, ["first turn", "sent mid-turn", "left queued"])

      # No runner yet: this one cold-starts it into an ordinary one-shot turn
      # (the stub CLI blocks on stdin until it is signalled).
      assert :ok = SessionHeartbeat.send_queued_message_now(session.id, first.id)

      assert wait_until(fn ->
               match?({:running, %{port: p}} when is_port(p), runner_state(session))
             end)

      {:running, %{port: first_port}} = runner_state(session)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")

      # Mid-turn: SIGINT, and the exit auto-resumes with the sent message.
      assert :ok = SessionHeartbeat.send_queued_message_now(session.id, second.id)

      assert wait_until(fn ->
               match?(
                 {:running, %{port: p, pending_prompts: []}} when is_port(p) and p != first_port,
                 runner_state(session)
               )
             end),
             "expected the runner to auto-resume on a fresh port with the sent message"

      session_id = session.id
      refute_receive {^session_id, {:status, _}}, 200
      assert SessionHeartbeat.list_queued_messages(session.id) == [third]
    end
  end

  defp runner_state(session), do: :sys.get_state(SessionRunner.via(session.id))

  defp wait_until(fun, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        poll_until(fun, deadline)
    end
  end
end
