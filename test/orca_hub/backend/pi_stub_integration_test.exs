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
