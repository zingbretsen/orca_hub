defmodule OrcaHub.Voice.IntentTest do
  @moduledoc """
  Parity, not "roughly right".

  The headline test replays all 344 SPIKE 2b observations and asserts that
  `OrcaHub.Voice.Intent` produces the SAME intent and the SAME score — to
  1.0e-9 — as the normative Python reference. See
  `test/support/fixtures/voice/README.md` for how the fixture was produced.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Intent

  doctest OrcaHub.Voice.Intent

  @corpus Path.expand("../../support/fixtures/voice/intent_corpus.json", __DIR__)

  setup_all do
    corpus = @corpus |> File.read!() |> Jason.decode!()
    {:ok, corpus: corpus}
  end

  describe "parity with the Python reference (spike-asr/intent_ref.py @ 4675905)" do
    test "every one of the 344 observations produces the reference intent and score", %{
      corpus: corpus
    } do
      threshold = corpus["source"]["threshold"]

      mismatches =
        for obs <- corpus["observations"],
            {got, score} = Intent.intent(obs["text"], threshold: threshold),
            expected = atom_or_nil(obs["ref_intent"]),
            got != expected or abs(score - obs["ref_score"]) > 1.0e-9 do
          %{
            clip: obs["clip"],
            rep: obs["rep"],
            text: obs["text"],
            want: {expected, obs["ref_score"]},
            got: {got, score}
          }
        end

      assert mismatches == [],
             "#{length(mismatches)} of #{length(corpus["observations"])} observations " <>
               "diverged from the reference:\n" <>
               Enum.map_join(Enum.take(mismatches, 10), "\n", &inspect/1)
    end

    test "the corpus is the full 190 positives + 154 negatives", %{corpus: corpus} do
      obs = corpus["observations"]
      assert length(obs) == 344
      assert Enum.count(obs, &(&1["label"] == "positive")) == 190
      assert Enum.count(obs, &(&1["label"] == "negative")) == 154
    end

    test "the aggregate headline at 0.85: 184/190 TP, 0 wrong intent, 0/154 FP", %{corpus: corpus} do
      tally =
        Enum.reduce(corpus["observations"], %{tp: 0, wrong: 0, miss: 0, fp: 0, pos: 0, neg: 0}, fn
          obs, acc ->
            {got, _score} = Intent.intent(obs["text"], threshold: 0.85)
            want = atom_or_nil(obs["expected_intent"])

            case obs["label"] do
              "positive" ->
                acc
                |> Map.update!(:pos, &(&1 + 1))
                |> bump(:tp, got == want)
                |> bump(:wrong, got != nil and got != want)
                |> bump(:miss, is_nil(got))

              "negative" ->
                acc
                |> Map.update!(:neg, &(&1 + 1))
                |> bump(:fp, not is_nil(got))
            end
        end)

      assert tally == %{pos: 190, tp: 184, wrong: 0, miss: 6, neg: 154, fp: 0}

      # And the same numbers the fixture recorded straight from the reference.
      assert corpus["aggregate"] == %{
               "positives" => 190,
               "tp" => 184,
               "wrong_intent" => 0,
               "miss" => 6,
               "negatives" => 154,
               "fp" => 0
             }
    end

    test "the threshold really is a knob: 0.80 admits false positives, 0.90 costs recall", %{
      corpus: corpus
    } do
      # Rule 4 — these are the spec's other two sweep rows. If the threshold
      # were baked in as a constant, the 0.85 row would be the only one
      # reachable and these counts would not move.
      at = fn thr ->
        Enum.reduce(corpus["observations"], %{tp: 0, wrong: 0, fp: 0}, fn obs, acc ->
          {got, _} = Intent.intent(obs["text"], threshold: thr)
          want = atom_or_nil(obs["expected_intent"])

          case obs["label"] do
            "positive" ->
              acc |> bump(:tp, got == want) |> bump(:wrong, got != nil and got != want)

            "negative" ->
              bump(acc, :fp, not is_nil(got))
          end
        end)
      end

      assert at.(0.80) == %{tp: 186, wrong: 2, fp: 4}
      assert at.(0.85) == %{tp: 184, wrong: 0, fp: 0}
      assert at.(0.90) == %{tp: 178, wrong: 0, fp: 0}
    end
  end

  describe "phonetic/1" do
    test "the spec's headline example: `or Kapaz` and `orca pause` key the same" do
      assert Intent.phonetic("or Kapaz") == "arkps"
      assert Intent.phonetic("orca pause") == "arkps"
      # ...and so does the third surface form the ASR returned for it.
      assert Intent.phonetic("work a pause") == "arkps"
    end

    test "the other measured surface forms collapse onto their command's key" do
      assert Intent.phonetic("orca send") == "arksnt"
      assert Intent.phonetic("orcasend") == "arksnt"
      assert Intent.phonetic("or Cascend") == "arksknt"
      assert Intent.phonetic("Orc Ascend") == "arksknt"
      assert Intent.phonetic("orca stop") == "arkstp"
      assert Intent.phonetic("Orca stopped") == "arkstpt"
      assert Intent.phonetic("orca cancel") == "arknkl"
      assert Intent.phonetic("or cut cancel") == "arktknkl"
    end

    test "digraphs are applied in order, before the per-character fold" do
      assert Intent.phonetic("phocks") == "fks"
      assert Intent.phonetic("quick") == "k"
      assert Intent.phonetic("church") == "krk"
    end

    test "`x` folds to the two-character `ks`, which collapses as one unit" do
      # Python appends the whole "ks" and compares `out[-1] != k` against it,
      # so "xxx" is one "ks" but "ksx" is two.
      assert Intent.phonetic("xxx") == "ks"
      assert Intent.phonetic("ksx") == "ksks"
      assert Intent.phonetic("box") == "pks"
    end

    test "vowels survive only at index 0, and `w` folding to \"\" counts as a vowel there" do
      assert Intent.phonetic("yellow") == "al"
      # `_FOLD["w"]` is "", and Python's `"" in "aeiou"` is True — so a leading
      # `w` becomes "a". This is not a quirk to clean up; it is why
      # "work a pause" matches at all.
      assert Intent.phonetic("WOW") == "a"
    end

    test "non-letters are stripped entirely" do
      assert Intent.phonetic("") == ""
      assert Intent.phonetic("123") == ""
      assert Intent.phonetic("Or-ca, send!") == "arksnt"
    end
  end

  describe "ratio/2 (difflib.SequenceMatcher(None, a, b).ratio())" do
    # Reference values from:
    #   python3 -c 'import difflib; print(repr(difflib.SequenceMatcher(None, "orcascend", "orcasend").ratio()))'
    test "matches difflib on the corpus's real pairs" do
      assert_ratio("orcasend", "orcasend", 1.0)
      assert_ratio("orcascend", "orcasend", 0.9411764705882353)
      assert_ratio("send", "orcasend", 0.6666666666666666)
      assert_ratio("snt", "arksnt", 0.6666666666666666)
      assert_ratio("orcapaws", "orcapause", 0.8235294117647058)
      assert_ratio("orkapaz", "orcapause", 0.625)
      assert_ratio("workapause", "orcapause", 0.8421052631578947)
      assert_ratio("orcastopped", "orcastop", 0.8421052631578947)
      assert_ratio("oritcouldcancel", "orcacancel", 0.72)
    end

    test "matches difflib on cases that exercise the recursive decomposition" do
      # "abcd"/"bcda": longest block is "bcd", then the recursion finds "a"
      # only on ONE side of it, so M = 3, not 4.
      assert_ratio("abcd", "bcda", 0.75)
      assert_ratio("kitten", "sitting", 0.6153846153846154)
      assert_ratio("tellthetmabotit", "orcasend", 0.08695652173913043)
    end

    test "edge cases: two empty strings are 1.0, one empty is 0.0" do
      assert_ratio("", "", 1.0)
      assert_ratio("abc", "", 0.0)
      assert_ratio("", "abc", 0.0)
    end

    test "is NOT String.jaro_distance/2 (rule 3)" do
      # The canary, taken from a real corpus NEGATIVE: swapping in Jaro turns
      # this ordinary dictation into a false "orca send" at 0.85. That is why
      # Jaro's zero-FP point is 0.90, and why it may not be substituted here.
      negative = "If you think the migration is safe, then go ahead. If you second,"

      assert_in_delta Intent.score(negative, "orca send"), 0.7272727272727273, 1.0e-9
      assert {nil, _} = Intent.intent(negative)

      # The divergence is on the phonetic pair of the winning 2-token tail:
      # "you second" -> "asknt" against "orca send" -> "arksnt".
      assert Intent.phonetic("yousecond") == "asknt"
      assert Intent.phonetic("orcasend") == "arksnt"
      assert_in_delta Intent.ratio("asknt", "arksnt"), 0.7272727272727273, 1.0e-9
      assert_in_delta String.jaro_distance("asknt", "arksnt"), 0.8777777777777779, 1.0e-9
    end
  end

  describe "score/2" do
    test "scores the terminal 1-3 tokens with spaces removed (rule 1)" do
      assert Intent.score("or Kapaz.", "orca pause") == 1.0
      assert Intent.score("Orcasend.", "orca send") == 1.0
      assert Intent.score("let's ship it orca send", "orca send") == 1.0

      assert_in_delta Intent.score("I clicked submit and then went home.", "orca send"),
                      0.6,
                      1.0e-9
    end

    test "only the TERMINAL position can match" do
      {mid, _} = Intent.intent("Orca send the email to Bob and copy Alice.")
      assert mid == nil

      {terminal, _} = Intent.intent("Send the email to Bob. Orca send.")
      assert terminal == :send
    end

    test "never looks further back than three tokens" do
      # The command is there, but four tokens from the end.
      {got, _} = Intent.intent("orca send and then go home now please")
      assert got == nil
    end
  end

  describe "intent/2 — argmax then threshold (rule 2)" do
    test "picks the best-scoring vocabulary entry, not the first one that clears" do
      # Both entries clear 0.85 for this text, and `:decoy` is FIRST — so a
      # first-match matcher returns :decoy where argmax returns :stop.
      vocab = [{:decoy, "orca stops"}, {:stop, "orca stop"}]

      assert_in_delta Intent.score("Orcastop.", "orca stops"), 0.9411764705882353, 1.0e-9
      assert Intent.score("Orcastop.", "orca stops") < Intent.score("Orcastop.", "orca stop")
      assert {:stop, 1.0} = Intent.intent("Orcastop.", vocab: vocab)

      # Reversed order changes nothing — that is the point of argmax.
      assert {:stop, 1.0} = Intent.intent("Orcastop.", vocab: Enum.reverse(vocab))
    end

    test "a sub-threshold best still returns its score, with a nil intent" do
      assert {nil, score} = Intent.intent("or it could cancel.")
      assert_in_delta score, 0.8, 1.0e-9
    end

    test "the threshold is an option, not a constant (rule 4)" do
      # Same text, three thresholds, three answers.
      text = "or it could cancel."
      assert {nil, _} = Intent.intent(text)
      assert {:cancel, _} = Intent.intent(text, threshold: 0.75)
      assert {nil, _} = Intent.intent(text, threshold: 0.95)
      assert Intent.default_threshold() == 0.85
    end

    test "the vocabulary is an option" do
      assert {:eject, 1.0} = Intent.intent("Orcasend.", vocab: %{eject: "orca send"})
      assert {nil, _} = Intent.intent("Orcasend.", vocab: %{stop: "orca stop"})
    end

    test "the default vocabulary is the spec's four commands" do
      assert Intent.default_vocab() == %{
               send: "orca send",
               cancel: "orca cancel",
               stop: "orca stop",
               pause: "orca pause"
             }
    end

    test "empty and whitespace-only text never fires" do
      assert {nil, +0.0} = Intent.intent("")
      assert {nil, +0.0} = Intent.intent("   \n ")
    end

    test "the measured surface forms from the spec all resolve to the right intent" do
      for {text, want} <- [
            {"or Cascend,", :send},
            {"Orcasend.", :send},
            {"Orc Ascend.", :send},
            {"or consent.", :send},
            {"Orca Paws.", :pause},
            {"or Kapaz.", :pause},
            {"work a pause.", :pause},
            {"Orca stopped.", :stop},
            {"Orcastop.", :stop},
            {"or cut cancel.", :cancel}
          ] do
        assert {^want, _} = Intent.intent(text), "expected #{want} for #{inspect(text)}"
      end
    end
  end

  describe "strip_command/3 (rule 5)" do
    test "a segment that is entirely the command comes back empty, to be dropped" do
      assert Intent.strip_command("Orcasend.", :send) == ""
      assert Intent.strip_command("Orca send.", :send) == ""
      assert Intent.strip_command("or Kapaz.", :pause) == ""
      assert Intent.strip_command("Orca stopped.", :stop) == ""
    end

    test "a segment with a draft in front keeps the draft" do
      assert Intent.strip_command("let's ship it orca send", :send) == "let's ship it"
    end

    test "punctuation and casing in the kept prefix are preserved" do
      assert Intent.strip_command("Let's ship the patch today. Orcasend.", :send) ==
               "Let's ship the patch today."

      assert Intent.strip_command("Tell the team about it, orca send.", :send) ==
               "Tell the team about it,"
    end

    test "removes exactly the k tail tokens that won, no more" do
      # k=2 here ("orca" + "send"), so "it" survives.
      assert Intent.strip_command("ship it orca send", :send) == "ship it"
      # k=1 here — the ASR glued the command into one token.
      assert Intent.strip_command("ship it Orcasend", :send) == "ship it"
    end

    test "a nil intent, or one outside the vocabulary, leaves the text alone" do
      assert Intent.strip_command("no command here", nil) == "no command here"
      assert Intent.strip_command("Orcasend.", :nonesuch) == "Orcasend."
    end

    test "an intent that does not actually match this text leaves it alone" do
      # Defensive: a stale/mistaken intent must not eat the tail of a draft.
      assert Intent.strip_command("no command here", :send) == "no command here"
      assert Intent.strip_command("Orcasend.", :pause) == "Orcasend."
    end

    test "honours the same threshold knob intent/2 used" do
      # "Orca stopped." scores 0.923 for :stop — a command at 0.85, not one at
      # 0.95. `strip_command/3` must agree with whichever threshold produced
      # the intent, or a tightened threshold would still eat the segment.
      assert Intent.strip_command("Orca stopped.", :stop) == ""
      assert Intent.strip_command("Orca stopped.", :stop, threshold: 0.95) == "Orca stopped."
    end

    test "strips only the tokens that actually matched, even mid-phrase" do
      # "or it could cancel." wins at k=1 on "cancel" alone (0.8) — so at a
      # threshold loose enough to fire, only "cancel" comes off, not "orca
      # cancel"'s worth of tokens.
      assert Intent.strip_command("or it could cancel.", :cancel, threshold: 0.75) ==
               "or it could"
    end

    test "round-trips with intent/2 over the corpus's positive clips" do
      for text <- [
            "Let's ship the patch today and tell the team about it. Orcasend.",
            "or Cascend,",
            "Orca Paws.",
            "Orcastop."
          ] do
        {got, _} = Intent.intent(text)
        assert got != nil
        stripped = Intent.strip_command(text, got)
        # Whatever remains must no longer look like a command.
        assert {nil, _} = Intent.intent(stripped)
      end
    end
  end

  defp assert_ratio(a, b, expected) do
    assert_in_delta Intent.ratio(a, b), expected, 1.0e-9
  end

  defp bump(acc, key, true), do: Map.update!(acc, key, &(&1 + 1))
  defp bump(acc, _key, false), do: acc

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(name) when is_binary(name), do: String.to_existing_atom(name)
end
