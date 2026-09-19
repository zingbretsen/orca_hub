defmodule OrcaHub.Voice.IntentVocabTest do
  @moduledoc """
  The phase 2c vocabulary acceptance bar (`voice_mode_spec.md` §8.3.4).

  `test/orca_hub/voice/intent_test.exs` pins the §5.1.1 MATCHER against the
  Python reference and must not change; this file pins what phase 2c added on
  top of it — the shipped VOCABULARY. Every assertion here is a measurement
  against the same frozen 344-clip corpus, because the only thing that makes a
  new spoken command safe is that it was scored against real dictation before
  it shipped, not that it reads sensibly.

  Three bars, in §8.3.4's order:

    1. zero false positives — no negative clip fires any command;
    2. no stolen positives — every positive clip resolves to the SAME name it
       resolves to under `default_vocab/0`;
    3. the §5.1.1 parity test is untouched (it lives in the other file, and
       `default_vocab/0` staying exactly the four commands is what keeps it
       measuring the reference).
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Intent

  @corpus Path.expand("../../support/fixtures/voice/intent_corpus.json", __DIR__)

  # ORCAHUB3-99: 41 segments of REAL dictation, pasted out of the bar's own
  # event log the night a cancel false positive ate four minutes of it. The
  # corpus is one synthetic voice reading a fixed script; this is a person.
  @dictation Path.expand("../../support/fixtures/voice/dictation_orcahub3_99.json", __DIR__)

  # Each entry's MAXIMUM score over the 154 negative clips, i.e. the closest any
  # ordinary dictation in the corpus comes to firing it. These numbers are the
  # published safety margin (they are in the moduledoc table and the spec), so
  # they are pinned: re-wording an entry has to re-measure, not guess.
  @max_score_on_negatives %{
    send: 0.833,
    cancel: 0.833,
    stop: 0.727,
    pause: 0.750,
    search: 0.667,
    open: 0.727,
    back: 0.600,
    sessions: 0.727,
    new_session: 0.727,
    new_line: 0.667,
    new_paragraph: 0.667,
    session_search: 0.714,
    hashtag: 0.667,
    project_search: 0.588,
    double_hashtag: 0.667,
    first: 0.700,
    second: 0.700,
    third: 0.700,
    fourth: 0.667,
    fifth: 0.667,
    sixth: 0.700,
    seventh: 0.700,
    eighth: 0.667,
    ninth: 0.714,
    help: 0.625
  }

  setup_all do
    corpus = @corpus |> File.read!() |> Jason.decode!()

    {:ok,
     corpus: corpus,
     negatives: Enum.filter(corpus["observations"], &(&1["label"] == "negative")),
     positives: Enum.filter(corpus["observations"], &(&1["label"] == "positive")),
     dictation: (@dictation |> File.read!() |> Jason.decode!())["segments"]}
  end

  describe "§8.3.4 corpus acceptance bar" do
    test "1. zero false positives: no negative clip fires a command", %{negatives: negatives} do
      fps =
        for obs <- negatives,
            {got, score} =
              Intent.intent(obs["text"], vocab: Intent.command_vocab(), threshold: 0.85),
            not is_nil(got) do
          %{clip: obs["clip"], text: obs["text"], fired: got, score: score}
        end

      assert fps == [],
             "#{length(fps)} of #{length(negatives)} negative clips fired a phase 2c command:\n" <>
               Enum.map_join(fps, "\n", &inspect/1)
    end

    test "2. no stolen positives: every positive resolves exactly as it does under default_vocab/0",
         %{positives: positives} do
      stolen =
        for obs <- positives,
            {was, _} = Intent.intent(obs["text"], threshold: 0.85),
            {now, score} =
              Intent.intent(obs["text"], vocab: Intent.command_vocab(), threshold: 0.85),
            was != now do
          %{clip: obs["clip"], text: obs["text"], was: was, now: {now, score}}
        end

      assert stolen == [],
             "#{length(stolen)} of #{length(positives)} positive clips changed intent:\n" <>
               Enum.map_join(stolen, "\n", &inspect/1)
    end

    test "2b. the whole 344-clip corpus is unchanged by the additions, not just the positives", %{
      corpus: corpus
    } do
      diffs =
        for obs <- corpus["observations"],
            {was, _} = Intent.intent(obs["text"], threshold: 0.85),
            {now, _} = Intent.intent(obs["text"], vocab: Intent.command_vocab(), threshold: 0.85),
            was != now,
            do: {obs["clip"], obs["text"], was, now}

      assert diffs == []
    end

    test "3. default_vocab/0 is still exactly the four phase-1 commands" do
      # This is what keeps the §5.1.1 parity test in intent_test.exs measuring
      # the Python reference: the 2c vocabulary is a separate, opt-in list.
      assert Intent.default_vocab() == %{
               send: "orca send",
               cancel: "orca cancel",
               stop: "orca stop",
               pause: "orca pause"
             }
    end

    test "each entry's maximum score over the 154 negatives is the published one", %{
      negatives: negatives
    } do
      measured =
        Map.new(Intent.command_vocab(), fn {name, phrase} ->
          {name, negatives |> Enum.map(&Intent.score(&1["text"], phrase)) |> Enum.max()}
        end)

      assert Map.keys(measured) |> Enum.sort() == Map.keys(@max_score_on_negatives) |> Enum.sort()

      for {name, expected} <- @max_score_on_negatives do
        assert_in_delta measured[name], expected, 5.0e-4

        assert measured[name] < 0.85,
               "#{name} scores #{measured[name]} on a negative clip — that is a false positive"
      end
    end

    test "only the two phase-1 entries are within 0.05 of the threshold", %{
      negatives: negatives
    } do
      # A thin-margin canary rather than a hard bar: :send/:cancel have carried
      # 0.833 since phase 1. Anything else creeping into this set wants
      # re-measuring before it ships.
      #
      # ORCAHUB3-103 took :ninth OUT of this set: `orca ninth item` scored 0.833
      # on a negative, `orca select ninth` scores 0.714. The re-framing improved
      # every entry in the family (worst 0.833 -> 0.714).
      thin =
        for {name, phrase} <- Intent.command_vocab(),
            max = negatives |> Enum.map(&Intent.score(&1["text"], phrase)) |> Enum.max(),
            max >= 0.80,
            do: name

      assert Enum.sort(thin) == [:cancel, :send]
    end
  end

  # ORCAHUB3-103's bar, and the reason it is a separate one: the three §8.3.4
  # bars above are all measured against the 344-clip corpus, which is one
  # SYNTHETIC voice reading a fixed script. "Work Ascend." — the rendering that
  # actually broke Zach's sends — is not in it, and no amount of re-running the
  # corpus would have produced it. So the vocabulary now also has to survive a
  # hand-built adversarial set: every plausible way an ASR mangles the
  # highest-frequency command in the app.
  #
  # The bar is `>`, not `>=`. A TIE is safe, because `:send` is the first entry
  # of `command_vocab/0` and `intent/2`'s strict `s > best_score` keeps the
  # earlier entry on one. Under the SUPERSEDED `orca <ord> item` frame a tie
  # really existed (`:ninth` on "Orca cent."); the `orca select <ord>` frame has
  # 0.1091 of headroom there instead. The ordering is still load bearing and is
  # pinned separately below.
  describe "§8.3.4b no entry may outscore :send on a mangled \"orca send\" (ORCAHUB3-103)" do
    # Zach's own log line is the first entry; the rest are the corpus's known
    # send surface forms plus hand-built neighbours. Add to this list rather
    # than relaxing it.
    @send_renderings [
      "Work Ascend.",
      "Orc Ascend.",
      "Orcasend.",
      "Work a send.",
      "Or a send.",
      "Orca send.",
      "or Cascend.",
      "Orca ascend.",
      "Or cascend.",
      "Orcus end.",
      "Work Assend.",
      "Orca Sind.",
      "Orka send.",
      "work ascend",
      "or KaSend.",
      "Orcascend.",
      "Oracle send.",
      "Orc a send.",
      "Orca sent.",
      "Orca cent.",
      "Work a Cent.",
      "Or cast end.",
      "Orca's end.",
      "orcasend",
      "Orkasend."
    ]

    test "no vocabulary entry outscores :send on any of them" do
      beaten =
        for said <- @send_renderings,
            send_score = Intent.score(said, "orca send"),
            {name, phrase} <- Intent.command_vocab(),
            name != :send,
            score = Intent.score(said, phrase),
            score > send_score do
          %{said: said, entry: name, phrase: phrase, scored: score, send: send_score}
        end

      assert beaten == [],
             "#{length(beaten)} entry/rendering pairs outscore :send — the send would be " <>
               "eaten and the other command would fire instead:\n" <>
               Enum.map_join(beaten, "\n", &inspect/1)
    end

    test "and every one of them actually resolves to :send" do
      # Stronger than the bar above, and the thing the user experiences: not
      # merely "nothing beat :send" but "the send fires".
      wrong =
        for said <- @send_renderings,
            {name, score} = Intent.intent(said, vocab: Intent.command_vocab()),
            name != :send,
            do: {said, name, score}

      assert wrong == []
    end

    test "the defect itself: \"Work Ascend.\" resolved to :second under the old frame" do
      # Executable proof the issue was real, kept so the re-framing is not undone
      # as cosmetic. These are the exact floats from Zach's report.
      superseded = "orca second item"

      assert_in_delta Intent.score("Work Ascend.", superseded), 0.9333, 5.0e-4
      assert_in_delta Intent.score("Work Ascend.", "orca send"), 0.9231, 5.0e-4
      assert Intent.score("Work Ascend.", superseded) > Intent.score("Work Ascend.", "orca send")

      # ...and the reason the `item` suffix bought so little: the fold collapses
      # `second`'s "d" and `item`'s "t" together, so three extra letters add one
      # phonetic character, and the mangling's key is a PREFIX of the result.
      assert Intent.phonetic("workascend") == "arksknt"
      assert Intent.phonetic("orcasecond") == "arksknt"
      assert Intent.phonetic("orcaseconditem") == "arkskntm"
      assert Intent.phonetic("orcasend") == "arksnt"

      # The shipped frame, on the same input: the ordinal is no longer in
      # terminal position, so nothing in the family is near the "…ascend" shape.
      assert_in_delta Intent.score("Work Ascend.", "orca select second"), 0.7778, 5.0e-4
      assert_in_delta Intent.score("Work Ascend.", "orca select ninth"), 0.875, 5.0e-4
      assert {:send, _} = Intent.intent("Work Ascend.", vocab: Intent.command_vocab())
    end

    test "why no tie-break was added: the two utterances are the SAME to this matcher" do
      # The rejected alternative fix was an epsilon tie-break favouring :send.
      # It cannot work, and this is why rather than an opinion: "work ascend"
      # and "orca second" fold to the identical key, so they score identically
      # against every entry that can reach the threshold. Any rule that sends
      # one sends the other.
      assert Intent.phonetic("work ascend") == Intent.phonetic("orca second")

      differ =
        for {name, phrase} <- Intent.command_vocab(),
            a = Intent.score("work ascend", phrase),
            b = Intent.score("orca second", phrase),
            a != b,
            do: {name, a, b}

      # One entry differs, and it is nowhere near the threshold.
      assert [{:help, help_a, help_b}] = differ
      assert help_a < 0.6 and help_b < 0.6
    end

    test "the old frame's tie on \"Orca cent.\" is gone, and order still protects the bar" do
      # Under `orca <ord> item`, :ninth and :send both scored 0.9091 here and
      # only vocabulary ORDER kept the send. The new frame has real headroom, but
      # the ordering guarantee is what the `>` in this bar rests on, so it stays
      # pinned: put any entry ahead of :send and a future tie becomes a defect
      # with no score change anywhere.
      assert_in_delta Intent.score("Orca cent.", "orca ninth item"), 0.9091, 5.0e-4
      assert_in_delta Intent.score("Orca cent.", "orca select ninth"), 0.7143, 5.0e-4
      assert {:send, _} = Intent.intent("Orca cent.", vocab: Intent.command_vocab())

      assert 0 == Enum.find_index(Intent.command_vocab(), &(elem(&1, 0) == :send)),
             ":send must stay the FIRST entry — it is what wins every tie"
    end

    test "the rewording did not cost the corpus or the real-dictation bars anything", %{
      corpus: corpus,
      negatives: negatives,
      dictation: dictation
    } do
      # The §8.3.4 bars are asserted in full above; this pins the SPECIFIC
      # before/after for the entry that moved, so a future re-wording has a
      # baseline to beat rather than a vibe.
      assert_in_delta negatives
                      |> Enum.map(&Intent.score(&1["text"], "orca ninth item"))
                      |> Enum.max(),
                      0.8333,
                      5.0e-4

      assert_in_delta negatives
                      |> Enum.map(&Intent.score(&1["text"], "orca select ninth"))
                      |> Enum.max(),
                      0.7143,
                      5.0e-4

      assert [] ==
               for(
                 obs <- corpus["observations"],
                 {was, _} = Intent.intent(obs["text"], threshold: 0.85),
                 {now, _} =
                   Intent.intent(obs["text"], vocab: Intent.command_vocab(), threshold: 0.85),
                 was != now,
                 do: {obs["clip"], was, now}
               )

      assert [] ==
               for(
                 %{"n" => n, "text" => text} <- dictation,
                 n != 41,
                 {name, score} = Intent.intent(text, vocab: Intent.command_vocab()),
                 name != nil,
                 do: {n, name, score}
               )
    end
  end

  # ORCAHUB3-99. The corpus is one synthetic voice reading a fixed script and
  # it says the vocabulary has ZERO false positives. Four minutes of a real
  # person talking says otherwise. Everything in here is a measurement against
  # that transcript, kept because it is the only adversarial sample this
  # project has that a human actually produced.
  describe "§8.3.11 real dictation (ORCAHUB3-99)" do
    test "the fixture is the whole incident: 41 segments, 40 appended, 1 cancel",
         %{dictation: dictation} do
      assert length(dictation) == 41
      assert Enum.count(dictation, &(&1["action"] == "appended")) == 40

      assert [%{"n" => 41, "text" => text, "action" => "cancel"}] =
               Enum.filter(dictation, &(&1["action"] == "cancel"))

      assert text == "That is not what the original goal was."
    end

    # THE number the issue asked for. Pinned to its full float, because the
    # next test turns on it being EXACTLY equal to something else.
    test "segment #41 scores 0.8571428571428571 against \"orca cancel\"" do
      text = "That is not what the original goal was."

      assert Intent.score(text, "orca cancel") == 0.8571428571428571
      assert Intent.intent(text, vocab: Intent.command_vocab()) == {:cancel, 0.8571428571428571}
      # Over the shared threshold by 0.0071 — a rounding error's worth of margin.
      assert Intent.score(text, "orca cancel") - Intent.default_threshold() < 0.008
    end

    # The finding that decided the threshold question, and the reason there is
    # no `:cancel`-specific threshold in `Intent`. A higher bar for :cancel is
    # defensible in principle — the error costs ARE asymmetric — but it cannot
    # be implemented here, because the false positive and six TRUE positives
    # are the same float. Any threshold that rejects one rejects all seven.
    test "six GENUINE \"orca cancel\" clips score the identical float, so no threshold separates them",
         %{positives: positives} do
      fp = Intent.score("That is not what the original goal was.", "orca cancel")

      identical =
        for clip <- positives,
            clip["expected_intent"] == "cancel",
            Intent.score(clip["text"], "orca cancel") == fp,
            do: clip["text"]

      assert length(identical) == 6
      # One Whisper surface form, in two casings — "or cut cancel."
      assert identical |> Enum.map(&String.downcase/1) |> Enum.uniq() == ["or cut cancel."]

      # What a `:cancel`-only threshold would actually cost, measured rather
      # than asserted: the corpus's cancel true positives fall 44 -> 38.
      cancel_positives = Enum.filter(positives, &(&1["expected_intent"] == "cancel"))
      scores = Enum.map(cancel_positives, &Intent.score(&1["text"], "orca cancel"))

      assert length(cancel_positives) == 46
      assert Enum.count(scores, &(&1 >= 0.85)) == 44
      # Anything strictly above the false positive takes those six with it —
      # all the way up to 1.0, because nothing sits in between.
      for threshold <- [0.86, 0.90, 0.95, 1.0] do
        assert Enum.count(scores, &(&1 >= threshold)) == 38
      end
    end

    # The rest of the transcript, scored against the WHOLE vocabulary. Two
    # segments sit inside 0.05 of firing a command they were never meant to,
    # which is the same near-miss class as ORCAHUB3-92's "…orca hub". They are
    # pinned so a re-wording that makes either one WORSE fails here.
    test "no other segment of four minutes of real speech fires a command",
         %{dictation: dictation} do
      fired =
        for %{"n" => n, "text" => text} <- dictation,
            n != 41,
            {name, score} = Intent.intent(text, vocab: Intent.command_vocab()),
            name != nil,
            do: {n, name, score}

      assert fired == []
    end

    test "the two near misses in the transcript are pinned, not forgotten",
         %{dictation: dictation} do
      near =
        for %{"n" => n, "text" => text} <- dictation,
            n != 41,
            best =
              Intent.command_vocab()
              |> Enum.map(fn {name, phrase} -> {Intent.score(text, phrase), name} end)
              |> Enum.max(),
            elem(best, 0) >= 0.80,
            do: {n, elem(best, 1), Float.round(elem(best, 0), 4)}

      # #30 "...do a bunch of research," is 0.0167 away from opening the
      # command palette AND having "bunch of research" eaten out of the draft
      # by strip_command/3 — the same shape of hazard as "…orca hub" was for
      # `orca help`, found the same way (by hand, against a phrase the corpus
      # does not contain).
      # ORCAHUB3-103 moved #9 and #25 from 0.80 to 0.8235: `orca select third` is
      # a slightly closer neighbour of those two segments than `orca third item`
      # was. Still 0.0265 below the threshold, and the re-framing bought far more
      # than that back on the corpus negatives (family worst 0.833 -> 0.714).
      assert near == [
               {9, :third, 0.8235},
               {25, :third, 0.8235},
               {30, :search, 0.8333}
             ]
    end
  end

  describe "§8.3.2 command_vocab/0" do
    test "the four phase-1 commands come first, in order, so nothing can displace them" do
      assert Enum.take(Intent.command_vocab(), 4) == [
               {:send, "orca send"},
               {:cancel, "orca cancel"},
               {:stop, "orca stop"},
               {:pause, "orca pause"}
             ]
    end

    test "every phrase is at most three tokens — the matcher cannot see a fourth" do
      for {name, phrase} <- Intent.command_vocab() do
        tokens = Intent.tokenize(phrase)

        assert length(tokens) <= 3,
               "#{name} is #{length(tokens)} tokens (#{inspect(phrase)}); score/2 only ever " <>
                 "compares the last 1-3 tokens of a segment, so it could never match in full"

        assert hd(tokens) == "orca", "#{name} must keep the two-word `orca` prefix"
      end
    end

    test "names and phrases are both unique" do
      names = Enum.map(Intent.command_vocab(), &elem(&1, 0))
      phrases = Enum.map(Intent.command_vocab(), &elem(&1, 1))

      assert names == Enum.uniq(names)
      assert phrases == Enum.uniq(phrases)
    end

    test "the phase 2c additions are §8.3.3's, in §8.3.3's order, then later arrivals" do
      assert Enum.drop(Intent.command_vocab(), 4) == [
               {:search, "orca search"},
               {:open, "orca open"},
               {:back, "orca back"},
               {:sessions, "orca all sessions"},
               {:new_session, "orca new session"},
               {:new_line, "orca new line"},
               {:new_paragraph, "orca new paragraph"},
               {:session_search, "orca session search"},
               {:hashtag, "orca hashtag"},
               {:project_search, "orca project search"},
               {:double_hashtag, "orca double hashtag"},
               {:first, "orca select first"},
               {:second, "orca select second"},
               {:third, "orca select third"},
               {:fourth, "orca select fourth"},
               {:fifth, "orca select fifth"},
               {:sixth, "orca select sixth"},
               {:seventh, "orca select seventh"},
               {:eighth, "orca select eighth"},
               {:ninth, "orca select ninth"},
               # ORCAHUB3-92, after §8.3.3's block: arrival order, not taxonomy.
               {:help, "orca help menu"}
             ]
    end
  end

  describe "every phrase wins its own name" do
    test "spoken cleanly, each phrase resolves to ITS OWN name at 1.0" do
      for {name, phrase} <- Intent.command_vocab() do
        assert {^name, score} = Intent.intent(phrase, vocab: Intent.command_vocab()),
               "#{inspect(phrase)} did not resolve to #{name}: " <>
                 inspect(Intent.intent(phrase, vocab: Intent.command_vocab()))

        assert score == 1.0
      end
    end

    test "and beats its nearest rival by a real margin, not a rounding error" do
      margins =
        for {name, phrase} <- Intent.command_vocab() do
          {rival_score, rival} =
            Intent.command_vocab()
            |> Enum.reject(fn {other, _} -> other == name end)
            |> Enum.map(fn {other, other_phrase} ->
              {Intent.score(phrase, other_phrase), other}
            end)
            |> Enum.max()

          {1.0 - rival_score, name, rival}
        end

      # ORCAHUB3-103 lowered this bar from 0.05 to 0.045, deliberately and on
      # evidence. `orca select <ord>` makes all nine ordinals share the long
      # "orcaselect" prefix, so :first vs :fourth is 0.9524 — a 0.0476 margin.
      # The 0.05 was always a PROXY for "survives ASR noise"; the frame change
      # made it cheap to measure the noise directly instead, which the
      # sibling-confusion test below does (60 of 61 word-form manglings resolve
      # correctly, none below threshold, none firing :send). The proxy loses to
      # the direct measurement.
      for {margin, name, rival} <- margins do
        assert margin >= 0.045,
               "#{name} beats #{rival} by only #{Float.round(margin, 4)} — too close to survive ASR noise"
      end

      # The tightest pair in the shipped vocabulary, pinned so a re-wording that
      # tightens it further has to say so out loud.
      assert {tightest, name, rival} = Enum.min(margins)
      assert_in_delta tightest, 0.0476, 5.0e-4
      assert {name, rival} in [{:first, :fourth}, {:fourth, :first}]
    end

    test "the near-collisions §8.3's review called out all resolve the right way" do
      vocab = Intent.command_vocab()

      assert {:search, 1.0} = Intent.intent("orca search", vocab: vocab)
      assert {:session_search, 1.0} = Intent.intent("orca session search", vocab: vocab)
      assert {:sessions, 1.0} = Intent.intent("orca all sessions", vocab: vocab)
      assert {:first, 1.0} = Intent.intent("orca select first", vocab: vocab)
      assert {:third, 1.0} = Intent.intent("orca select third", vocab: vocab)
      assert {:fourth, 1.0} = Intent.intent("orca select fourth", vocab: vocab)
      assert {:hashtag, 1.0} = Intent.intent("orca hashtag", vocab: vocab)
      assert {:double_hashtag, 1.0} = Intent.intent("orca double hashtag", vocab: vocab)

      # "orca search" vs "orca session search" is the closest of them at 0.857 —
      # comfortably below each phrase's own 1.0.
      assert_in_delta Intent.score("orca search", "orca session search"), 0.8571, 5.0e-4
      assert_in_delta Intent.score("orca all sessions", "orca session search"), 0.8, 5.0e-4
      # ORCAHUB3-103 tightened this pair (0.9333 -> 0.9524) as the price of
      # taking the family off the "…ascend" shape; §8.3.4c measures what that
      # costs against real ASR noise rather than leaving it to the margin alone.
      assert_in_delta Intent.score("orca select first", "orca select fourth"), 0.9524, 5.0e-4
    end

    test "and each one survives the punctuation and casing the ASR actually emits" do
      vocab = Intent.command_vocab()

      assert {:first, 1.0} = Intent.intent("Orca select first.", vocab: vocab)
      assert {:ninth, 1.0} = Intent.intent("Orca, select ninth!", vocab: vocab)

      assert {:new_paragraph, 1.0} =
               Intent.intent("that is the plan orca new paragraph", vocab: vocab)
    end
  end

  describe "spoken variants that must keep working (§13.5's aliases)" do
    test "\"orca newline\" and \"orca new line\" are the same target once spaces are removed" do
      vocab = Intent.command_vocab()

      assert {:new_line, 1.0} = Intent.intent("orca newline", vocab: vocab)
      assert {:new_line, 1.0} = Intent.intent("orca new line", vocab: vocab)
      # Which is why §13.5's alias needs no entry of its own.
      refute Enum.any?(vocab, fn {_name, phrase} -> phrase == "orca newline" end)
    end

    test "\"orca hash tag\" and \"orca double hash tag\" split the same way" do
      vocab = Intent.command_vocab()

      assert {:hashtag, 1.0} = Intent.intent("orca hash tag", vocab: vocab)
      assert {:double_hashtag, score} = Intent.intent("orca double hash tag", vocab: vocab)
      assert_in_delta score, 0.8667, 5.0e-4
    end

    test "the short \"orca sessions\" still reaches :sessions, which is why the long phrase ships" do
      assert {:sessions, score} = Intent.intent("orca sessions", vocab: Intent.command_vocab())
      assert_in_delta score, 0.9231, 5.0e-4
    end

    test "\"orca go back\" reaches :back" do
      assert {:back, 1.0} = Intent.intent("orca go back", vocab: Intent.command_vocab())
    end

    test "bare ordinals reach NO select command any more, and never a wrong send" do
      # ORCAHUB3-103 replaced `orca <ord> item` with `orca select <ord>`, which
      # deliberately gives up the bare-ordinal short forms: the ordinal alone is
      # what collided with "orca send" in the first place. What matters is that
      # giving them up is SAFE — a bare ordinal is dictated, not acted on.
      #
      # The two exceptions are the two that were always the problem: "second"
      # and "ninth" fold onto "orca send" itself.
      got =
        Map.new(
          ~w(first second third fourth fifth sixth seventh eighth ninth),
          fn ord ->
            {ord, Intent.intent("orca #{ord}", vocab: Intent.command_vocab()) |> elem(0)}
          end
        )

      # All three of these fold onto "orca send" itself: "arksknt" / "arksfnt" /
      # "arksnt" against send's "arksnt".
      assert got["second"] == :send
      assert got["seventh"] == :send
      assert got["ninth"] == :send

      for ord <- ~w(first third fourth fifth sixth eighth) do
        assert got[ord] == nil,
               "bare \"orca #{ord}\" fired #{inspect(got[ord])} — it should just be dictated"
      end
    end
  end

  # ORCAHUB3-103's OTHER bar. Moving the ordinal behind "select" fixed the send
  # collision by giving all nine entries a long shared prefix — which is exactly
  # what makes them closer to EACH OTHER than anything else in the vocabulary
  # (:first vs :fourth is 0.9524). The clean-speech margin alone would be a
  # rounding error to rely on, and relying on clean-speech numbers is precisely
  # the mistake that let the original defect through. So the noise is measured.
  #
  # Ranked failure modes, worst first: firing :send (silently loses the user's
  # turn) > falling below threshold (the phrase is dictated into the draft) >
  # selecting the wrong row (the user SEES it and can correct it). Only the
  # third is acceptable, and only the third occurs.
  describe "§8.3.4c sibling confusion in the \"orca select <ord>\" family (ORCAHUB3-103)" do
    # Plausible ASR manglings per slot: homophones ("forth" / "turd" / "ate"),
    # verb-agreement slips ("orca selects third"), prefix elisions
    # ("or a select first"), the leading-"w" shape that produced "Work Ascend",
    # and dropped final consonants ("firs", "six", "nine").
    @manglings %{
      first: [
        "Orca select first.",
        "or a select first",
        "Work select first.",
        "orca selects first",
        "orcaselect first",
        "orca select firs",
        "orca select furs",
        "or Kaselect first"
      ],
      second: [
        "Orca select second.",
        "or a select second",
        "Work select second.",
        "orca selects second",
        "orcaselect second",
        "orca select seconds",
        "orca select secund"
      ],
      third: [
        "Orca select third.",
        "or a select third",
        "Work select third.",
        "orca selects third",
        "orcaselect third",
        "orca select thirds",
        "orca select turd"
      ],
      fourth: [
        "Orca select fourth.",
        "or a select fourth",
        "Work select fourth.",
        "orca selects fourth",
        "orcaselect fourth",
        "orca select forth",
        "orca select fort",
        "orca select force"
      ],
      fifth: [
        "Orca select fifth.",
        "or a select fifth",
        "Work select fifth.",
        "orca selects fifth",
        "orcaselect fifth",
        "orca select fith"
      ],
      sixth: [
        "Orca select sixth.",
        "or a select sixth",
        "Work select sixth.",
        "orca selects sixth",
        "orcaselect sixth",
        "orca select six"
      ],
      seventh: [
        "Orca select seventh.",
        "or a select seventh",
        "Work select seventh.",
        "orca selects seventh",
        "orcaselect seventh",
        "orca select seven"
      ],
      eighth: [
        "Orca select eighth.",
        "or a select eighth",
        "Work select eighth.",
        "orca selects eighth",
        "orcaselect eighth",
        "orca select eight",
        "orca select ate"
      ],
      ninth: [
        "Orca select ninth.",
        "or a select ninth",
        "Work select ninth.",
        "orca selects ninth",
        "orcaselect ninth",
        "orca select nine"
      ]
    }

    defp classify(said, want) do
      case Intent.intent(said, vocab: Intent.command_vocab()) do
        {^want, _} -> :correct
        {nil, _} -> :below_threshold
        {:send, _} -> :fired_send
        {other, _} -> if Intent.class(other) == :select, do: :wrong_row, else: :wrong_class
      end
    end

    test "not one word-form mangling fires :send — the failure that loses a turn" do
      offenders =
        for {want, saids} <- @manglings,
            said <- saids,
            classify(said, want) == :fired_send,
            do: {said, want}

      assert offenders == []
    end

    test "not one falls below the threshold and gets dictated into the draft instead" do
      offenders =
        for {want, saids} <- @manglings,
            said <- saids,
            classify(said, want) == :below_threshold,
            do: {said, want, Intent.intent(said, vocab: Intent.command_vocab())}

      assert offenders == []
    end

    test "and none of them is answered by a command from a different CLASS" do
      offenders =
        for {want, saids} <- @manglings,
            said <- saids,
            classify(said, want) == :wrong_class,
            do: {said, want, Intent.intent(said, vocab: Intent.command_vocab())}

      assert offenders == []
    end

    test "the residue is wrong-row only, and the exact set is pinned" do
      wrong =
        for {want, saids} <- @manglings,
            said <- saids,
            classify(said, want) == :wrong_row,
            do: {said, want, Intent.intent(said, vocab: Intent.command_vocab()) |> elem(0)}

      # One of 61. "ate" for "eighth" is the most generous reading of a homophone
      # in the set, and it lands on a neighbouring row rather than on a send.
      assert wrong == [{"orca select ate", :eighth, :third}]

      total = @manglings |> Map.values() |> List.flatten() |> length()
      assert total == 61
      correct = for {w, ss} <- @manglings, s <- ss, classify(s, w) == :correct, do: s
      assert length(correct) == 60
    end

    test "the tight first/fourth pair specifically survives every mangling of both" do
      # The 0.0476 clean-speech margin lives here. Both slots resolve correctly
      # on all of their own manglings, which is what justifies accepting it.
      for want <- [:first, :fourth], said <- @manglings[want] do
        assert {^want, _} = Intent.intent(said, vocab: Intent.command_vocab()),
               "#{inspect(said)} -> #{inspect(Intent.intent(said, vocab: Intent.command_vocab()))}"
      end
    end
  end

  describe "known limitations, pinned so they are not rediscovered as bugs" do
    test "a truncated \"orca ninth\" resolves to :send, not :ninth" do
      # The ordinal word alone is closer to "orca send" (0.909) than to its own
      # phrase, which is exactly why the bare ordinals were rejected in §8.3.4
      # and why the help affordance must teach the full three-token phrase.
      assert {:send, score} = Intent.intent("orca ninth", vocab: Intent.command_vocab())
      assert_in_delta score, 0.9091, 5.0e-4
      assert {:ninth, 1.0} = Intent.intent("orca select ninth", vocab: Intent.command_vocab())
    end

    # ORCAHUB3-103. This test used to assert the OPPOSITE — that a truncated
    # `orca second` beat `:send` by 0.010 and resolved to `:second`. That was
    # the defect: the same 0.010 applied to "Work Ascend.", the ASR's commonest
    # mangling of "orca send", and ate the send. The collision is now resolved
    # in favour of `:send`, permanently and by construction.
    test "a bare \"orca second\" resolves to :send, because nothing can separate them" do
      assert {:send, score} = Intent.intent("orca second", vocab: Intent.command_vocab())
      assert_in_delta score, 0.9231, 5.0e-4

      # The full phrase is unambiguous, which is what the help affordance teaches.
      assert {:second, 1.0} = Intent.intent("orca select second", vocab: Intent.command_vocab())
    end

    test "a truncated \"orca select\" picks the THIRD row rather than doing nothing" do
      # The slot word alone is closer to `orcaselectthird` than to any sibling,
      # so it is not a safe no-op. A visible wrong selection rather than a send,
      # which is the tolerable direction — and why the help text says the
      # ordinal is required.
      assert {:third, score} = Intent.intent("orca select", vocab: Intent.command_vocab())
      assert_in_delta score, 0.875, 5.0e-4
    end

    test "the superseded \"orca <ord> item\" phrases are gone, and two of them SEND" do
      # The accepted cost of the re-framing, pinned so it is a known quantity
      # rather than a surprise: seven of the nine old phrases fall below the
      # threshold and are simply dictated, but two land on :send.
      resolved =
        Map.new(
          ~w(first second third fourth fifth sixth seventh eighth ninth),
          fn ord ->
            {ord, Intent.intent("orca #{ord} item", vocab: Intent.command_vocab()) |> elem(0)}
          end
        )

      assert resolved["second"] == :send
      assert resolved["seventh"] == :send

      for ord <- ~w(first third fourth fifth sixth eighth ninth) do
        assert resolved[ord] == nil,
               "stale \"orca #{ord} item\" resolved to #{inspect(resolved[ord])}"
      end
    end

    test "ordinals the ASR writes as NUMERALS mostly land on the wrong row (pre-existing)" do
      # `letters_only/1` strips digits before folding, so every "<n>th" collapses
      # to the same key. NOT introduced by ORCAHUB3-103 — under `orca <ord> item`
      # the same seven numerals resolved to :fifth instead of :third. Recorded
      # rather than fixed: the fix is digit-to-word normalisation ahead of
      # `phonetic/1`, which is a §5.1.1 matcher change needing its own parity run.
      assert Intent.phonetic("orcaselect4th") == Intent.phonetic("orcaselect9th")

      got =
        for {numeral, want} <-
              Enum.zip(~w(1st 2nd 3rd 4th 5th 6th 7th 8th 9th), [
                :first,
                :second,
                :third,
                :fourth,
                :fifth,
                :sixth,
                :seventh,
                :eighth,
                :ninth
              ]) do
          {numeral, want,
           Intent.intent("orca select #{numeral}", vocab: Intent.command_vocab()) |> elem(0)}
        end

      correct = for {n, want, got} <- got, want == got, do: n
      assert correct == ["1st", "3rd"]

      # Every wrong one is a wrong SELECTION, never a send — the tolerable
      # direction, and the reason this is a limitation rather than a blocker.
      refute Enum.any?(got, fn {_n, _want, g} -> g == :send end)
      refute Enum.any?(got, fn {_n, _want, g} -> is_nil(g) end)
    end

    test "the rejected bare ordinals really would have broken the corpus", %{
      positives: positives,
      negatives: negatives
    } do
      # The measurement that got them dropped, kept executable: "orca second" is
      # a phonetic TWIN of the corpus's commonest send surface form, and
      # "orca ninth" fires on ordinary speech.
      assert Intent.phonetic("orcasecond") == Intent.phonetic("orcascend")

      stolen =
        Enum.count(positives, fn obs ->
          {was, was_score} = Intent.intent(obs["text"], threshold: 0.85)
          score = Intent.score(obs["text"], "orca second")
          was == :send and score >= 0.85 and score > was_score
        end)

      assert stolen == 30

      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca ninth")) |> Enum.max() >= 0.85
      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca second")) |> Enum.max() >= 0.85

      # Both intermediate wordings fixed the corpus bar...
      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca ninth item")) |> Enum.max() <
               0.85

      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca second item")) |> Enum.max() <
               0.85

      # ...and the SHIPPED `orca select <ord>` frame improves on them, which is
      # the ORCAHUB3-103 half of the story: the corpus bar was never the binding
      # constraint, the mangled-send bar was.
      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca select ninth")) |> Enum.max() <
               negatives |> Enum.map(&Intent.score(&1["text"], "orca ninth item")) |> Enum.max()

      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca select second")) |> Enum.max() <
               0.85
    end

    test "§13.5's \"orca the third one\" cannot match: four tokens, three-token window" do
      assert {nil, _} = Intent.intent("orca the third one", vocab: Intent.command_vocab())
    end
  end

  describe ":help (ORCAHUB3-92) — the hazard the corpus cannot see" do
    # The three bars above all PASS for the bare "orca help": 0.571 on the
    # negatives (the lowest score in the vocabulary), 0 false positives, 0
    # stolen positives. It was reworded anyway, because the corpus contains no
    # clip with the word "help" and only one saying "orca hub" — and this
    # project's own name is what the danger is made of. Keep the rejected
    # wording measured here so the rewording is not undone as pointless.
    test "the rejected \"orca help\" would have fired on a terminal \"orca hub\"" do
      assert_in_delta Intent.score("deploy orca hub", "orca help"), 0.9091, 5.0e-4
      assert Intent.score("deploy orca hub", "orca help") >= 0.85

      # ...and `strip_command/3` would then have eaten the project's name out
      # of the draft, which is the part that makes it worse than a stray panel.
      rejected = Intent.command_vocab() ++ [{:help_rejected, "orca help"}]

      assert Intent.strip_command("deploy the orca hub", :help_rejected, vocab: rejected) ==
               "deploy the"
    end

    test "the shipped \"orca help menu\" leaves the whole \"…orca hub\" family alone" do
      vocab = Intent.command_vocab()

      for said <- [
            "orca hub",
            "the orca hub",
            "deploy orca hub",
            "restart orca hub",
            "let's look at orca hub"
          ] do
        assert_in_delta Intent.score(said, "orca help menu"), 0.7692, 5.0e-4

        refute match?({:help, _}, Intent.intent(said, vocab: vocab)),
               "#{inspect(said)} fired :help — #{inspect(Intent.intent(said, vocab: vocab))}"
      end
    end

    test "the short forms a user actually says still reach it" do
      vocab = Intent.command_vocab()

      assert {:help, 1.0} = Intent.intent("orca help menu", vocab: vocab)
      assert {:help, 1.0} = Intent.intent("Orca help menu.", vocab: vocab)
      assert {:help, 1.0} = Intent.intent("orca helpmenu", vocab: vocab)

      # The same bargain `orca all sessions` struck: the long phrase ships, the
      # short one the user reaches for still resolves.
      assert {:help, short} = Intent.intent("orca help", vocab: vocab)
      assert_in_delta short, 0.8571, 5.0e-4

      assert {:help, with_me} = Intent.intent("orca help me", vocab: vocab)
      assert_in_delta with_me, 0.9333, 5.0e-4
    end

    test "a bare \"help\" mid-dictation is just dictation" do
      vocab = Intent.command_vocab()

      assert {nil, _} = Intent.intent("help", vocab: vocab)
      assert {nil, _} = Intent.intent("can you help me with this", vocab: vocab)
      assert {nil, _} = Intent.intent("that was not very helpful", vocab: vocab)
    end

    test "the residue, pinned: a terminal \"orca hub menu\" does fire it" do
      # Accepted, and recorded in the moduledoc's known limitations: the panel
      # is read-only and "hub menu" is not a phrase this app has.
      assert {:help, score} = Intent.intent("orca hub menu", vocab: Intent.command_vocab())
      assert_in_delta score, 0.9333, 5.0e-4
    end
  end

  describe "§8.3.2 class/1" do
    test "every name in the vocabulary has a class, and only the documented ones" do
      for {name, _phrase} <- Intent.command_vocab() do
        assert Intent.class(name) in [:action, :insert, :select, :navigate, :ignore]
      end
    end

    test "the phase-1 four keep their §8.1/§8.2 meaning" do
      assert Intent.class(:send) == :action
      assert Intent.class(:cancel) == :action
      assert Intent.class(:stop) == :ignore
      assert Intent.class(:pause) == :ignore
    end

    test "the phase 2c names carry §8.3.3's classes" do
      for name <- [:search, :open, :back, :sessions, :new_session, :help] do
        assert Intent.class(name) == :navigate
      end

      for name <- [
            :new_line,
            :new_paragraph,
            :session_search,
            :hashtag,
            :project_search,
            :double_hashtag
          ] do
        assert Intent.class(name) == :insert
      end

      for name <- [:first, :second, :third, :fourth, :fifth, :sixth, :seventh, :eighth, :ninth] do
        assert Intent.class(name) == :select
      end
    end

    test "an unknown name degrades to :ignore rather than to an action" do
      assert Intent.class(:nonesuch) == :ignore
      assert Intent.class(nil) == :ignore
    end
  end

  describe "§8.3.2 payload/1" do
    test "insert names carry the literal draft text" do
      assert Intent.payload(:new_line) == %{text: "\n"}
      assert Intent.payload(:new_paragraph) == %{text: "\n\n"}
      assert Intent.payload(:session_search) == %{text: "#"}
      assert Intent.payload(:hashtag) == %{text: "#"}
      assert Intent.payload(:project_search) == %{text: "##"}
      assert Intent.payload(:double_hashtag) == %{text: "##"}
    end

    test "select names carry a 1-BASED ordinal" do
      names = [:first, :second, :third, :fourth, :fifth, :sixth, :seventh, :eighth, :ninth]

      assert Enum.map(names, &Intent.payload/1) ==
               Enum.map(1..9, &%{ordinal: &1})
    end

    test "navigate names carry the ui_action the client executes" do
      assert Intent.payload(:search) == %{kind: "open_palette"}
      assert Intent.payload(:open) == %{kind: "open_palette"}
      assert Intent.payload(:back) == %{kind: "back"}
      assert Intent.payload(:sessions) == %{kind: "navigate", path: "/sessions"}
      assert Intent.payload(:new_session) == %{kind: "navigate", path: "/sessions/new"}
      assert Intent.payload(:help) == %{kind: "open_help"}
    end

    test "every navigate path is one of §8.3.3's fixed set" do
      paths =
        for {name, _phrase} <- Intent.command_vocab(),
            Intent.class(name) == :navigate,
            path = Intent.payload(name)[:path],
            do: path

      assert Enum.sort(paths) == ["/sessions", "/sessions/new"]
    end

    test "actions, ignores and unknown names carry an empty payload" do
      for name <- [:send, :cancel, :stop, :pause, :nonesuch] do
        assert Intent.payload(name) == %{}
      end
    end

    test "class and payload agree: every class gets the shape its router expects" do
      for {name, _phrase} <- Intent.command_vocab() do
        case {Intent.class(name), Intent.payload(name)} do
          {:insert, payload} ->
            assert is_binary(payload[:text])

          {:select, payload} ->
            assert payload[:ordinal] in 1..9

          {:navigate, payload} ->
            assert payload[:kind] in ["open_palette", "back", "navigate", "open_help"]

          {_action_or_ignore, payload} ->
            assert payload == %{}
        end
      end
    end
  end

  describe "§8.3.8 match_label/2" do
    @candidates [
      %{"index" => 0, "label" => "Deploy the hub"},
      %{"index" => 1, "label" => "Voice mode phase 2c"},
      %{"index" => 2, "label" => "orca_hub"}
    ]

    test "an exact spoken label matches, echoing the CLIENT's 0-based index" do
      assert {:ok, %{index: 1, label: "Voice mode phase 2c", score: 1.0}} =
               Intent.match_label("voice mode phase 2c", @candidates)
    end

    test "punctuation and casing in the transcript are normalised away" do
      assert {:ok, %{index: 0, score: 1.0}} = Intent.match_label("Deploy the hub.", @candidates)
    end

    test "a phonetic near-miss still matches when nothing else is close" do
      assert {:ok, %{index: 2, label: "orca_hub"}} = Intent.match_label("Orca hub", @candidates)
    end

    test "the WHOLE transcript is compared, not its terminal three tokens" do
      # `intent/2` would only ever see "the hub"; match_label sees all of it, so
      # a longer utterance that is not the label scores low and does not match.
      assert :no_match = Intent.match_label("please go and deploy the hub", @candidates)
    end

    test "two similar candidates cancel each other out (the 0.10 margin rule)" do
      assert :no_match =
               Intent.match_label("deploy the hub", [
                 %{"index" => 0, "label" => "Deploy the hub"},
                 %{"index" => 1, "label" => "Deploy the hubs"}
               ])
    end

    test "with a single candidate the runner-up is 0.0, so a clean match stands" do
      assert {:ok, %{index: 0, label: "Deploy the hub"}} =
               Intent.match_label("deploy the hub", [%{"index" => 0, "label" => "Deploy the hub"}])
    end

    test "a sub-threshold best never matches, however clear the margin" do
      assert :no_match = Intent.match_label("something else entirely", @candidates)
    end

    test "an empty candidate list, or one with no usable labels, is :no_match" do
      assert :no_match = Intent.match_label("deploy the hub", [])
      assert :no_match = Intent.match_label("deploy the hub", [%{"index" => 0}])
      assert :no_match = Intent.match_label("", @candidates)
    end

    test "atom-keyed candidates and bare strings work too" do
      assert {:ok, %{index: 3, label: "Deploy the hub"}} =
               Intent.match_label("deploy the hub", [%{index: 3, label: "Deploy the hub"}])

      # No index at all: fall back to the entry's position in the list.
      assert {:ok, %{index: 1, label: "Deploy the hub"}} =
               Intent.match_label("deploy the hub", ["Voice mode", "Deploy the hub"])
    end

    test "the threshold and the margin are knobs, like §5.1.1's rule 4" do
      near = [%{"index" => 0, "label" => "Deploy the hubs and more"}]

      assert :no_match = Intent.match_label("deploy the hub", near)
      assert {:ok, %{index: 0}} = Intent.match_label("deploy the hub", near, threshold: 0.7)

      ambiguous = [
        %{"index" => 0, "label" => "Deploy the hub"},
        %{"index" => 1, "label" => "Deploy the hubs"}
      ]

      assert :no_match = Intent.match_label("deploy the hub", ambiguous)
      assert {:ok, %{index: 0}} = Intent.match_label("deploy the hub", ambiguous, margin: 0.01)
    end

    test "a real session title matches the way a user would say it" do
      candidates = [
        %{"index" => 0, "label" => "Voice 2c slice a: Intent vocabulary + classes"},
        %{"index" => 1, "label" => "Full-suite gate at the issue-indexing tip"},
        %{"index" => 2, "label" => "Trigger: Weekly orca updates"}
      ]

      assert {:ok, %{index: 2, label: "Trigger: Weekly orca updates"}} =
               Intent.match_label("trigger weekly orca updates", candidates)

      # A vague utterance that could be either of two sessions selects neither —
      # the caller turns :no_match into a palette query instead.
      assert :no_match = Intent.match_label("voice", candidates)
    end
  end
end
