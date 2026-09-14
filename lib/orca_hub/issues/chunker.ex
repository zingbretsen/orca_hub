defmodule OrcaHub.Issues.Chunker do
  @moduledoc """
  Splits an issue's prose fields into embeddable chunks. Pure — no I/O, no
  DB, no HTTP — so it is cheap to test exhaustively and safe to call from
  anywhere.

  `chunk/1` returns an ordered list of `%{field:, chunk_index:, content:}`,
  one entry per chunk, `chunk_index` restarting at 0 **per field** (identity
  in `issue_chunks` is `(issue_id, field, chunk_index)`).

  ## Token budget math

  The embedding server (`OrcaHub.Embeddings`) has `n_ctx` **8192 tokens**,
  enforced PER INPUT, and an over-length input is a hard HTTP 400
  (`exceed_context_size_error`) — not a silent truncation. So a chunk that
  is too big doesn't degrade, it fails. Everything below is sized against
  the *pessimistic* chars-per-token ratio, measured live on this model:

  | text shape                       | chars/token |
  |----------------------------------|-------------|
  | repetitive latin prose           | ~6.4        |
  | dense code / identifier-heavy    | ~1.85       |

  Taking **1.85 chars/token** as the floor, 8192 tokens is only ~15,155
  characters. Against that:

  - `@target_chars` (1,500) -> <= ~810 tokens, ~10% of the budget.
  - `@single_chunk_max_chars` (6,000) -> <= ~3,240 tokens, ~40% of the
    budget. This is the ceiling above which even a "single chunk" field
    (see below) gets split anyway.
  - the field label prefix adds at most ~20 characters.

  The margin is deliberately large: issue text routinely contains code
  blocks, stack traces and git hashes, which sit at the bad end of that
  ratio, and the cost of being wrong is a failed embedding rather than a
  slightly worse one. For reference, the largest real field in the corpus
  is a 35,092-char `notes` blob — ~19,000 tokens, i.e. over budget on its
  own by more than 2x, which is why splitting is not optional.

  ## Which fields, and how they split

  Every non-empty field of `OrcaHub.Issues.IssueChunk.indexable_fields/0`
  is chunked, in the order listed by `field_order/0`.

  - `title`, `premise`, `plan` are emitted as ONE chunk. They're short by
    nature (corpus max 206 / 2,387 / 4,411 chars) and splitting them would
    just shred a single coherent thought. They still fall back to splitting
    past `@single_chunk_max_chars`, so a pathologically long `plan` can't
    blow the context limit.
  - `description`, `resolution`, `notes`, `approaches_tried` split. `notes`
    is a single append-only blob separated by blank lines (see
    `OrcaHub.Issues.append_note/2`, into which `update_issue/3` also
    auto-appends provenance notes), so a blank line is the natural note
    boundary and is preferred over every other break. `approaches_tried`
    is unused in the corpus today but is append-only prose of the same
    shape, so it splits rather than being trusted to stay short.

  Break preference within a window, best first: a blank line (`\\n\\n`), a
  newline, then any whitespace — so a chunk never ends mid-word. The one
  exception is a window containing no usable break at all (a 1,500-char
  base64 blob, a minified payload): that is hard-split at
  `@target_chars`, backed off to a UTF-8 codepoint boundary so the result
  is always valid text. A break is only accepted at or past
  `@min_chunk_chars`, so preferring a boundary never produces a runt chunk.

  Consecutive chunks overlap by about `@overlap_chars` characters, advanced
  forward to a whitespace boundary so an overlap never *starts* mid-word
  either. Overlap exists so a sentence straddling a boundary is still
  retrievable from at least one chunk.

  Whitespace-only chunks are dropped before indexing, so `chunk_index`
  stays contiguous.

  ## The field label, and recovering the raw text

  Each chunk's `content` is prefixed with a short field label — `"notes:
  "`, `"resolution: "` — so the embedded text carries its own context and a
  search hit reads sensibly on its own without a join back to the issue.
  The prefix is a fixed, per-field string, so the raw slice is always
  recoverable: `strip_label/2` (or `label/1`) undoes it exactly.
  """

  alias OrcaHub.Issues.IssueChunk

  @target_chars 1500
  @overlap_chars 150
  @min_chunk_chars 750
  @single_chunk_max_chars 6000

  # Read order, not storage order — a search result set reads better with
  # the framing fields (title/description/premise/plan) ahead of the
  # outcome and the append-only logs.
  @field_order [
    :title,
    :description,
    :premise,
    :plan,
    :resolution,
    :approaches_tried,
    :notes
  ]

  # Short, coherent fields that are emitted whole rather than split — see
  # the moduledoc. They still split past @single_chunk_max_chars.
  @single_chunk_fields [:title, :premise, :plan]

  @type chunk :: %{field: String.t(), chunk_index: non_neg_integer(), content: String.t()}

  @doc "The fields this module chunks, in the order `chunk/1` emits them."
  @spec field_order() :: [atom()]
  def field_order, do: @field_order

  @doc "Target characters per chunk for the splitting fields."
  def target_chars, do: @target_chars

  @doc "Approximate overlap, in characters, between consecutive chunks."
  def overlap_chars, do: @overlap_chars

  @doc """
  The hard ceiling above which even a `@single_chunk_fields` field is split
  anyway.
  """
  def single_chunk_max_chars, do: @single_chunk_max_chars

  @doc """
  Chunks an issue (an `%OrcaHub.Issues.Issue{}`, or any map carrying the
  same atom keys) into an ordered list of
  `%{field:, chunk_index:, content:}`.

  Fields that are nil, missing, or whitespace-only produce no chunks at all
  — so an issue with only a title yields exactly one chunk, and this never
  returns a chunk whose content is blank.
  """
  @spec chunk(map()) :: [chunk()]
  def chunk(issue) when is_map(issue) do
    Enum.flat_map(@field_order, fn field -> chunk_field(field, Map.get(issue, field)) end)
  end

  @doc """
  Chunks ONE field's text. Same shape as `chunk/1`, useful for reindexing a
  single field without rebuilding the whole issue's chunk set.
  """
  @spec chunk_field(atom() | String.t(), String.t() | nil) :: [chunk()]
  def chunk_field(field, text)

  def chunk_field(field, text) when is_binary(field), do: chunk_field(to_atom(field), text)

  def chunk_field(field, text) when is_atom(field) and is_binary(text) do
    if field in @field_order and String.trim(text) != "" do
      text
      |> split(field)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.with_index()
      |> Enum.map(fn {slice, index} ->
        %{field: Atom.to_string(field), chunk_index: index, content: label(field) <> slice}
      end)
    else
      []
    end
  end

  def chunk_field(_field, _text), do: []

  @doc ~S|The label prefixed onto a field's chunk content, e.g. `"notes: "`.|
  @spec label(atom() | String.t()) :: String.t()
  def label(field) when is_atom(field), do: Atom.to_string(field) <> ": "
  def label(field) when is_binary(field), do: field <> ": "

  @doc """
  Recovers the raw slice from a chunk's labelled `content` — the inverse of
  the prefix `chunk/1` adds. Returns `content` unchanged if the expected
  label isn't there, so it's safe to call on already-stripped text.
  """
  @spec strip_label(atom() | String.t(), String.t()) :: String.t()
  def strip_label(field, content) when is_binary(content) do
    prefix = label(field)

    case content do
      <<^prefix::binary, rest::binary>> -> rest
      other -> other
    end
  end

  @doc "`strip_label/2` taking a chunk map produced by `chunk/1`."
  @spec strip_label(chunk()) :: String.t()
  def strip_label(%{field: field, content: content}), do: strip_label(field, content)

  # ── splitting ──────────────────────────────────────────────────────────

  defp split(text, field) do
    if field in @single_chunk_fields and byte_size(text) <= @single_chunk_max_chars do
      [text]
    else
      do_split(text, 0, byte_size(text), [])
    end
  end

  defp do_split(_text, pos, total, acc) when pos >= total, do: Enum.reverse(acc)

  defp do_split(text, pos, total, acc) do
    remaining = total - pos

    if remaining <= @target_chars do
      Enum.reverse([binary_part(text, pos, remaining) | acc])
    else
      window = binary_part(text, pos, @target_chars)
      break = break_point(text, pos, window)
      slice = binary_part(window, 0, break)
      do_split(text, next_start(text, total, pos, break), total, [slice | acc])
    end
  end

  # Best break inside `window`, as a byte offset. Preference order is blank
  # line -> newline -> any whitespace, each only accepted at or past
  # @min_chunk_chars so honouring a boundary can't produce a runt chunk.
  #
  # Byte offsets are safe for all three: "\n", " " and "\t" are ASCII, and
  # an ASCII byte never occurs inside a UTF-8 multi-byte sequence. Only the
  # no-break-found fallback can land mid-codepoint, so that one is backed
  # off explicitly.
  defp break_point(text, pos, window) do
    last_match(window, ["\n\n"]) ||
      last_match(window, ["\n"]) ||
      last_match(window, [" ", "\t"]) ||
      codepoint_boundary_at_or_before(text, pos, byte_size(window))
  end

  defp last_match(window, patterns) do
    window
    |> :binary.matches(patterns)
    |> Enum.reduce(nil, fn {start, len}, best ->
      if start + len >= @min_chunk_chars, do: start + len, else: best
    end)
  end

  # Start of the next chunk: back up @overlap_chars from this chunk's end,
  # then advance to just past the next whitespace so the overlap doesn't
  # begin mid-word. Always strictly ahead of `pos` — `break` is at least
  # @min_chunk_chars (750), comfortably more than @overlap_chars (150), so
  # forward progress is guaranteed and this can't loop.
  defp next_start(text, total, pos, break) do
    candidate = max(pos + break - @overlap_chars, pos + 1)

    case advance_to_word_start(text, total, candidate, pos + break) do
      nil -> codepoint_boundary_at_or_before(text, 0, candidate)
      adjusted -> adjusted
    end
  end

  defp advance_to_word_start(text, total, from, limit) do
    search_len = min(limit, total) - from

    if search_len <= 0 do
      nil
    else
      case :binary.match(binary_part(text, from, search_len), [" ", "\n", "\t"]) do
        {start, len} -> from + start + len
        :nomatch -> nil
      end
    end
  end

  # Walks back off a UTF-8 continuation byte (0b10xxxxxx). Only reachable
  # from the no-usable-break fallbacks above.
  defp codepoint_boundary_at_or_before(_text, _base, offset) when offset <= 0, do: offset

  defp codepoint_boundary_at_or_before(text, base, offset) do
    case :binary.at(text, base + offset) do
      byte when byte in 0x80..0xBF -> codepoint_boundary_at_or_before(text, base, offset - 1)
      _ -> offset
    end
  rescue
    ArgumentError -> offset
  end

  defp to_atom(field) do
    if field in IssueChunk.indexable_fields(), do: String.to_existing_atom(field), else: nil
  end
end
