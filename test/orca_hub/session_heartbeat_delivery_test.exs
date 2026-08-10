defmodule OrcaHub.SessionHeartbeatDeliveryTest do
  @moduledoc """
  Coverage for ORCAHUB3-26 item 2: a heartbeat fire is QUEUED (never dropped)
  when the target session is `:running`, and delivered - with an explanation
  of why it arrived - once the session's status broadcasts back into a
  deliverable one, instead of interrupting the in-flight turn (see FR
  53f5b223: an unexplained mid-tool-call interrupt led a worker to conclude
  the orchestrator was fabricating instructions).

  Drives the real `OrcaHub.SessionHeartbeat` singleton GenServer end to end
  (fire via a direct `{:heartbeat, id}` message rather than waiting out the
  30s minimum interval, flush via a real `SessionRunner.running/3`
  running->idle transition, same pattern as
  `SessionRunnerLifecycleNotifyTest`) rather than reaching into its private
  functions.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionHeartbeat, SessionRunner, Sessions, SessionSupervisor}

  @claude_stub Path.expand("support/fixtures/claude_stub_noop.sh", __DIR__ <> "/..")

  setup do
    Application.put_env(:orca_hub, :claude_executable, @claude_stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "heartbeat-delivery-#{System.unique_integer([:positive])}")
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

  # Fires the heartbeat now (instead of waiting out the real timer) and
  # blocks until the GenServer has processed it - send/call to the same
  # named process from the same test process is FIFO, so the `get/1` call
  # right after is guaranteed to observe the fire's effect.
  defp fire_now(session_id) do
    send(SessionHeartbeat, {:heartbeat, session_id})
    SessionHeartbeat.get(session_id)
  end

  describe "a heartbeat fire while the session is running" do
    test "is queued (not delivered, not dropped) rather than interrupting the turn", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "check on progress")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert %{pending_delivery: %{queued_status: "running", message: message}} =
               fire_now(session.id)

      assert message =~ "check on progress"
      # Nothing was sent to the session - no interrupt, no message yet.
      assert Sessions.list_messages(session.id) == []
    end

    test "is delivered, annotated with why it arrived, once the turn ends", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "check on progress")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert %{pending_delivery: %{}} = fire_now(session.id)

      # Turn ends (running -> idle) - the same real transition/broadcast a
      # live SessionRunner would produce, driven directly per
      # SessionRunnerLifecycleNotifyTest's pattern.
      data = base_data(session, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      message = wait_for_message(session.id, ~r/check on progress/)
      refute is_nil(message), "expected the queued heartbeat to be delivered at turn end"

      text = message_text(message)
      assert text =~ "delivered late"
      assert text =~ "\"running\""

      # The queued entry is cleared after flushing - no double-delivery on a
      # later, unrelated status broadcast.
      assert %{pending_delivery: nil} = SessionHeartbeat.get(session.id)
    end

    test "a later fire while still running supersedes (does not stack behind) an earlier queued one",
         %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "first check")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert %{pending_delivery: %{message: first_message}} = fire_now(session.id)
      assert first_message =~ "first check"

      assert :ok = SessionHeartbeat.schedule(session.id, 30, "second check")
      assert %{pending_delivery: %{message: second_message}} = fire_now(session.id)
      assert second_message =~ "second check"

      data = base_data(session, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      message = wait_for_message(session.id, ~r/second check/)
      refute is_nil(message)

      # Only one delivered message, not two.
      delivered =
        session.id
        |> Sessions.list_messages()
        |> Enum.filter(fn m -> (message_text(m) || "") =~ "check" end)

      assert length(delivered) == 1
    end
  end

  describe "a heartbeat fire while the session is already deliverable" do
    test "delivers immediately, with no queueing/annotation", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "idle",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "check on progress")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert %{pending_delivery: nil} = fire_now(session.id)

      message = wait_for_message(session.id, ~r/check on progress/)
      refute is_nil(message)
      refute (message_text(message) || "") =~ "delivered late"
    end
  end
end
