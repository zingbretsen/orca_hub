defmodule OrcaHub.Backend.PiStubIntegrationTest do
  @moduledoc """
  Strongest guard for the pi adapter (backend_abstraction_spec.md §9/§12.2):
  a REAL `OrcaHub.SessionRunner` (full GenStatem, DB writes, PubSub, the
  actual `Backend.Pi` module) driven end-to-end against
  `test/support/fixtures/pi_stub_rpc.py` — a stand-in process that speaks
  just enough of the `pi --mode rpc` wire protocol on stdio. No network, no
  real `pi` binary required.

  Exercises the full cold-open path: `on_open/1` writes `get_state` ->
  `encode_user_turn/2` writes `prompt` immediately (no handshake FSM, unlike
  Codex) -> the stub's `agent_start`/`message_end`{toolCall
  bash}/`tool_execution_end`/`message_end`{text}/`agent_end` sequence ->
  normalized into a `system`/init event (from the get_state response),
  `assistant` text/tool_use, `user` tool_result, and a synthesized `result`
  with summed usage/cost — the runner transitions :running -> :idle exactly
  as it does for Claude and Codex.
  """

  # async: false — starts a real SessionRunner (GenStatem) child under the
  # shared OrcaHub.SessionSupervisor, which needs the DB sandbox in SHARED
  # mode to read the session back in init/1 (see codex_stub_integration_test.exs
  # / index_test.exs for the same pattern). Also flips the global
  # `:orca_hub, :pi_executable` app-env seam for the duration.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, SessionSupervisor, Sessions}

  @stub_script Path.expand("../../support/fixtures/pi_stub_rpc.py", __DIR__)

  setup do
    refute is_nil(System.find_executable("python3")),
           "python3 not found — required to run the pi --mode rpc stub fixture"

    Application.put_env(:orca_hub, :pi_executable, @stub_script)
    on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)

    dir = Path.join(System.tmp_dir!(), "pi_stub_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "pi",
        model: nil,
        code_exec: false,
        orchestrator: false
      })

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id) do
        SessionSupervisor.stop_session(session.id)
      end
    end)

    {:ok, session: session}
  end

  test "a real SessionRunner drives a full turn end-to-end against the stub pi agent", %{
    session: session
  } do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    state = wait_until_terminal(session.id)

    assert state.status == :idle
    assert state.claude_session_id == "stub-pi-session-1"

    types = Enum.map(state.messages, & &1["type"])
    assert "user" in types
    assert "system" in types
    assert "assistant" in types
    assert "result" in types

    system_event = Enum.find(state.messages, &(&1["type"] == "system"))
    assert system_event["session_id"] == "stub-pi-session-1"
    assert system_event["subtype"] == "init"

    tool_uses = tool_blocks(state.messages, "assistant", "tool_use")
    bash_use = Enum.find(tool_uses, &(&1["name"] == "Bash"))
    assert bash_use["id"] == "call-stub-1"
    assert bash_use["input"] == %{"command" => "echo hello"}

    # §3.3 invariant: the tool_result's tool_use_id echoes the tool_use's id.
    tool_results = tool_blocks(state.messages, "user", "tool_result")
    bash_result = Enum.find(tool_results, &(&1["tool_use_id"] == "call-stub-1"))
    assert bash_result["content"] == [%{"type" => "text", "text" => "hello\n"}]
    assert bash_result["is_error"] == false

    texts =
      state.messages
      |> Enum.filter(&(&1["type"] == "assistant"))
      |> Enum.flat_map(&get_in(&1, ["message", "content"]))
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    assert "Hello from the stub pi agent!" in texts

    result_event = Enum.find(state.messages, &(&1["type"] == "result"))
    assert result_event["is_error"] == false

    assert result_event["usage"] == %{
             "input_tokens" => 130,
             "output_tokens" => 32,
             "cache_read_input_tokens" => 0
           }

    assert_in_delta result_event["total_cost_usd"], 0.00015, 0.0000001
    assert is_integer(result_event["duration_ms"])

    # The --append-system-prompt flag carries the system prompt at spawn time
    # (spec's :flag system_prompt kind) — NOT prepended to the turn text, so
    # the STORED "user" event is the prompt exactly as typed (unlike Codex's
    # :leading_message kind).
    user_event = Enum.find(state.messages, &(&1["type"] == "user"))
    assert get_in(user_event, ["message", "content", Access.at(0), "text"]) == "say hi"
  end

  # spec §12.6 — mid-turn steering, queue_update, and compaction events, all
  # exercised end-to-end through a REAL SessionRunner (not just the pi.ex
  # normalize unit tests). The stub's "PAUSE_FOR_STEER" prompt pauses after
  # agent_start (simulating a still-running turn) so the runner's :running
  # send_message clause has something to steer against.
  test "a mid-turn send_message STEERS the running turn instead of interrupting it", %{
    session: session
  } do
    log_path = Path.join(System.tmp_dir!(), "pi_stub_log_#{System.unique_integer([:positive])}")
    System.put_env("PI_STUB_LOG", log_path)

    on_exit(fn ->
      System.delete_env("PI_STUB_LOG")
      File.rm(log_path)
    end)

    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "PAUSE_FOR_STEER") == :ok

    # The turn is paused mid-flight (stub sent agent_start, then nothing) —
    # give the port's async response/agent_start a moment to land, then
    # confirm the runner is genuinely :running (not idle/error) before
    # steering, so this test can't pass by accident on a fast-completing turn.
    Process.sleep(100)
    assert SessionRunner.get_state(session.id).status == :running

    assert SessionRunner.send_message(session.id, "actually stop and say STEERED") == :ok

    state = wait_until_terminal(session.id)
    assert state.status == :idle

    # Exactly ONE turn ran end-to-end: a single `result` event, not two (which
    # interrupt-then-resend would produce), and both user messages are
    # preserved distinctly (not combined into one resent prompt).
    types = Enum.map(state.messages, & &1["type"])
    assert Enum.count(types, &(&1 == "result")) == 1

    user_texts =
      state.messages
      |> Enum.filter(&(&1["type"] == "user"))
      |> Enum.map(&get_in(&1, ["message", "content", Access.at(0), "text"]))

    assert user_texts == ["PAUSE_FOR_STEER", "actually stop and say STEERED"]

    # The steered instruction was actually delivered to (and echoed by) the
    # agent, not silently dropped or queued for after the turn.
    assistant_texts =
      state.messages
      |> Enum.filter(&(&1["type"] == "assistant"))
      |> Enum.flat_map(&get_in(&1, ["message", "content"]))
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    assert "Steered: actually stop and say STEERED" in assistant_texts

    # compaction_start/compaction_end normalize onto persisted `system`
    # events (spec §12.6) — rendered by MessageComponents' existing
    # system_message/1 path with no new component.
    system_subtypes =
      state.messages
      |> Enum.filter(&(&1["type"] == "system"))
      |> Enum.map(& &1["subtype"])

    assert "compaction_start" in system_subtypes
    assert "compaction_end" in system_subtypes

    compaction_end =
      Enum.find(state.messages, &(&1["type"] == "system" && &1["subtype"] == "compaction_end"))

    assert compaction_end["reason"] == "manual"
    assert compaction_end["aborted"] == false
    assert compaction_end["tokens_before"] == 1000
    assert compaction_end["estimated_tokens_after"] == 200

    # queue_update is broadcast-only (spec §12.6) — never persisted, so it
    # must NOT show up as a feed message even though the stub emitted one.
    refute "queue_update" in system_subtypes

    # The wire-level proof that steering (not interrupt-then-resend) is what
    # happened: the stub's command log shows "prompt" exactly once and
    # "steer" exactly once — never "abort".
    log = log_path |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(log, &(&1 == "prompt")) == 1
    assert Enum.count(log, &(&1 == "steer")) == 1
    refute "abort" in log
  end

  test "Cluster.send_message restarts a dead runner and completes the turn", %{session: session} do
    refute SessionSupervisor.session_alive?(session.id)

    assert OrcaHub.Cluster.send_message(node(), session.id, "say hi") == :ok
    assert SessionSupervisor.session_alive?(session.id)

    state = wait_until_terminal(session.id)
    assert state.status == :idle
    assert Enum.map(state.messages, & &1["type"]) |> Enum.member?("result")
  end

  test "extension-UI reply loop: a dialog request answered via answer_ui_request/3 completes the turn",
       %{session: session} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "ask a question") == :ok

    # The stub blocks mid-turn on the extension_ui_response — wait for the
    # normalized "pi_ui_request" event (Backend.Pi.handle_peer_request/2) to
    # land before answering, exactly like a real user would only see (and
    # only be able to answer) the dialog once it's actually pending.
    state = wait_until_message(session.id, "pi_ui_request")
    assert state.status == :running

    ui_request = Enum.find(state.messages, &(&1["type"] == "pi_ui_request"))
    assert ui_request["id"] == "ui-req-1"
    assert ui_request["method"] == "select"
    assert ui_request["options"] == ["Red", "Blue"]

    assert SessionRunner.answer_ui_request(session.id, "ui-req-1", %{"value" => "Blue"}) == :ok

    final = wait_until_terminal(session.id)
    assert final.status == :idle

    # The answer round-tripped through the port and back: the stub's
    # tool_result and follow-up assistant text both reflect "Blue".
    tool_results = tool_blocks(final.messages, "user", "tool_result")
    question_result = Enum.find(tool_results, &(&1["tool_use_id"] == "call-question-1"))
    assert question_result["content"] == [%{"type" => "text", "text" => "User answered: Blue"}]

    texts =
      final.messages
      |> Enum.filter(&(&1["type"] == "assistant"))
      |> Enum.flat_map(&get_in(&1, ["message", "content"]))
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    assert "You picked Blue." in texts

    # A confirmation was persisted to the feed and the pending marker cleared.
    ui_response = Enum.find(final.messages, &(&1["type"] == "pi_ui_response"))
    assert ui_response["id"] == "ui-req-1"
    assert ui_response["answer"] == %{"value" => "Blue"}

    # A stale/duplicate answer for the same (now-resolved) request id no-ops
    # rather than writing anything else to a port that's since moved on.
    assert SessionRunner.answer_ui_request(session.id, "ui-req-1", %{"value" => "Red"}) ==
             {:error, :not_running}
  end

  test "answer_ui_request/3 for an unknown request id no-ops while a DIFFERENT turn is running",
       %{session: session} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    assert SessionRunner.answer_ui_request(session.id, "never-requested", %{"value" => "x"}) ==
             {:error, :not_pending}

    wait_until_terminal(session.id)
  end

  test "session stats: a pi_session_stats event is appended after each completed turn",
       %{session: session} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    wait_until_terminal(session.id)
    # The get_session_stats round trip is written the moment agent_end is
    # normalized but its response is a separate async port message — it can
    # (and in practice usually does) arrive after the turn has already gone
    # :idle, exercising the idle(:info, {port, {:data, raw}}, ...) fallback
    # added alongside this feature so the response isn't silently dropped.
    state = wait_until_message(session.id, "pi_session_stats")

    stats = Enum.find(state.messages, &(&1["type"] == "pi_session_stats"))
    assert stats["tokens"]["total"] == 162
    assert_in_delta stats["cost"], 0.00015, 0.0000001
    assert stats["context_usage"]["percent"] == 1
  end

  test "toggle_plan_mode/1: a real turn warms the port, then /plan round-trips with no agent turn",
       %{session: session} do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok
    idle_state = wait_until_terminal(session.id)
    assert idle_state.status == :idle

    # toggle_plan_mode/1 is refused before the port is warm (spec §12.4 —
    # only reachable from :idle with an already-open port) — a freshly
    # started runner that has never sent a message is :ready, not :idle.
    fresh_dir =
      Path.join(System.tmp_dir!(), "pi_stub_it_cold_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fresh_dir)
    on_exit(fn -> File.rm_rf(fresh_dir) end)

    {:ok, cold_session} =
      Sessions.create_session(%{directory: fresh_dir, backend: "pi", model: nil})

    on_exit(fn ->
      if SessionSupervisor.session_alive?(cold_session.id),
        do: SessionSupervisor.stop_session(cold_session.id)
    end)

    assert {:ok, _pid} = SessionSupervisor.start_session(cold_session.id)
    assert SessionRunner.toggle_plan_mode(cold_session.id) == {:error, :not_running}

    # Against the WARM session, the stub's live-verified-shape response for
    # "/plan" (a fire-and-forget setStatus, then the prompt ack, no
    # agent_start/agent_end at all) round-trips into a persisted
    # `pi_plan_mode` event without the runner ever leaving :idle.
    assert SessionRunner.toggle_plan_mode(session.id) == :ok

    state = wait_until_message(session.id, "pi_plan_mode")
    assert state.status == :idle

    plan_event = Enum.find(state.messages, &(&1["type"] == "pi_plan_mode"))
    assert plan_event["enabled"] == true
    assert plan_event["executing"] == false
  end

  test "a spawn failure lands as a cli_error card instead of crashing the runner", %{
    session: session
  } do
    Application.put_env(
      :orca_hub,
      :pi_executable,
      "/nonexistent/pi-#{System.unique_integer([:positive])}"
    )

    assert OrcaHub.Cluster.send_message(node(), session.id, "hi") == :ok

    state = wait_until_terminal(session.id)
    assert state.status == :error
    assert SessionSupervisor.session_alive?(session.id)

    cli_error = Enum.find(state.messages, &(&1["type"] == "cli_error"))
    refute is_nil(cli_error)
    assert cli_error["message"] =~ "Failed to start the agent CLI (OrcaHub.Backend.Pi)"
  end

  defp tool_blocks(messages, msg_type, block_type) do
    messages
    |> Enum.filter(&(&1["type"] == msg_type))
    |> Enum.flat_map(&get_in(&1, ["message", "content"]))
    |> Enum.filter(&(&1["type"] == block_type))
  end

  defp wait_until_message(session_id, type, attempts \\ 100) do
    state = SessionRunner.get_state(session_id)

    cond do
      Enum.any?(state.messages, &(&1["type"] == type)) ->
        state

      attempts <= 0 ->
        flunk(
          "session #{session_id} never received a #{inspect(type)} message; " <>
            "last status=#{inspect(state.status)}, messages=#{inspect(state.messages)}"
        )

      true ->
        Process.sleep(50)
        wait_until_message(session_id, type, attempts - 1)
    end
  end

  defp wait_until_terminal(session_id, attempts \\ 100) do
    state = SessionRunner.get_state(session_id)

    cond do
      state.status in [:idle, :error, :waiting] and state.messages != [] ->
        state

      attempts <= 0 ->
        flunk(
          "session #{session_id} never reached a terminal status; last status=#{inspect(state.status)}, " <>
            "messages=#{inspect(state.messages)}"
        )

      true ->
        Process.sleep(50)
        wait_until_terminal(session_id, attempts - 1)
    end
  end
end
