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

  describe "resolve_engine/1 — runtime kill switch is ABSOLUTE" do
    @kill_key {OrcaHub.Streaming, :runtime_kill}

    setup do
      Application.put_env(:orca_hub, :disable_streaming, false)
      :persistent_term.erase(@kill_key)

      on_exit(fn ->
        :persistent_term.erase(@kill_key)
        Application.put_env(:orca_hub, :disable_streaming, false)
      end)

      :ok
    end

    test "kill switch engaged forces :one_shot even over per-session streaming: true" do
      :persistent_term.put(@kill_key, true)
      assert SessionRunner.resolve_engine(%{streaming: true}) == :one_shot
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :one_shot
      assert SessionRunner.resolve_engine(%{streaming: false}) == :one_shot
    end

    test "with kill switch off, the per-session column still wins as before" do
      :persistent_term.erase(@kill_key)
      assert SessionRunner.resolve_engine(%{streaming: true}) == :streaming
      assert SessionRunner.resolve_engine(%{streaming: nil}) == :streaming
    end
  end

  describe "OrcaHub.Streaming kill switch API" do
    setup do
      on_exit(fn -> OrcaHub.Streaming.enable!() end)
      :ok
    end

    test "disable!/enable! toggle kill_engaged? and status/0 effective_default" do
      OrcaHub.Streaming.enable!()
      refute OrcaHub.Streaming.kill_engaged?()
      assert OrcaHub.Streaming.status().effective_default == :streaming

      OrcaHub.Streaming.disable!()
      assert OrcaHub.Streaming.kill_engaged?()
      status = OrcaHub.Streaming.status()
      assert status.runtime_kill == true
      assert status.effective_default == :one_shot

      OrcaHub.Streaming.enable!()
      refute OrcaHub.Streaming.kill_engaged?()
    end

    test "disable! rejects unknown modes" do
      assert_raise FunctionClauseError, fn -> OrcaHub.Streaming.disable!(:bogus) end
    end

    test "warm_cap/0 + set_warm_cap/1 round-trip; nil reverts to default 6" do
      assert OrcaHub.Streaming.warm_cap() == 6
      OrcaHub.Streaming.set_warm_cap(3)
      assert OrcaHub.Streaming.warm_cap() == 3
      OrcaHub.Streaming.set_warm_cap(nil)
      assert OrcaHub.Streaming.warm_cap() == 6
    end
  end

  describe "downgrade_target/4 — per-state kill-switch downgrade table" do
    test "one-shot runners are already downgraded" do
      assert SessionRunner.downgrade_target(:one_shot, true, true, :graceful) == :already_one_shot

      assert SessionRunner.downgrade_target(:one_shot, false, false, :interrupt) ==
               :already_one_shot
    end

    test "mid-turn: graceful waits, interrupt ends the turn first" do
      assert SessionRunner.downgrade_target(:streaming, true, true, :graceful) ==
               :pending_after_turn

      assert SessionRunner.downgrade_target(:streaming, true, true, :interrupt) ==
               :pending_interrupt
    end

    test "no turn in flight: warm port tears down, cold just flips" do
      assert SessionRunner.downgrade_target(:streaming, true, false, :graceful) ==
               :teardown_one_shot

      assert SessionRunner.downgrade_target(:streaming, false, false, :graceful) == :flip_one_shot
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
