defmodule OrcaHub.Voice.Cleanup.Guard do
  @moduledoc """
  The acceptance guard for `OrcaHub.Voice.Cleanup`: decides, from the RAW
  text and the model's OUTPUT alone, whether a cleanup rewrite may replace
  the raw segments in the draft. A port of the voice-cleanup bench's
  `FINAL = mk(0.1, 1)` rule (`~/voice-cleanup-bench/guard.py`, with its
  tokenizer and two features from `score.py`).

  Accept only if ALL hold, checked in this order (the first failure is the
  reject reason):

    1. `:missing_content` — raw CONTENT words (not a stopword, filler or list
       ordinal) absent from the output, after crediting 2 for every glossary
       term the output introduces that the raw lacked, are at most
       `max(1, trunc(0.1 * content_words))`. "Absent" is a SUBSTRING test
       against the de-spaced output, so "post gress" -> "postgres" passes.
    2. `:novel` — at most 25% of output words appear nowhere in the raw
       (glossary words exempt).
    3. `:too_long` — the output is at most 1.6x the raw's word count
       (fillers excluded from the raw).
    4. `:protected` — every protected raw token (a path, `snake_case`,
       `CONST_CASE`, a decimal number, an `h:mm` time, a URL) appears
       verbatim in the output.

  Measured on the bench's 2,634 manually-judged outputs: 1.0% false rejects
  (24/2,525), 72% of bad outputs caught (78/109) — 23/25 answers, 14/16
  context echoes. It is a backstop for catastrophic rewrites, not a meaning
  checker: a one-word meaning change ("the hub" -> "OrcaHub") passes it.

  ## Parity is the acceptance test

  `test/orca_hub/voice/cleanup/guard_test.exs` replays every recorded bench
  output (all three models, every prompt and mode, good AND bad) and asserts
  this module reaches the reference's decision, reason and features on
  every row. The details that matter for that, and must not be "tidied":

    * whitespace splitting is Python's `str.split()` (which splits on NBSP
      and the `\\x1c`-`\\x1f` separators; `String.split/1` does not);
    * token stripping is `str.strip(chars)` over a fixed character set;
    * every regex is Unicode-aware (`\\w`/`\\d` as in Python 3);
    * the budget is `trunc(0.1 * n)` on a float, exactly as `int(0.1 * n)`.

  ## The glossary

  The guard needs two views of the cleanup glossary (`glossary/1`): CREDIT
  terms (rule 1) and NOVELTY-exempt words (rule 2). Both are derived from the
  same comma-separated text the prompt carries, parenthetical notes removed.
  Credit terms shorter than 3 characters are left out — crediting two
  missing words for an introduced "pi" is too generous — which reproduces
  the bench's two hand-written lists exactly from its glossary (pinned by the
  parity test).
  """

  @stopwords ~w(a an the and or but so if then than that this these those it its it's is are was were be been being am
                i i'm i've i'd i'll you you're we we're we've they they're he she him her them us our your my me of to in on at for
                with by from as about into over up down out off just really kind sort like okay ok well yeah also too very actually
                do does did doing don't doesn't didn't can can't could would should will won't might may must have has had not no
                there here what which who whom when where why how all any some more most other such only own same few each both
                first second third fourth number bullet one two three four five um uh er ah erm hmm going gonna get got)
             |> MapSet.new()

  @fillers MapSet.new(~w(um uh er ah erm hmm))

  # score.py STRIP + "-": what norm_tokens strips off both ends of a token.
  @token_strip String.codepoints(".,;:!?\"'()[]{}*`“”‘’…-")

  # guard.py protected_ok: what is stripped off a raw token before PROTECT.
  @protect_strip String.codepoints(".,;:!?\"'()")

  @min_credit_chars 3
  @missing_fraction 0.1
  @missing_floor 1
  @max_novel 0.25
  @max_length_ratio 1.6

  @type glossary :: %{credit: [{String.t(), Regex.t()}], tokens: MapSet.t(String.t())}
  @type reason :: :missing_content | :novel | :too_long | :protected

  @doc """
  The guard's view of a cleanup glossary — the comma-separated term list the
  prompt carries, e.g. `"OrcaHub, GB10, pi (a coding-agent backend), Darling
  Court"`. Parenthetical notes are dropped; a blank glossary is valid and
  credits/exempts nothing.
  """
  @spec glossary(String.t() | nil) :: glossary()
  def glossary(text) do
    terms =
      (text || "")
      |> String.replace(~r/\s*\([^)]*\)/u, "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    credit =
      terms
      |> Enum.map(&(&1 |> norm_tokens() |> Enum.join(" ")))
      |> Enum.filter(&(String.length(&1) >= @min_credit_chars))
      |> Enum.uniq()
      |> Enum.map(&{&1, Regex.compile!("(?<!\\w)" <> Regex.escape(&1) <> "(?!\\w)", "u")})

    %{credit: credit, tokens: terms |> Enum.flat_map(&norm_tokens/1) |> MapSet.new()}
  end

  @doc """
  `:ok`, or `{:reject, reason}` for the FIRST failing rule in the order the
  moduledoc lists them.
  """
  @spec check(String.t(), String.t(), glossary()) :: :ok | {:reject, reason()}
  def check(raw, output, glossary) do
    case features(raw, output, glossary) do
      %{reason: nil} -> :ok
      %{reason: reason} -> {:reject, reason}
    end
  end

  @doc """
  Every feature the decision is made from, plus the decision itself — what
  the parity test compares field by field, and what `OrcaHub.Voice.Cleanup`
  logs on a rejection.
  """
  @spec features(String.t(), String.t(), glossary()) :: map()
  def features(raw, output, glossary) do
    raw_t = norm_tokens(raw)
    out_t = norm_tokens(output)

    raw_content = Enum.reject(raw_t, &MapSet.member?(@stopwords, &1))
    flat = Enum.join(out_t)
    missing = Enum.count(raw_content, &(not String.contains?(flat, &1)))

    raw_line = Enum.join(raw_t, " ")
    out_line = Enum.join(out_t, " ")

    introduced =
      Enum.count(glossary.credit, fn {_term, re} ->
        Regex.match?(re, out_line) and not Regex.match?(re, raw_line)
      end)

    known = MapSet.union(MapSet.new(raw_t), glossary.tokens)
    novel = Enum.count(out_t, &(not MapSet.member?(known, &1))) / max(1, length(out_t))

    raw_words = Enum.count(raw_t, &(not MapSet.member?(@fillers, &1)))
    length_ratio = length(out_t) / max(1, raw_words)

    n = length(raw_content)
    missing_adj = max(0, missing - 2 * introduced)
    allowed = max(@missing_floor, trunc(@missing_fraction * n))
    protected = protected_ok?(raw, output)

    reason =
      cond do
        missing_adj > allowed -> :missing_content
        novel > @max_novel -> :novel
        length_ratio > @max_length_ratio -> :too_long
        not protected -> :protected
        true -> nil
      end

    %{
      content_words: n,
      missing: missing,
      introduced: introduced,
      missing_adj: missing_adj,
      allowed_missing: allowed,
      novel: novel,
      length_ratio: length_ratio,
      protected: protected,
      reason: reason
    }
  end

  @doc """
  The bench tokenizer (`score.py` `norm_tokens`): curly apostrophes folded,
  dashes and intra-word hyphens split, lowercased, a line-leading list or
  heading marker dropped, punctuation stripped off both ends of each token.
  """
  @spec norm_tokens(String.t() | nil) :: [String.t()]
  def norm_tokens(nil), do: []

  def norm_tokens(text) do
    text
    |> String.replace("’", "'")
    |> String.replace("‘", "'")
    |> String.replace("—", " ")
    |> String.replace("–", " ")
    |> then(&Regex.replace(~r/(?<=\w)-(?=\w)/u, &1, " "))
    |> String.downcase()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      line
      |> py_split()
      |> drop_line_marker()
      |> Enum.map(&py_strip(&1, @token_strip))
      |> Enum.reject(&(&1 == ""))
    end)
  end

  defp drop_line_marker([first | rest] = tokens) do
    if Regex.match?(~r/\A(?:[-*•]|\d+[.)]|#+)\z/u, first), do: rest, else: tokens
  end

  defp drop_line_marker([]), do: []

  # guard.py protected_ok: every raw token that looks like an identifier must
  # survive VERBATIM (a substring of the untokenized output).
  defp protected_ok?(raw, output) do
    raw
    |> py_split()
    |> Enum.map(&py_strip(&1, @protect_strip))
    |> Enum.filter(&(&1 != "" and protected_token?(&1)))
    |> Enum.all?(&String.contains?(output, &1))
  end

  defp protected_token?(token) do
    Regex.match?(
      ~r{^(?=.*[A-Za-z0-9])(?:[\w$.,:/@-]*[_/@][\w$.,:/@-]*|[A-Z][A-Z0-9]*_[A-Z0-9_]+|\$?\d[\d,]*\.\d+|\d+:\d\d|https?://\S+)$}u,
      token
    )
  end

  # Python's str.split() with no separator: runs of str.isspace() characters,
  # empty ends dropped. Spelled out because String.split/1 does NOT split on
  # NBSP and friends.
  defp py_split(text) do
    Regex.split(
      ~r/[\x{09}-\x{0d}\x{1c}-\x{20}\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}]+/u,
      text,
      trim: true
    )
  end

  # Python's str.strip(chars): drop any of `chars` (code points) off both ends.
  defp py_strip(token, chars) do
    token
    |> String.codepoints()
    |> Enum.drop_while(&(&1 in chars))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in chars))
    |> Enum.reverse()
    |> Enum.join()
  end
end
