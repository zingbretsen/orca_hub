defmodule OrcaHub.Voice.Intent do
  @moduledoc """
  Terminal-position phonetic matcher for spoken commands ("orca send",
  "orca cancel", "orca stop", "orca pause").

  This is a pure-Elixir port of SPIKE 2b's normative reference,
  `spike-asr/intent_ref.py` (repo `/home/zach/transcription` on gb10, commit
  `4675905`). The specification it implements is **`voice_mode_spec.md`
  section 5.1.1**; read that before changing anything here.

  Measured on the SPIKE 2b corpus at threshold `0.85`: **184/190 true
  positives (96.8%), 0 wrong-intent, 0/154 false positives**. Those exact
  numbers, plus the per-clip `{intent, score}` the Python reference produces,
  are pinned by `test/orca_hub/voice/intent_test.exs` against the committed
  fixture in `test/support/fixtures/voice/`.

  ## The five rules the port must not get wrong

  1. **Compare with SPACES REMOVED**, on both the candidate tail and the
     target phrase. Whisper glues and splits words freely (`Orcasend.`,
     `Orc Ascend.`); a token-aligned comparison throws away the only stable
     signal. See `score/2`.
  2. **ARGMAX THEN THRESHOLD, never first-match.** Every vocabulary entry is
     scored, the best is taken, and only then is the threshold applied. See
     `intent/2`.
  3. **Ratcliff-Obershelp, not Jaro.** `String.jaro_distance/2` is NOT a
     drop-in: on this corpus its best zero-FP operating point is 0.90 at
     92.6% TP, against 0.85 at 96.8% here. `ratio/2` ports Python's
     `difflib.SequenceMatcher(None, a, b).ratio()` instead.
  4. **The threshold is a runtime knob, not a constant.** `default_threshold/0`
     supplies the corpus-tuned 0.85; callers (e.g. the `ASRConfig`-backed
     voice channel) pass their resolved value as the `:threshold` option.
  5. **Strip the command tokens before the segment joins the draft.** A
     segment that is ENTIRELY the command contributes nothing and must be
     dropped, not appended. See `strip_command/3`.

  ## Example

      iex> OrcaHub.Voice.Intent.intent("Let's ship the patch today. Orcasend.")
      {:send, 1.0}

      iex> OrcaHub.Voice.Intent.intent("I clicked submit and then went home.")
      {nil, 0.6}

  ## Phase 2c vocabulary (`voice_mode_spec.md` §8.3)

  `command_vocab/0` is the phase-1 four PLUS §8.3.3's navigation, insertion and
  selection commands; `class/1` says how `Voice.Session` routes a match and
  `payload/1` carries its argument. `default_vocab/0` is deliberately frozen at
  the four so the §5.1.1 parity corpus keeps measuring what the Python
  reference measured.

  Every shipped phrase was scored against all 344 corpus clips before it landed
  (§8.3.4). The table is each entry's MAXIMUM score over the 154 negative clips
  — the distance between it and the 0.85 threshold is the whole safety margin:

  | name | phrase | class | max score on a negative |
  |---|---|---|---|
  | `:send` | orca send | action | 0.833 (phase 1, unchanged) |
  | `:cancel` | orca cancel | action | 0.833 (phase 1, unchanged) |
  | `:stop` | orca stop | ignore | 0.727 (phase 1, unchanged) |
  | `:pause` | orca pause | ignore | 0.750 (phase 1, unchanged) |
  | `:search` | orca search | navigate | 0.667 |
  | `:open` | orca open | navigate | 0.727 |
  | `:back` | orca back | navigate | 0.600 |
  | `:sessions` | orca all sessions | navigate | 0.727 |
  | `:new_session` | orca new session | navigate | 0.727 |
  | `:new_line` | orca new line | insert | 0.667 |
  | `:new_paragraph` | orca new paragraph | insert | 0.667 |
  | `:session_search` | orca session search | insert | 0.714 |
  | `:hashtag` | orca hashtag | insert | 0.667 |
  | `:project_search` | orca project search | insert | 0.588 |
  | `:double_hashtag` | orca double hashtag | insert | 0.667 |
  | `:first` | orca first item | select | 0.714 |
  | `:second` | orca second item | select | 0.769 |
  | `:third` | orca third item | select | 0.769 |
  | `:fourth` | orca fourth item | select | 0.769 |
  | `:fifth` | orca fifth item | select | 0.667 |
  | `:sixth` | orca sixth item | select | 0.667 |
  | `:seventh` | orca seventh item | select | 0.714 |
  | `:eighth` | orca eighth item | select | 0.667 |
  | `:ninth` | orca ninth item | select | 0.833 |
  | `:help` | orca help menu | navigate | 0.625 |

  ### What the measurement changed, and why

  Three §8.3.3 candidates did not survive and were REWORDED rather than dropped:

  * **the bare ordinals `orca first` .. `orca ninth`.** `orca second` is a
    phonetic TWIN of the send command — `phonetic("orcasecond") == "arksknt" ==
    phonetic("orcascend")`, and `or Cascend` is the single commonest ASR surface
    form of "orca send" in the corpus. Added as-is it scored 1.0 on 30 positive
    SEND clips and stole every one of them, plus two false positives at 0.900
    ("...think about the schema for a second."). `orca ninth` separately scored
    0.909 on a negative (the JFK passage's "...can do for your country"), a
    false positive on its own. The whole family therefore ships with an `item`
    suffix — `orca first item` .. `orca ninth item` — which drops the worst
    negative in the family from 0.909 to 0.833 and the worst stolen-positive
    count from 30 to 0, while keeping every sibling separable (worst intra-family
    rival 0.933, `orca first item` vs `orca fourth item`).
  * **`orca sessions`** scored 0.800 on a negative ("...test slash orcahub slash
    voicetest dot exs") — no false positive, but only 0.05 of headroom. It ships
    as `orca all sessions` (0.727), and the shorter `orca sessions` still
    resolves to `:sessions` at 0.923, so nothing was taken away from the user.

  A fourth, `:help` (ORCAHUB3-92), was reworded for a hazard the CORPUS CANNOT
  SEE. `orca help` passes every §8.3.4 bar and passes them well — 0.571 on the
  negatives, the lowest score in the whole vocabulary, 0 stolen positives — but
  the corpus contains no clip with the word "help" in it and only one saying
  "orca hub", mid-sentence. Scored by hand against the phrase this project says
  more than any other, **`orca help` matches a terminal "orca hub" at 0.909**:
  "deploy orca hub." would have fired the panel AND had those two words eaten
  out of the draft by `strip_command/3`. It therefore ships as
  `orca help menu` (0.625 on the negatives), which drops the whole "…orca hub"
  family to 0.769 — 0.081 of headroom, more than the reworded `:sessions` got —
  while the natural short forms still reach it: `orca help` at 0.857 and
  `orca help me` at 0.933, exactly the way `orca sessions` still reaches
  `:sessions`.

  Kept despite a thin margin: `:ninth` at 0.833 is the highest in the new
  vocabulary, but it is no thinner than the phase-1 `:send`/`:cancel` entries
  (0.833 each) that have been in production since phase 1, and dropping the
  ninth slot would make the last palette result unreachable by ordinal.

  ### Known limitations (measured, not fixed)

  * **A truncated `orca ninth` resolves to `:send` (0.909), not `:ninth`.** The
    ordinal word alone is closer to "orca send" than to its own phrase, so the
    help affordance must teach the full three-token phrase. `orca first` ..
    `orca eighth` do resolve to their own names (0.923-0.933); only the ninth
    does not, and a stray send is recoverable (§5.1.1's asymmetry note).
  * `orca second` (truncated) beats `:send` by only 0.010 — it resolves to
    `:second`, which is the intent of the utterance, but do not narrow that gap
    further when re-wording anything in this vocabulary.
  * **`orca newline` needs no separate entry.** Spaces are removed on both sides
    before scoring, so "orca newline" and "orca new line" are the SAME target
    string (`orcanewline`) and both score 1.0 against `:new_line`. The same goes
    for `orca hash tag` -> `:hashtag`. §13.5's aliases are already covered.
  * **`orca the third one` cannot match** (0.571): it is four tokens, and
    `score/2` never looks further back than three. Every phrase here is <= 3
    tokens for that reason.
  * **A sentence ending in "orca hub menu" opens the help** (0.933 against
    `orca help menu`). It is the residue of the `:help` rewording above: the
    plain "…orca hub" ending, the one that actually occurs, is safe at 0.800,
    and "hub menu" is not a thing this app has. A help panel is read-only, so
    the cost is the two eaten words rather than an action.
  """

  # The reference `VOCAB`, in the reference's insertion order. Order is load
  # bearing: `intent/2` keeps the FIRST entry on a score tie, exactly as the
  # Python `if s > best_s` does over an insertion-ordered dict.
  @default_vocab [
    {:send, "orca send"},
    {:cancel, "orca cancel"},
    {:stop, "orca stop"},
    {:pause, "orca pause"}
  ]

  # The phase 2c additions (`voice_mode_spec.md` §8.3.3), in the spec's order,
  # APPENDED to the four phase-1 commands. Two rules constrain this list:
  #
  #   * at most THREE tokens per phrase — `score/2` only ever looks at the last
  #     1-3 tokens of a segment, so a four-token phrase can never match in full;
  #   * every phrase is scored against the 344-clip corpus before it ships (§8.3.4)
  #     and drops out if it produces a false positive on a negative clip or steals
  #     a positive clip from a phase-1 command.
  #
  # Three candidate phrases from §8.3.3 did not survive that measurement and were
  # REWORDED, as was `:help` (added later, ORCAHUB3-92); see the "Phase 2c
  # vocabulary" section of the moduledoc for the numbers and the reasoning.
  @command_vocab @default_vocab ++
                   [
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
                     # ORCAHUB3-92, appended AFTER §8.3.3's entries because it
                     # arrived after them and order is a tie-break, not a
                     # taxonomy. "orca help" — the phrase actually asked for —
                     # is a terminal-position twin of "orca hub"; see the
                     # moduledoc.
                     {:help, "orca help menu"}
                   ]

  # §8.3.2: what the session DOES with a matched name. `:ignore` is the safe
  # default for anything not listed, so an unknown name can never be routed as
  # an action, an insert or a navigation.
  @classes %{
    send: :action,
    cancel: :action,
    stop: :ignore,
    pause: :ignore,
    search: :navigate,
    open: :navigate,
    back: :navigate,
    sessions: :navigate,
    new_session: :navigate,
    new_line: :insert,
    new_paragraph: :insert,
    session_search: :insert,
    hashtag: :insert,
    project_search: :insert,
    double_hashtag: :insert,
    first: :select,
    second: :select,
    third: :select,
    fourth: :select,
    fifth: :select,
    sixth: :select,
    seventh: :select,
    eighth: :select,
    ninth: :select,
    help: :navigate
  }

  # §8.3.2: the argument the class needs. Insert payloads are the literal text
  # appended to the draft (§8.3.7 owns the join rule); select payloads are
  # 1-BASED ordinals; navigate payloads are the `ui_action` the client executes.
  @payloads %{
    new_line: %{text: "\n"},
    new_paragraph: %{text: "\n\n"},
    session_search: %{text: "#"},
    hashtag: %{text: "#"},
    project_search: %{text: "##"},
    double_hashtag: %{text: "##"},
    first: %{ordinal: 1},
    second: %{ordinal: 2},
    third: %{ordinal: 3},
    fourth: %{ordinal: 4},
    fifth: %{ordinal: 5},
    sixth: %{ordinal: 6},
    seventh: %{ordinal: 7},
    eighth: %{ordinal: 8},
    ninth: %{ordinal: 9},
    search: %{kind: "open_palette"},
    open: %{kind: "open_palette"},
    back: %{kind: "back"},
    sessions: %{kind: "navigate", path: "/sessions"},
    new_session: %{kind: "navigate", path: "/sessions/new"},
    help: %{kind: "open_help"}
  }

  @default_threshold 0.85

  # §8.3.8: a spoken name has to CLEAR the same 0.85 the commands use AND beat
  # the next-best label by this much. Names are a bonus path; ordinals are the
  # reliable one, so an ambiguous field of candidates resolves to nothing.
  @default_label_margin 0.10

  # The reference `_FOLD`: confusable consonants collapsed onto one spelling.
  @fold %{
    "c" => "k",
    "q" => "k",
    "g" => "k",
    "x" => "ks",
    "z" => "s",
    "d" => "t",
    "b" => "p",
    "v" => "f",
    "j" => "s",
    "y" => "i",
    "w" => ""
  }

  # The reference `_DIGRAPH`, applied IN THIS ORDER, each one replace-all.
  # Order matters: "ch" must be tried after "ck"/"sh" but before "th".
  @digraphs [{"ph", "f"}, {"ck", "k"}, {"sh", "s"}, {"ch", "k"}, {"th", "t"}, {"qu", "k"}]

  @type intent_name :: :send | :cancel | :stop | :pause
  @type vocab :: %{intent_name() => String.t()} | [{intent_name(), String.t()}]

  @typedoc "Any name in `command_vocab/0` — the four phase-1 intents plus §8.3.3's."
  @type command_name :: atom()

  @typedoc "§8.3.2's routing classes. `:ignore` is also the fallback for unknown names."
  @type class :: :action | :insert | :select | :navigate | :ignore

  @typedoc """
  One entry of the client's reported candidate list (§8.3.5's `ui_focus`).

  Accepted with either string keys (straight off the wire) or atom keys.
  `index` is 0-BASED and is echoed back untouched — it is the index the CLIENT
  said it would act on, not a position in this list.
  """
  @type candidate :: %{optional(atom() | binary()) => term()}

  @doc """
  The corpus-tuned threshold, `0.85`.

  Rule 4: this is a DEFAULT, not a constant baked into the decision. It is the
  knee of the SPIKE 2b sweep and the first threshold at which wrong-intent
  errors vanish (0.80 -> 2 wrong-intent + 2.6% FP; 0.90 -> 93.7% TP). Callers
  with a configured value — the voice channel resolving `ASRConfig` — pass it
  as `intent/2`'s `:threshold` option rather than changing this.
  """
  @spec default_threshold() :: float()
  def default_threshold, do: @default_threshold

  @doc """
  The default vocabulary: `%{send: "orca send", cancel: "orca cancel",
  stop: "orca stop", pause: "orca pause"}`.
  """
  @spec default_vocab() :: %{intent_name() => String.t()}
  def default_vocab, do: Map.new(@default_vocab)

  @doc """
  The full phase 2c vocabulary as an ORDERED list of `{name, phrase}` (§8.3.2).

  The four `default_vocab/0` commands come first, in their existing order, then
  §8.3.3's entries. Order is load bearing twice over: `intent/2` keeps the
  EARLIER entry on an exact score tie, so nothing added here can displace
  phase-1 behaviour, and the help affordance (§8.3.10) renders this list.

  Pass it to `intent/2`/`strip_command/3` as `vocab:` — `default_vocab/0` is
  deliberately left as the four phase-1 commands so the §5.1.1 parity corpus
  keeps measuring exactly what the Python reference measured.

      iex> OrcaHub.Voice.Intent.command_vocab() |> Enum.take(4)
      [{:send, "orca send"}, {:cancel, "orca cancel"}, {:stop, "orca stop"}, {:pause, "orca pause"}]

      iex> OrcaHub.Voice.Intent.intent("open the queue orca all sessions",
      ...>   vocab: OrcaHub.Voice.Intent.command_vocab())
      {:sessions, 1.0}
  """
  @spec command_vocab() :: [{command_name(), String.t()}]
  def command_vocab, do: @command_vocab

  @doc """
  How `Voice.Session` should route a matched command (§8.3.2).

  `:action` is §8.1/§8.2's send/cancel, `:ignore` is the barge-in stop/pause
  pair, and `:insert`/`:select`/`:navigate` are phase 2c's. Anything not in
  `command_vocab/0` is `:ignore`, so a stale or mistyped name degrades into
  "do nothing" rather than into an action.

      iex> {OrcaHub.Voice.Intent.class(:send), OrcaHub.Voice.Intent.class(:new_line)}
      {:action, :insert}

      iex> {OrcaHub.Voice.Intent.class(:third), OrcaHub.Voice.Intent.class(:nonesuch)}
      {:select, :ignore}
  """
  @spec class(command_name()) :: class()
  def class(name), do: Map.get(@classes, name, :ignore)

  @doc """
  The argument `class/1`'s routing needs (§8.3.2).

  Insert names carry `%{text: ...}` — the literal draft text, joined by §8.3.7's
  rule, NOT here. Select names carry `%{ordinal: n}`, 1-BASED. Navigate names
  carry the `ui_action` payload the client executes. Every other name, including
  `:send`/`:cancel`/`:stop`/`:pause` and anything unknown, carries `%{}`.

      iex> OrcaHub.Voice.Intent.payload(:new_paragraph)
      %{text: "\\n\\n"}

      iex> OrcaHub.Voice.Intent.payload(:second)
      %{ordinal: 2}

      iex> OrcaHub.Voice.Intent.payload(:sessions)
      %{kind: "navigate", path: "/sessions"}

      iex> OrcaHub.Voice.Intent.payload(:send)
      %{}
  """
  @spec payload(command_name()) :: map()
  def payload(name), do: Map.get(@payloads, name, %{})

  @doc """
  Matches a whole transcript against the client's visible candidate labels (§8.3.8).

  Used only when `focus == "palette"` and nothing in `command_vocab/0` matched:
  the alternative to a name match is a palette query, so this is deliberately
  CONSERVATIVE — ordinals (`class/1 == :select`) are the reliable selection
  path and names are a bonus.

  Unlike `intent/2` this compares the WHOLE transcript, not its terminal 1-3
  tokens: a spoken selection is the entire utterance. Both sides are normalised
  the way `score/2` normalises a candidate tail — lowercased, punctuation and
  spaces removed — and scored `max(ratio(a, b), ratio(phonetic(a), phonetic(b)))`.

  A match needs BOTH `best >= threshold` (default `default_threshold/0`) AND
  `best - runner_up >= margin` (default `0.10`); with a single candidate the
  runner-up is `0.0`. Anything else is `:no_match`, which the caller turns into
  a `palette_query`.

  `candidates` are §8.3.5's `ui_focus` entries, accepted with string OR atom
  keys. `index` is echoed back untouched — it is the 0-BASED index the CLIENT
  said it would act on. Entries without a usable label are skipped; an entry
  without an `index` falls back to its position in the list.

  ## Options

    * `:threshold` — float, defaults to `default_threshold/0`.
    * `:margin` — float, defaults to `0.10`.

      iex> OrcaHub.Voice.Intent.match_label("deploy the hub", [
      ...>   %{"index" => 0, "label" => "Deploy the hub"},
      ...>   %{"index" => 1, "label" => "Voice mode phase 2c"}
      ...> ])
      {:ok, %{index: 0, label: "Deploy the hub", score: 1.0}}

      iex> OrcaHub.Voice.Intent.match_label("deploy the hub", [
      ...>   %{"index" => 0, "label" => "Deploy the hub"},
      ...>   %{"index" => 1, "label" => "Deploy the hubs"}
      ...> ])
      :no_match
  """
  @spec match_label(String.t(), [candidate()], keyword()) ::
          {:ok, %{index: integer(), label: String.t(), score: float()}} | :no_match
  def match_label(text, candidates, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    margin = Keyword.get(opts, :margin, @default_label_margin)
    spoken = normalize(text)
    spoken_p = phonetic(spoken)

    scored =
      candidates
      |> Enum.with_index()
      |> Enum.flat_map(fn {candidate, position} ->
        case candidate_label(candidate) do
          "" ->
            []

          label ->
            target = normalize(label)
            s = max(ratio(spoken, target), ratio(spoken_p, phonetic(target)))
            [{s, candidate_index(candidate, position), label}]
        end
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    case scored do
      [] ->
        :no_match

      [{best, index, label} | rest] ->
        runner_up =
          case rest do
            [{second, _index, _label} | _] -> second
            [] -> 0.0
          end

        if best >= threshold and best - runner_up >= margin do
          {:ok, %{index: index, label: label, score: best}}
        else
          :no_match
        end
    end
  end

  @doc """
  Classifies the terminal 1-3 tokens of `text` as a spoken command.

  Returns `{intent, score}` when the best score across the WHOLE vocabulary
  reaches the threshold, and `{nil, best_score}` otherwise — the score is
  returned either way so callers can log near misses.

  ## Options

    * `:threshold` — float, defaults to `default_threshold/0` (rule 4).
    * `:vocab` — a map of `intent_atom => phrase`, or a list of
      `{intent_atom, phrase}` pairs. Defaults to `default_vocab/0`.

  Rule 2, argmax then threshold: every entry is scored before the threshold is
  applied. First-match is what produces the wrong-intent errors visible in the
  0.80 row of the spec's sweep.

  On a score tie the EARLIER vocabulary entry wins, matching the reference's
  strict `s > best_s` over an insertion-ordered dict. A `:vocab` map is
  iterated in Erlang term order (i.e. alphabetically by atom); pass a list of
  pairs when tie-break order matters.
  """
  @spec intent(String.t(), keyword()) :: {intent_name() | nil, float()}
  def intent(text, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    vocab = opts |> Keyword.get(:vocab, @default_vocab) |> vocab_entries()

    {best, best_score} =
      Enum.reduce(vocab, {nil, 0.0}, fn {name, phrase}, {_best, best_score} = acc ->
        s = score(text, phrase)
        if s > best_score, do: {name, s}, else: acc
      end)

    if best_score >= threshold, do: {best, best_score}, else: {nil, best_score}
  end

  @doc """
  Best similarity between `phrase` and the last 1-3 tokens of `text`.

  For each k in 1..3 the last k tokens are JOINED WITH NO SPACES and compared
  against the space-stripped `phrase` two ways — raw `ratio/2` and `ratio/2`
  over `phonetic/1` keys — and the maximum over all six comparisons is
  returned (rule 1).

      iex> OrcaHub.Voice.Intent.score("or Kapaz.", "orca pause")
      1.0
  """
  @spec score(String.t(), String.t()) :: float()
  def score(text, phrase) do
    {best, _k} = score_with_k(text, phrase)
    best
  end

  @doc """
  Removes the matched terminal command tokens from a segment.

  Rule 5. Given the `intent` that `intent/2` returned for this same text, the
  exact k (1, 2 or 3) tail tokens that produced the winning score are removed
  from the ORIGINAL text — casing, inner punctuation and spacing of the
  remainder are preserved, only trailing whitespace is trimmed.

  ## Contract

    * returns the remaining segment text when there is any;
    * returns `""` when the segment was ENTIRELY the command — the caller must
      DROP such a segment, not append an empty string to the draft;
    * returns `text` unchanged when `intent` is `nil`, is not in the vocab, or
      does not actually reach the threshold on this text — stripping is only
      ever done for a command that genuinely matched, so passing a stale or
      mistaken intent cannot silently eat the tail of a draft.

  Accepts the same `:vocab` and `:threshold` options as `intent/2`; pass the
  SAME threshold that produced the `intent`.

      iex> OrcaHub.Voice.Intent.strip_command("let's ship it orca send", :send)
      "let's ship it"

      iex> OrcaHub.Voice.Intent.strip_command("Orcasend.", :send)
      ""
  """
  @spec strip_command(String.t(), intent_name() | nil, keyword()) :: String.t()
  def strip_command(text, intent, opts \\ [])

  def strip_command(text, nil, _opts), do: text

  def strip_command(text, intent, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    vocab = opts |> Keyword.get(:vocab, @default_vocab) |> vocab_entries()

    case List.keyfind(vocab, intent, 0) do
      nil ->
        text

      {_name, phrase} ->
        case score_with_k(text, phrase) do
          {best, k} when is_integer(k) and best >= threshold -> drop_tail_tokens(text, k)
          _below_threshold_or_no_tokens -> text
        end
    end
  end

  @doc """
  The consonant-skeleton phonetic key: confusable consonants folded together,
  vowels kept only as a leading "a".

  Ported character-for-character from the reference. In order: lowercase and
  drop everything outside `a-z`; apply the digraph replacements
  (`ph`->`f`, `ck`->`k`, `sh`->`s`, `ch`->`k`, `th`->`t`, `qu`->`k`)
  sequentially, each replace-all; then fold each character, dropping any vowel
  that is not at index 0 of the post-digraph string and collapsing runs of the
  same folded output.

  This is the whole trick: the ASR's `or Kapaz` and the literal `orca pause`
  reduce to the same key.

      iex> OrcaHub.Voice.Intent.phonetic("or Kapaz")
      "arkps"

      iex> OrcaHub.Voice.Intent.phonetic("orca pause")
      "arkps"
  """
  @spec phonetic(String.t()) :: String.t()
  def phonetic(s) do
    s
    |> letters_only()
    |> apply_digraphs()
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce([], fn {ch, i}, acc ->
      k = Map.get(@fold, ch, ch)
      # Python's `if k in "aeiou"` is a SUBSTRING test: true for a single
      # vowel AND for the empty string that "w" folds to — which is why a
      # leading "w" becomes "a" and "work a pause" also keys to "arkps".
      k = if String.contains?("aeiou", k), do: if(i == 0, do: "a", else: ""), else: k

      # Collapse doubles. `acc` holds whole folded outputs, so the multi-char
      # "ks" that "x" folds to is compared as one unit, exactly as in Python.
      if k != "" and (acc == [] or hd(acc) != k), do: [k | acc], else: acc
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  @doc """
  Python's `difflib.SequenceMatcher(None, a, b).ratio()` — the
  Ratcliff-Obershelp similarity, `2 * M / T`.

  `M` is the total size of the recursively-derived matching blocks: take the
  longest matching substring, then recurse into the regions to its left and to
  its right. `T` is `String.length(a) + String.length(b)`; two empty strings
  score `1.0`.

  Rule 3 — this exists because `String.jaro_distance/2` is a DIFFERENT metric
  with a materially worse operating point on this corpus. Do not substitute it.

  difflib's `autojunk` heuristic only engages for sequences of 200+ elements,
  so for command-length strings this plain implementation is exactly
  equivalent; the longest-match tie-break (earliest in `a`, then earliest in
  `b`) is reproduced so block selection is identical too.

      iex> OrcaHub.Voice.Intent.ratio("orcascend", "orcasend")
      0.9411764705882353
  """
  @spec ratio(String.t(), String.t()) :: float()
  def ratio(a, b) do
    at = a |> String.to_charlist() |> List.to_tuple()
    bt = b |> String.to_charlist() |> List.to_tuple()
    total = tuple_size(at) + tuple_size(bt)

    if total == 0 do
      1.0
    else
      2.0 * match_count(at, bt) / total
    end
  end

  @doc """
  Tokenises `text` the way the reference does: lowercase, every run of
  characters outside `[a-z0-9 ]` becomes a separator, split on whitespace.

      iex> OrcaHub.Voice.Intent.tokenize("Let's ship it. Orcasend.")
      ["let", "s", "ship", "it", "orcasend"]
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text), do: text |> tokens_with_spans() |> Enum.map(&elem(&1, 0))

  # -- scoring ---------------------------------------------------------------

  # Returns {best_score, k} where k is the tail length that produced it, or nil
  # when `text` has no tokens at all. Mirrors the reference's
  # `best = max(best, ...)`: only a STRICTLY greater score displaces the
  # incumbent, so the SMALLEST k achieving the maximum is the one reported.
  defp score_with_k(text, phrase) do
    toks = tokenize(text)
    target = String.replace(phrase, " ", "")
    target_p = phonetic(target)

    Enum.reduce_while(1..3, {0.0, nil}, fn k, {best, best_k} = acc ->
      if k > length(toks) do
        {:halt, acc}
      else
        cand = toks |> Enum.take(-k) |> Enum.join()
        s = max(ratio(cand, target), ratio(phonetic(cand), target_p))
        {:cont, if(s > best, do: {s, k}, else: {best, best_k})}
      end
    end)
  end

  defp vocab_entries(vocab) when is_map(vocab), do: Enum.to_list(vocab)
  defp vocab_entries(vocab) when is_list(vocab), do: vocab

  # -- label matching --------------------------------------------------------

  # "Spaces removed on both sides" (§8.3.8), done with the SAME tokenizer
  # `score/2` uses — so a label's punctuation ("Deploy the hub?") and an ASR
  # transcript's punctuation are stripped identically before they are compared.
  defp normalize(text), do: text |> tokenize() |> Enum.join()

  defp candidate_label(%{"label" => label}) when is_binary(label), do: label
  defp candidate_label(%{label: label}) when is_binary(label), do: label
  defp candidate_label(label) when is_binary(label), do: label
  defp candidate_label(_other), do: ""

  defp candidate_index(%{"index" => index}, _position) when is_integer(index), do: index
  defp candidate_index(%{index: index}, _position) when is_integer(index), do: index
  defp candidate_index(_candidate, position), do: position

  # -- stripping -------------------------------------------------------------

  defp drop_tail_tokens(text, k) do
    spans = tokens_with_spans(text)
    keep = length(spans) - k

    if keep <= 0 do
      ""
    else
      {_tok, start} = Enum.at(spans, keep)

      text
      |> String.to_charlist()
      |> Enum.take(start)
      |> List.to_string()
      |> String.trim_trailing()
    end
  end

  # Tokens paired with their start offset (in codepoints) in the ORIGINAL text,
  # so a match can be sliced back out of it without disturbing the prefix.
  #
  # A codepoint contributes to a token when its lowercased form contains
  # `[a-z0-9]` characters; anything else (spaces, punctuation, non-Latin) is a
  # separator. On the ASCII that ASR returns this is identical to the
  # reference's `_PUNCT.sub(" ", text.lower()).split()`.
  defp tokens_with_spans(text) do
    text
    |> String.to_charlist()
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {cp, idx}, {done, current} ->
      folded = <<cp::utf8>> |> String.downcase() |> keep_alnum()

      case {folded, current} do
        {"", nil} -> {done, nil}
        {"", {buf, start}} -> {[{IO.iodata_to_binary(buf), start} | done], nil}
        {f, nil} -> {done, {[f], idx}}
        {f, {buf, start}} -> {done, {[buf, f], start}}
      end
    end)
    |> then(fn
      {done, nil} -> done
      {done, {buf, start}} -> [{IO.iodata_to_binary(buf), start} | done]
    end)
    |> Enum.reverse()
  end

  defp keep_alnum(s), do: String.replace(s, ~r/[^a-z0-9]/, "")
  defp letters_only(s), do: s |> String.downcase() |> String.replace(~r/[^a-z]/, "")

  defp apply_digraphs(s),
    do: Enum.reduce(@digraphs, s, fn {a, b}, acc -> String.replace(acc, a, b) end)

  # -- difflib internals -----------------------------------------------------

  # Total size of `get_matching_blocks()`, computed the same way difflib does:
  # find the longest matching block in the window, then recurse into the region
  # before it and the region after it.
  defp match_count(a, b), do: match_count(a, b, [{0, tuple_size(a), 0, tuple_size(b)}], 0)

  defp match_count(_a, _b, [], acc), do: acc

  defp match_count(a, b, [{alo, ahi, blo, bhi} | rest], acc) do
    {i, j, k} = find_longest_match(a, b, alo, ahi, blo, bhi)

    if k == 0 do
      match_count(a, b, rest, acc)
    else
      queue = if alo < i and blo < j, do: [{alo, i, blo, j} | rest], else: rest
      queue = if i + k < ahi and j + k < bhi, do: [{i + k, ahi, j + k, bhi} | queue], else: queue
      match_count(a, b, queue, acc + k)
    end
  end

  # difflib's `find_longest_match`, minus the junk handling (`isjunk` is None
  # and autojunk needs 200+ elements, so both extension passes are no-ops here).
  # The `k > bestsize` comparison is STRICT and i/j both ascend, which is what
  # makes the earliest-in-a-then-earliest-in-b block win a length tie.
  defp find_longest_match(a, b, alo, ahi, blo, bhi) do
    {best, _j2len} =
      Enum.reduce(alo..(ahi - 1)//1, {{alo, blo, 0}, %{}}, fn i, {best, j2len} ->
        ai = elem(a, i)

        Enum.reduce(blo..(bhi - 1)//1, {best, %{}}, fn j, {best, new_j2len} ->
          if elem(b, j) == ai do
            k = Map.get(j2len, j - 1, 0) + 1
            {_bi, _bj, bs} = best
            best = if k > bs, do: {i - k + 1, j - k + 1, k}, else: best
            {best, Map.put(new_j2len, j, k)}
          else
            {best, new_j2len}
          end
        end)
      end)

    best
  end
end
