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

  ## What fusion actually buys, measured (112 real prod issues, 2026-09-14)

  Recorded because the answer is not the obvious one, and because the next
  person to touch `fuse/3` should know what the legs really look like rather
  than assuming two comparable retrievers.

  The two legs are good at DISJOINT things, and each is near-useless at the
  other's job:

    * Natural-language paraphrase (8 queries worded to share no distinctive
      terms with their target): semantic put the right issue at #1 six
      times, cosine 0.59-0.76. The lexical leg returned **zero rows for all
      eight** — `websearch_to_tsquery` ANDs bare terms, so a sentence
      matches nothing.
    * Rare exact identifiers (10 queries: `OOMKill`, `NodeArg.resolve`,
      `gemma-4-26B-A4B`, …): lexical put the right issue at #1 ten times out
      of ten, while semantic MISSED TWO ENTIRELY (not in its top 10) and
      ranked three others below lexical (#2, #2, #7).

  So "hybrid beats either leg alone" holds across the query MIX, not on any
  single query: hybrid was #1 on 9/10 exact-term queries that would have
  been 2 outright misses under semantic-only, and #1 on the paraphrases that
  lexical could not answer at all. It routes to whichever leg the caller's
  phrasing suits without the caller having to know which regime they're in.

  What fusion did NOT do is improve on the better leg. Across 28 queries RRF
  never ranked a target ABOVE the best single leg, and in 4 it cost one or
  two ranks (#1 -> #2 twice, #1 -> #3 once). The mechanism is not a bug:
  an issue found by BOTH legs scores ~0.0325 and legitimately outranks a
  semantic-only #1 at ~0.0164, so one topical keyword coincidence can
  displace a strong vector match. RRF assumes two comparably-recalled
  rankings and these are not that. It is kept anyway — the ranks lost are
  small and stay on page one, while the misses it prevents are total — but
  if this is ever revisited, weighting the legs is the knob, and it should
  be re-measured, not reasoned about.

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

  # Default cosine-similarity floor for `similar_issues/2`, CALIBRATED
  # against the real 112-issue prod corpus rather than guessed — the first
  # guess here was 0.62, which measurement showed would have been a disaster.
  #
  # Method: embed every issue's title, find its nearest OTHER issue, and look
  # at the distribution. With qwen3-embedding-0.6b these issues are all
  # written in the same register about the same system, so they sit close
  # together in general: the MEDIAN issue's nearest neighbour scores 0.72,
  # p90 is 0.81. Nearness is therefore weak evidence of duplication.
  #
  #   the one genuine duplicate pair in the corpus     0.974
  #     ("get_session_tail truncates last_assistant_text" filed twice)
  #   related-but-distinct pairs                       0.80 - 0.83
  #     (churn detector false-POSITIVE vs false-NEGATIVE; file-tree inline
  #      previews vs per-file download — same area, different asks)
  #   median issue's nearest neighbour                 0.72
  #
  # Share of the corpus a threshold would flag as "already filed":
  # 0.62 -> 88%, 0.70 -> 62%, 0.80 -> 12%, 0.85 -> 1.8%. Only the true
  # duplicate pair clears 0.85, so that is the floor: at this altitude a hit
  # is real evidence, and the asymmetry demands it — a missed dedup costs one
  # duplicate issue someone can merge later, while a FALSE dedup silently
  # swallows a real report and returns an unrelated issue in its place.
  @similar_threshold 0.85

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

  ## `:relax` — any-term matching as a last resort

  `websearch_to_tsquery` ANDs bare terms, exactly like a web search box, so
  a SENTENCE-length query ("a timer I set to remind myself later silently
  did nothing") requires all nine stems to appear in one issue and reliably
  matches nothing. That's correct behaviour — and irrelevant while the
  semantic leg is up, since a sentence is what the vector leg is FOR.

  With `relax: true`, a strict pass that returns zero rows is retried with
  the same terms ORed. Measured against the real corpus, those results are
  noticeably noisier (a hit on a common word like "agent" can top the
  list), which is why `hybrid_search/2` turns this on ONLY when the
  semantic leg failed: fusing noise in alongside good vector results makes
  the ranking worse, but noise beats returning nothing at all when
  keywords are the only tool left.

  Relaxation is SKIPPED for a query containing a quoted phrase or a
  `-exclusion` — rewriting `a & !b` to `a | !b` inverts what the caller
  asked for, which is worse than an empty result.
  """
  @spec lexical_search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def lexical_search(query, opts \\ [])

  def lexical_search(query, opts) when is_binary(query) do
    cond do
      blank?(query) ->
        {:ok, []}

      Keyword.get(opts, :relax, false) ->
        case run_lexical(query, opts) do
          {:ok, []} -> if relaxable?(query), do: run_lexical(query, opts, :any), else: {:ok, []}
          other -> other
        end

      true ->
        run_lexical(query, opts)
    end
  end

  def lexical_search(other, _opts), do: {:error, {:invalid_query, other}}

  defp relaxable?(query) do
    not String.contains?(query, "\"") and not Regex.match?(~r/(^|\s)-\S/, query)
  end

  # `search_tsv` is referenced UNQUALIFIED inside the fragments below rather
  # than as `i.search_tsv`: it's a generated column that deliberately isn't in
  # the `Issue` schema (loading a tsvector into every struct is pure waste),
  # and Ecto rejects a field reference it can't find in the schema. The
  # lexical query has exactly one table in its FROM, so the bare name is
  # unambiguous. The cost is that a missing column is a runtime error rather
  # than a compile-time one — which is precisely the `:not_migrated` case
  # `postgrex_reason/1` names and `hybrid_search/2` survives.
  defp run_lexical(query, opts, mode \\ :all) do
    case tsquery_text(query, mode) do
      "" -> {:ok, []}
      tsquery -> {:ok, lexical_rows(tsquery, opts)}
    end
  rescue
    e in Postgrex.Error ->
      {:error, postgrex_reason(e)}

    e ->
      Logger.warning("Issues.Search lexical leg failed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  # The parsed tsquery is resolved in its own (trivial) round trip rather
  # than inlined as `websearch_to_tsquery(...)` in five places, for three
  # reasons: the `:any` rewrite below needs the parsed text anyway, a query
  # that parses to NOTHING (only stopwords) is answered without touching the
  # issues table at all, and the main query then has ONE shape instead of
  # one per mode.
  defp tsquery_text(query, mode) do
    %{rows: [[text]]} =
      Repo.query!("SELECT websearch_to_tsquery('english', $1)::text", [query])

    text = text || ""

    case mode do
      :all -> text
      # 'a' & 'b' -> 'a' | 'b'. Only reached via relaxable?/1, so there is no
      # `!` or `<->` in here whose meaning the rewrite could invert.
      :any -> String.replace(text, " & ", " | ")
    end
  end

  defp lexical_rows(tsquery, opts) do
    from(i in Issue, as: :issue)
    |> where([issue: _i], fragment("search_tsv @@ ?::text::tsquery", ^tsquery))
    |> apply_filters(opts)
    |> order_by(
      [issue: i],
      desc: fragment("ts_rank(search_tsv, ?::text::tsquery)", ^tsquery),
      desc: i.inserted_at
    )
    |> limit(^limit(opts))
    |> select([issue: i], %{
      issue: i,
      rank: fragment("ts_rank(search_tsv, ?::text::tsquery)", ^tsquery),
      # Which field the hit landed in, in weight order. The repeated
      # to_tsvector calls here are evaluated on the result rows only, so at
      # this corpus size they cost nothing — and they're the difference
      # between a snippet an agent can place and one it can't.
      field:
        fragment(
          """
          CASE
            WHEN to_tsvector('english', coalesce(?, '')) @@ ?::text::tsquery THEN 'title'
            WHEN to_tsvector('english', coalesce(?, '')) @@ ?::text::tsquery THEN 'description'
            WHEN to_tsvector('english', coalesce(?, '')) @@ ?::text::tsquery THEN 'premise'
            WHEN to_tsvector('english', coalesce(?, '')) @@ ?::text::tsquery THEN 'resolution'
            WHEN to_tsvector('english', coalesce(?, '')) @@ ?::text::tsquery THEN 'notes'
            ELSE NULL
          END
          """,
          i.title,
          ^tsquery,
          i.description,
          ^tsquery,
          i.premise,
          ^tsquery,
          i.resolution,
          ^tsquery,
          i.notes,
          ^tsquery
        ),
      snippet:
        fragment(
          """
          ts_headline('english',
            concat_ws(E'\\n', ?, ?, ?, ?, ?),
            ?::text::tsquery,
            'MaxFragments=1, MaxWords=34, MinWords=12, StartSel=**, StopSel=**')
          """,
          i.title,
          i.description,
          i.premise,
          i.resolution,
          i.notes,
          ^tsquery
        )
    })
    |> Repo.all()
    |> preload_row_issues()
    |> Enum.map(&lexical_result/1)
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
  def hybrid_search(query, opts \\ []) do
    case hybrid_search_meta(query, opts) do
      {:ok, results, _meta} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `hybrid_search/2` plus which legs actually ran:

      {:ok, results, %{semantic: :ok | {:error, term}, lexical: :ok | {:error, term},
                       degraded: boolean}}

  A caller that SHOWS results to someone needs this — "no semantic hits" and
  "the semantic leg never ran" are indistinguishable from the result list
  alone, and only one of them means "try again later". `degraded: true`
  whenever either leg failed.
  """
  @spec hybrid_search_meta(String.t(), keyword()) :: {:ok, [result()], map()} | {:error, term()}
  def hybrid_search_meta(query, opts \\ [])

  def hybrid_search_meta(query, opts) when is_binary(query) do
    if blank?(query) do
      {:ok, [], %{semantic: :ok, lexical: :ok, degraded: false}}
    else
      semantic = leg(:semantic, fn -> semantic_search(query, oversampled(opts)) end)
      lexical = leg(:lexical, fn -> lexical_search(query, oversampled(opts)) end)
      {lexical, relaxed?} = maybe_relax(query, opts, semantic, lexical)

      case {semantic, lexical} do
        {{:error, _}, {:error, lexical_reason}} ->
          {:error, lexical_reason}

        {sem, lex} ->
          meta = %{
            semantic: leg_status(sem),
            lexical: if(relaxed?, do: :relaxed, else: leg_status(lex)),
            degraded: match?({:error, _}, sem) or match?({:error, _}, lex)
          }

          {:ok, fuse(ok(sem), ok(lex), limit(opts)), meta}
      end
    end
  end

  def hybrid_search_meta(other, _opts), do: {:error, {:invalid_query, other}}

  # Any-term matching is a LAST resort, not a general widening: it only runs
  # when the vector leg is gone AND strict keyword matching found nothing, so
  # its measurable noise never dilutes a healthy fusion. See
  # `lexical_search/2`'s `:relax` section.
  defp maybe_relax(query, opts, {:error, _semantic}, {:ok, []}) do
    case leg(:lexical, fn ->
           lexical_search(query, opts |> oversampled() |> Keyword.put(:relax, true))
         end) do
      {:ok, []} -> {{:ok, []}, false}
      {:ok, rows} -> {{:ok, rows}, true}
      {:error, _} = error -> {error, false}
    end
  end

  defp maybe_relax(_query, _opts, _semantic, lexical), do: {lexical, false}

  defp leg_status({:ok, _}), do: :ok
  defp leg_status({:error, reason}), do: {:error, reason}

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

    semantic_ranks = rank_index(semantic)
    lexical_ranks = rank_index(lexical)

    scores
    # RRF ties are COMMON and not a corner case: a semantic-only hit and a
    # lexical-only hit that are each rank 1 in their own leg score exactly
    # 1/61. MemoryService.RRF breaks that by ascending id, which here is a
    # random UUID — and measured on the real corpus that arbitrarily demoted
    # two correct #1 answers to #2 behind an irrelevant keyword hit. So the
    # tiebreak is: better semantic rank first, then better lexical rank, then
    # id for determinism. Preferring the semantic leg on a tie is the
    # measured-better default for natural-language queries, and it barely
    # bites elsewhere: when a rare exact term matches lexically it is almost
    # always IN the issue's text too, so that issue is a both-leg hit with a
    # strictly higher score and never reaches this comparison.
    |> Enum.sort_by(fn {id, score} ->
      {-score, Map.get(semantic_ranks, id, :infinity), Map.get(lexical_ranks, id, :infinity), id}
    end)
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

  # issue_id => 1-based rank within one leg. Absent means "this leg didn't
  # find it", which the tiebreak reads as `:infinity` — and Erlang's term
  # order puts every integer before every atom, so that comparison works
  # without a sentinel number.
  defp rank_index(results) do
    results
    |> Enum.with_index(1)
    |> Map.new(fn {result, rank} -> {result.issue.id, rank} end)
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
