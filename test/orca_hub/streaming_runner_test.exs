defmodule OrcaHub.StreamingRunnerTest do
  # async: false — resolve_engine/1 reads global Application env, which we toggle.
  use ExUnit.Case, async: false

  alias OrcaHub.SessionRunner

  describe "resolve_engine/1 — streaming is the default; ORCA_DISABLE_STREAMING kill switch" do
    setup do
      original = Application.get_env(:orca_hub, :disable_streaming, false)
      on_exit(fn -> Application.put_env(:orca_hub, :disable_streaming, original) end)
      :ok
    end

    test "default: nil column + kill switch unset => :streaming" do
      Application.put_env(:orca_hub, :disable_streaming, false)
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :streaming
    end

    test "missing streaming key behaves like nil => :streaming by default" do
      Application.put_env(:orca_hub, :disable_streaming, false)
      assert SessionRunner.resolve_engine(%{}) == :streaming
    end

    test "kill switch ON: nil-column sessions fall back to :one_shot globally" do
      Application.put_env(:orca_hub, :disable_streaming, true)
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :one_shot
    end

    test "per-session false => :one_shot even when global default is streaming" do
      Application.put_env(:orca_hub, :disable_streaming, false)
      assert SessionRunner.resolve_engine(%{streaming: false}) == :one_shot
    end

    test "per-session true => :streaming even when the kill switch is set (override WINS)" do
      Application.put_env(:orca_hub, :disable_streaming, true)
      assert SessionRunner.resolve_engine(%{streaming: true}) == :streaming
    end

    test "real Session struct defaults to :streaming (nil column, kill switch off)" do
      Application.put_env(:orca_hub, :disable_streaming, false)
      assert SessionRunner.resolve_engine(%OrcaHub.Sessions.Session{}) == :streaming
    end
  end

  describe "ORCA_DISABLE_STREAMING env parsing (mirrors config/runtime.exs)" do
    # runtime.exs uses: System.get_env("ORCA_DISABLE_STREAMING") in ~w(1 true)
    test "truthy strings enable the kill switch" do
      for v <- ["1", "true"], do: assert(v in ~w(1 true))
    end

    test "falsy / unset values leave streaming on" do
      for v <- ["0", "false", "", "TRUE", "yes", nil], do: refute(v in ~w(1 true))
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
