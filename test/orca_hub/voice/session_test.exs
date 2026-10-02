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
    assert [{:dispatch, ^seq, _pcm, _asr_opts}] = dispatch
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
      assert [{:dispatch, 2, _pcm, _asr_opts}] = dispatch

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
      assert [{:dispatch, 2, _pcm, _asr_opts}] = dispatch

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

    # §8.3.11 had to answer this explicitly: a SPOKEN cancel is armed now, so
    # does an outstanding `send_request` die when the cancel LANDS or when it
    # FIRES? The two halves are separable and are separated:
    #
    #   * abandoning the send is NOT destructive, so it happens at LAND time.
    #     Waiting for the window would let the 5 s deadline in
    #     `expire_send_request/2` deliver — and on the no-composer branch that
    #     is a real delivery of the very text being cancelled, i.e.
    #     ORCAHUB3-86 resurrected.
    #   * clearing the DRAFT is destructive, so it waits for the window.
    #
    # Note what state this can even be reached in: the composer round trip is
    # ~100 ms, while a spoken command cannot land sooner than ~1.1 s (600 ms
    # VAD redemption + ~0.5 s ASR). A cancel that still sees `send_pending` is
    # therefore always the STUCK-composer path — where the draft demonstrably
    # has NOT been delivered and still needs protecting (see the fixture
    # above: `request_send/2` leaves `draft` intact).
    test "a SPOKEN cancel abandons the send_request at LAND time, not at fire time",
         %{armed: state} do
      assert state.send_pending
      assert state.draft == "ship it"

      {state, effects} = utterance(state, 2, "or cut cancel.", @t0 + 1600)
      assert actions(effects) == ["cancel"]

      # Dead on arrival: the deadline can no longer deliver anything.
      assert state.send_pending == nil
      refute state.sending
      # ...but the draft is only counting down.
      assert state.draft == "ship it"
      assert state.arming_kind == :cancel

      {state, effects} = Session.tick(state, @t0 + 60_000)
      assert effects == [{:cancelled, "ship it"}]
      assert state.draft == ""
    end

    # The property that makes the choice above safe rather than merely early:
    # aborting the cancel must NOT resurrect the send. The cost of getting
    # this wrong in the other direction is an unwanted delivery; the cost of
    # this direction is saying "orca send" again, which is §5.1.1's own cheap
    # side of the asymmetry.
    test "aborting the cancel leaves the draft intact and the send still abandoned",
         %{armed: state} do
      {state, _} = utterance(state, 2, "or cut cancel.", @t0 + 1600)
      {state, []} = Session.speech_start(state)

      assert state.arming_until == nil
      assert state.draft == "ship it"
      assert state.send_pending == nil

      # Nothing delivers, ever, without the user asking again.
      assert {state, []} = Session.tick(state, @t0 + 120_000)
      assert state.draft == "ship it"

      # And asking again works, from a clean slate.
      {state, [{:send_request, "ship it"}, _tick]} = Session.send_now(state, @t0 + 130_000)
      assert state.send_pending
    end

    # The reverse race: an explicit send during an armed cancel. `request_send`
    # disarms, so the send wins and no clear is left pending behind it.
    test "a manual send during an armed cancel wins, and kills the window" do
      {state, _} = utterance(Session.new(), 1, "ship it")
      {state, _} = utterance(state, 2, "or cut cancel.", @t0 + 10)
      assert state.arming_kind == :cancel

      {state, [{:send_request, "ship it"} | _]} = Session.send_now(state, @t0 + 20)
      assert state.arming_until == nil
      assert state.arming_kind == nil

      {state, effects} = Session.tick(state, @t0 + 20 + 1500)
      refute Enum.any?(effects, &match?({:cancelled, _}, &1))
      assert state.draft == "ship it"
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
      assert [{:dispatch, 1, _, _}] = dispatch

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
      assert [{:dispatch, 2, merged, _asr_opts}] = effects
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
      assert [{:dispatch, 1, _pcm, _asr_opts}] = effects
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
      refute Enum.any?(effects, &match?({:dispatch, _, _, _}, &1))
      assert state.awaiting == []
    end

    test "exactly 0.8 s dispatches and exactly 20 s is still allowed" do
      assert {_s, [{:dispatch, 1, _, _}]} =
               Session.segment_received(Session.new(), frame(1, 12_800), @t0)

      assert {_s, [{:dispatch, 2, _, _}]} =
               Session.segment_received(Session.new(), frame(2, 320_000), @t0)
    end
  end

  describe "mic state" do
    test "a segment arriving while muted is dropped without dispatch" do
      {state, _} = Session.mic(Session.new(), true)
      {state, effects} = Session.segment_received(state, frame(1, 16_000), @t0)

      assert [%{seq: 1, action: "dropped_muted"}] = results(effects)
      refute Enum.any?(effects, &match?({:dispatch, _, _, _}, &1))
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
      {state, effects} = utterance(state, 2, "orca select third")

      assert [%{action: "select", intent: "third"}] = results(effects)
      assert ui_actions(effects) == [{"select", %{ordinal: 3}}]
      assert state.draft == "some dictation"
    end

    test ":select discards its remainder — a selection is not dictation" do
      {state, effects} = utterance(Session.new(), 1, "hmm let me see orca select first")

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
      {selected, effects} = utterance(state, 2, "orca select first", @t0 + 10)
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

      for said <- ["orca new line", "orca select third", "orca back", "orca search"] do
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
      for said <- ["orca new line", "orca select third", "orca back", "orca search"] do
        {state, effects} = utterance(Session.new(), 1, said)

        assert state.arming_until == nil, "#{said} armed a send"
        refute state.sending
        refute Enum.any?(effects, &match?({:schedule_tick, _}, &1))
        refute Enum.any?(effects, &match?({:send_request, _}, &1))
      end
    end
  end

  describe "the Whisper prompt on each dispatch" do
    @vocab "OrcaHub, GB10, Darling Court"

    # The `initial_prompt` a long segment would be dispatched with right now.
    defp prompt_for(state, seq, now \\ @t0) do
      {_state, effects} = Session.segment_received(state, frame(seq, 16_000), now)
      assert [{:dispatch, ^seq, _pcm, asr_opts}] = effects
      Keyword.fetch!(asr_opts, :initial_prompt)
    end

    test "vocabulary first, then the draft as of dispatch" do
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "Deploy the hub to mini")

      assert prompt_for(state, 2) == "OrcaHub, GB10, Darling Court. Deploy the hub to mini"
    end

    test "an empty draft sends the vocabulary alone, and nothing at all sends \"\"" do
      assert prompt_for(Session.new(vocabulary: @vocab), 1) == "OrcaHub, GB10, Darling Court."
      assert prompt_for(Session.new(), 1) == ""
    end

    test "a hand-typed draft counts as context too" do
      {state, _} = Session.draft_edit(Session.new(vocabulary: @vocab), "note for\nZach:")
      assert prompt_for(state, 1) == "OrcaHub, GB10, Darling Court. note for Zach:"
    end

    test "a long draft contributes only its tail, bounded and word-aligned" do
      draft = Enum.map_join(1..300, " ", &"word#{&1}")
      {state, _} = Session.draft_edit(Session.new(vocabulary: @vocab), draft)

      prompt = prompt_for(state, 1)
      assert String.length(prompt) <= OrcaHub.Voice.Prompt.max_chars()
      assert String.ends_with?(prompt, "word299 word300")

      "OrcaHub, GB10, Darling Court. " <> tail = prompt
      assert String.ends_with?(draft, " " <> tail)
    end

    test "the command words never reach it — they are stripped before the append" do
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "let's ship it orca send")
      assert state.draft == "let's ship it"

      prompt = prompt_for(state, 2, @t0 + 100)
      assert prompt == "OrcaHub, GB10, Darling Court. let's ship it"
      refute prompt =~ ~r/orca send/i
    end

    test "palette focus leaves the draft out: the segment is a query or a command" do
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "Deploy the hub")
      state = focused(state, "palette", @candidates)

      assert prompt_for(state, 2) == "OrcaHub, GB10, Darling Court."

      # ...and it comes back with composer focus.
      assert prompt_for(focused(state, "composer"), 2) ==
               "OrcaHub, GB10, Darling Court. Deploy the hub"
    end

    test "a pending # insert leaves the draft out: the segment is a search query" do
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "look at")
      {state, _} = utterance(state, 2, "orca hashtag", @t0 + 10)
      assert state.pending_insert

      assert prompt_for(state, 3, @t0 + 20) == "OrcaHub, GB10, Darling Court."

      # Once the query has consumed the trigger, the draft is context again.
      {state, _} = utterance(state, 3, "voice", @t0 + 20)
      refute state.pending_insert
      assert prompt_for(state, 4, @t0 + 30) == "OrcaHub, GB10, Darling Court. look at #voice"
    end

    test "a newline insert is NOT a query, so the draft still rides along" do
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "see the logs orca new line")
      refute state.pending_insert

      assert prompt_for(state, 2, @t0 + 10) == "OrcaHub, GB10, Darling Court. see the logs"
    end

    test "draft_context: false sends the vocabulary alone" do
      state = Session.new(vocabulary: @vocab, draft_context: false)
      {state, _} = utterance(state, 1, "Deploy the hub")

      assert prompt_for(state, 2) == "OrcaHub, GB10, Darling Court."
    end

    test "an earlier segment still in flight is absent from a later one's context" do
      # Accepted, not a bug: segments are transcribed concurrently and applied
      # in dispatch order, so seq 2's prompt can only quote what had landed.
      {state, _} = utterance(Session.new(vocabulary: @vocab), 1, "first")
      {state, [{:dispatch, 2, _, _}]} = Session.segment_received(state, frame(2, 16_000), @t0)

      assert prompt_for(state, 3) == "OrcaHub, GB10, Darling Court. first"
    end

    test "a held segment dispatched at hold expiry is prompted as of THAT moment" do
      state = Session.new(vocabulary: @vocab)
      {state, _} = Session.segment_received(state, frame(1, 9_600, flags: 0x2), @t0)
      {state, _} = Session.draft_edit(state, "typed meanwhile")

      {_state, [{:dispatch, 1, _pcm, asr_opts}]} = Session.tick(state, @t0 + 1500)
      assert asr_opts[:initial_prompt] == "OrcaHub, GB10, Darling Court. typed meanwhile"
    end
  end

  # ORCAHUB3-120. The draft is partitioned into RAW dictation spans and
  # SETTLED text; only a contiguous run of raw spans is ever sent to the
  # cleanup model, and its answer lands only on the exact spans it was
  # computed from.
  describe "rolling cleanup (ORCAHUB3-120)" do
    @dictation_fixture Path.expand(
                         "../../support/fixtures/voice/dictation_orcahub3_99.json",
                         __DIR__
                       )

    defp cs(opts \\ []), do: Session.new(Keyword.merge([cleanup: true], opts))

    defp cleanups(effects), do: for({:cleanup, id, input} <- effects, do: {id, input})

    defp kinds(state), do: Enum.map(state.spans, & &1.kind)

    defp ok(text), do: {:ok, text, %{model: "gemma-4-26B-A4B", latency_ms: 590}}

    defp assert_partition(state) do
      assert Enum.map_join(state.spans, &(&1.sep <> &1.text)) == state.draft
      state
    end

    test "disabled — the default — never emits a cleanup or an idle tick" do
      for state <- [Session.new(), Session.new(cleanup: false)] do
        {state, e1} = utterance(state, 1, "one thing.")
        {state, e2} = utterance(state, 2, "Another thing.", @t0 + 10)
        {state, e3} = utterance(state, 3, "ship it orca send", @t0 + 20)
        {state, e4} = Session.tick(state, @t0 + 20 + 1500)
        {state, e5} = Session.tick(state, @t0 + 60_000)
        {state, e6} = Session.speech_start(state, @t0 + 60_001)
        {state, e7} = Session.speech_misfire(state, @t0 + 60_002)
        {_state, e8} = Session.mic(state, true, @t0 + 60_003)

        assert [{:segment_result, _}] = e1
        assert [{:segment_result, _}] = e2
        assert e6 ++ e7 ++ e8 == []
        all = e1 ++ e2 ++ e3 ++ e4 ++ e5
        assert cleanups(all) == []

        assert for({:schedule_tick, _} = t <- all, do: t) == [
                 {:schedule_tick, 1500},
                 {:schedule_tick, 5000}
               ]
      end
    end

    test "one raw segment waits; the second sends both, joined exactly as in the draft" do
      {state, effects} = utterance(cs(), 1, "So the thing is.")
      assert cleanups(effects) == []
      assert {:schedule_tick, 2000} in effects

      {state, effects} = utterance(state, 2, "It keeps disconnecting.", @t0 + 300)

      assert [{1, %{context: "", raw: "So the thing is. It keeps disconnecting."}}] =
               cleanups(effects)

      # The slot's own deadline: the module's timeout plus grace.
      assert {:schedule_tick, 5000} in effects
      assert state.cleanup_inflight.id == 1
      assert kinds(state) == [:raw, :raw]
    end

    test "an ok answer replaces exactly the batch with one settled span" do
      {state, _} = utterance(cs(), 1, "So the thing is.")
      {state, _} = utterance(state, 2, "It keeps disconnecting.", @t0 + 300)

      {state, effects} =
        Session.cleanup_result(
          state,
          1,
          ok("So the thing is, it keeps disconnecting."),
          @t0 + 900
        )

      assert effects == []
      assert state.draft == "So the thing is, it keeps disconnecting."
      assert kinds(state) == [:settled]
      assert state.cleanup_inflight == nil
    end

    test "the context is the settled text before the batch, and the batch keeps its separator" do
      {state, _} = Session.draft_edit(cs(), "Typed intro.")
      {state, _} = utterance(state, 1, "and then.")
      {state, effects} = utterance(state, 2, "We ship.", @t0 + 10)

      assert [{1, %{context: "Typed intro.", raw: "and then. We ship."}}] = cleanups(effects)

      {state, _} = Session.cleanup_result(state, 1, ok("And then we ship."), @t0 + 20)
      assert state.draft == "Typed intro. And then we ship."
      assert_partition(state)
    end

    test "the context is the last ~400 characters, word-aligned, with its layout kept" do
      long = Enum.map_join(1..200, " ", &"w#{&1}") <> "\n- item"
      {state, _} = Session.draft_edit(cs(), long)
      {state, _} = utterance(state, 1, "one.")
      {_state, effects} = utterance(state, 2, "Two.", @t0 + 10)

      [{1, %{context: context, raw: "one. Two."}}] = cleanups(effects)
      assert String.length(context) <= 400
      assert String.ends_with?(context, "w200\n- item")
      assert String.ends_with?(long, context)
      # ...and it starts on a whole word, not half of one.
      cut = String.slice(long, 0, String.length(long) - String.length(context))
      assert String.ends_with?(cut, " ")
    end

    test "one batch at a time; a segment that lands meanwhile stays raw behind the replacement" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, e3} = utterance(state, 3, "Gamma.", @t0 + 20)
      {state, e4} = utterance(state, 4, "Delta.", @t0 + 30)
      assert cleanups(e3 ++ e4) == []

      {state, effects} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 600)

      assert state.draft == "Alpha, beta. Gamma. Delta."
      assert kinds(state) == [:settled, :raw, :raw]
      # The next batch goes out in the same transition, with the CLEANED text
      # as its context — answers apply strictly in order.
      assert [{2, %{context: "Alpha, beta.", raw: "Gamma. Delta."}}] = cleanups(effects)
    end

    test "an answer for anything but the batch in flight is ignored" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

      assert {^state, []} = Session.cleanup_result(state, 7, ok("nope"), @t0 + 20)
      assert {^state, []} = Session.cleanup_result(state, 0, ok("nope"), @t0 + 20)

      # ...including a duplicate of one already applied.
      {state, _} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 30)
      assert {^state, []} = Session.cleanup_result(state, 1, ok("again"), @t0 + 40)
      assert state.draft == "Alpha, beta."
    end

    test "a batch holds at most four segments and ~80 words; the rest waits its turn" do
      {state, _} = utterance(cs(), 1, "s1.")
      {state, _} = utterance(state, 2, "s2.", @t0 + 10)

      state =
        Enum.reduce(3..8, state, fn n, st ->
          {st, effects} = utterance(st, n, "s#{n}.", @t0 + 10 * n)
          assert cleanups(effects) == []
          st
        end)

      {state, effects} = Session.cleanup_result(state, 1, ok("S1, s2."), @t0 + 100)
      assert [{2, %{raw: "s3. s4. s5. s6."}}] = cleanups(effects)

      {_state, effects} = Session.cleanup_result(state, 2, ok("S3 to s6."), @t0 + 200)
      assert [{3, %{context: "S1, s2. S3 to s6.", raw: "s7. s8."}}] = cleanups(effects)

      # The word cap: 30 + 30 fit, a third 30 would not; one long segment
      # still goes on its own.
      thirty = Enum.map_join(1..30, " ", &"word#{&1}")
      {state, _} = Session.draft_edit(cs(), "x")
      {state, _} = utterance(state, 1, "a.")
      {state, _} = utterance(state, 2, "b.", @t0 + 10)

      state =
        Enum.reduce(3..5, state, fn n, st ->
          {st, _} = utterance(st, n, thirty, @t0 + 10 * n)
          st
        end)

      {_state, effects} = Session.cleanup_result(state, 1, ok("A, b."), @t0 + 100)
      assert [{2, %{raw: raw}}] = cleanups(effects)
      assert raw == thirty <> " " <> thirty

      hundred = Enum.map_join(1..100, " ", &"w#{&1}")
      {state, _} = utterance(cs(), 1, hundred)
      {_state, effects} = utterance(state, 2, "tail.", @t0 + 10)
      assert [{1, %{raw: ^hundred}}] = cleanups(effects)
    end

    test "idle: a lone segment goes 2000 ms after the last applied transcript" do
      {state, effects} = utterance(cs(), 1, "Just one thought.")
      assert {:schedule_tick, 2000} in effects

      {state, effects} = Session.tick(state, @t0 + 1999)
      assert effects == [{:schedule_tick, 1}]

      {_state, effects} = Session.tick(state, @t0 + 2000)
      assert [{1, %{raw: "Just one thought."}}] = cleanups(effects)
    end

    test "idle never fires while a segment is still on its way to ASR" do
      {state, _} = utterance(cs(), 1, "Just one thought.")

      {state, [{:dispatch, 2, _, _}]} =
        Session.segment_received(state, frame(2, 16_000), @t0 + 500)

      {state, effects} = Session.tick(state, @t0 + 10_000)
      assert cleanups(effects) == []

      # When it lands the run is two segments, so it goes at once.
      {_state, effects} = Session.transcript(state, 2, {:ok, asr("And another.")}, @t0 + 10_100)
      assert [{1, %{raw: "Just one thought. And another."}}] = cleanups(effects)
    end

    test "an insert closes the run: what precedes it goes at once, the insert never does" do
      {state, effects} = utterance(cs(), 1, "see the logs orca new line")

      assert state.draft == "see the logs\n"
      assert kinds(state) == [:raw, :settled]
      assert [{1, %{context: "", raw: "see the logs"}}] = cleanups(effects)

      {state, _} = Session.cleanup_result(state, 1, ok("See the logs."), @t0 + 10)
      assert state.draft == "See the logs.\n"

      {state, _} = utterance(state, 2, "first point.", @t0 + 20)
      {state, effects} = utterance(state, 3, "Second point.", @t0 + 30)

      assert [{2, %{context: "See the logs.\n", raw: "first point. Second point."}}] =
               cleanups(effects)

      assert_partition(state)
    end

    test "a #/## query is never sent: the trigger and the query both settle" do
      {state, _} = utterance(cs(), 1, "look at")
      {state, effects} = utterance(state, 2, "orca hashtag", @t0 + 10)
      assert [{1, %{raw: "look at"}}] = cleanups(effects)

      {state, _} = utterance(state, 3, "voice.", @t0 + 20)
      assert state.draft == "look at #voice"
      assert kinds(state) == [:raw, :settled, :settled]

      {state, effects} = Session.cleanup_result(state, 1, ok("Look at"), @t0 + 30)
      assert state.draft == "Look at #voice"
      assert cleanups(effects) == []

      {_state, effects} = Session.tick(state, @t0 + 60_000)
      assert cleanups(effects) == []
    end

    test "palette focus: nothing goes out, and an answer landing there is dropped and resent" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, []} = Session.ui_focus(state, "palette", [], @t0 + 10)

      {state, effects} = Session.tick(state, @t0 + 10_000)
      assert cleanups(effects) == []

      # Back to the composer: the overdue batch goes at once.
      {state, effects} = Session.ui_focus(state, "composer", [], @t0 + 10_001)
      assert [{1, %{raw: "alpha."}}] = cleanups(effects)

      # The palette opens while it is out; the draft is untouchable there.
      {state, []} = Session.ui_focus(state, "palette", [], @t0 + 10_002)
      {state, []} = Session.cleanup_result(state, 1, ok("Alpha."), @t0 + 10_500)
      assert state.draft == "alpha."
      assert kinds(state) == [:raw]

      {_state, effects} = Session.ui_focus(state, "composer", [], @t0 + 10_600)
      assert [{2, %{raw: "alpha."}}] = cleanups(effects)
    end

    test "rejected and skipped settle the batch as it is, and it is never retried" do
      for result <- [
            {:rejected, :missing_words, %{model: "gemma-4-26B-A4B", latency_ms: 700}},
            {:skip, :no_model_loaded, %{model: nil, latency_ms: 3}},
            {:ok, "   ", %{model: "gemma-4-26B-A4B", latency_ms: 400}}
          ] do
        {state, _} = utterance(cs(), 1, "alpha.")
        {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

        {state, effects} = Session.cleanup_result(state, 1, result, @t0 + 20)
        assert effects == []
        assert state.draft == "alpha. Beta."
        assert kinds(state) == [:settled, :settled]
        assert state.cleanup_inflight == nil

        {_state, effects} = Session.tick(state, @t0 + 60_000)
        assert cleanups(effects) == [], "#{inspect(result)} was retried"
      end
    end

    test "a hand edit that changes the text drops the batch; dictation after it starts fresh" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

      {state, []} = Session.draft_edit(state, "alpha. Beta, gamma")
      assert kinds(state) == [:settled]
      assert state.cleanup_inflight.stale

      # Fresh raw dictation, held back while the stale batch still holds the GPU.
      {state, _} = utterance(state, 3, "delta.", @t0 + 20)
      {state, effects} = utterance(state, 4, "Epsilon.", @t0 + 30)
      assert cleanups(effects) == []

      {state, effects} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 600)
      assert state.draft == "alpha. Beta, gamma delta. Epsilon."
      assert [{2, %{context: "alpha. Beta, gamma", raw: "delta. Epsilon."}}] = cleanups(effects)
    end

    test "an edit that matches the server's draft — the client echoing it — keeps the batch" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

      {state, []} = Session.draft_edit(state, "alpha. Beta.")
      refute state.cleanup_inflight.stale

      {state, _} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 20)
      assert state.draft == "Alpha, beta."
    end

    test "a cancel while a batch is out: the answer never resurrects the draft" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

      {state, [{:cancelled, "alpha. Beta."}]} = Session.cancel(state)
      {state, []} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 20)
      assert state.draft == ""
      assert state.spans == []

      # The undo is what was cancelled, and it comes back as the user's text.
      {state, []} = Session.restore(state)
      assert state.draft == "alpha. Beta."
      assert kinds(state) == [:settled]
    end

    test "a spoken send flushes even a lone raw tail, and the answer lands inside the window" do
      {state, effects} = utterance(cs(), 1, "ship the patch")
      assert cleanups(effects) == []

      {state, effects} = utterance(state, 2, "Orcasend.", @t0 + 800)
      assert actions(effects) == ["dropped_command_only"]
      assert [{1, %{raw: "ship the patch"}}] = cleanups(effects)

      {state, effects} = Session.cleanup_result(state, 1, ok("Ship the patch."), @t0 + 1400)
      assert effects == []
      # A cleanup is not speech: the window is still open.
      assert state.arming_until == @t0 + 800 + 1500

      {_state, effects} = Session.tick(state, @t0 + 800 + 1500)
      assert effects == [{:send_request, "Ship the patch."}, {:schedule_tick, 5000}]
    end

    test "the send never waits: the window expiring with a batch out sends the draft as is" do
      {state, effects} = utterance(cs(), 1, "let's ship it orca send")
      # The command's own remainder is the raw tail the flush sends.
      assert [{1, %{raw: "let's ship it"}}] = cleanups(effects)

      {state, effects} = Session.tick(state, @t0 + 1500)
      assert effects == [{:send_request, "let's ship it"}, {:schedule_tick, 5000}]
      assert state.cleanup_inflight.stale

      {state, []} = Session.cleanup_result(state, 1, ok("Let's ship it."), @t0 + 1600)
      assert state.draft == "let's ship it"

      assert {_state, [{:sent, "let's ship it"}]} = Session.sent_ack(state)
    end

    test "a manual send drops the batch too, and nothing goes out while a send is pending" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)

      {state, [{:send_request, "alpha. Beta."}, _]} = Session.send_now(state, @t0 + 20)
      assert kinds(state) == [:settled]

      {state, _} = utterance(state, 3, "gamma.", @t0 + 30)
      {state, _} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 40)
      {state, effects} = utterance(state, 4, "Delta.", @t0 + 50)
      assert cleanups(effects) == []
      assert state.draft == "alpha. Beta. gamma. Delta."

      # The composer refused: the draft stays, and the dictation after the
      # send is cleaned like any other.
      {state, []} = Session.send_failed(state, "Session is busy")
      {_state, effects} = Session.tick(state, @t0 + 60)
      assert [{2, %{context: "alpha. Beta.", raw: "gamma. Delta."}}] = cleanups(effects)
    end

    test "a lost answer frees the slot at its deadline, settling its batch" do
      {state, _} = utterance(cs(cleanup_timeout_ms: 3000), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, _} = utterance(state, 3, "gamma.", @t0 + 20)
      {state, _} = utterance(state, 4, "Delta.", @t0 + 30)

      {state, effects} = Session.tick(state, @t0 + 10 + 4999)
      assert cleanups(effects) == []

      {state, effects} = Session.tick(state, @t0 + 10 + 5000)
      # "gamma." continues "Beta." (lowercase), a join that waited on the
      # batch in flight and lands the moment it settles.
      assert [{2, %{context: "alpha. Beta", raw: "gamma. Delta."}}] = cleanups(effects)
      assert kinds(state) == [:settled, :settled, :raw, :raw]

      # The lost answer turning up after all changes nothing.
      assert {^state, []} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 6000)
    end

    test "the Whisper prompt quotes the CLEANED text once it has landed" do
      {state, _} = utterance(cs(), 1, "so the thing is.")
      {state, _} = utterance(state, 2, "It keeps disconnecting.", @t0 + 10)

      {state, _} =
        Session.cleanup_result(state, 1, ok("So the thing is, it keeps disconnecting."), @t0 + 20)

      assert prompt_for(state, 3, @t0 + 30) == "So the thing is, it keeps disconnecting."
    end

    test "the draft is always exactly its spans, through every kind of transition" do
      steps = [
        &utterance(&1, 1, "one."),
        &utterance(&1, 2, "Two. orca new line", @t0 + 10),
        &utterance(&1, 3, "three.", @t0 + 20),
        &Session.cleanup_result(&1, 1, ok("One, two."), @t0 + 30),
        &utterance(&1, 4, "Four orca hashtag", @t0 + 40),
        &utterance(&1, 5, "query.", @t0 + 50),
        &Session.cleanup_result(&1, 2, ok("Three, four"), @t0 + 60),
        &utterance(&1, 6, "five.", @t0 + 70),
        &utterance(&1, 7, "orca new paragraph", @t0 + 80),
        &Session.draft_edit(&1, &1.draft <> " typed"),
        &utterance(&1, 8, "six.", @t0 + 90),
        &Session.tick(&1, @t0 + 10_000),
        &Session.cleanup_result(&1, &1.cleanup_seq, {:rejected, :novel_words, %{}}, @t0 + 10_100),
        &utterance(&1, 9, "seven orca send", @t0 + 10_200),
        &Session.tick(&1, @t0 + 20_000),
        &Session.send_failed(&1, "busy"),
        &Session.cancel/1,
        &Session.restore/1,
        &utterance(&1, 10, "eight.", @t0 + 30_000),
        &Session.draft_delivered/1
      ]

      Enum.reduce(steps, cs(), fn step, state ->
        {state, _effects} = step.(state)
        assert_partition(state)
      end)
    end

    # The only adversarial dictation a human actually produced. Replayed with
    # an identity cleaner, every raw segment must be sent exactly ONCE, in
    # order, with nothing skipped — and the draft must end up what
    # cleanup-off produces, minus exactly the pause full stops the boundary
    # join drops. It was recorded BEFORE Whisper got the draft tail as its
    # prompt, and still starts a continuation lowercase 12 times.
    test "the ORCAHUB3-99 dictation: batches partition the speech exactly, in order" do
      segments =
        (@dictation_fixture |> File.read!() |> Jason.decode!())["segments"]
        |> Enum.filter(&(&1["action"] == "appended"))
        |> Enum.map(& &1["text"])

      assert length(segments) == 40

      {off, _} =
        segments
        |> Enum.with_index(1)
        |> Enum.reduce({Session.new(), nil}, fn {text, n}, {state, _} ->
          utterance(state, n, text, @t0 + n * 1000)
        end)

      # Cleanup off is byte for byte the old draft: no join.
      assert off.draft == Enum.join(segments, " ")

      {on, sent} =
        segments
        |> Enum.with_index(1)
        |> Enum.reduce({cs(), []}, fn {text, n}, {state, sent} ->
          {state, effects} = utterance(state, n, text, @t0 + n * 1000)
          answer_all(state, effects, sent, @t0 + n * 1000 + 500)
        end)

      {on, effects} = Session.tick(on, @t0 + 100_000)
      {on, sent} = answer_all(on, effects, sent, @t0 + 100_500)

      # Segment i's full stop goes iff segment i + 1 starts lowercase. (No
      # segment here ends in anything the guards protect.)
      joined =
        segments
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, next] ->
          String.ends_with?(prev, ".") and next =~ ~r/^\p{Ll}/u
        end)

      assert Enum.count(joined, & &1) == 12

      expected =
        segments
        |> Enum.zip(joined ++ [false])
        |> Enum.map_join(" ", fn
          {text, true} -> String.trim_trailing(text, ".")
          {text, false} -> text
        end)

      assert on.draft == expected
      assert on.draft =~ "The idea behind pie that if we're using local models,"

      assert on.draft =~
               "with pi we will likely be using one model for everything and it's local."

      assert kinds(on) |> Enum.uniq() == [:settled]

      # The batches partition the speech: every word once, in order. (A
      # join that lands after a batch went out differs from it by that one
      # full stop, so compare words.)
      words = &(&1 |> String.replace(".", "") |> String.split())
      assert sent |> Enum.reverse() |> Enum.join(" ") |> words.() == words.(off.draft)
      # Real dictation arrives one segment at a time and is answered at once,
      # so it goes in the 2-segment batches the trigger aims for.
      assert length(sent) >= 20
    end
  end

  # One segment received at `received` and its transcript applied at
  # `applied`, every effect of both returned.
  defp heard(state, seq, text, received, applied) do
    {state, effects} = Session.segment_received(state, frame(seq, 16_000), received)
    assert [{:dispatch, ^seq, _pcm, _asr_opts}] = for({:dispatch, _, _, _} = d <- effects, do: d)
    {state, more} = Session.transcript(state, seq, {:ok, asr(text)}, applied)
    {state, effects ++ more}
  end

  # ORCAHUB3-120 follow-up: the idle rule must not elapse while the user is
  # mid-utterance.
  describe "rolling cleanup: the idle trigger and speech in progress" do
    # Measured on the real page (session 927c0b4c, against 0855183):
    # segment 1 applied at :27.16, segment 2's onset at :27.923, and the old
    # rule cleaned segment 1 ALONE at ~:29.16 — three 1-segment batches,
    # gemma returned each unchanged, and both pause full stops survived as
    # settled context. Times are ms after segment 1's arrival.
    test "the real-page scenario: three fragments, ~1.4 s pauses, an onset inside each gap" do
      t = &(@t0 + &1)

      {state, effects} = heard(cs(), 1, "to the OrcaHub Voice channel.", t.(0), t.(260))
      assert cleanups(effects) == []

      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, t.(1023))
      # The old deadline (applied + 2000) passes mid-utterance: nothing goes.
      {state, effects} = Session.tick(state, t.(2260))
      assert cleanups(effects) == []

      {state, effects} =
        heard(state, 2, "should send every segment to the GB10.", t.(3400), t.(3700))

      raw1 = "to the OrcaHub Voice channel should send every segment to the GB10."
      assert [{1, %{context: "", raw: ^raw1}}] = cleanups(effects)

      # gemma returns it unchanged, as it did on the real page.
      {state, []} = Session.cleanup_result(state, 1, ok(raw1), t.(4250))
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, t.(5100))

      {state, effects} =
        heard(state, 3, "and then clean it up with Gemma or Nemotron.", t.(6800), t.(7100))

      assert cleanups(effects) == []
      assert {:schedule_tick, 2000} in effects

      # The continuation joined onto the settled batch the moment it landed,
      # so the context the model gets no longer ends in a full stop.
      {state, effects} = Session.tick(state, t.(9100))

      assert [
               {2,
                %{
                  context: "to the OrcaHub Voice channel should send every segment to the GB10",
                  raw: "and then clean it up with Gemma or Nemotron."
                }}
             ] = cleanups(effects)

      {state, []} =
        Session.cleanup_result(
          state,
          2,
          ok("and then clean it up with Gemma or Nemotron."),
          t.(9650)
        )

      assert state.draft ==
               "to the OrcaHub Voice channel should send every segment to the GB10 " <>
                 "and then clean it up with Gemma or Nemotron."

      assert_partition(state)
    end

    test "idle counts from the later of the last segment's ARRIVAL and the last applied transcript" do
      {state, _} = heard(cs(), 1, "Just one thought.", @t0 - 300, @t0)
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 1500)

      # The onset's utterance is too short and never merges: held, then dropped.
      {state, [{:schedule_tick, 1500}]} =
        Session.segment_received(state, frame(2, 4_000), @t0 + 2600)

      {state, effects} = Session.tick(state, @t0 + 4100)
      assert actions(effects) == ["dropped_short"]
      assert cleanups(effects) == []
      # 2000 ms after that segment ARRIVED, not after segment 1 was applied.
      assert {:schedule_tick, 500} in effects

      {state, effects} = Session.tick(state, @t0 + 4599)
      assert effects == [{:schedule_tick, 1}]

      {_state, effects} = Session.tick(state, @t0 + 4600)
      assert [{1, %{raw: "Just one thought."}}] = cleanups(effects)
    end

    test "a misfire ends the utterance: an early one waits out the rest, an overdue one goes at once" do
      {state, _} = heard(cs(), 1, "Just one thought.", @t0, @t0 + 300)

      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 1000)
      {state, effects} = Session.speech_misfire(state, @t0 + 1600)
      assert effects == [{:schedule_tick, 700}]

      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 2000)
      # Mid-utterance at the deadline: nothing, not even another timer — the
      # onset's own lapse tick is the only one.
      {state, effects} = Session.tick(state, @t0 + 2300)
      assert effects == []

      {_state, effects} = Session.speech_misfire(state, @t0 + 2700)
      assert [{1, %{raw: "Just one thought."}}] = cleanups(effects)
    end

    test "an onset nobody closes holds the idle rule off for at most 20 s" do
      {state, _} = heard(cs(), 1, "Just one thought.", @t0, @t0)
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 1000)

      {state, effects} = Session.tick(state, @t0 + 2000)
      assert effects == []

      {state, effects} = Session.tick(state, @t0 + 20_999)
      assert effects == []

      {_state, effects} = Session.tick(state, @t0 + 21_000)
      assert [{1, %{raw: "Just one thought."}}] = cleanups(effects)
    end

    test "a mute ends the utterance it cut off; an unmute changes nothing" do
      {state, _} = heard(cs(), 1, "Just one thought.", @t0, @t0)
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 1000)
      {state, effects} = Session.tick(state, @t0 + 2500)
      assert cleanups(effects) == []

      {state, []} = Session.mic(state, false, @t0 + 2550)
      {_state, effects} = Session.mic(state, true, @t0 + 2600)
      assert [{1, %{raw: "Just one thought."}}] = cleanups(effects)
    end

    test "speech in progress never holds back the 2-segment rule or a closed run" do
      {state, _} = heard(cs(), 1, "alpha.", @t0, @t0 + 300)
      {state, _} = Session.segment_received(state, frame(2, 16_000), @t0 + 2000)
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 2100)
      {_state, effects} = Session.transcript(state, 2, {:ok, asr("Beta.")}, @t0 + 2400)
      assert [{1, %{raw: "alpha. Beta."}}] = cleanups(effects)

      {state, _} = Session.segment_received(cs(), frame(1, 16_000), @t0)
      {state, [{:schedule_tick, 20_000}]} = Session.speech_start(state, @t0 + 100)

      {_state, effects} =
        Session.transcript(state, 1, {:ok, asr("see the logs orca new line")}, @t0 + 400)

      assert [{1, %{raw: "see the logs"}}] = cleanups(effects)
    end
  end

  # ORCAHUB3-120 follow-up: a batch boundary must not freeze a full stop a
  # pause put mid-sentence.
  describe "rolling cleanup: the boundary join" do
    test "a lowercase continuation drops the pause full stop before it; the batch carries the join" do
      {state, _} = utterance(cs(), 1, "to the OrcaHub Voice channel.")
      {state, effects} = utterance(state, 2, "should send every segment.", @t0 + 10)

      assert state.draft == "to the OrcaHub Voice channel should send every segment."

      assert [{1, %{raw: "to the OrcaHub Voice channel should send every segment."}}] =
               cleanups(effects)

      assert_partition(state)
    end

    test "cleanup off: no join, the draft is byte for byte the old one" do
      {state, _} = utterance(Session.new(), 1, "to the OrcaHub Voice channel.")
      {state, _} = utterance(state, 2, "should send every segment.", @t0 + 10)
      assert state.draft == "to the OrcaHub Voice channel. should send every segment."
    end

    test "the full stop stays when it belongs to the word before it, or is not a full stop" do
      for prev <- [
            "use a short name, e.g.",
            "the lowercase one, i.e.",
            "logs, traces, etc.",
            "the sessions vs.",
            "ask Dr.",
            "talk to Mr.",
            "around 9 a.m.",
            "bump it to v1.2.",
            "the value is 3.5.",
            "that was step 3.",
            "ship v2.",
            "it costs 1,000.",
            "and then...",
            "wait..",
            "edit lib/orca_hub/voice/session.ex.",
            "see example.com.",
            "signed John J.",
            "- the first item.",
            "1. Install the deps.",
            "is it ready?",
            "ship it!",
            "a stray ."
          ] do
        {state, _} = utterance(cs(), 1, prev)
        {state, _} = utterance(state, 2, "and then more.", @t0 + 10)
        assert state.draft == prev <> " and then more.", "joined after #{inspect(prev)}"
        assert_partition(state)
      end
    end

    test "...and stays when what follows is not an ordinary lowercase word" do
      for next <- [
            "And then more.",
            # (not "… works.": it scores 0.889 against "orca pause")
            "iPhone builds fine.",
            "run_elixir is the tool.",
            "2 more things.",
            ~s("quoted" words.)
          ] do
        {state, _} = utterance(cs(), 1, "to the GB10.")
        {state, _} = utterance(state, 2, next, @t0 + 10)
        assert state.draft == "to the GB10. " <> next, "joined before #{inspect(next)}"
      end

      for next <- ["cost-wise it's fine.", "it's fine.", "and so on"] do
        {state, _} = utterance(cs(), 1, "to the GB10.")
        {state, _} = utterance(state, 2, next, @t0 + 10)
        assert state.draft == "to the GB10 " <> next
      end
    end

    test "never onto typed text or an insert" do
      {state, _} = Session.draft_edit(cs(), "Typed sentence.")
      {state, _} = utterance(state, 1, "and dictated.")
      assert state.draft == "Typed sentence. and dictated."

      # Dictation the user then edited is the user's text.
      {state, _} = utterance(cs(), 1, "Dictated one.")
      {state, _} = Session.draft_edit(state, "Dictated one, edited.")
      {state, _} = utterance(state, 2, "and two.", @t0 + 10)
      assert state.draft == "Dictated one, edited. and two."

      # A spoken newline sits between them.
      {state, _} = utterance(cs(), 1, "see the logs.")
      {state, _} = utterance(state, 2, "orca new line", @t0 + 10)
      {state, _} = utterance(state, 3, "and the traces.", @t0 + 20)
      assert state.draft == "see the logs.\nand the traces."
      assert_partition(state)
    end

    test "cleaned text that starts lowercase joins onto the dictated text before it" do
      {state, _} = utterance(cs(), 1, "First part.")
      {state, _} = utterance(state, 2, "Is here.", @t0 + 10)
      {state, _} = Session.cleanup_result(state, 1, ok("First part is here."), @t0 + 20)
      {state, _} = utterance(state, 3, "And the second.", @t0 + 30)
      {state, effects} = utterance(state, 4, "Part.", @t0 + 40)

      assert [{2, %{context: "First part is here.", raw: "And the second. Part."}}] =
               cleanups(effects)

      {state, _} = Session.cleanup_result(state, 2, ok("and the second part."), @t0 + 50)
      assert state.draft == "First part is here and the second part."
      assert_partition(state)
    end

    test "a refused batch settles as dictation, so a continuation still joins onto it" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, _} = Session.cleanup_result(state, 1, {:rejected, :novel_words, %{}}, @t0 + 20)
      {state, _} = utterance(state, 3, "and gamma.", @t0 + 30)
      assert state.draft == "alpha. Beta and gamma."
      assert_partition(state)
    end

    test "race: a continuation landing while its predecessor is in flight waits, then joins the CLEANED text" do
      {state, _} = utterance(cs(), 1, "alpha one.")
      {state, effects} = utterance(state, 2, "Beta two.", @t0 + 10)
      assert [{1, %{raw: "alpha one. Beta two."}}] = cleanups(effects)

      {state, effects} = utterance(state, 3, "and gamma.", @t0 + 20)
      # The batch out must land on exactly the text it was sent: no join yet.
      assert state.draft == "alpha one. Beta two. and gamma."
      assert cleanups(effects) == []
      assert_partition(state)

      {state, effects} = Session.cleanup_result(state, 1, ok("Alpha one, beta two."), @t0 + 600)
      # The answer applied — the batch was not invalidated — and the join landed on it.
      assert state.draft == "Alpha one, beta two and gamma."
      assert kinds(state) == [:settled, :raw]
      assert effects == [{:schedule_tick, 1420}]

      {_state, effects} = Session.tick(state, @t0 + 2020)
      assert [{2, %{context: "Alpha one, beta two", raw: "and gamma."}}] = cleanups(effects)
    end

    test "race: a continuation onto a raw span NOT in flight joins at once, leaving the batch out alone" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, _} = utterance(state, 3, "Gamma.", @t0 + 20)
      {state, effects} = utterance(state, 4, "and delta.", @t0 + 30)
      assert state.draft == "alpha. Beta. Gamma and delta."
      assert cleanups(effects) == []

      {state, effects} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 600)
      assert state.draft == "Alpha, beta. Gamma and delta."
      assert [{2, %{context: "Alpha, beta.", raw: "Gamma and delta."}}] = cleanups(effects)
    end

    test "race: a typed edit while a join is pending — nothing is ever joined onto the user's text" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, _} = utterance(state, 3, "and gamma.", @t0 + 20)
      assert state.draft == "alpha. Beta. and gamma."

      {state, []} = Session.draft_edit(state, "alpha. Beta. and gamma. Typed.")
      {state, _} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 600)
      assert state.draft == "alpha. Beta. and gamma. Typed."

      {state, _} = utterance(state, 4, "and dictated.", @t0 + 700)
      assert state.draft == "alpha. Beta. and gamma. Typed. and dictated."
      assert_partition(state)
    end

    test "race: palette focus holds a pending join back; it lands, and rides the batch, on return" do
      {state, _} = utterance(cs(), 1, "alpha.")
      {state, _} = utterance(state, 2, "Beta.", @t0 + 10)
      {state, _} = utterance(state, 3, "and gamma.", @t0 + 20)
      {state, []} = Session.ui_focus(state, "palette", [], @t0 + 30)

      {state, []} = Session.cleanup_result(state, 1, ok("Alpha, beta."), @t0 + 600)
      # The draft is untouchable in palette focus — joins included.
      assert state.draft == "alpha. Beta. and gamma."

      {state, effects} = Session.ui_focus(state, "composer", [], @t0 + 700)
      assert state.draft == "alpha. Beta and gamma."
      assert [{2, %{raw: "alpha. Beta and gamma."}}] = cleanups(effects)
      assert_partition(state)
    end
  end

  # Answers every `{:cleanup, …}` in `effects` with the raw text unchanged,
  # recursively, so a replay never leaves a batch in flight.
  defp answer_all(state, effects, sent, now) do
    case for({:cleanup, id, %{raw: raw}} <- effects, do: {id, raw}) do
      [] ->
        {state, sent}

      [{id, raw}] ->
        {state, more} = Session.cleanup_result(state, id, {:ok, raw, %{}}, now)
        answer_all(state, more, [raw | sent], now)
    end
  end
end
