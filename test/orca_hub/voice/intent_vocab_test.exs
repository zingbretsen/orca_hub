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
    first: 0.714,
    second: 0.769,
    third: 0.769,
    fourth: 0.769,
    fifth: 0.667,
    sixth: 0.667,
    seventh: 0.714,
    eighth: 0.667,
    ninth: 0.833,
    help: 0.625
  }

  setup_all do
    corpus = @corpus |> File.read!() |> Jason.decode!()

    {:ok,
     corpus: corpus,
     negatives: Enum.filter(corpus["observations"], &(&1["label"] == "negative")),
     positives: Enum.filter(corpus["observations"], &(&1["label"] == "positive"))}
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

    test "only the two phase-1 entries and :ninth are within 0.05 of the threshold", %{
      negatives: negatives
    } do
      # A thin-margin canary rather than a hard bar: :send/:cancel have carried
      # 0.833 since phase 1, and :ninth is the price of a reachable ninth slot.
      # Anything else creeping into this set wants re-measuring before it ships.
      thin =
        for {name, phrase} <- Intent.command_vocab(),
            max = negatives |> Enum.map(&Intent.score(&1["text"], phrase)) |> Enum.max(),
            max >= 0.80,
            do: name

      assert Enum.sort(thin) == [:cancel, :ninth, :send]
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
               {:first, "orca first item"},
               {:second, "orca second item"},
               {:third, "orca third item"},
               {:fourth, "orca fourth item"},
               {:fifth, "orca fifth item"},
               {:sixth, "orca sixth item"},
               {:seventh, "orca seventh item"},
               {:eighth, "orca eighth item"},
               {:ninth, "orca ninth item"},
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

      for {margin, name, rival} <- margins do
        assert margin >= 0.05,
               "#{name} beats #{rival} by only #{Float.round(margin, 4)} — too close to survive ASR noise"
      end

      # The tightest pair in the shipped vocabulary, pinned so a re-wording that
      # tightens it further has to say so out loud.
      assert {tightest, _name, _rival} = Enum.min(margins)
      assert_in_delta tightest, 0.0667, 5.0e-4
    end

    test "the near-collisions §8.3's review called out all resolve the right way" do
      vocab = Intent.command_vocab()

      assert {:search, 1.0} = Intent.intent("orca search", vocab: vocab)
      assert {:session_search, 1.0} = Intent.intent("orca session search", vocab: vocab)
      assert {:sessions, 1.0} = Intent.intent("orca all sessions", vocab: vocab)
      assert {:first, 1.0} = Intent.intent("orca first item", vocab: vocab)
      assert {:third, 1.0} = Intent.intent("orca third item", vocab: vocab)
      assert {:fourth, 1.0} = Intent.intent("orca fourth item", vocab: vocab)
      assert {:hashtag, 1.0} = Intent.intent("orca hashtag", vocab: vocab)
      assert {:double_hashtag, 1.0} = Intent.intent("orca double hashtag", vocab: vocab)

      # "orca search" vs "orca session search" is the closest of them at 0.857 —
      # comfortably below each phrase's own 1.0.
      assert_in_delta Intent.score("orca search", "orca session search"), 0.8571, 5.0e-4
      assert_in_delta Intent.score("orca all sessions", "orca session search"), 0.8, 5.0e-4
      assert_in_delta Intent.score("orca first item", "orca fourth item"), 0.9333, 5.0e-4
    end

    test "and each one survives the punctuation and casing the ASR actually emits" do
      vocab = Intent.command_vocab()

      assert {:first, 1.0} = Intent.intent("Orca first item.", vocab: vocab)
      assert {:ninth, 1.0} = Intent.intent("Orca, ninth item!", vocab: vocab)

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

    test "bare ordinals one through eight still reach their own select command" do
      for {spoken, want} <- [
            {"orca first", :first},
            {"orca second", :second},
            {"orca third", :third},
            {"orca fourth", :fourth},
            {"orca fifth", :fifth},
            {"orca sixth", :sixth},
            {"orca seventh", :seventh},
            {"orca eighth", :eighth}
          ] do
        assert {^want, _} = Intent.intent(spoken, vocab: Intent.command_vocab()),
               "#{inspect(spoken)} -> #{inspect(Intent.intent(spoken, vocab: Intent.command_vocab()))}"
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
      assert {:ninth, 1.0} = Intent.intent("orca ninth item", vocab: Intent.command_vocab())
    end

    test "a truncated \"orca second\" wins over :send by only 0.010" do
      assert {:second, second} = Intent.intent("orca second", vocab: Intent.command_vocab())
      assert_in_delta second, 0.9333, 5.0e-4
      assert_in_delta Intent.score("orca second", "orca send"), 0.9231, 5.0e-4
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

      # The shipped wording fixes both.
      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca ninth item")) |> Enum.max() <
               0.85

      assert negatives |> Enum.map(&Intent.score(&1["text"], "orca second item")) |> Enum.max() <
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
