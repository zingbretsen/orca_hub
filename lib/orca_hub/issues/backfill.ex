defmodule OrcaHub.Issues.Backfill do
  @moduledoc """
  Bulk (re)indexing of the whole issue corpus — the one-off counterpart to
  `OrcaHub.Issues.IndexSweep`'s steady-state trickle. Used to populate the
  index the first time, and after a model change, when waiting 20 issues per
  10 minutes is silly.

  Two front doors, same code:

    * `mix orca.reindex_issues` in dev (see `Mix.Tasks.Orca.ReindexIssues`);
    * `run/1` on a node that already has the app running, which is how prod
      reaches it — a release has no Mix at all:

          bin/orca_hub rpc 'OrcaHub.Issues.Backfill.run(force: true) |> IO.inspect()'

      `run_from_release/1` is the variant for `bin/orca_hub eval`, where the
      app is loaded but NOT started: it starts the Repo (and only the Repo)
      first. Prefer `rpc` against the live hub — `eval` spins up a second,
      separate connection to the same database.

  ## Shape of the work

  Keyset pagination by `id`, then `Task.async_stream/3` with bounded
  concurrency over each page. Two properties this buys, both of which matter
  more than speed:

    * **Termination.** Paging by id rather than by staleness means a
      permanently-failing issue is behind the cursor and cannot be handed
      back forever. A "keep fetching stale issues until none remain" loop
      would spin on it indefinitely.
    * **Bounded memory and bounded blast radius.** The corpus is 111 issues
      today, which would fit in one query — this is written for the corpus it
      will be, not the one it is, so nothing here loads every issue or fans
      out unboundedly.

  Concurrency defaults to 4. The embedding endpoint is a single small GPU box
  shared with every other project on the LAN, so this is deliberately modest;
  it is the knob to turn down first, never up by much.

  An endpoint-level failure (`Indexer.endpoint_failure?/1` — unreachable,
  5xx, dimension mismatch) ABORTS the run rather than marching the rest of
  the corpus through a server that is plainly down. A per-issue failure (a
  hard 400 on one over-length chunk) is counted and stepped over.
  """

  require Logger

  alias OrcaHub.Issues.Indexer

  @page_size 25
  @default_concurrency 4
  # Embeddings' own receive timeout is 60s and HubRPC allows 65s, so this only
  # fires for something genuinely wedged.
  @task_timeout 120_000

  @type summary :: %{
          visited: non_neg_integer(),
          indexed: non_neg_integer(),
          embedded: non_neg_integer(),
          deleted: non_neg_integer(),
          unchanged: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [{String.t(), term()}],
          aborted: nil | :endpoint,
          duration_ms: non_neg_integer()
        }

  @doc """
  Reindexes the corpus. Returns `{:ok, summary}` (see `t:summary/0`) or
  `{:error, :disabled}` when no embedding endpoint is configured.

  Options:

    * `:force` — reindex every issue, not just those behind their watermark
      (default `false`). Note that even a forced pass re-embeds only chunks
      whose content hash changed; `:force` controls which issues are VISITED,
      while `OrcaHub.Issues.Indexer` still decides what actually needs
      embedding. To genuinely re-embed unchanged text (after a model change
      that kept the same model NAME, say), clear `embedding_model` or
      `indexed_at` first.
    * `:concurrency` — issues in flight at once (default #{@default_concurrency}).
    * `:limit` — stop after visiting this many issues; for a trial run.
    * `:dry_run` — count what would be visited and return without embedding.
    * `:progress` — 1-arity fun called with each page's running summary, for a
      CLI to print. Defaults to a `Logger.info` line per page.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    cond do
      not Indexer.enabled?() ->
        {:error, :disabled}

      opts[:dry_run] ->
        {:ok, %{empty_summary() | visited: countable(opts)}}

      true ->
        do_run(opts)
    end
  end

  @doc """
  `run/1` for `bin/orca_hub eval`, where the application is loaded but not
  started. Starts SSL and the Repo first, then delegates. Prefer
  `bin/orca_hub rpc 'OrcaHub.Issues.Backfill.run([])'` against the running
  hub, which needs none of this.
  """
  @spec run_from_release(keyword()) :: {:ok, summary()} | {:error, term()}
  def run_from_release(opts \\ []) do
    Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    Application.ensure_loaded(:orca_hub)
    {:ok, _} = OrcaHub.Repo.start_link(pool_size: 2)
    run(opts)
  end

  @doc "How many issues a run with these options would visit."
  @spec countable(keyword()) :: non_neg_integer()
  def countable(opts \\ []), do: Indexer.countable(stale_only: not force?(opts))

  @doc "Default concurrency, for a CLI's help text."
  def default_concurrency, do: @default_concurrency

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp do_run(opts) do
    started = System.monotonic_time(:millisecond)
    total = countable(opts)

    Logger.info(
      "Issue backfill: #{total} issue(s) to visit " <>
        "(#{if force?(opts), do: "forced: every issue", else: "stale only"}), " <>
        "concurrency #{concurrency(opts)}"
    )

    summary =
      page_loop(nil, empty_summary(), opts)
      |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - started)

    Logger.info(
      "Issue backfill: done — #{summary.indexed}/#{summary.visited} indexed, " <>
        "#{summary.embedded} chunk(s) embedded, #{summary.deleted} deleted, " <>
        "#{summary.failed} failed, #{summary.duration_ms}ms" <>
        if(summary.aborted, do: " (ABORTED: #{summary.aborted})", else: "")
    )

    {:ok, summary}
  end

  defp page_loop(cursor, acc, opts) do
    remaining = remaining(acc, opts)

    case fetch_page(cursor, remaining, opts) do
      [] ->
        acc

      ids ->
        acc = process_page(ids, acc, opts)
        progress(acc, opts)

        cond do
          acc.aborted -> acc
          remaining(acc, opts) == 0 -> acc
          true -> page_loop(List.last(ids), acc, opts)
        end
    end
  end

  defp fetch_page(_cursor, 0, _opts), do: []

  defp fetch_page(cursor, remaining, opts) do
    Indexer.page_issue_ids(cursor, min(@page_size, remaining), stale_only: not force?(opts))
  end

  # `reduce_while`, not `reduce`: halting the stream is what actually stops
  # the work. Under a plain reduce, an endpoint-level abort only prevented the
  # NEXT page, so a down server still got every id in the CURRENT page thrown
  # at it (25 issues x 2 attempts each) — the amplification this is supposed
  # to prevent, just one page wide. Halting shuts the remaining tasks down, so
  # the overrun is at most `concurrency` issues already in flight.
  defp process_page(ids, acc, opts) do
    ids
    |> Task.async_stream(&reindex_one/1,
      max_concurrency: concurrency(opts),
      timeout: @task_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce_while(acc, fn result, acc ->
      case merge_result(result, acc) do
        %{aborted: nil} = acc -> {:cont, acc}
        aborted -> {:halt, aborted}
      end
    end)
  end

  defp reindex_one(id), do: {id, Indexer.reindex_issue(id)}

  defp merge_result({:ok, {_id, {:ok, stats}}}, acc) do
    %{
      acc
      | visited: acc.visited + 1,
        indexed: acc.indexed + 1,
        embedded: acc.embedded + stats.embedded,
        deleted: acc.deleted + stats.deleted,
        unchanged: acc.unchanged + stats.unchanged
    }
  end

  defp merge_result({:ok, {id, {:error, reason}}}, acc) do
    Logger.warning("Issue backfill: issue #{id} failed - #{inspect(reason)}")

    acc = %{
      acc
      | visited: acc.visited + 1,
        failed: acc.failed + 1,
        errors: [{id, reason} | acc.errors]
    }

    if Indexer.endpoint_failure?(reason) do
      Logger.error(
        "Issue backfill: aborting — #{inspect(reason)} is an endpoint-level failure, so every " <>
          "remaining issue would fail the same way. Nothing already indexed is lost; re-run when " <>
          "the endpoint is back."
      )

      %{acc | aborted: :endpoint}
    else
      acc
    end
  end

  # A killed task (the @task_timeout above) — counted, never fatal.
  defp merge_result({:exit, reason}, acc) do
    Logger.warning("Issue backfill: a reindex task exited - #{inspect(reason)}")

    %{
      acc
      | visited: acc.visited + 1,
        failed: acc.failed + 1,
        errors: [{nil, reason} | acc.errors]
    }
  end

  defp progress(acc, opts) do
    case opts[:progress] do
      fun when is_function(fun, 1) ->
        fun.(acc)

      _ ->
        Logger.info("Issue backfill: #{acc.visited} visited, #{acc.embedded} chunk(s) embedded")
    end
  end

  defp remaining(acc, opts) do
    case opts[:limit] do
      limit when is_integer(limit) and limit > 0 -> max(limit - acc.visited, 0)
      _ -> @page_size
    end
  end

  defp force?(opts), do: !!opts[:force]

  defp concurrency(opts) do
    case opts[:concurrency] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_concurrency
    end
  end

  defp empty_summary do
    %{
      visited: 0,
      indexed: 0,
      embedded: 0,
      deleted: 0,
      unchanged: 0,
      failed: 0,
      errors: [],
      aborted: nil,
      duration_ms: 0
    }
  end
end
