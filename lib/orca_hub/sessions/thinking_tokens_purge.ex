defmodule OrcaHub.Sessions.ThinkingTokensPurge do
  @moduledoc """
  One-off, batched purge of persisted `system`/`thinking_tokens` rows from
  `messages`.

  A running Claude turn emits a `thinking_tokens` tick about once a second.
  `OrcaHub.SessionRunner` used to persist every one; it now only broadcasts
  them. The rows already in the table are write-only: the feed hides them
  (`MessageComponents.hidden_message?/1`) and nothing reads them back. A
  2026-10-22 prod audit found them to be 41% of all new message rows.

  Run it on the live HUB (a release has no Mix):

      bin/orca_hub rpc 'OrcaHub.Sessions.purge_thinking_tokens_events(dry_run: true) |> IO.inspect()'
      bin/orca_hub rpc 'OrcaHub.Sessions.purge_thinking_tokens_events([]) |> IO.inspect()'

  ## Query shape

  A table-wide `data ->> 'subtype' = 'thinking_tokens'` predicate is a
  sequential scan that also detoasts every large message. Instead every
  query names its sessions (`session_id = ANY($1)`), so both columns of
  `messages_session_id_subtype_index` are index conditions and only the
  matching rows are read:

    1. Count the matching rows per session, in chunks of session ids taken
       from the `sessions` table (`messages.session_id` cascades from it, so
       no message is missed).
    2. Pack those sessions into groups of about `:batch_size` rows. Delete
       each group in batches of at most `:batch_size` rows until a batch
       comes back short, with a `:sleep_ms` pause between batches.

  Without that index every query reads and detoasts every message of its
  sessions, so a full run reads the whole table (about 5 GB with TOAST on
  prod). So `run/1` refuses to start until the index exists and is valid.

  ## Re-running

  No cursor or state is kept: each run recounts what is left. Each batch is
  its own statement and commits on its own. An interrupted run (a dropped
  `kubectl exec`, a hub restart) rolls back only the batch in flight, and
  the next run deletes the rest. A second complete run deletes nothing.

  ## Disk

  Deleting rows does not shrink the table or index files. VACUUM (auto or
  manual) removes the dead rows and their index entries and makes the space
  reusable by new rows; only `VACUUM FULL` or `pg_repack` (a full rewrite)
  return it to the OS. The win is fewer rows to scan and smaller future
  growth, not disk.
  """

  import Ecto.Query

  alias OrcaHub.{Mode, Repo}
  alias OrcaHub.Sessions.{Message, Session}

  @subtype "thinking_tokens"
  @index "messages_session_id_subtype_index"
  @default_batch_size 5_000
  # On prod's stats (2.0 M rows) a 20,000-row batch is still that many
  # primary-key lookups, but at 40,000 the planner switches to a hash join
  # over a sequential scan of the whole table, once per batch.
  @max_batch_size 10_000
  @default_sleep_ms 200
  # Session ids per counting query.
  @count_chunk 500
  # One batch is an index lookup plus a few thousand heap updates, well
  # under a second. This only fires for a long lock wait.
  @query_timeout :timer.minutes(2)

  @type summary :: %{
          dry_run: boolean(),
          rows: non_neg_integer(),
          sessions: non_neg_integer(),
          deleted: non_neg_integer(),
          batches: non_neg_integer(),
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Counts (and, unless `dry_run: true`, deletes) the `thinking_tokens` rows.
  Returns a `t:summary/0`: `rows` and `sessions` are what the count found,
  `deleted` and `batches` what the delete did.

  Raises when this node is not the hub, when the Repo is not running, when
  `messages_session_id_subtype_index` is missing or invalid, or on an unknown
  or out-of-range option (so a typo such as `dryrun: true` cannot turn into a
  real run).

  Options:

    * `:dry_run` — count only, delete nothing (default `false`).
    * `:batch_size` — rows per DELETE, at most #{@max_batch_size}
      (default #{@default_batch_size}).
    * `:sleep_ms` — pause between batches (default #{@default_sleep_ms}).
    * `:session_ids` — limit the run to these sessions (default: every
      session). Useful for a trial on one session.
    * `:progress` — 1-arity fun called with each progress line. Defaults to
      `IO.puts/1`, which prints to the caller's group leader: the terminal,
      under `bin/orca_hub rpc`. Not Logger: the default log handler drops
      events from a process whose group leader is on another node (its
      `remote_gl` filter), and an `rpc` call is exactly that.
    * `:index` — the index to require (default `#{@index}`).
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        dry_run: false,
        batch_size: @default_batch_size,
        sleep_ms: @default_sleep_ms,
        session_ids: nil,
        progress: &IO.puts/1,
        index: @index
      )

    unless is_integer(opts[:batch_size]) and opts[:batch_size] in 1..@max_batch_size,
      do: raise(ArgumentError, ":batch_size must be an integer in 1..#{@max_batch_size}")

    unless is_integer(opts[:sleep_ms]) and opts[:sleep_ms] >= 0,
      do: raise(ArgumentError, ":sleep_ms must be a non-negative integer")

    unless is_function(opts[:progress], 1),
      do: raise(ArgumentError, ":progress must be a 1-arity function")

    ensure_hub!()
    ensure_index!(opts[:index])

    started = System.monotonic_time(:millisecond)
    counts = count_by_session(opts[:session_ids] || all_session_ids())
    rows = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    progress(
      opts,
      "#{rows} row(s) in #{length(counts)} session(s)" <>
        if(opts[:dry_run], do: " (dry run, nothing deleted)", else: "")
    )

    result =
      if opts[:dry_run],
        do: %{deleted: 0, batches: 0},
        else: delete_all(counts, rows, started, opts)

    summary =
      Map.merge(result, %{
        dry_run: opts[:dry_run],
        rows: rows,
        sessions: length(counts),
        elapsed_ms: elapsed_ms(started)
      })

    progress(
      opts,
      "done: deleted #{summary.deleted} row(s) in #{summary.batches} batch(es), " <>
        "#{format_elapsed(summary.elapsed_ms)}"
    )

    summary
  end

  defp ensure_hub! do
    cond do
      not Mode.hub?() ->
        raise "thinking_tokens purge must run on the hub, and #{node()} is a(n) " <>
                "#{Mode.mode()} node. Only the hub owns the database."

      Process.whereis(Repo) == nil ->
        raise "thinking_tokens purge needs OrcaHub.Repo running on #{node()}. Run it " <>
                "against the live hub with `bin/orca_hub rpc`, not `bin/orca_hub eval`."

      true ->
        :ok
    end
  end

  defp ensure_index!(name) do
    %{rows: rows} =
      Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [name])

    case rows do
      [[true]] ->
        :ok

      [[false]] ->
        raise "index #{name} exists but is INVALID (a build still running, or an " <>
                "abandoned one). Wait for it, or re-run its migration, then retry."

      [] ->
        raise "index #{name} is missing. Without it every batch reads and detoasts " <>
                "whole sessions. Run this after the deploy that applies migration " <>
                "20261105120200_add_messages_session_subtype_index."
    end
  end

  defp all_session_ids do
    Repo.all(from(s in Session, select: s.id, order_by: s.id), timeout: @query_timeout)
  end

  # [{session_id, count}] for the sessions with at least one matching row.
  defp count_by_session(session_ids) do
    session_ids
    |> Enum.chunk_every(@count_chunk)
    |> Enum.flat_map(fn ids ->
      from(m in matching(ids), group_by: m.session_id, select: {m.session_id, count()})
      |> Repo.all(timeout: @query_timeout)
    end)
  end

  defp matching(session_ids) do
    from(m in Message,
      where: m.session_id in ^session_ids,
      where: fragment("? ->> 'subtype'", m.data) == @subtype
    )
  end

  defp delete_all(counts, rows, started, opts) do
    counts
    |> pack(opts[:batch_size])
    |> Enum.reduce(%{deleted: 0, batches: 0}, &delete_group(&1, &2, rows, started, opts))
  end

  # Groups sessions so that each group holds about `batch_size` rows. A
  # session with more than that is a group of its own and takes several
  # batches.
  defp pack(counts, batch_size) do
    Enum.chunk_while(
      counts,
      {[], 0},
      fn {id, n}, {ids, sum} ->
        if ids != [] and sum + n > batch_size,
          do: {:cont, ids, {[id], n}},
          else: {:cont, {[id | ids], sum + n}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {ids, _} -> {:cont, ids, {[], 0}}
      end
    )
  end

  defp delete_group(session_ids, acc, rows, started, opts) do
    if acc.batches > 0, do: Process.sleep(opts[:sleep_ms])

    batch = from(m in matching(session_ids), select: m.id, limit: ^opts[:batch_size])

    {n, _} =
      Repo.delete_all(from(m in Message, where: m.id in subquery(batch)),
        timeout: @query_timeout
      )

    acc = %{deleted: acc.deleted + n, batches: acc.batches + 1}

    progress(
      opts,
      "batch #{acc.batches}: deleted #{n} (#{acc.deleted} of #{rows}), " <>
        "#{format_elapsed(elapsed_ms(started))} elapsed"
    )

    # A full batch may have left rows behind; a short one emptied the group.
    if n == opts[:batch_size],
      do: delete_group(session_ids, acc, rows, started, opts),
      else: acc
  end

  defp progress(opts, line), do: opts[:progress].("[thinking_tokens purge] " <> line)

  defp elapsed_ms(started), do: System.monotonic_time(:millisecond) - started

  defp format_elapsed(ms), do: "#{Float.round(ms / 1000, 1)} s"
end
