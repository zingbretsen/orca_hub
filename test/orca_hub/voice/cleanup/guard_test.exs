defmodule OrcaHub.Voice.Cleanup.GuardTest do
  @moduledoc """
  Parity, not "roughly right" — the same discipline as `IntentTest`.

  `cleanup_guard_parity.json` holds every distinct output the voice-cleanup
  bench recorded (all three models, every prompt and output mode, the held-out
  set — good outputs AND the bad ones the guard exists to catch), with the
  decision, reason and features the Python reference (`guard.py` `FINAL`)
  computed for each. See `test/support/fixtures/voice/README.md`.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Cleanup
  alias OrcaHub.Voice.Cleanup.Guard

  @fixture Path.expand("../../../support/fixtures/voice/cleanup_guard_parity.json", __DIR__)

  setup_all do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    {:ok, fixture: fixture, glossary: Guard.glossary(Cleanup.default_glossary())}
  end

  describe "parity with the Python reference (voice-cleanup-bench guard.py FINAL)" do
    test "every recorded output gets the reference decision, reason and features", %{
      fixture: fixture,
      glossary: glossary
    } do
      mismatches =
        for row <- fixture["rows"],
            raw = Map.fetch!(fixture["cases"], row["case"]),
            f = Guard.features(raw, row["output"], glossary),
            got = %{
              n: f.content_words,
              miss: f.missing,
              intro: f.introduced,
              miss_adj: f.missing_adj,
              novel: f.novel,
              len: f.length_ratio,
              prot: f.protected,
              reason: f.reason && Atom.to_string(f.reason)
            },
            want = %{
              n: row["n"],
              miss: row["miss"],
              intro: row["intro"],
              miss_adj: row["miss_adj"],
              novel: row["novel"],
              len: row["len"],
              prot: row["prot"],
              reason: row["reason"]
            },
            # The floats are compared EXACTLY: both sides do the same IEEE
            # division of the same two integers.
            got != want do
          %{case: row["case"], output: row["output"], want: want, got: got}
        end

      assert mismatches == [],
             "#{length(mismatches)} of #{length(fixture["rows"])} rows diverged from the " <>
               "reference:\n" <> Enum.map_join(Enum.take(mismatches, 5), "\n", &inspect/1)
    end

    test "check/3 agrees with the reference's accept/reject on every row", %{
      fixture: fixture,
      glossary: glossary
    } do
      for row <- fixture["rows"] do
        raw = fixture["cases"][row["case"]]

        expected =
          if row["accept"], do: :ok, else: {:reject, String.to_existing_atom(row["reason"])}

        assert Guard.check(raw, row["output"], glossary) == expected, inspect(row)
      end
    end

    test "the fixture covers the whole recorded population, bad outputs included", %{
      fixture: fixture
    } do
      assert fixture["aggregate"]["unique_pairs"] == length(fixture["rows"])
      assert length(fixture["rows"]) == 552
      assert fixture["aggregate"]["recorded_outputs"] == 3209

      reasons = Enum.frequencies_by(fixture["rows"], & &1["reason"])

      assert reasons == %{
               nil => 494,
               "missing_content" => 41,
               "novel" => 9,
               "protected" => 6,
               "too_long" => 2
             }
    end

    test "reproduces the report's headline: 24/2525 good rejected, 78/109 bad caught", %{
      fixture: fixture,
      glossary: glossary
    } do
      tally =
        Enum.reduce(fixture["rows"], %{good: 0, bad: 0, good_rejected: 0, bad_caught: 0}, fn
          row, acc ->
            rejected? = Guard.check(fixture["cases"][row["case"]], row["output"], glossary) != :ok

            %{
              good: acc.good + row["good"],
              bad: acc.bad + row["bad"],
              good_rejected: acc.good_rejected + if(rejected?, do: row["good"], else: 0),
              bad_caught: acc.bad_caught + if(rejected?, do: row["bad"], else: 0)
            }
        end)

      assert tally == %{good: 2525, bad: 109, good_rejected: 24, bad_caught: 78}

      assert Map.take(fixture["aggregate"], ~w(verdict_good verdict_bad good_rejected bad_caught)) ==
               %{
                 "verdict_good" => 2525,
                 "verdict_bad" => 109,
                 "good_rejected" => 24,
                 "bad_caught" => 78
               }
    end
  end

  describe "the glossary" do
    test "the default glossary derives EXACTLY the bench's two hand-written lists", %{
      fixture: fixture,
      glossary: glossary
    } do
      assert Enum.map(glossary.credit, &elem(&1, 0)) == fixture["source"]["credit_glossary"]
      assert Enum.sort(glossary.tokens) == fixture["source"]["novelty_glossary"]
    end

    test "notes in parentheses are dropped, even when they contain commas" do
      glossary = Guard.glossary("Foo Bar (a thing, really), baz-qux, pi (lowercase)")

      assert Enum.map(glossary.credit, &elem(&1, 0)) == ["foo bar", "baz qux"]
      assert Enum.sort(glossary.tokens) == ["bar", "baz", "foo", "pi", "qux"]
    end

    test "a blank glossary credits and exempts nothing" do
      assert Guard.glossary("") == %{credit: [], tokens: MapSet.new()}
      assert Guard.glossary(nil) == %{credit: [], tokens: MapSet.new()}
    end

    test "a glossary term the output introduces pays for two missing raw words", %{
      glossary: glossary
    } do
      raw = "check the author Leah config and the post gress pool"
      out = "Check the Authelia config and the Postgres pool."

      # "author", "leah" and "gress" are not substrings of the output; the
      # two introduced terms (Authelia, Postgres) credit four.
      f = Guard.features(raw, out, glossary)
      assert {f.missing, f.introduced, f.missing_adj} == {3, 2, 0}
      assert Guard.check(raw, out, glossary) == :ok
      assert Guard.check(raw, out, Guard.glossary("")) == {:reject, :missing_content}
    end
  end

  describe "the four rules" do
    setup %{glossary: glossary}, do: {:ok, g: glossary}

    test "an ANSWER instead of a cleanup is rejected", %{g: g} do
      raw = "What is two plus two? Answer in one word."
      assert {:reject, _} = Guard.check(raw, "Four.", g)
    end

    test "a reply padded with new content is rejected as novel or too long", %{g: g} do
      raw = "Can you draft an email to Bob."

      assert {:reject, reason} =
               Guard.check(
                 raw,
                 "Sure! Here is a draft email to Bob: Hi Bob, hope you are well.",
                 g
               )

      assert reason in [:novel, :too_long]
    end

    test "a corrupted path is rejected even when every word survives", %{g: g} do
      raw = "Open lib/orca_hub/voice/session.ex. And check it."
      assert Guard.check(raw, "Open lib/orca_hub/voice/session.ex and check it.", g) == :ok

      assert Guard.check(raw, "Open lib/OrcaHub/voice/session.ex and check it.", g) ==
               {:reject, :protected}
    end

    test "rejoining pause-split fragments is accepted", %{g: g} do
      raw = "We have a court date. On the 12th. For the parking ticket."

      assert Guard.check(raw, "We have a court date on the 12th for the parking ticket.", g) ==
               :ok
    end

    test "Python's whitespace: NBSP separates tokens, as str.split() does", %{g: g} do
      assert Guard.norm_tokens("one two") == ["one", "two"]
      assert Guard.norm_tokens("a\u001Fb") == ["a", "b"]
      assert Guard.check("alpha beta gamma", "alpha beta gamma", g) == :ok
    end

    test "the tokenizer drops line-leading list markers and strips punctuation", %{g: _g} do
      assert Guard.norm_tokens("1. Eggs\n- milk,\n## “Bread”…") == ["eggs", "milk", "bread"]
      assert Guard.norm_tokens("re-run the — check") == ["re", "run", "the", "check"]
    end
  end
end
