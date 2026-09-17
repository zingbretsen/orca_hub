defmodule OrcaHub.Voice.SessionTest do
  @moduledoc """
  The voice state machine on its own: no channel, no socket, no network, no
  timers. Every rule pinned here is `voice_mode_spec.md` section 8.1's
  "Server-side semantics"; the clock is an integer this test supplies.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Session

  @t0 1_000_000

  # 16 kHz mono int16. 0.8 s = 12,800 samples is the ASR dispatch floor.
  defp pcm(samples), do: :binary.copy(<<0, 0>>, samples)

  defp frame(seq, samples, opts \\ []) do
    %{
      seq: seq,
      start_sample: Keyword.get(opts, :start_sample, 0),
      sample_count: samples,
      flags: Keyword.get(opts, :flags, 0),
      pcm: Keyword.get(opts, :pcm, pcm(samples))
    }
  end

  defp asr(text, opts \\ []) do
    %{
      text: text,
      language: "en",
      duration: Keyword.get(opts, :duration, 2.0),
      model: "large-v3-turbo",
      elapsed_seconds: Keyword.get(opts, :elapsed_seconds, 0.6)
    }
  end

  # Dispatches one long segment and feeds `text` back as its transcript.
  defp utterance(state, seq, text, now \\ @t0) do
    {state, dispatch} = Session.segment_received(state, frame(seq, 16_000), now)
    assert [{:dispatch, ^seq, _pcm}] = dispatch
    Session.transcript(state, seq, {:ok, asr(text)}, now)
  end

  defp results(effects), do: for({:segment_result, r} <- effects, do: r)
  defp actions(effects), do: effects |> results() |> Enum.map(& &1.action)

  describe "draft accumulation" do
    test "a non-command segment is appended, and segments join with a space" do
      state = Session.new()

      {state, effects} = utterance(state, 1, "let's ship the patch")
      assert actions(effects) == ["appended"]
      assert state.draft == "let's ship the patch"

      {state, effects} = utterance(state, 2, "after lunch")
      assert actions(effects) == ["appended"]
      assert state.draft == "let's ship the patch after lunch"

      assert [%{seq: 2, text: "after lunch", intent: nil, action: "appended"}] = results(effects)
    end

    test "a hand edit replaces the draft outright" do
      {state, _} = utterance(Session.new(), 1, "dictated text")
      {state, effects} = Session.draft_edit(state, "typed instead")

      assert effects == []
      assert state.draft == "typed instead"
    end
  end

  describe "the SEND command" do
    test "strips the command tokens, appends the remainder and opens the arming window" do
      {state, effects} = utterance(Session.new(), 1, "let's ship it orca send")

      assert state.draft == "let's ship it"
      assert [%{action: "send", intent: "send", score: score}] = results(effects)
      assert score >= 0.85
      assert {:schedule_tick, 1500} in effects

      snapshot = Session.snapshot(state, @t0)
      assert snapshot.status == "arming"
      assert snapshot.arming_ms == 1500
    end

    test "an all-command segment arms without appending anything" do
      {state, _} = utterance(Session.new(), 1, "let's ship it")
      {state, effects} = utterance(state, 2, "Orcasend.", @t0)

      assert state.draft == "let's ship it"
      assert actions(effects) == ["dropped_command_only"]
      assert state.arming_until == @t0 + 1500
    end

    test "a send against an empty draft does not arm" do
      {state, effects} = utterance(Session.new(), 1, "Orcasend.")

      assert state.draft == ""
      assert state.arming_until == nil
      assert [%{action: "send", detail: "empty draft"}] = results(effects)
      assert Session.snapshot(state, @t0).arming_ms == nil
    end

    test "the arming window expiring sends the draft" do
      {state, _} = Session.warm_ok(Session.new())
      {state, _} = utterance(state, 1, "let's ship it orca send")

      # Still inside the window: nothing happens.
      {state, effects} = Session.tick(state, @t0 + 1499)
      assert effects == []
      assert state.arming_until == @t0 + 1500

      {state, effects} = Session.tick(state, @t0 + 1500)
      assert effects == [{:send, "let's ship it"}]
      assert state.arming_until == nil
      assert Session.snapshot(state, @t0 + 1500).status == "sending"

      {state, effects} = Session.send_result(state, :ok)
      assert effects == [{:sent, "let's ship it"}]
      assert state.draft == ""
      assert Session.snapshot(state, @t0 + 1500).status == "listening"
    end

    test "speech onset cancels the arming window immediately" do
      {state, _} = utterance(Session.new(), 1, "let's ship it orca send")
      {state, effects} = Session.speech_start(state)

      assert effects == []
      assert state.arming_until == nil

      # A stale timer firing after the cancel must not send anything.
      assert {_state, []} = Session.tick(state, @t0 + 5000)
    end

    test "a hand edit cancels the arming window" do
      {state, _} = utterance(Session.new(), 1, "let's ship it orca send")
      {state, _} = Session.draft_edit(state, "actually, hold off")

      assert state.arming_until == nil
      assert {_state, []} = Session.tick(state, @t0 + 5000)
    end

    test "a following non-command segment cancels the arming window" do
      {state, _} = utterance(Session.new(), 1, "let's ship it orca send")
      {state, effects} = utterance(state, 2, "no wait", @t0 + 200)

      assert actions(effects) == ["appended"]
      assert state.arming_until == nil
      assert state.draft == "let's ship it no wait"
    end

    test "speech resuming before the :send result lands skips arming entirely" do
      # The real timeline: the command segment closes 600 ms after speech
      # offset, its ASR round trip takes ~0.5 s, and the user starts talking
      # again in between — before the window would have opened.
      {state, _} = Session.warm_ok(Session.new())
      {state, _} = utterance(state, 1, "let's ship it")

      {state, dispatch} = Session.segment_received(state, frame(2, 16_000), @t0)
      assert [{:dispatch, 2, _pcm}] = dispatch

      {state, []} = Session.speech_start(state)

      {state, effects} = Session.transcript(state, 2, {:ok, asr("hold on orca send")}, @t0 + 500)

      assert [%{seq: 2, action: "send", intent: "send", detail: detail}] = results(effects)
      assert detail == "arming skipped: speech resumed"
      refute Enum.any?(effects, &match?({:schedule_tick, _}, &1))

      # The stripped remainder still lands in the draft, and nothing is armed.
      assert state.draft == "let's ship it hold on"
      assert state.arming_until == nil
      assert Session.snapshot(state, @t0 + 500).status == "listening"
      assert Session.snapshot(state, @t0 + 500).arming_ms == nil

      # No deadline exists, so no amount of ticking sends anything.
      assert {_state, []} = Session.tick(state, @t0 + 10_000)

      # The resumed speech's own segment appends normally.
      {state, effects} = utterance(state, 3, "actually not yet", @t0 + 1200)
      assert actions(effects) == ["appended"]
      assert state.draft == "let's ship it hold on actually not yet"
    end

    test "the speech onset that STARTED the command segment does not skip arming" do
      {state, _} = utterance(Session.new(), 1, "let's ship it")

      # Onset arrives BEFORE the segment it opens is received — the ordinary
      # case for every utterance, and it must not count as "resumed speech".
      {state, []} = Session.speech_start(state)
      {state, dispatch} = Session.segment_received(state, frame(2, 16_000), @t0)
      assert [{:dispatch, 2, _pcm}] = dispatch

      {state, effects} = Session.transcript(state, 2, {:ok, asr("now orca send")}, @t0 + 500)

      assert [%{action: "send", detail: nil}] = results(effects)
      assert {:schedule_tick, 1500} in effects
      assert state.draft == "let's ship it now"
      assert state.arming_until == @t0 + 500 + 1500
      assert Session.snapshot(state, @t0 + 500).status == "arming"
    end

    test "send_now is unaffected by speech resuming mid-flight" do
      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, []} = Session.speech_start(state)
      {_state, effects} = Session.send_now(state)

      assert effects == [{:send, "ship it"}]
    end

    test "send_now sends immediately with no arming window, and is a no-op when empty" do
      assert {%Session{} = empty, []} = Session.send_now(Session.new())
      assert empty.draft == ""

      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, effects} = Session.send_now(state)

      assert effects == [{:send, "ship it"}]
      assert Session.snapshot(state, @t0).status == "sending"
    end

    test "a failed send surfaces a readable error" do
      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, _} = Session.send_now(state)

      {busy, effects} = Session.send_result(state, {:error, :busy})
      assert effects == []
      assert busy.error == "Session is busy"
      assert Session.snapshot(busy, @t0).status == "error"
      # The draft survives a failed send — it is the user's text.
      assert busy.draft == "ship it"

      {other, []} = Session.send_result(state, {:error, :nope})
      assert other.error == "Could not send: :nope"
    end
  end

  describe "the CANCEL command" do
    test "clears the draft and any arming window" do
      {state, _} = utterance(Session.new(), 1, "let's ship it orca send")
      {state, effects} = utterance(state, 2, "or cut cancel.", @t0 + 100)

      assert actions(effects) == ["cancel"]
      assert state.draft == ""
      assert state.arming_until == nil
    end
  end

  describe "the STOP / PAUSE commands" do
    test "are ignored apart from stripping the command out of the draft" do
      {state, effects} = utterance(Session.new(), 1, "hang on a second Orcastop.")

      assert [%{action: "ignored_stop_pause", intent: "stop"}] = results(effects)
      assert state.draft == "hang on a second"
      assert state.arming_until == nil

      {state, effects} = utterance(state, 2, "or Kapaz.", @t0)
      assert [%{action: "ignored_stop_pause", intent: "pause"}] = results(effects)
      # The whole segment was the command, so the draft is untouched.
      assert state.draft == "hang on a second"
    end

    test "do not send, even with a draft waiting" do
      {state, _} = Session.warm_ok(Session.new())
      {state, _} = utterance(state, 1, "ready to go orca send")
      {state, _} = Session.speech_start(state)
      {state, effects} = utterance(state, 2, "Orcastop.", @t0 + 100)

      assert actions(effects) == ["ignored_stop_pause"]
      refute Enum.any?(effects, &match?({:send, _}, &1))
      assert Session.snapshot(state, @t0 + 100).status == "listening"
    end
  end

  describe "silence and errors" do
    test "a blank transcript is dropped" do
      {state, effects} = utterance(Session.new(), 1, "")

      assert actions(effects) == ["dropped_silence"]
      assert state.draft == ""
    end

    test "a sub-50 ms server time is dropped even with text" do
      {state, dispatch} = Session.segment_received(Session.new(), frame(1, 16_000), @t0)
      assert [{:dispatch, 1, _}] = dispatch

      {state, effects} =
        Session.transcript(state, 1, {:ok, asr("archives.", elapsed_seconds: 0.014)}, @t0)

      assert actions(effects) == ["dropped_silence"]
      assert state.draft == ""
    end

    test "an ASR failure is reported as an error result, not a crash" do
      {state, _} = Session.segment_received(Session.new(), frame(1, 16_000), @t0)

      {state, effects} =
        Session.transcript(state, 1, {:error, "ASR timed out after 10000 ms"}, @t0)

      assert [%{action: "error", detail: "ASR timed out after 10000 ms"}] = results(effects)
      assert state.draft == ""
      assert Session.snapshot(state, @t0).pending == 0
    end

    test "a result for a seq that was never dispatched is ignored" do
      assert {%Session{}, []} = Session.transcript(Session.new(), 7, {:ok, asr("hello")}, @t0)
    end
  end

  describe "result ordering" do
    test "out-of-order completions are buffered and applied in dispatch order" do
      state = Session.new()
      {state, _} = Session.segment_received(state, frame(1, 16_000), @t0)
      {state, _} = Session.segment_received(state, frame(2, 16_000), @t0)
      assert Session.snapshot(state, @t0).pending == 2

      # seq 2 lands first and must wait.
      {state, effects} = Session.transcript(state, 2, {:ok, asr("second")}, @t0)
      assert effects == []
      assert state.draft == ""

      {state, effects} = Session.transcript(state, 1, {:ok, asr("first")}, @t0)
      assert Enum.map(results(effects), & &1.seq) == [1, 2]
      assert state.draft == "first second"
      assert Session.snapshot(state, @t0).pending == 0
    end
  end

  describe "the 0.8 s floor and the 20 s cap" do
    test "a short segment is held, then merged with the next one and dispatched once" do
      state = Session.new()

      {state, effects} = Session.segment_received(state, frame(1, 8_000), @t0)
      assert effects == [{:schedule_tick, 1500}]
      assert Session.snapshot(state, @t0).pending == 1

      {state, effects} = Session.segment_received(state, frame(2, 8_000), @t0 + 400)
      assert [{:dispatch, 2, merged}] = effects
      # The PCM really is concatenated, not replaced.
      assert byte_size(merged) == 16_000 * 2
      assert state.held == nil

      {state, effects} = Session.transcript(state, 2, {:ok, asr("ship it")}, @t0 + 900)
      assert [%{seq: 2, action: "appended", detail: "merged with segment 1"}] = results(effects)
      assert state.draft == "ship it"
    end

    test "a merge that is still short is held again rather than dispatched" do
      state = Session.new()
      {state, _} = Session.segment_received(state, frame(1, 4_000), @t0)
      {state, effects} = Session.segment_received(state, frame(2, 4_000), @t0 + 100)

      assert effects == [{:schedule_tick, 1500}]
      assert state.held.sample_count == 8_000
      assert state.held.merged_from == [1]
    end

    test "a held segment the client already padded is dispatched when the hold expires" do
      state = Session.new()
      {state, _} = Session.segment_received(state, frame(1, 9_600, flags: 0x2), @t0)

      assert {_state, []} = Session.tick(state, @t0 + 1499)

      {state, effects} = Session.tick(state, @t0 + 1500)
      assert [{:dispatch, 1, _pcm}] = effects
      assert state.held == nil
    end

    test "a held unpadded segment with nothing to merge is dropped as too short" do
      state = Session.new()
      {state, _} = Session.segment_received(state, frame(1, 9_600), @t0)

      {state, effects} = Session.tick(state, @t0 + 1500)
      assert [%{seq: 1, action: "dropped_short", detail: detail}] = results(effects)
      assert detail =~ "0.8 s"
      assert state.held == nil
      assert Session.snapshot(state, @t0 + 1500).pending == 0
    end

    test "a segment over the 20 s cap is refused without a round trip" do
      state = Session.new()
      {state, effects} = Session.segment_received(state, frame(1, 320_001), @t0)

      assert [%{seq: 1, action: "error", detail: "segment over 20 s cap"}] = results(effects)
      refute Enum.any?(effects, &match?({:dispatch, _, _}, &1))
      assert state.awaiting == []
    end

    test "exactly 0.8 s dispatches and exactly 20 s is still allowed" do
      assert {_s, [{:dispatch, 1, _}]} =
               Session.segment_received(Session.new(), frame(1, 12_800), @t0)

      assert {_s, [{:dispatch, 2, _}]} =
               Session.segment_received(Session.new(), frame(2, 320_000), @t0)
    end
  end

  describe "mic state" do
    test "a segment arriving while muted is dropped without dispatch" do
      {state, _} = Session.mic(Session.new(), true)
      {state, effects} = Session.segment_received(state, frame(1, 16_000), @t0)

      assert [%{seq: 1, action: "dropped_muted"}] = results(effects)
      refute Enum.any?(effects, &match?({:dispatch, _, _}, &1))
      assert Session.snapshot(state, @t0).muted == true

      {state, _} = Session.mic(state, false)
      assert Session.snapshot(state, @t0).muted == false
    end
  end

  describe "warm-up and status precedence" do
    test "a fresh session is warming, and a successful ping makes it listening" do
      state = Session.new()
      assert %{status: "warming", warm: false, error: nil} = Session.snapshot(state, @t0)

      {state, []} = Session.warm_ok(state)
      assert %{status: "listening", warm: true} = Session.snapshot(state, @t0)
    end

    test "a failed ping shows the error until a retry" do
      {state, []} = Session.warm_error(Session.new(), "ASR unreachable: connection refused")

      assert %{status: "error", error: "ASR unreachable: connection refused"} =
               Session.snapshot(state, @t0)

      {state, []} = Session.retry_warmup(state)
      assert %{status: "warming", error: nil} = Session.snapshot(state, @t0)
    end

    test "a successful transcript clears a lingering error" do
      {state, _} = Session.warm_error(Session.new(), "ASR unreachable")
      {state, _} = utterance(state, 1, "back online")

      assert state.error == nil
      assert Session.snapshot(state, @t0).status == "listening"
    end

    test "error beats sending beats arming beats transcribing" do
      {armed, _} = utterance(Session.new(), 1, "ship it orca send")
      {armed, _} = Session.warm_ok(armed)
      assert Session.snapshot(armed, @t0).status == "arming"

      {transcribing, _} = Session.segment_received(armed, frame(2, 16_000), @t0)
      # arming still outranks transcribing
      assert Session.snapshot(transcribing, @t0).status == "arming"

      {sending, _} = Session.send_now(armed)
      assert Session.snapshot(sending, @t0).status == "sending"

      {errored, _} = Session.send_result(sending, {:error, :busy})
      assert Session.snapshot(errored, @t0).status == "error"
    end

    test "arming_ms counts down and never goes negative" do
      {state, _} = utterance(Session.new(), 1, "ship it orca send")

      assert Session.snapshot(state, @t0 + 400).arming_ms == 1100
      assert Session.snapshot(state, @t0 + 9_999).arming_ms == 0
    end
  end
end
