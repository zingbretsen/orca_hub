defmodule OrcaHub.Voice.PromptTest do
  @moduledoc """
  The Whisper `initial_prompt` builder on its own. Which draft text counts
  as context (palette focus, a pending `#` insert) is `Voice.Session`'s
  call and is pinned in `session_test.exs`; this file pins the shaping and
  the bounds.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Prompt

  @max Prompt.max_chars()

  describe "build/2" do
    test "vocabulary first, terminated, then the context" do
      assert Prompt.build("OrcaHub, GB10, Keene", "deploy it to mini") ==
               "OrcaHub, GB10, Keene. deploy it to mini"
    end

    test "a vocabulary that already ends in punctuation is not given a second stop" do
      assert Prompt.build("OrcaHub, GB10.", "go") == "OrcaHub, GB10. go"
      assert Prompt.build("Terms:", "go") == "Terms: go"
    end

    test "either half may be blank or nil; both blank is the empty string" do
      assert Prompt.build("OrcaHub", "") == "OrcaHub."
      assert Prompt.build("OrcaHub", nil) == "OrcaHub."
      assert Prompt.build("", "just the draft") == "just the draft"
      assert Prompt.build(nil, "just the draft") == "just the draft"
      assert Prompt.build("", "") == ""
      assert Prompt.build(nil, nil) == ""
      assert Prompt.build("  \n ", " \t") == ""
    end

    test "whitespace runs, newlines included, collapse to one space" do
      assert Prompt.build("OrcaHub,\n  GB10", "line one\n\nline   two ") ==
               "OrcaHub, GB10. line one line two"
    end

    test "a short context is kept whole" do
      context = String.duplicate("abcd ", 100) |> String.trim_trailing()
      assert Prompt.build("", context) == context
    end
  end

  describe "the bound" do
    test "a context over budget keeps its TAIL, cut on a word boundary" do
      # 5 + 700 chars: the cut falls inside "xyzzy", which must go entirely.
      body = String.duplicate(" abcdefghi", 70)
      prompt = Prompt.build("", "xyzzy" <> body)

      assert prompt == String.trim_leading(body)
      assert String.length(prompt) == 699
    end

    test "a tail that starts exactly on a word is kept to the last character of budget" do
      # Exactly @max chars, starting with a whole word, after one to drop.
      kept = "z" <> (String.duplicate("abcd ", 140) |> String.trim_trailing())
      assert String.length(kept) == @max

      assert Prompt.build("", "drop " <> kept) == kept
    end

    test "one word longer than the whole budget contributes nothing" do
      assert Prompt.build("OrcaHub", String.duplicate("x", @max + 50)) == "OrcaHub."
    end

    test "the vocabulary's length comes out of the context's budget" do
      vocabulary = "OrcaHub, GB10, Elixir, Phoenix LiveView, Darling Court, Keene"
      context = Enum.map_join(1..400, " ", &"w#{&1}")

      prompt = Prompt.build(vocabulary, context)

      assert String.length(prompt) <= @max
      assert String.starts_with?(prompt, vocabulary <> ". ")
      assert String.ends_with?(prompt, "w399 w400")

      # Word-aligned: the tail is a suffix of the context starting after a space.
      tail = String.replace_prefix(prompt, vocabulary <> ". ", "")
      assert String.ends_with?(context, " " <> tail)
    end

    test "an over-long vocabulary keeps its HEAD, word-aligned, and leaves room for context" do
      vocabulary = Enum.map_join(1..200, ", ", &"Term#{&1}")
      assert String.length(vocabulary) > Prompt.max_vocabulary_chars()

      prompt = Prompt.build(vocabulary, "the end of the draft")

      assert String.starts_with?(prompt, "Term1, Term2, ")
      assert String.ends_with?(prompt, ". the end of the draft")
      assert String.length(prompt) <= @max

      [kept_vocabulary, _] = String.split(prompt, ". the end", parts: 2)
      assert String.length(kept_vocabulary) <= Prompt.max_vocabulary_chars()
      assert String.starts_with?(vocabulary, kept_vocabulary)
      # cut between entries, not inside one
      assert String.starts_with?(String.replace_prefix(vocabulary, kept_vocabulary, ""), ", ")
    end

    test "never exceeds the bound, whatever the inputs" do
      for v <- [0, 10, 399, 400, 1_000], c <- [0, 1, 699, 700, 701, 5_000] do
        vocabulary = String.duplicate("v ", v)
        context = String.duplicate("c ", c)
        assert String.length(Prompt.build(vocabulary, context)) <= @max
      end
    end

    test "UTF-8 is counted in characters, not bytes" do
      context = String.duplicate("café naïve ", 100)
      prompt = Prompt.build("", context)

      assert String.valid?(prompt)
      assert String.length(prompt) <= @max
      assert String.ends_with?(prompt, "café naïve")
    end
  end
end
