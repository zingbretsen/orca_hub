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
      assert %{messages: ["check in on this"]} = SessionHeartbeat.peek_message_queue(session.id)
    end

    test "a second queued message accumulates rather than replacing the first", %{dir: dir} do
      {:ok, session} = running_session(dir)
      on_exit(fn -> stop_if_alive(session.id) end)

      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "first", :queue)
      assert {:queued, "running"} = Cluster.send_message(node(), session.id, "second", :queue)

      assert %{messages: ["first", "second"]} = SessionHeartbeat.peek_message_queue(session.id)
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
