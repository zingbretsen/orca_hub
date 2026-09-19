defmodule OrcaHub.Voice.SessionTest do
  @moduledoc """
  The voice state machine on its own: no channel, no socket, no network, no
  timers. Every rule pinned here is `voice_mode_spec.md` section 8.1's
  "Server-side semantics"; the clock is an integer this test supplies.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.{Intent, Session}

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

    test "the arming window expiring asks the CLIENT to send the draft" do
      {state, _} = Session.warm_ok(Session.new())
      {state, _} = utterance(state, 1, "let's ship it orca send")

      # Still inside the window: nothing happens.
      {state, effects} = Session.tick(state, @t0 + 1499)
      assert effects == []
      assert state.arming_until == @t0 + 1500

      {state, effects} = Session.tick(state, @t0 + 1500)
      # Spec 8.2: the server no longer delivers — the client runs the draft
      # through the real composer so uploads and attachment lines ride along.
      assert effects == [{:send_request, "let's ship it"}, {:schedule_tick, 5000}]
      assert state.arming_until == nil
      assert Session.snapshot(state, @t0 + 1500).status == "sending"

      {state, effects} = Session.sent_ack(state)
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
      {_state, effects} = Session.send_now(state, @t0)

      assert effects == [{:send_request, "ship it"}, {:schedule_tick, 5000}]
    end

    test "send_now sends immediately with no arming window, and is a no-op when empty" do
      assert {%Session{} = empty, []} = Session.send_now(Session.new(), @t0)
      assert empty.draft == ""

      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, effects} = Session.send_now(state, @t0)

      assert effects == [{:send_request, "ship it"}, {:schedule_tick, 5000}]
      assert Session.snapshot(state, @t0).status == "sending"
    end

    test "a failed direct send surfaces a readable error" do
      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, _} = Session.send_now(state, @t0)
      # No composer on the page, so the client asked the server to deliver.
      {state, effects} = Session.send_direct(state)
      assert effects == [{:send, "ship it"}]

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

  # Spec 8.2 / ORCAHUB3-86: the send goes out through the page's REAL
  # composer form, so staged uploads are consumed and the `[Attached
  # image: …]` lines ride along. The server only asks, and only delivers
  # by itself when the client says there is no composer.
  describe "the single send path" do
    setup do
      {state, _} = Session.warm_ok(Session.new())
      {state, _} = utterance(state, 1, "ship it orca send")
      {state, effects} = Session.tick(state, @t0 + 1500)
      assert [{:send_request, "ship it"} | _] = effects
      %{armed: state}
    end

    test "sent_ack clears the draft and reports the sent text", %{armed: state} do
      {state, effects} = Session.sent_ack(state)

      assert effects == [{:sent, "ship it"}]
      assert state.draft == ""
      assert state.send_pending == nil
      assert Session.snapshot(state, @t0 + 1600).status == "listening"

      # A duplicate ack (or one racing the deadline) is inert.
      assert {^state, []} = Session.sent_ack(state)
    end

    test "send_failed KEEPS the draft and shows the composer's reason", %{armed: state} do
      {state, effects} = Session.send_failed(state, "Session is busy")

      assert effects == []
      assert state.draft == "ship it"
      assert state.error == "Session is busy"
      assert Session.snapshot(state, @t0 + 1600).status == "error"

      # Nothing is retried behind the user's back.
      assert {_state, []} = Session.tick(state, @t0 + 60_000)
    end

    test "send_direct falls back to the server's own delivery", %{armed: state} do
      {state, effects} = Session.send_direct(state)

      assert effects == [{:send, "ship it"}]
      assert state.send_pending == nil
      assert Session.snapshot(state, @t0 + 1600).status == "sending"

      {state, effects} = Session.send_result(state, {:queued, :running})
      assert effects == [{:sent, "ship it"}]
      assert state.draft == ""
    end

    test "a silent client with NO composer falls back to a direct send after 5 s",
         %{armed: state} do
      assert {^state, []} = Session.tick(state, @t0 + 1500 + 4999)

      {state, effects} = Session.tick(state, @t0 + 1500 + 5000)
      assert effects == [{:send, "ship it"}]
      assert state.error == nil
      assert Session.snapshot(state, @t0).status == "sending"
    end

    test "a silent client that DID report a composer errors instead of double-sending" do
      {state, _} = Session.warm_ok(Session.new())
      {state, []} = Session.composer(state, true)
      {state, _} = utterance(state, 1, "ship it orca send")
      {state, _} = Session.tick(state, @t0 + 1500)

      {state, effects} = Session.tick(state, @t0 + 1500 + 5000)

      # Never {:send, _} — the composer may well have delivered it already.
      assert effects == []
      assert state.draft == "ship it"
      assert state.error =~ "composer did not respond"
      assert Session.snapshot(state, @t0).status == "error"
    end

    test "a cancel abandons an outstanding send_request", %{armed: state} do
      {state, [{:cancelled, "ship it"}]} = Session.cancel(state)

      assert state.send_pending == nil
      assert state.draft == ""
      # The 5 s deadline must not resurrect the cancelled text.
      assert {_state, []} = Session.tick(state, @t0 + 60_000)
    end

    # §8.3.11: the hook pushes this instead of `cancel` when the page's own
    # composer delivered the draft. Same clearing, no undo — a restore
    # affordance for a message that WAS sent invites a double send.
    test "draft_delivered clears like a cancel but records no undo", %{armed: state} do
      {state, []} = Session.draft_delivered(state)

      assert state.draft == ""
      assert state.send_pending == nil
      assert state.last_cancelled_draft == nil
      refute Session.snapshot(state, @t0).restorable

      {state, []} = Session.restore(state)
      assert state.draft == ""
    end

    test "ack/failed/direct are inert with nothing pending" do
      state = Session.new()

      assert {^state, []} = Session.sent_ack(state)
      assert {^state, []} = Session.send_failed(state, "nope")
      assert {^state, []} = Session.send_direct(state)
    end

    test "composer/2 mirrors the client's report" do
      state = Session.new()
      refute state.composer_present

      {state, []} = Session.composer(state, true)
      assert state.composer_present

      {state, []} = Session.composer(state, false)
      refute state.composer_present
    end
  end

  # §8.3.11 / ORCAHUB3-99. A spoken cancel destroyed ~4 minutes of real
  # dictation on a 0.857 false positive, with no undo, while the RECOVERABLE
  # action (send) was the only one that had an arming window. These tests pin
  # both halves of the correction: the window, and the undo.
  describe "the CANCEL command" do
    test "kills an open send window immediately, and only ARMS the clear" do
      {state, _} = utterance(Session.new(), 1, "let's ship it orca send")
      assert state.arming_kind == :send

      {state, effects} = utterance(state, 2, "or cut cancel.", @t0 + 100)

      assert actions(effects) == ["cancel"]
      # The send it called off is gone at once — that is not destructive.
      refute state.send_pending
      # The draft is NOT gone. It is counting down.
      assert state.draft == "let's ship it"
      assert state.arming_kind == :cancel
      assert Session.snapshot(state, @t0 + 100).arming == "cancel"
      assert Session.snapshot(state, @t0 + 100).status == "arming"
      assert {:schedule_tick, 1500} in effects

      # ...and the send that was armed before it never fires.
      {state, effects} = Session.tick(state, @t0 + 100 + 1500)
      assert effects == [{:cancelled, "let's ship it"}]
      assert state.draft == ""
    end

    test "the armed clear fires on expiry and is restorable byte for byte" do
      {state, _} = utterance(Session.new(), 1, "a detailed design argument")
      {state, _} = utterance(state, 2, "about pi forking", @t0 + 10)
      {state, _} = utterance(state, 3, "or cut cancel.", @t0 + 20)

      before = "a detailed design argument about pi forking"
      assert state.draft == before

      {state, effects} = Session.tick(state, @t0 + 20 + 1500)
      assert effects == [{:cancelled, before}]
      assert state.draft == ""
      assert Session.snapshot(state, @t0).restorable

      {state, []} = Session.restore(state)
      assert state.draft == before
      refute Session.snapshot(state, @t0).restorable
    end

    # The whole point of the window: the user was mid-sentence, so they are
    # still talking, so the false positive costs nothing.
    test "speech onset during the window aborts the clear" do
      {state, _} = utterance(Session.new(), 1, "forty segments of dictation")
      {state, _} = utterance(state, 2, "or cut cancel.", @t0 + 10)
      assert state.arming_kind == :cancel

      {state, []} = Session.speech_start(state)
      assert state.arming_until == nil
      assert state.arming_kind == nil

      assert {state, []} = Session.tick(state, @t0 + 60_000)
      assert state.draft == "forty segments of dictation"
      refute Session.snapshot(state, @t0).restorable
    end

    test "a following segment aborts the clear, and its words still land" do
      {state, _} = utterance(Session.new(), 1, "forty segments of dictation")
      {state, _} = utterance(state, 2, "or cut cancel.", @t0 + 10)

      {state, effects} = utterance(state, 3, "and more after that", @t0 + 20)
      assert actions(effects) == ["appended"]
      assert state.arming_until == nil

      assert {state, []} = Session.tick(state, @t0 + 60_000)
      assert state.draft == "forty segments of dictation and more after that"
    end

    # `armable?/2` — the ~0.6-1.1 s blind spot between the command segment's
    # receipt and its transcript landing. Send has always refused to arm
    # there; cancel refuses to clear.
    test "no window opens at all when speech resumed before the transcript landed" do
      {state, _} = utterance(Session.new(), 1, "forty segments of dictation")
      {state, _} = Session.segment_received(state, frame(2, 16_000), @t0 + 10)
      {state, []} = Session.speech_start(state)
      {state, effects} = Session.transcript(state, 2, {:ok, asr("or cut cancel.")}, @t0 + 20)

      assert [%{action: "cancel", detail: detail}] = results(effects)
      assert detail =~ "arming skipped: speech resumed"
      assert state.arming_until == nil
      assert state.draft == "forty segments of dictation"
    end

    # The measured defect verbatim. #41 of Zach's transcript scores
    # 0.8571428571428571 against "orca cancel" — over the 0.85 threshold, and
    # bit-identical to six GENUINE "orca cancel" clips in the §5.1.1 corpus,
    # so no threshold can tell them apart. The window and the undo are what
    # make it survivable.
    test "ORCAHUB3-99: the real false positive no longer destroys the draft" do
      assert Intent.intent("That is not what the original goal was.",
               vocab: Intent.command_vocab()
             ) == {:cancel, 0.8571428571428571}

      {state, _} = utterance(Session.new(), 1, "This does not mean")

      {state, _} =
        utterance(
          state,
          2,
          "that, for example, when we create a brand new orchestrator, " <>
            "we cannot give it useful information when we start it.",
          @t0 + 10
        )

      kept = state.draft

      # The user is mid-dictation, so speech has resumed: the window never
      # even opens and nothing is lost at all.
      {state, _} = Session.segment_received(state, frame(3, 16_000), @t0 + 20)
      {state, []} = Session.speech_start(state)

      {state, effects} =
        Session.transcript(
          state,
          3,
          {:ok, asr("That is not what the original goal was.")},
          @t0 + 30
        )

      assert [%{action: "cancel"}] = results(effects)
      assert {state, []} = Session.tick(state, @t0 + 60_000)
      assert String.starts_with?(state.draft, kept)
    end

    # Worst case: the user really had stopped talking, so the clear fires.
    # The undo is what stops that from being four lost minutes.
    test "ORCAHUB3-99: even a cancel that FIRES is fully recoverable" do
      {state, _} = utterance(Session.new(), 1, "four minutes of speech")

      {state, _} =
        Session.transcript(
          elem(Session.segment_received(state, frame(2, 16_000), @t0 + 10), 0),
          2,
          {:ok, asr("That is not what the original goal was.")},
          @t0 + 20
        )

      {state, [{:cancelled, lost}]} = Session.tick(state, @t0 + 20 + 1500)
      assert state.draft == ""

      {state, []} = Session.restore(state)
      assert state.draft == lost
      assert String.starts_with?(state.draft, "four minutes of speech")
    end

    # Found by the browser check: the undo buffer outlived the send that
    # followed it, so `restorable` came back true minutes later offering text
    # the user had long since dealt with.
    test "a DELIVERED draft retires the undo, but ordinary typing does not" do
      {state, _} = utterance(Session.new(), 1, "four minutes of speech")
      {state, [{:cancelled, lost}]} = Session.cancel(state)
      assert Session.snapshot(state, @t0).restorable

      # One word typed while deciding: the undo is merely out of the way...
      {typing, _} = Session.draft_edit(state, "wait")
      refute Session.snapshot(typing, @t0).restorable
      assert typing.last_cancelled_draft == lost

      # ...and comes back the moment there is room for it again.
      {typing, _} = Session.draft_edit(typing, "")
      assert Session.snapshot(typing, @t0).restorable
      {typing, []} = Session.restore(typing)
      assert typing.draft == lost

      # A delivery, on the other hand, retires it for good.
      {delivered, []} = Session.draft_delivered(state)
      refute Session.snapshot(delivered, @t0).restorable
      assert delivered.last_cancelled_draft == nil

      {state, _} = Session.draft_edit(state, "a new message")
      {state, _} = Session.send_now(state, @t0)
      {state, [{:sent, "a new message"}]} = Session.sent_ack(state)
      refute Session.snapshot(state, @t0).restorable
    end

    test "restore is a no-op with nothing to restore, or over a live draft" do
      assert {%Session{draft: ""}, []} = Session.restore(Session.new())

      {state, _} = utterance(Session.new(), 1, "first draft")
      {state, [{:cancelled, "first draft"}]} = Session.cancel(state)
      {state, _} = utterance(state, 2, "second draft", @t0 + 10)

      # Restoring here would destroy "second draft" — the exact failure mode
      # this whole affordance exists to prevent.
      {unchanged, []} = Session.restore(state)
      assert unchanged.draft == "second draft"
      assert unchanged.last_cancelled_draft == "first draft"
    end

    test "a cancel that clears nothing records nothing" do
      {state, effects} = utterance(Session.new(), 1, "or cut cancel.")

      assert [%{action: "cancel", detail: detail}] = results(effects)
      assert detail =~ "empty draft"
      assert state.arming_until == nil
      refute Session.snapshot(state, @t0).restorable

      # ...and it cannot erase an earlier undo either.
      {state, _} = utterance(state, 2, "something worth keeping", @t0 + 10)
      {state, [{:cancelled, _}]} = Session.cancel(state)
      {state, _} = utterance(state, 3, "or cut cancel.", @t0 + 20)
      assert state.last_cancelled_draft == "something worth keeping"
    end

    # Dictation that came BEFORE the command word is still dictation, exactly
    # as it is for `:send`. An aborted cancel must not eat it.
    test "the stripped remainder is appended, not discarded" do
      {state, _} = utterance(Session.new(), 1, "keep this")
      {state, _} = utterance(state, 2, "and this too or cut cancel.", @t0 + 10)

      assert state.draft == "keep this and this too"
      assert state.arming_kind == :cancel

      {state, [{:cancelled, lost}]} = Session.tick(state, @t0 + 10 + 1500)
      assert lost == "keep this and this too"

      {state, []} = Session.restore(state)
      assert state.draft == "keep this and this too"
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

      {sending, _} = Session.send_now(armed, @t0)
      assert Session.snapshot(sending, @t0).status == "sending"

      {errored, _} = Session.send_failed(sending, "Session is busy")
      assert Session.snapshot(errored, @t0).status == "error"
    end

    test "arming_ms counts down and never goes negative" do
      {state, _} = utterance(Session.new(), 1, "ship it orca send")

      assert Session.snapshot(state, @t0 + 400).arming_ms == 1100
      assert Session.snapshot(state, @t0 + 9_999).arming_ms == 0
    end
  end

  # -- phase 2c: focus, the new intent classes, ui_action (spec §8.3) --------

  defp ui_actions(effects), do: for({:ui_action, kind, payload} <- effects, do: {kind, payload})

  # `ui_focus` is pure and effect-free, so the assertion is part of the helper.
  defp focused(state, focus, candidates \\ []) do
    {state, []} = Session.ui_focus(state, focus, candidates)
    state
  end

  # The wire shape §8.3.5 says the client sends: 0-based index, visible label.
  @candidates [
    %{"index" => 0, "label" => "Deploy the hub"},
    %{"index" => 1, "label" => "Voice mode phase 2c"}
  ]

  describe "focus (§8.3.1)" do
    test "a fresh session is composer-focused, and the snapshot echoes focus back" do
      state = Session.new()
      assert state.focus == "composer"
      assert Session.snapshot(state, @t0).focus == "composer"

      state = focused(state, "palette", @candidates)
      assert state.focus == "palette"
      assert state.candidates == @candidates
      assert Session.snapshot(state, @t0).focus == "palette"
    end

    test "anything that is not \"palette\" reads as composer" do
      for value <- ["composer", "Palette", "PALETTE", nil, "", 42] do
        assert focused(Session.new(), value).focus == "composer",
               "#{inspect(value)} was read as palette focus"
      end
    end

    test "candidates are capped at nine, and a missing list is empty" do
      many = for i <- 0..20, do: %{"index" => i, "label" => "item #{i}"}

      assert length(focused(Session.new(), "palette", many).candidates) == 9
      assert focused(Session.new(), "palette", nil).candidates == []
      assert focused(Session.new(), "palette").candidates == []
    end

    test "reporting focus is a report about the DOM, so it never disarms a send" do
      {state, _} = utterance(Session.new(), 1, "ship it orca send")
      assert state.arming_until == @t0 + 1500

      assert focused(state, "palette", @candidates).arming_until == @t0 + 1500
    end
  end

  describe "the new intent classes in composer focus (§8.3.6)" do
    test ":insert appends the payload text and emits NO ui_action" do
      {state, effects} = utterance(Session.new(), 1, "first line orca new line")

      assert [%{action: "insert", intent: "new_line"}] = results(effects)
      # The client learns about it through the ordinary `state` snapshot —
      # that is what mirrors it into the real composer with an `input` event.
      assert ui_actions(effects) == []
      assert state.draft == "first line\n"
    end

    test ":select emits a 1-BASED ordinal and leaves the draft alone" do
      {state, _} = utterance(Session.new(), 1, "some dictation")
      {state, effects} = utterance(state, 2, "orca third item")

      assert [%{action: "select", intent: "third"}] = results(effects)
      assert ui_actions(effects) == [{"select", %{ordinal: 3}}]
      assert state.draft == "some dictation"
    end

    test ":select discards its remainder — a selection is not dictation" do
      {state, effects} = utterance(Session.new(), 1, "hmm let me see orca first item")

      assert [%{action: "select", intent: "first"}] = results(effects)
      assert ui_actions(effects) == [{"select", %{ordinal: 1}}]
      assert state.draft == ""
    end

    test ":navigate emits the payload's kind, with :kind stripped out of the payload" do
      for {said, expected} <- [
            {"orca search", {"open_palette", %{}}},
            {"orca open", {"open_palette", %{}}},
            {"orca back", {"back", %{}}},
            {"orca all sessions", {"navigate", %{path: "/sessions"}}},
            {"orca new session", {"navigate", %{path: "/sessions/new"}}},
            {"orca help menu", {"open_help", %{}}}
          ] do
        {state, _} = utterance(Session.new(), 1, "keep this")
        {state, effects} = utterance(state, 2, said)

        assert [%{action: "navigate"}] = results(effects), "#{said} did not navigate"
        assert ui_actions(effects) == [expected]
        assert state.draft == "keep this"
      end
    end

    test "\"orca help menu\" routes itself: no new clause, no draft, no arming (ORCAHUB3-92)" do
      # The point of §8.3.6's dispatch-on-class: `:help` was added to `Intent`
      # alone and arrived here as a `:navigate` with a new kind. If this test
      # ever needs a `route/7` clause of its own, the class is wrong.
      {state, _} = utterance(Session.new(), 1, "keep this draft")
      {armed, _} = utterance(state, 2, "orca send", @t0 + 10)
      assert armed.arming_until != nil

      {state, effects} = utterance(armed, 3, "what can I say orca help menu", @t0 + 20)

      assert [%{action: "navigate", intent: "help"}] = results(effects)
      assert ui_actions(effects) == [{"open_help", %{}}]

      # A navigation utterance is not dictation, so the whole of it — command
      # and the "what can I say" in front of it — is discarded and the draft is
      # exactly what it was...
      assert state.draft == "keep this draft"
      # ...and a help panel is not a send: the arming window is closed, not
      # opened, so the pending "orca send" cannot land behind it.
      assert state.arming_until == nil
      refute state.sending
    end

    test "routing is by class, so every vocabulary entry has a home" do
      # The guard against a future `Intent` entry that this module has never
      # heard of: whatever it is, it routes somewhere, and never crashes.
      for {name, phrase} <- Intent.command_vocab() do
        {state, effects} = utterance(Session.new(), 1, phrase)

        assert [%{action: action, intent: intent}] = results(effects),
               "#{phrase} produced #{inspect(actions(effects))}"

        assert intent == to_string(name)
        assert action in ~w(send dropped_command_only cancel ignored_stop_pause insert select
                            navigate)

        refute state.sending, "#{phrase} set `sending`"
      end
    end
  end

  describe "the new intent classes in palette focus (§8.3.6)" do
    setup do
      {state, _} = utterance(Session.new(), 1, "draft I care about")
      {:ok, state: focused(state, "palette", @candidates)}
    end

    test ":send is ignored outright — draft untouched, nothing armed", %{state: state} do
      {state, effects} = utterance(state, 2, "ship it orca send", @t0 + 10)

      assert [%{action: "ignored_palette_focus", intent: "send"}] = results(effects)
      assert state.draft == "draft I care about"
      assert state.arming_until == nil
      assert ui_actions(effects) == []
      refute state.sending
    end

    test ":cancel closes the palette and does NOT clear the draft", %{state: state} do
      {state, effects} = utterance(state, 2, "or cut cancel.", @t0 + 10)

      assert [%{action: "cancel", intent: "cancel"}] = results(effects)
      assert ui_actions(effects) == [{"close_palette", %{}}]
      assert state.draft == "draft I care about"
    end

    test ":insert is ignored — the draft is untouchable while the palette is open",
         %{state: state} do
      {state, effects} = utterance(state, 2, "orca hashtag", @t0 + 10)

      assert [%{action: "ignored_palette_focus", intent: "hashtag"}] = results(effects)
      assert state.draft == "draft I care about"
      refute state.pending_insert
    end

    test ":stop does not append its remainder either", %{state: state} do
      {state, effects} = utterance(state, 2, "hang on Orcastop.", @t0 + 10)

      assert [%{action: "ignored_stop_pause", intent: "stop"}] = results(effects)
      assert state.draft == "draft I care about"
    end

    test ":select and :navigate work in either focus", %{state: state} do
      {selected, effects} = utterance(state, 2, "orca first item", @t0 + 10)
      assert actions(effects) == ["select"]
      assert ui_actions(effects) == [{"select", %{ordinal: 1}}]
      assert selected.draft == "draft I care about"

      {_navigated, effects} = utterance(state, 2, "orca back", @t0 + 10)
      assert actions(effects) == ["navigate"]
      assert ui_actions(effects) == [{"back", %{}}]
    end

    test "a non-command utterance becomes a palette query, never a draft append",
         %{state: state} do
      {state, effects} = utterance(state, 2, "the deploy script", @t0 + 10)

      assert [%{action: "palette_query", intent: nil}] = results(effects)
      assert ui_actions(effects) == [{"palette_query", %{text: "the deploy script"}}]
      assert state.draft == "draft I care about"
    end

    test "a spoken palette query is stripped of the ASR's sentence punctuation",
         %{state: state} do
      # Every filter behind the palette is a literal `String.contains?`, and
      # the ASR punctuates nearly every utterance — so an unstripped period
      # takes a query that matched one row to matching none.
      for {heard, wire} <- [
            {"the deploy script.", "the deploy script"},
            {"the deploy script?", "the deploy script"},
            {"the deploy script!", "the deploy script"},
            {"the deploy script,", "the deploy script"},
            {"the deploy script...", "the deploy script"},
            {"the deploy script. ", "the deploy script"}
          ] do
        {_state, effects} = utterance(state, 2, heard, @t0 + 10)

        assert ui_actions(effects) == [{"palette_query", %{text: wire}}],
               "heard #{inspect(heard)} should reach the palette as #{inspect(wire)}"
      end
    end

    test "stripping is spoken-query-only: dictation keeps its punctuation" do
      {state, effects} = utterance(Session.new(), 1, "ship it. then tell me.", @t0)

      assert actions(effects) == ["appended"]
      assert state.draft == "ship it. then tell me."
    end

    test "a palette query REPLACES rather than accumulating", %{state: state} do
      {state, effects} = utterance(state, 2, "the deploy script", @t0 + 10)
      assert ui_actions(effects) == [{"palette_query", %{text: "the deploy script"}}]

      {_state, effects} = utterance(state, 3, "some dictation", @t0 + 20)
      assert ui_actions(effects) == [{"palette_query", %{text: "some dictation"}}]
    end

    test "a non-command utterance that NAMES a candidate selects it by index",
         %{state: state} do
      {state, effects} = utterance(state, 2, "deploy the hub", @t0 + 10)

      assert [%{action: "select", intent: nil, detail: "matched Deploy the hub"}] =
               results(effects)

      assert ui_actions(effects) == [{"select", %{index: 0, label: "Deploy the hub"}}]
      assert state.draft == "draft I care about"
    end

    test "a NEAR miss falls through to a palette query rather than guessing (§8.3.8)" do
      # Two candidates a hair apart: over the 0.85 threshold but inside the
      # 0.10 margin, so the matcher refuses to pick one.
      state =
        focused(Session.new(), "palette", [
          %{"index" => 0, "label" => "Deploy the hub"},
          %{"index" => 1, "label" => "Deploy the hubs"}
        ])

      {_state, effects} = utterance(state, 1, "deploy the hub")

      assert actions(effects) == ["palette_query"]
      assert ui_actions(effects) == [{"palette_query", %{text: "deploy the hub"}}]
    end

    test "with no candidates reported at all, everything is a query", %{state: state} do
      state = focused(state, "palette", [])
      {_state, effects} = utterance(state, 2, "deploy the hub", @t0 + 10)

      assert actions(effects) == ["palette_query"]
    end
  end

  describe "insert join rules (§8.3.7)" do
    test "a newline insert trims the draft's trailing whitespace and concatenates" do
      {state, _} = Session.draft_edit(Session.new(), "first line   ")
      {state, effects} = utterance(state, 1, "orca new line")

      assert actions(effects) == ["insert"]
      assert state.draft == "first line\n"
      refute state.pending_insert

      {state, _} = utterance(state, 2, "orca new paragraph", @t0 + 10)
      assert state.draft == "first line\n\n"
    end

    test "a hashtag insert space-joins, and the NEXT transcript lands flush against it" do
      {state, _} = utterance(Session.new(), 1, "look at")
      {state, effects} = utterance(state, 2, "orca hashtag", @t0 + 10)

      assert actions(effects) == ["insert"]
      assert state.draft == "look at #"
      assert state.pending_insert

      {state, effects} = utterance(state, 3, "voice", @t0 + 20)
      assert actions(effects) == ["appended"]
      assert state.draft == "look at #voice"
      refute state.pending_insert

      # ...and the one after that is an ordinary space join again.
      {state, _} = utterance(state, 4, "mode", @t0 + 30)
      assert state.draft == "look at #voice mode"
    end

    test "both spellings of each trigger produce the same text" do
      for {said, expected} <- [
            {"orca hashtag", "#"},
            {"orca session search", "#"},
            {"orca double hashtag", "##"},
            {"orca project search", "##"}
          ] do
        {state, _} = utterance(Session.new(), 1, said)
        assert state.draft == expected, "#{said} inserted #{inspect(state.draft)}"
        assert state.pending_insert
      end
    end

    test "a hashtag insert on an empty draft, or after whitespace, does not double-space" do
      {state, _} = utterance(Session.new(), 1, "orca double hashtag")
      assert state.draft == "##"

      {state, _} = Session.draft_edit(Session.new(), "note: ")
      {state, _} = utterance(state, 1, "orca hashtag")
      assert state.draft == "note: #"
    end

    test "the remainder joins with the ordinary space rule BEFORE the payload goes on" do
      {state, _} = utterance(Session.new(), 1, "see")
      {state, effects} = utterance(state, 2, "the logs orca new line", @t0 + 10)

      assert actions(effects) == ["insert"]
      assert state.draft == "see the logs\n"
    end

    test "the segment consuming a # trigger loses the ASR's sentence punctuation" do
      # The session search behind the trigger is an ILIKE on the raw text, so
      # `#Voice.` matches nothing where `#Voice` matches two.
      for {heard, draft} <- [
            {"voice.", "#voice"},
            {"voice?", "#voice"},
            {"voice!", "#voice"},
            {"voice,", "#voice"},
            {"voice...", "#voice"}
          ] do
        {state, _} = utterance(Session.new(), 1, "orca session search")
        assert state.pending_insert

        {state, effects} = utterance(state, 2, heard, @t0 + 10)
        assert actions(effects) == ["appended"]
        assert state.draft == draft, "heard #{inspect(heard)} produced #{inspect(state.draft)}"
      end
    end

    test "stripping is scoped to the trigger: ordinary dictation keeps its punctuation" do
      {state, _} = utterance(Session.new(), 1, "ship it.")
      assert state.draft == "ship it."

      {state, _} = utterance(state, 2, "then tell me.", @t0 + 10)
      assert state.draft == "ship it. then tell me."
    end

    test "a NEWLINE insert never sets pending_insert, so the next line keeps its full stop" do
      {state, _} = utterance(Session.new(), 1, "hello there.")
      {state, _} = utterance(state, 2, "orca new line", @t0 + 10)
      refute state.pending_insert

      {state, _} = utterance(state, 3, "good morning.", @t0 + 20)
      assert state.draft == "hello there.\ngood morning."
    end

    test "pending_insert is cleared by ANOTHER insert" do
      {state, _} = utterance(Session.new(), 1, "orca hashtag")
      assert state.pending_insert

      {state, _} = utterance(state, 2, "orca new line", @t0 + 10)
      refute state.pending_insert
      assert state.draft == "#\n"
    end

    test "pending_insert is cleared by cancel, by a draft edit and by a send" do
      {hash, _} = utterance(Session.new(), 1, "orca hashtag")
      assert hash.pending_insert

      {cancelled, _} = Session.cancel(hash)
      refute cancelled.pending_insert

      {edited, _} = Session.draft_edit(hash, "typed")
      refute edited.pending_insert

      {requested, _} = Session.send_now(hash, @t0)
      refute requested.pending_insert

      {sent, _} = Session.sent_ack(requested)
      refute sent.pending_insert
    end

    # §8.3.11: `pending_insert` dies when the cancel LANDS, not when its
    # window expires — the `#` it was going to feed is not being typed into
    # any more either way, and an aborted cancel must not leave a stale one.
    test "a SPOKEN cancel clears pending_insert too" do
      {state, _} = utterance(Session.new(), 1, "orca hashtag")
      {state, effects} = utterance(state, 2, "or cut cancel.", @t0 + 10)

      assert actions(effects) == ["cancel"]
      refute state.pending_insert

      {state, [{:cancelled, "#"}]} = Session.tick(state, @t0 + 10 + 1500)
      assert state.draft == ""
    end

    # §8.3.7 as amended: an append never doubles a separator. Without this,
    # every spoken newline put a leading space on the line it had just
    # opened — visible in the composer on every single use.
    test "a transcript after a NEWLINE insert lands flush, with no leading space" do
      {state, _} = utterance(Session.new(), 1, "first line orca new line")
      {state, _} = utterance(state, 2, "second line", @t0 + 10)

      assert state.draft == "first line\nsecond line"

      # ...and the line after that still space-joins normally.
      {state, _} = utterance(state, 3, "and more", @t0 + 20)
      assert state.draft == "first line\nsecond line and more"
    end

    test "a paragraph insert keeps BOTH newlines, with no space after them" do
      {state, _} = utterance(Session.new(), 1, "intro orca new paragraph")
      {state, _} = utterance(state, 2, "body", @t0 + 10)

      assert state.draft == "intro\n\nbody"
    end

    test "the same rule saves a HAND-TYPED trailing space from doubling" do
      {state, _} = Session.draft_edit(Session.new(), "hello ")
      {state, effects} = utterance(state, 1, "world")

      assert actions(effects) == ["appended"]
      assert state.draft == "hello world"
    end
  end

  describe "arming and the phase 2c classes (§8.3.6)" do
    test "an insert, a selection, a navigation and a palette query all CANCEL an open window" do
      armed = fn ->
        {state, _} = utterance(Session.new(), 1, "ship it orca send")
        assert state.arming_until == @t0 + 1500
        state
      end

      for said <- ["orca new line", "orca third item", "orca back", "orca search"] do
        {state, effects} = utterance(armed.(), 2, said, @t0 + 100)

        assert state.arming_until == nil, "#{said} left the arming window open"
        refute Enum.any?(effects, &match?({:schedule_tick, _}, &1))
        assert Session.snapshot(state, @t0 + 100).status != "arming"
      end

      {state, _} =
        utterance(focused(armed.(), "palette", @candidates), 2, "the deploy script", @t0 + 100)

      assert state.arming_until == nil
    end

    test "and NONE of them ever opens one" do
      for said <- ["orca new line", "orca third item", "orca back", "orca search"] do
        {state, effects} = utterance(Session.new(), 1, said)

        assert state.arming_until == nil, "#{said} armed a send"
        refute state.sending
        refute Enum.any?(effects, &match?({:schedule_tick, _}, &1))
        refute Enum.any?(effects, &match?({:send_request, _}, &1))
      end
    end
  end
end
