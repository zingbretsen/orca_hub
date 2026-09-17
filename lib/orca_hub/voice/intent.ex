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

  @default_threshold 0.85

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
