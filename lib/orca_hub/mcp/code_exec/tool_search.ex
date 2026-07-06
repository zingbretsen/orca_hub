defmodule OrcaHub.MCP.CodeExec.ToolSearch do
  @moduledoc """
  Ranked keyword search (BM25) over a tool list, shared by the `search_tools`
  meta-tool (`MetaTools`) and the generated `Tools.search/1` (`ToolGen`).

  Ported from a sibling project's code-exec design (`phx-app`,
  `code-exec-tools` branch) which replaced tokenized-substring matching with
  this — substring matching required every query token to appear literally,
  so multi-word queries like "todo project" returned nothing unless every
  word matched somewhere, and there was no ranking among matches.

  Pure Elixir, no deps, no index: the corpus is whatever tool list is passed
  in per call (~150 docs at our scale), so IDF is computed fresh each time.
  A document is a tool's name tokens (counted TWICE — a cheap name-field
  boost) plus its description tokens. Tokenization downcases and splits on
  non-alphanumerics, which also splits snake_case tool names into words.

  Two deliberate deviations from textbook BM25:

    * **Positive IDF** — `log(1 + (n - df + 0.5) / (df + 0.5))` instead of
      the plain `log((n - df + 0.5) / (df + 0.5))`. Plain IDF goes negative
      once a token appears in more than half the corpus, which really
      happens here with common tokens like "list"/"get" in a ~150-tool
      corpus.
    * **Relative cutoff** — results are kept only if they score
      `>= 0.3 * top_score` (capped at 25), not by an absolute threshold. Raw
      BM25 scores aren't comparable across queries, so an absolute cutoff
      would be meaningless.

  Every result is guaranteed to share at least one token with the query.
  Known accepted caveat: no stemming ("todos" won't match "todo").
  """

  @k1 1.2
  @b 0.75
  @relative_cutoff 0.3
  @max_results 25

  @doc """
  Ranks `tools` (maps with at least `:name` and `:description`) against
  `query`. Returns the matching tools in score order (best first), or `[]`
  if nothing shares a token with the query.
  """
  def search(tools, query) when is_list(tools) and is_binary(query) do
    query_tokens = query |> tokenize() |> Enum.uniq()

    if query_tokens == [] do
      []
    else
      docs =
        Enum.map(tools, fn tool ->
          tokens = doc_tokens(tool)
          {tool, Enum.frequencies(tokens), length(tokens)}
        end)

      doc_count = length(docs)
      avg_length = average_doc_length(docs)

      doc_frequencies =
        Map.new(query_tokens, fn token ->
          {token, Enum.count(docs, fn {_tool, freqs, _len} -> Map.has_key?(freqs, token) end)}
        end)

      docs
      |> Enum.map(fn {tool, freqs, doc_length} ->
        {tool, score(query_tokens, freqs, doc_length, doc_frequencies, doc_count, avg_length)}
      end)
      |> Enum.filter(fn {_tool, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_tool, score} -> -score end)
      |> apply_relative_cutoff()
      |> Enum.take(@max_results)
      |> Enum.map(fn {tool, _score} -> tool end)
    end
  end

  @doc "Downcases and splits on non-alphanumerics (so snake_case names split too)."
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # --- Internals ---

  defp doc_tokens(%{name: name, description: description}) do
    name_tokens = tokenize(name)
    name_tokens ++ name_tokens ++ tokenize(description || "")
  end

  defp average_doc_length([]), do: 1.0

  defp average_doc_length(docs) do
    total = docs |> Enum.map(fn {_tool, _freqs, len} -> len end) |> Enum.sum()
    max(total / length(docs), 1.0)
  end

  defp score(query_tokens, freqs, doc_length, doc_frequencies, doc_count, avg_length) do
    Enum.reduce(query_tokens, 0.0, fn token, acc ->
      case Map.get(freqs, token, 0) do
        0 ->
          acc

        tf ->
          idf = idf(Map.fetch!(doc_frequencies, token), doc_count)

          acc +
            idf * (tf * (@k1 + 1)) /
              (tf + @k1 * (1 - @b + @b * doc_length / avg_length))
      end
    end)
  end

  # The +1 inside the log keeps IDF positive even for tokens present in most
  # documents (plain BM25 IDF can go negative past df > n/2).
  defp idf(df, n) do
    :math.log(1 + (n - df + 0.5) / (df + 0.5))
  end

  defp apply_relative_cutoff([]), do: []

  defp apply_relative_cutoff([{_tool, top_score} | _] = scored) do
    Enum.filter(scored, fn {_tool, score} -> score >= @relative_cutoff * top_score end)
  end
end
