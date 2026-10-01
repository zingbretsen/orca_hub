defmodule OrcaHub.Voice.DictationTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Voice.Dictation

  test "prefix/1 puts the note in its own leading paragraph" do
    assert Dictation.prefix("look at the Nemo Tron config") ==
             Dictation.note() <> "\n\nlook at the Nemo Tron config"
  end

  test "the note says it was dictated and asks for the intended meaning, briefly" do
    note = Dictation.note()
    assert note =~ "Dictated via speech recognition"
    assert note =~ "infer the intended meaning"
    assert String.length(note) < 160
  end

  describe "strip/1" do
    test "round-trips prefix/1" do
      assert Dictation.strip(Dictation.prefix("hello there")) == {true, "hello there"}
    end

    test "leaves a typed message untouched" do
      assert Dictation.strip("hello there") == {false, "hello there"}
    end

    test "finds the note behind a queued-delivery header" do
      queued =
        "[Message delivery note]\n\nThis message was sent with queued delivery...\n\n" <>
          Dictation.prefix("ship it")

      assert {true, rest} = Dictation.strip(queued)
      refute rest =~ Dictation.note()
      assert rest =~ "[Message delivery note]"
      assert String.ends_with?(rest, "\n\nship it")
    end

    test "strips every note in a batch of queued messages" do
      batch =
        Dictation.prefix("one") <>
          "\n\n\n" <> "typed two" <> "\n\n\n" <> Dictation.prefix("three")

      assert Dictation.strip(batch) == {true, "one\n\n\ntyped two\n\n\nthree"}
    end

    test "leaves a mid-sentence quotation of the note alone" do
      quoted = "the hook sends " <> Dictation.note() <> "\n\nas a prefix"
      assert Dictation.strip(quoted) == {false, quoted}
    end

    test "passes non-binaries through" do
      assert Dictation.strip(nil) == {false, nil}
    end
  end
end
