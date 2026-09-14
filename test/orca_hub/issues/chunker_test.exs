defmodule OrcaHub.Issues.ChunkerTest do
  @moduledoc """
  `OrcaHub.Issues.Chunker` is pure, so this is exhaustive and fast. The
  properties that matter are the ones a later indexer silently depends on:
  every chunk fits the embedding server's context, the chunks COVER the
  input (nothing is dropped), and order is stable.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Issues.Chunker
  alias OrcaHub.Issues.Issue

  @target Chunker.target_chars()
  @single_max Chunker.single_chunk_max_chars()

  # The pessimistic chars-per-token ratio measured on qwen3-embedding-0.6b
  # (dense code/identifier text). 8192 tokens at this ratio is ~15,155
  # chars — the absolute wall a chunk must stay under. See the Chunker
  # moduledoc.
  @worst_case_chars_per_token 1.85
  @server_context_tokens 8192
  @absolute_max_chars trunc(@server_context_tokens * @worst_case_chars_per_token)

  defp raw(chunk), do: Chunker.strip_label(chunk)

  # Asserts the chunks COVER `text` with no gap, in order.
  #
  # Deliberately not a "reassemble and compare" helper: with periodic text
  # (a repeated word, a hex blob) the longest-common-overlap reassembly is
  # ambiguous and silently swallows whole chunks, which makes the helper
  # itself the thing under test. Instead, each chunk is located in the
  # source at or before the previous chunk's end — proving there's no gap —
  # and the last chunk must end exactly at the end of the input.
  defp assert_covers(text, chunks) do
    assert chunks != []

    # Each chunk must be locatable at or before the previous chunk's end, so
    # the covered region stays contiguous. Progress is tracked with `max/2`
    # rather than asserted per chunk: with periodic text (a repeated word) a
    # chunk legitimately matches at several aliased offsets, and picking the
    # highest one can overshoot — which says nothing about the chunker.
    final_end =
      chunks
      |> Enum.map(&raw/1)
      |> Enum.reduce(0, fn slice, prev_end ->
        refute slice == "", "a chunk was empty"
        start = find_start(text, slice, prev_end)

        assert start,
               "chunk starting #{inspect(String.slice(slice, 0, 40))} was not found " <>
                 "at or before offset #{prev_end} — the chunks have a gap"

        max(start + byte_size(slice), prev_end)
      end)

    assert final_end == byte_size(text),
           "chunks stopped at #{final_end} of #{byte_size(text)} bytes"
  end

  # Overlap is bounded by Chunker.overlap_chars/0 (advancing to a word
  # boundary only ever shrinks it), so a small backwards window suffices.
  @search_window 400

  defp find_start(text, slice, upper_bound) do
    len = byte_size(slice)
    upper = min(upper_bound, byte_size(text) - len)

    if upper < 0 do
      nil
    else
      Enum.find(upper..max(0, upper - @search_window)//-1, fn p ->
        binary_part(text, p, len) == slice
      end)
    end
  end

  describe "chunk/1 field selection" do
    test "an issue with only a title yields exactly one chunk" do
      assert [%{field: "title", chunk_index: 0, content: "title: just a title"}] =
               Chunker.chunk(%Issue{title: "just a title"})
    end

    test "nil, missing and whitespace-only fields produce no chunks" do
      assert Chunker.chunk(%Issue{}) == []
      assert Chunker.chunk(%Issue{title: nil, notes: "   \n\n  \t "}) == []
      assert Chunker.chunk(%{}) == []
    end

    test "emits fields in field_order/0" do
      issue = %Issue{
        title: "t",
        description: "d",
        premise: "pr",
        plan: "pl",
        resolution: "r",
        approaches_tried: "a",
        notes: "n"
      }

      fields = Chunker.chunk(issue) |> Enum.map(& &1.field)
      assert fields == Enum.map(Chunker.field_order(), &Atom.to_string/1)
    end

    test "every emitted field is one the IssueChunk schema accepts" do
      assert Enum.all?(Chunker.field_order(), fn f ->
               Atom.to_string(f) in OrcaHub.Issues.IssueChunk.indexable_fields()
             end)
    end

    test "chunk_index restarts at 0 per field" do
      issue = %Issue{
        description: String.duplicate("word ", 1500),
        notes: String.duplicate("note ", 1500)
      }

      by_field = Chunker.chunk(issue) |> Enum.group_by(& &1.field, & &1.chunk_index)

      assert map_size(by_field) == 2

      for {_field, indexes} <- by_field do
        assert length(indexes) > 1
        assert indexes == Enum.to_list(0..(length(indexes) - 1))
      end
    end
  end

  describe "labels" do
    test "content carries the field label and the raw slice is recoverable" do
      [chunk] = Chunker.chunk(%Issue{resolution: "shipped it"})

      assert chunk.content == "resolution: shipped it"
      assert Chunker.strip_label(chunk) == "shipped it"
      assert Chunker.strip_label(:resolution, chunk.content) == "shipped it"
    end

    test "strip_label is a no-op on already-stripped text" do
      assert Chunker.strip_label(:notes, "no label here") == "no label here"
    end

    test "every chunk of a split field is labelled" do
      chunks = Chunker.chunk(%Issue{notes: String.duplicate("some note text ", 800)})

      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.starts_with?(&1.content, "notes: "))
    end
  end

  describe "single-chunk fields" do
    test "title, premise and plan are not split at ordinary sizes" do
      text = String.duplicate("plan detail. ", 300)
      assert byte_size(text) > @target
      assert byte_size(text) < @single_max

      for field <- [:title, :premise, :plan] do
        chunks = Chunker.chunk_field(field, text)
        assert length(chunks) == 1, "#{field} should have been one chunk"
        assert raw(hd(chunks)) == text
      end
    end

    test "but they DO split past the single-chunk ceiling, so a huge plan can't blow n_ctx" do
      text = String.duplicate("plan detail. ", 1000)
      assert byte_size(text) > @single_max

      chunks = Chunker.chunk_field(:plan, text)
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1.content) <= @target + 32))
      assert_covers(text, chunks)
    end
  end

  describe "splitting fields" do
    test "short text stays a single chunk" do
      assert [chunk] = Chunker.chunk_field(:description, "short enough")
      assert raw(chunk) == "short enough"
    end

    test "prefers blank lines — the natural notes boundary" do
      # 30 paragraphs of ~120 chars: several fit per chunk, and every chunk
      # should end at a paragraph break rather than mid-paragraph.
      paragraph = String.duplicate("sentence about the thing. ", 5)
      text = 1..30 |> Enum.map_join("\n\n", fn i -> "#{i}. #{paragraph}" end)

      chunks = Chunker.chunk_field(:notes, text)
      assert length(chunks) > 1

      # Every chunk but the last ends at a blank-line boundary.
      chunks
      |> Enum.drop(-1)
      |> Enum.each(fn chunk ->
        assert String.ends_with?(raw(chunk), "\n\n"),
               "chunk did not end on a blank line: #{inspect(String.slice(raw(chunk), -40, 40))}"
      end)
    end

    test "falls back to newlines when there are no blank lines" do
      text = 1..200 |> Enum.map_join("\n", fn i -> "line #{i} with some content on it" end)

      chunks = Chunker.chunk_field(:description, text)
      assert length(chunks) > 1

      chunks
      |> Enum.drop(-1)
      |> Enum.each(fn chunk -> assert String.ends_with?(raw(chunk), "\n") end)
    end

    test "falls back to whitespace, never splitting mid-word" do
      text = String.duplicate("supercalifragilistic ", 400)

      chunks = Chunker.chunk_field(:description, text)
      assert length(chunks) > 1

      # Every word in every chunk is a whole word.
      Enum.each(chunks, fn chunk ->
        chunk
        |> raw()
        |> String.split(~r/\s+/, trim: true)
        |> Enum.each(fn word -> assert word == "supercalifragilistic" end)
      end)
    end

    test "consecutive chunks overlap" do
      text = String.duplicate("alpha beta gamma delta ", 300)
      chunks = Chunker.chunk_field(:notes, text)
      assert length(chunks) > 1

      total = chunks |> Enum.map(&byte_size(raw(&1))) |> Enum.sum()
      assert total > byte_size(text), "chunks should overlap, not tile exactly"

      # The overlap is bounded — it should not double the corpus.
      assert total < byte_size(text) * 1.5
    end

    test "covers the input with no gap (nothing dropped, order preserved)" do
      text =
        1..120 |> Enum.map_join("\n\n", fn i -> "note #{i}: #{String.duplicate("x", 90)}" end)

      chunks = Chunker.chunk_field(:notes, text)
      assert_covers(text, chunks)
    end

    test "reassembles byte-exactly on non-periodic text" do
      # Every word is unique, so the longest-common-overlap reassembly below
      # is unambiguous — a stronger check than assert_covers/2, but only
      # sound when the text doesn't repeat itself.
      text = 1..900 |> Enum.map_join(" ", fn i -> "token#{i}" end)

      chunks = Chunker.chunk_field(:description, text)
      assert length(chunks) > 1

      reassembled =
        chunks
        |> Enum.map(&raw/1)
        |> Enum.reduce("", fn slice, acc ->
          overlap =
            Enum.find(min(byte_size(acc), byte_size(slice))..0//-1, 0, fn n ->
              binary_part(acc, byte_size(acc) - n, n) == binary_part(slice, 0, n)
            end)

          acc <> binary_part(slice, overlap, byte_size(slice) - overlap)
        end)

      assert reassembled == text
    end

    test "overlap between consecutive chunks is roughly overlap_chars" do
      text = 1..900 |> Enum.map_join(" ", fn i -> "token#{i}" end)
      chunks = Chunker.chunk_field(:description, text) |> Enum.map(&raw/1)

      overlaps =
        chunks
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] ->
          Enum.find(min(byte_size(a), byte_size(b))..0//-1, 0, fn n ->
            binary_part(a, byte_size(a) - n, n) == binary_part(b, 0, n)
          end)
        end)

      assert Enum.all?(overlaps, &(&1 > 0)), "consecutive chunks must overlap"

      assert Enum.all?(overlaps, &(&1 <= Chunker.overlap_chars())),
             "overlap should not exceed overlap_chars/0: #{inspect(overlaps)}"
    end

    test "a blob with no whitespace at all is still split, at a codepoint boundary" do
      text = String.duplicate("abcdef0123456789", 500)
      refute String.contains?(text, " ")

      chunks = Chunker.chunk_field(:description, text)
      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?(&1.content))
      assert_covers(text, chunks)
    end

    test "multi-byte text is never split mid-codepoint" do
      # No whitespace, so this is forced down the hard-split path, where a
      # naive byte split would corrupt a character.
      text = String.duplicate("日本語テキスト→", 400)

      chunks = Chunker.chunk_field(:notes, text)
      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?(&1.content))
      assert_covers(text, chunks)
    end

    test "drops whitespace-only chunks while keeping chunk_index contiguous" do
      text = String.duplicate("real content here. ", 200) <> String.duplicate("\n", 3000)

      chunks = Chunker.chunk_field(:notes, text)
      refute Enum.any?(chunks, &(String.trim(raw(&1)) == ""))
      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))
    end
  end

  describe "the real worst case: a 35k-char notes blob" do
    setup do
      # Shaped like the real corpus max (35,092 chars): an append-only blob
      # of blank-line-separated notes of varying length, including a code
      # block, which is the dense-token shape the budget is sized against.
      notes =
        1..110
        |> Enum.map(fn i ->
          body =
            case rem(i, 5) do
              0 ->
                "```\n" <>
                  Enum.map_join(1..8, "\n", fn j -> "  def handle_#{i}_#{j}(x), do: {:ok, x}" end) <>
                  "\n```"

              1 ->
                String.duplicate("a short note. ", 3)

              _ ->
                String.duplicate("a considerably longer note about what happened here. ", 8)
            end

          "[note #{i}] #{body}"
        end)
        |> Enum.join("\n\n")

      assert byte_size(notes) > 35_092
      %{notes: notes}
    end

    test "every chunk fits the server's context with a wide margin", %{notes: notes} do
      chunks = Chunker.chunk_field(:notes, notes)

      assert length(chunks) > 20

      Enum.each(chunks, fn chunk ->
        size = byte_size(chunk.content)

        assert size <= @absolute_max_chars,
               "chunk of #{size} chars could exceed the #{@server_context_tokens}-token limit"

        # And in practice well under the target, not just under the wall.
        assert size <= @target + 32
      end)
    end

    test "covers the whole input, in order", %{notes: notes} do
      chunks = Chunker.chunk_field(:notes, notes)

      assert_covers(notes, chunks)
      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1))
      assert Enum.all?(chunks, &(&1.field == "notes"))
    end

    test "chunking is deterministic", %{notes: notes} do
      assert Chunker.chunk_field(:notes, notes) == Chunker.chunk_field(:notes, notes)
    end

    test "a full issue built from it also stays under the limit", %{notes: notes} do
      issue = %Issue{
        title: String.duplicate("t", 206),
        description: String.duplicate("description sentence. ", 500),
        premise: String.duplicate("premise sentence. ", 130),
        plan: String.duplicate("plan step. ", 400),
        resolution: String.duplicate("resolution sentence. ", 340),
        notes: notes
      }

      chunks = Chunker.chunk(issue)

      assert Enum.all?(chunks, &(byte_size(&1.content) <= @absolute_max_chars))

      # Each splitting field is covered independently.
      for {field, text} <- [
            {"description", issue.description},
            {"resolution", issue.resolution},
            {"notes", issue.notes}
          ] do
        field_chunks = Enum.filter(chunks, &(&1.field == field))
        assert_covers(text, field_chunks)
      end
    end
  end

  describe "chunk_field/2 input handling" do
    test "accepts a string field name" do
      assert [%{field: "notes"}] = Chunker.chunk_field("notes", "a note")
    end

    test "an unknown field produces nothing" do
      assert Chunker.chunk_field(:bogus, "text") == []
      assert Chunker.chunk_field("bogus", "text") == []
      assert Chunker.chunk_field("status", "open") == []
    end

    test "nil and non-binary text produce nothing" do
      assert Chunker.chunk_field(:notes, nil) == []
      assert Chunker.chunk_field(:notes, 42) == []
    end
  end
end
