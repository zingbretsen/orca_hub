defmodule OrcaHub.Voice.Prompt do
  @moduledoc """
  Builds the Whisper `initial_prompt` sent with each dispatched voice
  segment: the configured domain VOCABULARY first, then the TAIL of the
  current draft.

  Pure — no config reads, no state. `OrcaHub.Voice.Session` decides WHICH
  draft text counts as context (none at all in palette focus, or while a
  `#`/`##` insert is waiting for its query), and this module only shapes
  and bounds it.

  ## Why that order, and why bounded

  Whisper conditions on the prompt as if it were the transcript immediately
  before the clip, and keeps only the END of it (~224 tokens). So the draft
  tail goes LAST — the words right before the segment matter most — and the
  whole prompt is capped at `max_chars/0`, comfortably under the token
  window, so the vocabulary at the front is never the part Whisper drops.
  The vocabulary is itself capped at `max_vocabulary_chars/0` (enforced at
  save time by `OrcaHub.ASRConfig.Entry`, and again here for an env value),
  which guarantees the draft tail a real share of the budget.

  The draft tail is trimmed on a WORD boundary: a half-word at the cut would
  be read as a real (mis-spelled) word preceding the clip. Whitespace runs —
  including the newlines a spoken `orca newline` inserts — collapse to one
  space, since the prompt is context, not layout.
  """

  @max_chars 700
  @max_vocabulary_chars 400

  @doc "The hard cap on the whole prompt, in characters."
  def max_chars, do: @max_chars

  @doc "The cap on the vocabulary part of the prompt, in characters."
  def max_vocabulary_chars, do: @max_vocabulary_chars

  @doc """
  `vocabulary` then the tail of `context`, joined by one space, at most
  `max_chars/0` characters. Either part may be blank or nil; both blank is
  `""`, which `OrcaHub.Voice.ASR` reads as "send no `initial_prompt` field".

  A vocabulary that does not already end in punctuation gets a full stop, so
  the draft tail reads to Whisper as the start of a new sentence rather than
  as one more glossary entry.
  """
  @spec build(String.t() | nil, String.t() | nil) :: String.t()
  def build(vocabulary, context) do
    vocabulary = vocabulary |> squish() |> head_on_word_boundary(@max_vocabulary_chars)
    vocabulary = terminate(vocabulary)

    budget =
      if vocabulary == "", do: @max_chars, else: @max_chars - String.length(vocabulary) - 1

    tail = context |> squish() |> tail_on_word_boundary(budget)

    [vocabulary, tail]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp squish(nil), do: ""
  defp squish(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")

  defp terminate(""), do: ""

  defp terminate(text) do
    if String.ends_with?(text, [".", "!", "?", ",", ";", ":"]), do: text, else: text <> "."
  end

  # The LAST `budget` characters, minus any partial word at the front. One
  # character more than the budget is taken so a window that happens to
  # start exactly on a word is told apart from one that starts mid-word: a
  # leading space there means the cut fell between words.
  defp tail_on_word_boundary(text, budget) do
    cond do
      budget <= 0 ->
        ""

      String.length(text) <= budget ->
        text

      true ->
        case text |> String.slice(-(budget + 1), budget + 1) |> String.split(" ", parts: 2) do
          [_partial, rest] -> rest
          [_one_long_word] -> ""
        end
    end
  end

  # The mirror image, for the vocabulary: its FIRST entries are the ones the
  # user listed first, so an over-long one keeps its head.
  defp head_on_word_boundary(text, limit) do
    if String.length(text) <= limit do
      text
    else
      case text |> String.slice(0, limit + 1) |> String.split(" ") |> Enum.drop(-1) do
        [] -> ""
        words -> words |> Enum.join(" ") |> String.trim_trailing(",")
      end
    end
  end
end
