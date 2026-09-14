defmodule OrcaHub.Issues.Search do
  @moduledoc """
  Search over issues — the read half of pgvector-backed issue indexing.

  Three entry points, all returning `{:ok, [result]} | {:error, reason}`:

    * `semantic_search/2` — embeds the query with `OrcaHub.Embeddings` and
      cosine-orders (`<=>`) the `issue_chunks` vectors written by the
      indexer. Finds an issue by a PARAPHRASE that shares no distinctive
      words with its text, which is the entire point of the feature.
    * `lexical_search/2` — Postgres full-text over the `issues.search_tsv`
      generated column (see the `AddIssuesFulltextSearch` migration).
      Exact/rare terms — an error string, a module name, an issue key —
      where embeddings are weakest.
    * `hybrid_search/2` — reciprocal-rank fusion of the two, and what the
      `search_issues` MCP tool calls.

  ## Degradation is a hard requirement, in both directions

  `hybrid_search/2` NEVER fails because one leg failed. The embedding
  endpoint lives on a single GPU box and `EMBEDDING_URL` is unset entirely
  in the test suite, so "the vector leg is unavailable" is a normal
  operating state, not an exception — hybrid silently returns lexical-only
  results in that case. The converse holds too: a full-text failure (a
  malformed `websearch_to_tsquery` input, a missing column on a not-yet-
  migrated database) degrades to vector-only rather than taking out a leg
  that was working. Only if BOTH legs fail does hybrid return `{:error,
  _}`.

  `:degraded` in each result set's metadata — see `hybrid_search/2`'s return
  — is what a caller surfaces when it wants to tell a user "these are
  keyword results only".

  ## Result shape

      %{
        issue: %OrcaHub.Issues.Issue{},   # with :project preloaded
        score: float(),                   # see below
        field: String.t() | nil,          # which issue field matched
        snippet: String.t() | nil,        # the matching text
        source: :semantic | :lexical | :both,
        semantic_score: float() | nil,    # cosine similarity, 0..1
        lexical_score: float() | nil      # ts_rank
      }

  `score` is the leg-native score for a single-leg search (cosine
  similarity for semantic, `ts_rank` for lexical) and the FUSED RRF score
  for `hybrid_search/2`. RRF scores are tiny by construction (`1/(60+rank)`
  per leg, so ~0.016 for a first-place hit and ~0.033 for first in both)
  and are meaningful only RELATIVE to each other within one result set —
  never compare one against a cosine threshold. `semantic_score`/
  `lexical_score` are preserved through fusion precisely so a caller that
  needs an absolute number (e.g. `similar_issues/2`'s threshold) has one.

  ## Options (all three entry points)

    * `:status` — `"open"` (default), any other status string, a LIST of
      statuses, or `"all"`. Matches `OrcaHub.Issues.list_issues/1`'s
      semantics, where the default is the exact string `"open"` and
      `"in_progress"` is therefore NOT included unless asked for.
    * `:kind` — `"task"`, `"feature_request"`, or `"all"` (default).
    * `:project_id` — scope to one project (omit for all projects).
    * `:created_by_session_id` — only issues filed by that session.
    * `:limit` — default #{10}.

  ## Why best-chunk-per-issue, and the oversample it costs

  An issue is chunked into many rows, so a naive vector query returns the
  same issue several times. This takes the BEST chunk per issue: the inner
  query pulls the top `limit * @oversample` chunks by distance and the
  per-issue reduction happens in Elixir. Doing it in SQL with `DISTINCT ON
  (issue_id)` would have to scan and sort every filtered chunk (no LIMIT
  can apply before the dedup), which gives up the HNSW index; oversampling
  keeps the index scan and is exact unless a single issue monopolizes more
  than `@oversample` of the top hits, which at this corpus size it does
  not. Raise `@oversample`, not the query shape, if that ever changes.
  """

  import Ecto.Query

  require Logger

  alias OrcaHub.Embeddings
  alias OrcaHub.Issues.{Chunker, Issue, IssueChunk}
  alias OrcaHub.Repo

  @default_limit 10
  @oversample 8
  @min_candidates 50

  # Reciprocal-rank-fusion constant. 60 is the value from the original RRF
  # paper and what /home/zach/memory-service's own fusion uses — matching it
  # keeps the two systems' relative scores comparable to a reader.
  @rrf_k 60

  # Default cosine-similarity floor for `similar_issues/2`. Calibrated on
  # the real 111-issue corpus (see the module's tests): genuine paraphrases
  # of the same issue land around 0.62-0.78 with qwen3-embedding-0.6b, while
  # merely same-topic-different-problem pairs sit below ~0.55. Set
  # deliberately on the conservative side — a missed dedup costs a duplicate
  # issue, a false one silently swallows a real report.
  @similar_threshold 0.62

  @type result :: %{
          issue: Issue.t() | struct(),
          score: float(),
          field: String.t() | nil,
          snippet: String.t() | nil,
          source: :semantic | :lexical | :both,
          semantic_score: float() | nil,
          lexical_score: float() | nil
        }

  @doc "The default cosine floor `similar_issues/2` applies."
  def similar_threshold, do: @similar_threshold

  @doc "The RRF constant `hybrid_search/2` fuses with."
  def rrf_k, do: @rrf_k

  # ── semantic ────────────────────────────────────────────────────────

  @doc """
  Vector search: embeds `query` and cosine-orders the stored chunk
  embeddings.

  `{:error, :disabled}` when `EMBEDDING_URL` is unset, `{:error, reason}`
  for any embedding failure (these are `OrcaHub.Embeddings`' own reasons —
  it never raises), and `{:ok, []}` for a blank query. Rows whose
  `embedding` is NULL are excluded: a NULL means "not embedded yet", not
  "no match".
  """
  @spec semantic_search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def semantic_search(query, opts \\ [])

  def semantic_search(query, opts) when is_binary(query) do
    if blank?(query) do
      {:ok, []}
    else
      case Embeddings.embed(query) do
        {:ok, vector} -> {:ok, semantic_by_vector(vector, opts)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def semantic_search(other, _opts), do: {:error, {:invalid_query, other}}

  @doc """
  `semantic_search/2` given an ALREADY-EMBEDDED query vector — for a caller
  that has one in hand (or is searching several times with it) and wants to
  skip the round trip to the embedding endpoint.
  """
  @spec semantic_by_vector([float()], keyword()) :: [result()]
  def semantic_by_vector(vector, opts \\ []) when is_list(vector) do
    limit = limit(opts)
    candidates = max(limit * @oversample, @min_candidates)

    IssueChunk
    |> join(:inner, [c], i in Issue, on: i.id == c.issue_id, as: :issue)
    |> where([c], not is_nil(c.embedding))
    |> apply_filters(opts)
    |> order_by([c], asc: fragment("? <=> ?", c.embedding, type(^vector, Pgvector.Ecto.Vector)))
    |> limit(^candidates)
    |> select([c, i], %{
      issue_id: c.issue_id,
      field: c.field,
      content: c.content,
      distance: fragment("? <=> ?", c.embedding, type(^vector, Pgvector.Ecto.Vector))
    })
    |> Repo.all()
    |> best_per_issue()
    |> Enum.sort_by(& &1.distance)
    |> Enum.take(limit)
    |> preload_issues()
    |> Enum.map(&semantic_result/1)
  end

  # ── lexical ─────────────────────────────────────────────────────────

  @doc """
  Full-text search over `issues.search_tsv` using `websearch_to_tsquery` —
  so an agent can pass quoted phrases and `-excluded` terms and have them
  mean what they do in a web search box, and a nonsense query degrades to
  zero results rather than a syntax error the way `to_tsquery` would.

  `{:ok, []}` for a blank query or one that parses to an empty tsquery
  (e.g. only stopwords). `{:error, reason}` if the query itself fails —
  notably `{:error, :not_migrated}` when `issues.search_tsv` doesn't exist
  yet, which is a legitimate transient state on a node that hasn't run
  migrations, and one `hybrid_search/2` deliberately survives.
  """
  @spec lexical_search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def lexical_search(query, opts \\ [])

  def lexical_search(query, opts) when is_binary(query) do
    if blank?(query) do
      {:ok, []}
    else
      run_lexical(query, opts)
    end
  end

  def lexical_search(other, _opts), do: {:error, {:invalid_query, other}}

  # `search_tsv` is referenced UNQUALIFIED inside the fragments below rather
  # than as `i.search_tsv`: it's a generated column that deliberately isn't in
  # the `Issue` schema (loading a tsvector into every struct is pure waste),
  # and Ecto rejects a field reference it can't find in the schema. The
  # lexical query has exactly one table in its FROM, so the bare name is
  # unambiguous. The cost is that a missing column is a runtime error rather
  # than a compile-time one — which is precisely the `:not_migrated` case
  # `postgrex_reason/1` names and `hybrid_search/2` survives.
  defp run_lexical(query, opts) do
    rows =
      from(i in Issue, as: :issue)
      |> where(
        [issue: _i],
        fragment("search_tsv @@ websearch_to_tsquery('english', ?)", ^query)
      )
      |> apply_filters(opts)
      |> order_by(
        [issue: i],
        desc: fragment("ts_rank(search_tsv, websearch_to_tsquery('english', ?))", ^query),
        desc: i.inserted_at
      )
      |> limit(^limit(opts))
      |> select([issue: i], %{
        issue: i,
        rank: fragment("ts_rank(search_tsv, websearch_to_tsquery('english', ?))", ^query),
        # Which field the hit landed in, in weight order. The repeated
        # to_tsvector calls here are evaluated on the result rows only, so at
        # this corpus size they cost nothing — and they're the difference
        # between a snippet an agent can place and one it can't.
        field:
          fragment(
            """
            CASE
              WHEN to_tsvector('english', coalesce(?, '')) @@ websearch_to_tsquery('english', ?) THEN 'title'
              WHEN to_tsvector('english', coalesce(?, '')) @@ websearch_to_tsquery('english', ?) THEN 'description'
              WHEN to_tsvector('english', coalesce(?, '')) @@ websearch_to_tsquery('english', ?) THEN 'premise'
              WHEN to_tsvector('english', coalesce(?, '')) @@ websearch_to_tsquery('english', ?) THEN 'resolution'
              WHEN to_tsvector('english', coalesce(?, '')) @@ websearch_to_tsquery('english', ?) THEN 'notes'
              ELSE NULL
            END
            """,
            i.title,
            ^query,
            i.description,
            ^query,
            i.premise,
            ^query,
            i.resolution,
            ^query,
            i.notes,
            ^query
          ),
        snippet:
          fragment(
            """
            ts_headline('english',
              concat_ws(E'\\n', ?, ?, ?, ?, ?),
              websearch_to_tsquery('english', ?),
              'MaxFragments=1, MaxWords=34, MinWords=12, StartSel=**, StopSel=**')
            """,
            i.title,
            i.description,
            i.premise,
            i.resolution,
            i.notes,
            ^query
          )
      })
      |> Repo.all()
      |> preload_row_issues()
      |> Enum.map(&lexical_result/1)

    {:ok, rows}
  rescue
    e in Postgrex.Error ->
      {:error, postgrex_reason(e)}

    e ->
      Logger.warning("Issues.Search lexical leg failed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # ── hybrid ──────────────────────────────────────────────────────────

  @doc """
  Reciprocal-rank fusion (k=#{@rrf_k}) of `semantic_search/2` and
  `lexical_search/2`.

  Returns `{:ok, results}`, or `{:ok, results, meta}`-style information via
  each result's `:source` field: `:both` for an issue found by both legs,
  `:semantic`/`:lexical` for one. An issue absent from a leg simply
  contributes no term for it, exactly as in
  `MemoryService.RRF.fuse/2`.

  Degradation (see the moduledoc): a failing leg is dropped with a log line
  and the surviving leg's ranking is returned unfused. `{:error, reason}`
  only when BOTH legs fail — and in that case the LEXICAL leg's reason is
  returned, since a semantic failure is usually the expected
  `:disabled`/endpoint-down and says less about what went wrong.
  """
  @spec hybrid_search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def hybrid_search(query, opts \\ [])

  def hybrid_search(query, opts) when is_binary(query) do
    if blank?(query) do
      {:ok, []}
    else
      semantic = leg(:semantic, fn -> semantic_search(query, oversampled(opts)) end)
      lexical = leg(:lexical, fn -> lexical_search(query, oversampled(opts)) end)

      case {semantic, lexical} do
        {{:error, _}, {:error, lexical_reason}} -> {:error, lexical_reason}
        {sem, lex} -> {:ok, fuse(ok(sem), ok(lex), limit(opts))}
      end
    end
  end

  def hybrid_search(other, _opts), do: {:error, {:invalid_query, other}}

  # Each leg is asked for more than the caller's limit: an issue ranked 12th
  # semantically and 3rd lexically should be able to surface, which it can't
  # if the semantic leg was truncated at 10.
  defp oversampled(opts), do: Keyword.put(opts, :limit, limit(opts) * 2)

  defp leg(name, fun) do
    case fun.() do
      {:ok, results} ->
        {:ok, results}

      {:error, reason} ->
        Logger.debug("Issues.Search #{name} leg unavailable: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Issues.Search #{name} leg raised: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp ok({:ok, results}), do: results
  defp ok({:error, _}), do: []

  defp fuse(semantic, lexical, limit) do
    scores =
      %{}
      |> accumulate_rrf(semantic)
      |> accumulate_rrf(lexical)

    by_id = Map.new(semantic ++ lexical, &{&1.issue.id, &1})

    semantic_ids = MapSet.new(semantic, & &1.issue.id)
    lexical_ids = MapSet.new(lexical, & &1.issue.id)
    semantic_by_id = Map.new(semantic, &{&1.issue.id, &1})
    lexical_by_id = Map.new(lexical, &{&1.issue.id, &1})

    scores
    # Ties broken by ascending id, matching MemoryService.RRF, so a result
    # set is deterministic rather than dependent on map ordering.
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
    |> Enum.take(limit)
    |> Enum.map(fn {id, score} ->
      base = Map.fetch!(by_id, id)
      semantic_hit = Map.get(semantic_by_id, id)
      lexical_hit = Map.get(lexical_by_id, id)

      # Prefer the semantic leg's snippet: it's the actual chunk that
      # matched, whereas the lexical one is a ts_headline of a concatenation.
      snippet_source = semantic_hit || lexical_hit

      %{
        issue: base.issue,
        score: score,
        field: snippet_source.field,
        snippet: snippet_source.snippet,
        source: source_of(id, semantic_ids, lexical_ids),
        semantic_score: semantic_hit && semantic_hit.semantic_score,
        lexical_score: lexical_hit && lexical_hit.lexical_score
      }
    end)
  end

  defp accumulate_rrf(acc, results) do
    results
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {result, rank}, acc ->
      Map.update(acc, result.issue.id, 1 / (@rrf_k + rank), &(&1 + 1 / (@rrf_k + rank)))
    end)
  end

  defp source_of(id, semantic_ids, lexical_ids) do
    cond do
      MapSet.member?(semantic_ids, id) and MapSet.member?(lexical_ids, id) -> :both
      MapSet.member?(semantic_ids, id) -> :semantic
      true -> :lexical
    end
  end

  # ── dedup ───────────────────────────────────────────────────────────

  @doc """
  Semantically nearest NON-TERMINAL issues to `text` — the dedup entry
  point, for "has someone already filed this?" at issue-creation time.

  Differs from `semantic_search/2` in three ways, all of them because the
  caller is about to make a create-or-not decision rather than show a list:

    * `:status` defaults to `["open", "in_progress"]`, not the exact string
      `"open"` — an in-progress issue is very much a duplicate.
    * results below `:threshold` (default `#{@similar_threshold}` cosine
      similarity) are dropped entirely, so an empty list genuinely means
      "nothing close enough", not "here's the least-bad match".
    * `:limit` defaults to 5.

  Returns `{:ok, results}` (possibly empty) or `{:error, reason}` — notably
  `{:error, :disabled}` when embeddings are off, which a caller must treat
  as "unknown", NOT as "no duplicate": falling back to a lexical heuristic
  is the right move there (see `OrcaHub.Issues.find_similar_open_issue/3`).

  Pass `:kind` and `:project_id` to scope it the way the caller's dedup
  rule actually works — this function deliberately does not assume them.
  """
  @spec similar_issues(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def similar_issues(text, opts \\ [])

  def similar_issues(text, opts) when is_binary(text) do
    threshold = Keyword.get(opts, :threshold, @similar_threshold)

    opts =
      opts
      |> Keyword.delete(:threshold)
      |> Keyword.put_new(:status, ["open", "in_progress"])
      |> Keyword.put_new(:limit, 5)

    case semantic_search(text, opts) do
      {:ok, results} -> {:ok, Enum.filter(results, &(&1.score >= threshold))}
      {:error, reason} -> {:error, reason}
    end
  end

  def similar_issues(other, _opts), do: {:error, {:invalid_query, other}}

  # ── shared ──────────────────────────────────────────────────────────

  # Both legs bind the issue as `:issue` — the chunk query as a join, the
  # lexical query as its own source — so ONE set of filter clauses serves
  # both rather than two near-identical sets that can drift apart.
  defp apply_filters(query, opts) do
    query
    |> filter_status(Keyword.get(opts, :status))
    |> filter_kind(Keyword.get(opts, :kind))
    |> filter_project(Keyword.get(opts, :project_id))
    |> filter_creator(Keyword.get(opts, :created_by_session_id))
  end

  defp filter_status(query, nil), do: filter_status(query, "open")
  defp filter_status(query, "all"), do: query

  defp filter_status(query, statuses) when is_list(statuses),
    do: where(query, [issue: i], i.status in ^statuses)

  defp filter_status(query, status) when is_binary(status),
    do: where(query, [issue: i], i.status == ^status)

  defp filter_kind(query, kind) when kind in [nil, "all"], do: query

  defp filter_kind(query, kind) when is_binary(kind),
    do: where(query, [issue: i], i.kind == ^kind)

  defp filter_project(query, nil), do: query

  defp filter_project(query, project_id),
    do: where(query, [issue: i], i.project_id == ^project_id)

  defp filter_creator(query, nil), do: query

  defp filter_creator(query, session_id),
    do: where(query, [issue: i], i.created_by_session_id == ^session_id)

  defp limit(opts), do: Keyword.get(opts, :limit) || @default_limit

  defp best_per_issue(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      Map.update(acc, row.issue_id, row, fn existing ->
        if row.distance < existing.distance, do: row, else: existing
      end)
    end)
    |> Map.values()
  end

  # `Repo.preload/2` takes structs, not the plain maps a custom `select`
  # returns — so preload the extracted issues (order-preserving) and put them
  # back rather than handing it the row maps.
  defp preload_row_issues([]), do: []

  defp preload_row_issues(rows) do
    issues = rows |> Enum.map(& &1.issue) |> Repo.preload(:project)

    rows
    |> Enum.zip(issues)
    |> Enum.map(fn {row, issue} -> %{row | issue: issue} end)
  end

  defp preload_issues([]), do: []

  defp preload_issues(rows) do
    ids = Enum.map(rows, & &1.issue_id)

    issues =
      Issue
      |> where([i], i.id in ^ids)
      |> preload(:project)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    rows
    |> Enum.filter(&Map.has_key?(issues, &1.issue_id))
    |> Enum.map(&Map.put(&1, :issue, Map.fetch!(issues, &1.issue_id)))
  end

  defp semantic_result(row) do
    # `<=>` is cosine DISTANCE; the score a caller reasons about (and
    # thresholds on) is similarity.
    similarity = 1.0 - row.distance

    %{
      issue: row.issue,
      score: similarity,
      field: row.field,
      snippet: Chunker.strip_label(row.field, row.content),
      source: :semantic,
      semantic_score: similarity,
      lexical_score: nil
    }
  end

  defp lexical_result(row) do
    %{
      issue: row.issue,
      score: row.rank,
      field: row.field,
      snippet: row.snippet,
      source: :lexical,
      semantic_score: nil,
      lexical_score: row.rank
    }
  end

  # A node that hasn't run the AddIssuesFulltextSearch migration yet is a
  # real transient state (and the reason hybrid tolerates a lexical
  # failure), so name it rather than surfacing a raw Postgres error.
  defp postgrex_reason(%Postgrex.Error{postgres: %{code: :undefined_column}}), do: :not_migrated
  defp postgrex_reason(%Postgrex.Error{postgres: %{code: code}}), do: {:postgres_error, code}
  defp postgrex_reason(e), do: {:postgres_error, Exception.message(e)}

  defp blank?(text), do: String.trim(text) == ""
end
