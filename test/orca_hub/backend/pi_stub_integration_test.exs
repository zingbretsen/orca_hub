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
