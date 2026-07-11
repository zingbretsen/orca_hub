defmodule OrcaHub.Backend.CodexStubIntegrationTest do
  @moduledoc """
  Strongest guard for the Codex adapter (backend_abstraction_spec.md §9,
  Phase 2 Step 4.4): a REAL `OrcaHub.SessionRunner` (full GenStatem, DB
  writes, PubSub, the actual `Backend.Codex` module) driven end-to-end
  against `test/support/fixtures/codex_stub_app_server.py` — a stand-in
  process that speaks just enough of the `codex app-server` wire protocol on
  stdio. No network, no real `codex` binary required.

  Exercises the full cold-open path: `on_open/1` writes `initialize` ->
  handshake reaction chain (`initialized` + `thread/start` queued via
  `pending_writes`) -> synthesized `system`/`init` event -> the prompt
  stashed by `encode_user_turn/2` during cold-start is flushed as
  `turn/start` -> `item/completed` (commandExecution + agentMessage) ->
  `thread/tokenUsage/updated` -> `turn/completed` synthesizes `result` ->
  the runner transitions :running -> :idle exactly as it does for Claude.
  """

  # async: false — starts a real SessionRunner (GenStatem) child under the
  # shared OrcaHub.SessionSupervisor, which needs the DB sandbox in SHARED
  # mode to read the session back in init/1 (see Ecto.Adapters.SQL.Sandbox
  # docs, and index_test.exs for the same pattern). Also flips the global
  # `:orca_hub, :codex_executable` app-env seam for the duration.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionRunner, SessionSupervisor, Sessions}

  @stub_script Path.expand("../../support/fixtures/codex_stub_app_server.py", __DIR__)

  setup do
    refute is_nil(System.find_executable("python3")),
           "python3 not found — required to run the codex app-server stub fixture"

    Application.put_env(:orca_hub, :codex_executable, @stub_script)
    on_exit(fn -> Application.delete_env(:orca_hub, :codex_executable) end)

    dir = Path.join(System.tmp_dir!(), "codex_stub_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "codex",
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

  # Regression: a backend spawn failure (codex executable missing from the
  # service PATH, observed live on the systemd agent) used to raise out of the
  # send_message call, crash the runner, and take the calling LiveView down
  # via erpc. It must land as a cli_error card in the feed with the runner
  # alive in :error state.
  test "a spawn failure lands as a cli_error card instead of crashing the runner", %{
    session: session
  } do
    Application.put_env(
      :orca_hub,
      :codex_executable,
      "/nonexistent/codex-#{System.unique_integer([:positive])}"
    )

    assert OrcaHub.Cluster.send_message(node(), session.id, "hi") == :ok

    state = wait_until_terminal(session.id)
    assert state.status == :error
    assert SessionSupervisor.session_alive?(session.id)

    cli_error = Enum.find(state.messages, &(&1["type"] == "cli_error"))
    refute is_nil(cli_error)
    assert cli_error["message"] =~ "Failed to start the agent CLI (OrcaHub.Backend.Codex)"

    # feedback item 2 (orchestrator-feedback-2026-07-10): the same failure
    # is persisted on the session row so `search_sessions` can surface it
    # without an orchestrator having to infer the cause from a short lifetime.
    assert Sessions.get_session!(session.id).error_detail =~
             "Failed to start the agent CLI (OrcaHub.Backend.Codex)"
  end

  # Regression: the abandoned-session cleanup used to stop the runner between
  # page load and send, and Cluster.send_message crashed the caller with a
  # GenError :noproc. It must transparently restart a dead runner instead —
  # this drives that restart through a full turn against the stub.
  test "Cluster.send_message restarts a dead runner and completes the turn", %{session: session} do
    refute SessionSupervisor.session_alive?(session.id)

    assert OrcaHub.Cluster.send_message(node(), session.id, "say hi") == :ok
    assert SessionSupervisor.session_alive?(session.id)

    state = wait_until_terminal(session.id)
    assert state.status == :idle
    assert Enum.map(state.messages, & &1["type"]) |> Enum.member?("result")
  end

  test "a real SessionRunner drives a full turn end-to-end against the stub app-server", %{
    session: session
  } do
    assert {:ok, _pid} = SessionSupervisor.start_session(session.id)
    assert SessionRunner.send_message(session.id, "say hi") == :ok

    state = wait_until_terminal(session.id)

    assert state.status == :idle
    assert state.claude_session_id == "stub-thread-1"

    types = Enum.map(state.messages, & &1["type"])
    assert "user" in types
    assert "system" in types
    assert "assistant" in types
    assert "result" in types

    system_event = Enum.find(state.messages, &(&1["type"] == "system"))
    assert system_event["session_id"] == "stub-thread-1"
    assert system_event["subtype"] == "init"

    tool_uses = tool_blocks(state.messages, "assistant", "tool_use")
    bash_use = Enum.find(tool_uses, &(&1["name"] == "Bash"))
    assert bash_use["id"] == "cmd-stub-1"
    assert bash_use["input"] == %{"command" => "echo hello"}

    # §3.3 invariant: the tool_result's tool_use_id echoes the tool_use's id.
    tool_results = tool_blocks(state.messages, "user", "tool_result")
    bash_result = Enum.find(tool_results, &(&1["tool_use_id"] == "cmd-stub-1"))
    assert bash_result["content"] == "hello\n"
    assert bash_result["is_error"] == false

    texts =
      state.messages
      |> Enum.filter(&(&1["type"] == "assistant"))
      |> Enum.flat_map(&get_in(&1, ["message", "content"]))
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])

    assert "Hello from the stub Codex app-server!" in texts

    result_event = Enum.find(state.messages, &(&1["type"] == "result"))
    assert result_event["is_error"] == false

    assert result_event["usage"] == %{
             "input_tokens" => 30,
             "output_tokens" => 12,
             "cache_read_input_tokens" => 0
           }

    assert result_event["duration_ms"] == 5

    # The leading-message system prompt (spec §6.3(1)) was prepended to the
    # persisted user turn — sent to the stub, not stored as a separate
    # message — so the STORED "user" event is the prompt exactly as typed.
    user_event = Enum.find(state.messages, &(&1["type"] == "user"))
    assert get_in(user_event, ["message", "content", Access.at(0), "text"]) == "say hi"
  end

  # NOTE: a genuine mid-flight `turn/interrupt` race isn't reproducible
  # against this stub — its `turn/start` handler answers synchronously and
  # emits the whole canned item/completed + turn/completed sequence before
  # the runner's `interrupt` call could ever reach its stdin, so there's no
  # window to actually race. `encode_interrupt/2`'s exact frame construction
  # (active-turn -> `turn/interrupt`; no-active-turn -> empty, never
  # `:signal`) and the `turn/completed{status:"interrupted"}` ->
  # `is_error:false` mapping are covered deterministically at the unit level
  # in `OrcaHub.Backend.CodexTest`. A REAL mid-turn interrupt (where a model
  # call gives a real race window) is exercised by the Phase 2 live smoke
  # test instead.

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
