defmodule OrcaHub.StreamingRunnerTest do
  # async: false — resolve_engine/1 reads global Application env, which we toggle.
  use ExUnit.Case, async: false

  alias OrcaHub.SessionRunner

  describe "resolve_engine/1 — feature flag + per-session override" do
    setup do
      original = Application.get_env(:orca_hub, :streaming_runner, false)
      on_exit(fn -> Application.put_env(:orca_hub, :streaming_runner, original) end)
      :ok
    end

    test "per-session streaming: true forces :streaming regardless of global flag" do
      Application.put_env(:orca_hub, :streaming_runner, false)
      assert SessionRunner.resolve_engine(%{streaming: true}) == :streaming
    end

    test "per-session streaming: false forces :one_shot even when global flag is on" do
      Application.put_env(:orca_hub, :streaming_runner, true)
      assert SessionRunner.resolve_engine(%{streaming: false}) == :one_shot
    end

    test "nil override inherits the global default (off → :one_shot)" do
      Application.put_env(:orca_hub, :streaming_runner, false)
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :one_shot
    end

    test "nil override inherits the global default (on → :streaming)" do
      Application.put_env(:orca_hub, :streaming_runner, true)
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :streaming
    end

    test "missing streaming key behaves like nil (inherits default)" do
      Application.put_env(:orca_hub, :streaming_runner, false)
      assert SessionRunner.resolve_engine(%{}) == :one_shot
    end

    test "works on a real Session struct (default-off → one_shot)" do
      Application.put_env(:orca_hub, :streaming_runner, false)
      assert SessionRunner.resolve_engine(%OrcaHub.Sessions.Session{}) == :one_shot
    end
  end

  describe "streaming_turn_decision/1 — stream-event injection through the state machine" do
    test "queued prompts flush the queue (interrupt or natural completion with pending)" do
      assert SessionRunner.streaming_turn_decision(%{
               pending_prompts: ["next"],
               interrupting: true,
               is_error: true
             }) == :flush_queue

      # queue takes precedence even over a success result with no interrupt
      assert SessionRunner.streaming_turn_decision(%{
               pending_prompts: ["next"],
               interrupting: false,
               is_error: false
             }) == :flush_queue
    end

    test "explicit interrupt with empty queue goes idle (not error)" do
      assert SessionRunner.streaming_turn_decision(%{
               pending_prompts: [],
               interrupting: true,
               is_error: true
             }) == :idle_stop
    end

    test "genuine error (no interrupt, no queue) goes to error" do
      assert SessionRunner.streaming_turn_decision(%{
               pending_prompts: [],
               interrupting: false,
               is_error: true
             }) == :error
    end

    test "clean success goes idle" do
      assert SessionRunner.streaming_turn_decision(%{
               pending_prompts: [],
               interrupting: false,
               is_error: false
             }) == :success
    end
  end

  describe "stdin framing" do
    test "user_turn_json/1 is newline-terminated stream-json with a text content block" do
      json = SessionRunner.user_turn_json("hello world")
      assert String.ends_with?(json, "\n")

      decoded = Jason.decode!(json)

      assert decoded == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello world"}]
               }
             }
    end

    test "control_interrupt_json/1 is the Agent-SDK interrupt control request" do
      json = SessionRunner.control_interrupt_json("int_7")
      assert String.ends_with?(json, "\n")

      assert Jason.decode!(json) == %{
               "type" => "control_request",
               "request_id" => "int_7",
               "request" => %{"subtype" => "interrupt"}
             }
    end
  end
end
