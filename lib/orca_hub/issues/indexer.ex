defmodule OrcaHub.Issues.Indexer do
  @moduledoc """
  Writes the pgvector index for one issue: chunk its prose
  (`OrcaHub.Issues.Chunker`), embed what actually changed
  (`OrcaHub.Embeddings`), upsert `issue_chunks`, delete rows the issue no
  longer produces, and stamp `issues.indexed_at`.

  `reindex_issue/1` is the only entry point that matters. It is idempotent
  (running it twice in a row embeds nothing the second time) and it **never
  raises** — every failure, including a DB exit or an unreachable embedding
  endpoint, comes back as `{:error, reason}`.

  ## Incremental by content hash

  Identity of a chunk is `(issue_id, field, chunk_index)`. For each chunk
  `Chunker` produces, the stored row's `content_hash` is compared against
  the fresh one and the chunk is re-embedded only when it is genuinely new
  work:

    * no row exists for that key yet,
    * the hash differs (the text changed),
    * the row has a NULL `embedding` (a previous pass wrote a row but the
      vector never landed — not a state this module creates, but one a
      manual fix or an older slice could leave behind), or
    * the row's `embedding_model` is not the currently configured
      `Embeddings.model/0` — a model swap invalidates every stored vector,
      since cosine distance between two different models' outputs is
      meaningless.

  Everything else is left completely untouched, `embedded_at` included —
  which is the observable property worth relying on: appending a note
  re-embeds the `notes` chunks it changed and nothing else.

  Keys that exist in the table but are no longer produced are DELETED in
  the same pass. A shrinking field (a `notes` blob edited down from three
  chunks to one) otherwise leaves `chunk_index: 1,2` behind forever as
  orphans that still match searches for text the issue no longer contains.

  ## Failure isolation, and why a chunk row always has a vector

  Indexing is strictly a side effect of an issue write and must never fail,
  slow, or roll back one. So: embedding happens BEFORE any DB write, with
  no transaction open, and if `Embeddings.embed_many/1` fails for any
  reason the whole pass aborts having written nothing at all — the previous
  index stays intact and usable rather than being half-demolished.

  A deliberate consequence: **this module never persists a chunk row with a
  NULL `embedding`.** `OrcaHub.Issues.IssueChunk` permits one, and the
  opposite choice (write the chunk rows, embed later) is defensible, but a
  vectorless row is invisible to search anyway — so it buys no retrieval
  and costs real write churn on every node where `EMBEDDING_URL` is unset,
  including the entire test suite. Since `indexed_at` is left unset on any
  failure, the reconciliation sweep
  (`OrcaHub.Issues.IndexSweep`) retries either way; nothing is lost by
  waiting for a working embedder. Search should still filter
  `not is_nil(embedding)` as the schema's moduledoc says — this module
  being the only writer today is not a reason for the query to assume it.

  ## The `indexed_at` watermark

  Stamped ONLY on a fully successful pass, and stamped with
  `Repo.update_all` rather than a changeset, for two reasons:

    * a changeset update would bump `updated_at` too, so `updated_at >
      indexed_at` would be true again immediately and the sweep would
      reindex the same issue on every tick, forever — the unbounded
      retry-amplification shape the sweep exists to avoid;
    * `Issues`' write hooks fire off a reindex after a successful
      `update_issue/2`, so stamping through that path would recurse.

  The stamp is guarded on the `updated_at` we observed when we read the
  issue (optimistic concurrency). If the issue was written again while we
  were embedding, the guard matches no rows and `indexed_at` stays behind —
  the chunks we wrote are still correct for the text we read, but the
  watermark honestly reports "not caught up", so the sweep picks it up.
  That is reported as `stale_write: true` in the stats rather than as an
  error.

  That guard only fires for a concurrent write in a LATER second, since
  `updated_at` is second-precision; the same-second case is covered instead
  by `stale_issue_ids/1` comparing `>=` rather than `>` — see the comment
  on `stale_query/0`, which is where the actual no-missed-writes guarantee
  lives.
  """

  import Ecto.Query
  require Logger

  alias OrcaHub.{Embeddings, Repo}
  alias OrcaHub.Issues.{Chunker, Issue, IssueChunk}

  @type stats :: %{
          issue_id: String.t(),
          chunks: non_neg_integer(),
          embedded: non_neg_integer(),
          unchanged: non_neg_integer(),
          deleted: non_neg_integer(),
          indexed_at: DateTime.t() | nil,
          stale_write: boolean()
        }

  @doc """
  Reindexes one issue, given an `%Issue{}` or an issue id.

  Returns `{:ok, stats}` (see `t:stats/0`) or `{:error, reason}`. Common
  reasons: `:disabled` (no `EMBEDDING_URL` — nothing is read or written),
  `:issue_not_found`, or any `OrcaHub.Embeddings` error verbatim
  (`{:http_error, 400, _}` for a chunk over the server's context limit,
  `{:request_failed, _}` for an unreachable endpoint, …).

  Never raises: a DB error or an unexpected exception is logged and
  returned as `{:error, {:exception, message}}` / `{:error, {:exit,
  reason}}`.
  """
  @spec reindex_issue(map() | String.t()) :: {:ok, stats()} | {:error, term()}
  def reindex_issue(issue_or_id) do
    with {:ok, issue} <- resolve_issue(issue_or_id),
         :ok <- check_enabled() do
      do_reindex(issue)
    end
  rescue
    e ->
      Logger.error(
        "Issue indexer: reindex failed - #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.error("Issue indexer: reindex exited - #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  @doc """
  Whether indexing can do anything at all right now — i.e. whether
  `OrcaHub.Embeddings` is configured. Callers that want to skip work
  entirely (the write hooks in `OrcaHub.Issues`, the sweep) check this
  first so a node with no embedder configured pays nothing.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Embeddings.enabled?()

  @doc """
  Fire-and-forget reindex of one issue — what `OrcaHub.Issues`' write hooks
  call after a successful write. Always returns `:ok`; the caller's write
  has already succeeded and must never be affected by what happens here.

  `mode/0` decides how:

    * `:off` — return immediately, spawning nothing. This is the case
      whenever `OrcaHub.Embeddings` is unconfigured (the whole test suite,
      and any node without `EMBEDDING_URL`), so an issue write on such a
      node costs one `Application.get_env` and nothing else.
    * `:async` (the default when enabled) — runs under
      `OrcaHub.TaskSupervisor`, unlinked from the caller, so an embedder
      that hangs for its full 60s timeout delays nothing an interactive
      write is waiting on and a crash there cannot propagate.
    * `:sync` — runs inline. For tests that want a deterministic write ->
      index sequence without chasing a Task; set
      `config :orca_hub, :issue_indexing, :sync`.
  """
  @spec reindex_async(map()) :: :ok
  def reindex_async(issue) do
    case mode() do
      :off ->
        :ok

      :sync ->
        log_outcome(reindex_issue(issue), issue)
        :ok

      :async ->
        spawn_reindex(issue)
        :ok
    end
  end

  # Even the spawn is wrapped: `Task.Supervisor.start_child/2` EXITS with
  # :noproc if OrcaHub.TaskSupervisor isn't running, and this runs inline on
  # the caller's process — i.e. inside an interactive issue write. The
  # supervisor is always up in a booted app, but a `mix run --no-start`
  # script, a release `eval`, or a supervisor restart racing a write are all
  # real, and none of them is a good reason to fail someone's issue update.
  defp spawn_reindex(issue) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      log_outcome(reindex_issue(issue), issue)
    end)
  rescue
    e -> Logger.warning("Issue indexer: could not spawn reindex - #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("Issue indexer: could not spawn reindex - #{inspect(reason)}")
  end

  @doc """
  Resolves the effective indexing mode: `:off`, `:async` or `:sync`.

  `config :orca_hub, :issue_indexing` accepts `false`/`:off` (kill switch),
  `:sync`, or `:async`/anything else (the default). An unconfigured
  embedder forces `:off` regardless — there is nothing for a Task to do but
  return `{:error, :disabled}`.
  """
  @spec mode() :: :off | :async | :sync
  def mode do
    case Application.get_env(:orca_hub, :issue_indexing, :async) do
      false -> :off
      :off -> :off
      other -> if enabled?(), do: sync_or_async(other), else: :off
    end
  end

  defp sync_or_async(:sync), do: :sync
  defp sync_or_async(_), do: :async

  defp log_outcome({:ok, %{embedded: 0, deleted: 0}}, _issue), do: :ok

  defp log_outcome({:ok, stats}, _issue) do
    Logger.info(
      "Issue indexer: issue #{stats.issue_id} — #{stats.chunks} chunk(s), " <>
        "#{stats.embedded} embedded, #{stats.unchanged} unchanged, #{stats.deleted} deleted" <>
        if(stats.stale_write, do: " (watermark skipped: issue changed mid-pass)", else: "")
    )
  end

  defp log_outcome({:error, reason}, issue) do
    Logger.warning(
      "Issue indexer: reindex of issue #{Map.get(issue, :id, "?")} failed - #{inspect(reason)}"
    )
  end

  @doc """
  Ids of issues whose index is behind their content — `indexed_at IS NULL
  OR updated_at >= indexed_at` — newest write first, capped at `limit`.

  Newest-first is deliberate: an issue that fails permanently (e.g. a
  chunk the server rejects outright) stays in this set forever, and
  oldest-first ordering would let a handful of such issues occupy the
  sweep's whole bounded batch on every tick and starve everything else.
  Successfully indexed issues leave the set, so with newest-first a poison
  issue costs exactly one slot per tick.
  """
  @spec stale_issue_ids(pos_integer()) :: [String.t()]
  def stale_issue_ids(limit) when is_integer(limit) and limit > 0 do
    stale_query()
    |> order_by([i], desc: i.updated_at)
    |> limit(^limit)
    |> select([i], i.id)
    |> Repo.all()
  end

  @doc "How many issues are currently behind their index (unbounded count, no rows loaded)."
  @spec stale_count() :: non_neg_integer()
  def stale_count, do: Repo.aggregate(stale_query(), :count, :id)

  @doc """
  Classifies a `reindex_issue/1` error as belonging to the ENDPOINT rather
  than to the one issue. Both bulk callers (`OrcaHub.Issues.IndexSweep` and
  `OrcaHub.Issues.Backfill`) use this to stop early instead of grinding
  every remaining issue through a server that just refused the connection —
  they would all fail identically, and hammering a single shared GPU box is
  the retry amplification worth avoiding.

  A hard `400` is deliberately NOT endpoint-level: it means the server
  rejected that specific input (e.g. a chunk over its context limit), so
  the next issue may well succeed.
  """
  @spec endpoint_failure?(term()) :: boolean()
  def endpoint_failure?(:disabled), do: true
  def endpoint_failure?({:request_failed, _}), do: true
  def endpoint_failure?({:exception, _}), do: true
  def endpoint_failure?({:exit, _}), do: true
  def endpoint_failure?({:dimension_mismatch, _, _}), do: true
  def endpoint_failure?({:count_mismatch, _, _}), do: true
  def endpoint_failure?({:http_error, status, _}) when status >= 500, do: true
  def endpoint_failure?({:http_error, status, _}) when status in [408, 429], do: true
  def endpoint_failure?(_), do: false

  @doc """
  Ids of issues to reindex in a full pass, ordered by id and starting after
  `after_id` — keyset pagination for `OrcaHub.Issues.Backfill`.

  `stale_only: true` restricts to the same candidate set as
  `stale_issue_ids/1`. Ordering by id (rather than by staleness) is what
  makes a backfill terminate: an issue that fails is still behind the
  cursor, so it cannot be handed back forever.
  """
  @spec page_issue_ids(String.t() | nil, pos_integer(), keyword()) :: [String.t()]
  def page_issue_ids(after_id, limit, opts \\ []) when is_integer(limit) and limit > 0 do
    base = if opts[:stale_only], do: stale_query(), else: from(i in Issue)

    base
    |> then(fn q -> if after_id, do: where(q, [i], i.id > ^after_id), else: q end)
    |> order_by([i], asc: i.id)
    |> limit(^limit)
    |> select([i], i.id)
    |> Repo.all()
  end

  @doc "How many issues a backfill would visit — every issue, or only the stale ones."
  @spec countable(keyword()) :: non_neg_integer()
  def countable(opts \\ []) do
    query = if opts[:stale_only], do: stale_query(), else: from(i in Issue)
    Repo.aggregate(query, :count, :id)
  end

  # `>=`, not `>`, and that is load-bearing. Ecto's `timestamps()` store
  # `updated_at` truncated to the SECOND, so a write that lands in the same
  # second as an index pass produces `updated_at == indexed_at` — under `>`
  # that write would be silently invisible to the sweep forever, which is
  # exactly the class of bug this watermark exists to prevent. Truncation is
  # monotone, so `updated_at >= indexed_at` catches every write at or after
  # the stamp with no fudge interval.
  #
  # The cost is bounded and self-limiting: an issue indexed within the same
  # second as its last write stays a candidate for exactly ONE more pass,
  # which embeds nothing (every content hash matches) and re-stamps
  # `indexed_at` strictly later than `updated_at`, after which the issue
  # drops out. One no-op pass per issue is the price of never missing a
  # same-second write.
  defp stale_query do
    from(i in Issue, where: is_nil(i.indexed_at) or i.updated_at >= i.indexed_at)
  end

  # -------------------------------------------------------------------
  # The pass itself
  # -------------------------------------------------------------------

  defp do_reindex(%Issue{} = issue) do
    desired = Chunker.chunk(issue)
    existing = load_existing(issue.id)
    model = Embeddings.model()

    {to_embed, unchanged} = Enum.split_with(desired, &needs_embedding?(&1, existing, model))
    orphan_ids = orphan_ids(desired, existing)

    with {:ok, vectors} <- embed_contents(to_embed) do
      rows = build_rows(issue.id, to_embed, vectors, model)

      case write(issue, rows, orphan_ids) do
        {:ok, {deleted, indexed_at}} ->
          {:ok,
           %{
             issue_id: issue.id,
             chunks: length(desired),
             embedded: length(to_embed),
             unchanged: length(unchanged),
             deleted: deleted,
             indexed_at: indexed_at,
             stale_write: is_nil(indexed_at)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_issue(%Issue{} = issue), do: {:ok, issue}

  defp resolve_issue(id) when is_binary(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :issue_not_found}
      issue -> {:ok, issue}
    end
  end

  defp resolve_issue(other), do: {:error, {:invalid_issue, other}}

  defp check_enabled do
    if Embeddings.enabled?(), do: :ok, else: {:error, :disabled}
  end

  defp load_existing(issue_id) do
    from(c in IssueChunk, where: c.issue_id == ^issue_id)
    |> Repo.all()
    |> Map.new(fn chunk -> {{chunk.field, chunk.chunk_index}, chunk} end)
  end

  defp needs_embedding?(chunk, existing, model) do
    case Map.get(existing, key(chunk)) do
      nil ->
        true

      row ->
        row.content_hash != IssueChunk.content_hash(chunk.content) or
          is_nil(row.embedding) or row.embedding_model != model
    end
  end

  defp orphan_ids(desired, existing) do
    keep = MapSet.new(desired, &key/1)

    existing
    |> Enum.reject(fn {k, _row} -> MapSet.member?(keep, k) end)
    |> Enum.map(fn {_k, row} -> row.id end)
  end

  defp key(%{field: field, chunk_index: index}), do: {to_string(field), index}

  defp embed_contents([]), do: {:ok, []}
  defp embed_contents(chunks), do: Embeddings.embed_many(Enum.map(chunks, & &1.content))

  defp build_rows(issue_id, chunks, vectors, model) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    naive_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    chunks
    |> Enum.zip(vectors)
    |> Enum.map(fn {chunk, vector} ->
      %{
        issue_id: issue_id,
        field: to_string(chunk.field),
        chunk_index: chunk.chunk_index,
        content: chunk.content,
        content_hash: IssueChunk.content_hash(chunk.content),
        embedding: vector,
        embedding_model: model,
        embedded_at: now,
        inserted_at: naive_now,
        updated_at: naive_now
      }
    end)
  end

  # One transaction for the three writes, so a reader never sees the
  # orphans gone but the replacements missing. No HTTP happens in here.
  defp write(issue, rows, orphan_ids) do
    Repo.transaction(fn ->
      upsert_rows(rows)
      deleted = delete_orphans(orphan_ids)
      {deleted, stamp_indexed_at(issue)}
    end)
  end

  defp upsert_rows([]), do: :ok

  defp upsert_rows(rows) do
    Repo.insert_all(IssueChunk, rows,
      on_conflict:
        {:replace,
         [:content, :content_hash, :embedding, :embedding_model, :embedded_at, :updated_at]},
      conflict_target: [:issue_id, :field, :chunk_index]
    )

    :ok
  end

  defp delete_orphans([]), do: 0

  defp delete_orphans(ids) do
    {deleted, _} = Repo.delete_all(from(c in IssueChunk, where: c.id in ^ids))
    deleted
  end

  # See the moduledoc: update_all (not a changeset) so `updated_at` is not
  # bumped, guarded on the `updated_at` we read so a concurrent write to the
  # issue leaves the watermark behind instead of falsely claiming caught-up.
  defp stamp_indexed_at(issue) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(i in Issue, where: i.id == ^issue.id and i.updated_at == ^issue.updated_at)
      |> Repo.update_all(set: [indexed_at: now])

    if count == 1, do: now, else: nil
  end
end
