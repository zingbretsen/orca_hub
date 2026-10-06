defmodule OrcaHub.SessionSearch.Indexer do
  @moduledoc """
  Hub-only sweep that pushes conversation text into memory-service's
  `session-messages` collection (ORCAHUB3-137), continuously and as the
  one-time backfill of all history — they are the same sweep, the backfill is
  just the cursor starting at NULL.

  ## The cursor

  `OrcaHub.SessionSearch.Cursor` (Postgres, one row, see the migration for
  why) holds a keyset position in `messages ORDER BY inserted_at, id`. A tick
  scans the next page after it, extracts docs (`Extractor`), posts up to
  `batch_size` of them, and advances the cursor ONLY after memory-service
  answers 200. Any transport/HTTP error leaves the cursor where it was, so an
  outage of memory-service, ES or the embedder self-heals on later ticks with
  no in-process state to lose. Posts are idempotent upserts keyed by message
  id, so the rescan after a crash between POST and cursor write is harmless.

  Messages with `inserted_at` newer than `settle_seconds` (30) are not
  scanned yet: `inserted_at` is assigned before commit, so a slow transaction
  could otherwise land a row BEHIND the cursor and never be seen.

  The scan pre-filters in SQL to user/assistant rows that have a text block
  and belong to `kind = "session"` sessions, so tool-result blobs are never
  pulled across the wire; the extractor re-checks everything.

  ## Per-doc errors

  A 200 can still carry `errors: [%{id, reason}]`. The cursor moves past
  those (one bad doc must not wedge the sweep) and each is recorded in
  `session_search_failures`. Every tick first retries failures older than
  `retry_backoff_seconds` (900), at most `@max_attempts` (5) times; after
  that the row stays as an inspectable dead letter and is no longer retried.
  A 400 for the WHOLE request (e.g. unknown `fields`) is a transport-level
  error here: loud, cursor held, retried with backoff.

  ## Pace and switches

  Defaults are gentle on the GB10 embedder: `batch_size` 100 docs per tick,
  `behind_interval_ms` 10 s between ticks while behind, `idle_interval_ms`
  60 s once caught up, doubling up to 5 min after errors. App env keys
  `:session_search_*` (set from `SESSION_SEARCH_*` env in runtime.exs).
  Runs only when `MemoryClient.enabled?/0` AND `SESSION_SEARCH_INDEXING` is
  not `false`; re-checked every tick.

  ## Observability

  Each tick logs and emits
  `[:orca_hub, :session_search, :tick]` with measurements `docs`, `errors`
  (per-doc), `unembedded` (chunks indexed without a vector — the embedder is
  down; memory-service backfills them) and `lag_seconds` (age of the cursor),
  metadata `%{result: :ok | :error, caught_up: boolean}`.
  """

  use GenServer
  import Ecto.Query
  require Logger

  alias OrcaHub.{MemoryClient, Repo}
  alias OrcaHub.SessionSearch.{Cursor, Extractor, Failure}
  alias OrcaHub.Sessions.{Message, Session}

  @cursor_name "session-messages"
  @max_attempts 5
  @retry_limit 50
  @max_error_backoff_ms 300_000
  @initial_delay_ms 20_000
  @text_path "$.message.content[*] ? (@.type == \"text\")"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # -- config ---------------------------------------------------------------

  def cursor_name, do: @cursor_name
  def max_attempts, do: @max_attempts

  @doc "Indexing is on iff the kill switch is not thrown and memory-service is configured."
  def enabled?, do: kill_switch_on?() and MemoryClient.enabled?()

  defp kill_switch_on?,
    do: Application.get_env(:orca_hub, :session_search_indexing, true) != false

  defp batch_size, do: Application.get_env(:orca_hub, :session_search_batch_size, 100)
  defp behind_ms, do: Application.get_env(:orca_hub, :session_search_behind_interval_ms, 10_000)
  defp idle_ms, do: Application.get_env(:orca_hub, :session_search_idle_interval_ms, 60_000)
  defp settle_seconds, do: Application.get_env(:orca_hub, :session_search_settle_seconds, 30)

  defp retry_backoff_seconds,
    do: Application.get_env(:orca_hub, :session_search_retry_backoff_seconds, 900)

  # -- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @initial_delay_ms)
    {:ok, %{error_streak: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    {delay, state} =
      if enabled?() do
        case safe_tick() do
          {:ok, %{behind: true}} -> {behind_ms(), %{state | error_streak: 0}}
          {:ok, _} -> {idle_ms(), %{state | error_streak: 0}}
          {:error, _} -> backoff(state)
        end
      else
        {idle_ms(), state}
      end

    Process.send_after(self(), :tick, delay)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp backoff(%{error_streak: n} = state) do
    {min(behind_ms() * Integer.pow(2, n), @max_error_backoff_ms), %{state | error_streak: n + 1}}
  end

  defp safe_tick do
    run_tick()
  rescue
    e ->
      Logger.error(
        "SessionSearch.Indexer: tick crashed - #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.error("SessionSearch.Indexer: tick exited - #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  # -- one tick -------------------------------------------------------------

  @doc """
  Runs one retry pass + one sweep page. Returns
  `{:ok, %{docs:, errors:, behind:, ...}} | {:error, reason}`; the cursor
  moves only on a successful post. Opts (tests / console): `:name` (cursor
  row), `:session_ids` (scope the scan), `:batch_size`, `:settle_seconds`,
  `:retry_backoff_seconds`, `:index_fun` (default
  `&MemoryClient.index_session_messages/1`).
  """
  def run_tick(opts \\ []) do
    name = Keyword.get(opts, :name, @cursor_name)
    retried = retry_failures(opts)

    case sweep_page(name, opts) do
      {:ok, stats} ->
        stats = Map.put(stats, :retried, retried)
        report(name, stats, :ok)
        {:ok, stats}

      {:error, reason} = error ->
        Logger.warning(
          "SessionSearch.Indexer: tick failed, cursor held - #{inspect(reason, limit: 5)}"
        )

        report(name, %{docs: 0, errors: 0, unembedded: 0, behind: true}, :error)
        error
    end
  end

  defp sweep_page(name, opts) do
    size = Keyword.get(opts, :batch_size, batch_size())
    scan_limit = size * 4
    cursor = Repo.get(Cursor, name)

    rows = scan(cursor, scan_limit, opts)
    pairs = for {m, s} <- rows, {:ok, doc} <- [Extractor.extract(m, s)], do: {doc, m}
    exhausted = length(rows) < scan_limit
    {batch, rest} = Enum.split(pairs, size)

    target =
      cond do
        rows == [] -> nil
        rest == [] -> rows |> List.last() |> elem(0)
        true -> batch |> List.last() |> elem(1)
      end

    behind = not exhausted or rest != []
    base = %{docs: length(batch), errors: 0, unembedded: 0, scanned: length(rows), behind: behind}

    if batch == [] do
      advance(name, target, 0)
      {:ok, base}
    else
      case post(Enum.map(batch, &elem(&1, 0)), opts) do
        {:ok, resp} ->
          errors = record_errors(resp, Enum.map(batch, &elem(&1, 0)))
          advance(name, target, length(batch) - errors)
          {:ok, %{base | errors: errors, unembedded: unembedded(resp)}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp scan(cursor, limit, opts) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-Keyword.get(opts, :settle_seconds, settle_seconds()), :second)

    from(m in Message,
      join: s in Session,
      on: s.id == m.session_id,
      where: s.kind == "session",
      where: fragment("?->>'type'", m.data) in ["user", "assistant"],
      where:
        fragment(
          "jsonb_typeof(?->'message'->'content') = 'string' OR jsonb_path_exists(?, (?::text)::jsonpath)",
          m.data,
          m.data,
          ^@text_path
        ),
      where: m.inserted_at <= ^cutoff,
      order_by: [asc: m.inserted_at, asc: m.id],
      limit: ^limit,
      select: {m, s}
    )
    |> after_cursor(cursor)
    |> scope_sessions(opts[:session_ids])
    |> Repo.all()
  end

  defp after_cursor(q, %Cursor{last_inserted_at: ts, last_message_id: id})
       when not is_nil(ts) and not is_nil(id) do
    from [m] in q, where: m.inserted_at > ^ts or (m.inserted_at == ^ts and m.id > ^id)
  end

  defp after_cursor(q, _), do: q

  defp scope_sessions(q, nil), do: q
  defp scope_sessions(q, ids), do: from([m] in q, where: m.session_id in ^ids)

  defp post(docs, opts) do
    fun = Keyword.get(opts, :index_fun, &MemoryClient.index_session_messages/1)

    case fun.(docs) do
      {:ok, %{} = resp} -> {:ok, resp}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = error -> error
    end
  end

  defp advance(_name, nil, _n), do: :ok

  defp advance(name, %Message{inserted_at: ts, id: id}, indexed) do
    now = NaiveDateTime.utc_now()

    Repo.insert!(
      %Cursor{name: name, last_inserted_at: ts, last_message_id: id, indexed_total: indexed},
      on_conflict: [
        set: [last_inserted_at: ts, last_message_id: id, updated_at: now],
        inc: [indexed_total: indexed]
      ],
      conflict_target: :name
    )

    :ok
  end

  # -- failures -------------------------------------------------------------

  defp record_errors(%{"errors" => [_ | _] = errors}, docs) do
    sessions = Map.new(docs, &{&1["id"], &1["group_id"]})
    now = NaiveDateTime.utc_now()

    errors
    |> Enum.filter(&Map.has_key?(sessions, &1["id"]))
    |> Enum.each(fn %{"id" => id} = e ->
      Repo.insert!(
        %Failure{message_id: id, session_id: sessions[id], reason: reason_text(e), attempts: 1},
        on_conflict: [set: [reason: reason_text(e), updated_at: now], inc: [attempts: 1]],
        conflict_target: :message_id
      )
    end)

    Logger.warning(
      "SessionSearch.Indexer: #{length(errors)} doc(s) rejected, recorded for retry: #{inspect(Enum.take(errors, 3))}"
    )

    length(errors)
  end

  defp record_errors(_resp, _docs), do: 0

  defp reason_text(e), do: e |> Map.get("reason") |> inspect_reason() |> String.slice(0, 1000)
  defp inspect_reason(r) when is_binary(r), do: r
  defp inspect_reason(r), do: inspect(r)

  defp unembedded(%{"chunks" => c, "embedded" => e}) when is_integer(c) and is_integer(e),
    do: max(c - e, 0)

  defp unembedded(_), do: 0

  defp retry_failures(opts) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(
        -Keyword.get(opts, :retry_backoff_seconds, retry_backoff_seconds()),
        :second
      )

    failures =
      from(f in Failure,
        where: f.attempts < ^@max_attempts and f.updated_at <= ^cutoff,
        order_by: [asc: f.updated_at],
        limit: ^@retry_limit
      )
      |> scope_failures(opts[:session_ids])
      |> Repo.all()

    if failures == [], do: 0, else: do_retry(failures, opts)
  end

  defp scope_failures(q, nil), do: q
  defp scope_failures(q, ids), do: from(f in q, where: f.session_id in ^ids)

  defp do_retry(failures, opts) do
    ids = Enum.map(failures, & &1.message_id)

    found =
      from(m in Message,
        join: s in Session,
        on: s.id == m.session_id,
        where: m.id in ^ids,
        select: {m, s}
      )
      |> Repo.all()

    pairs = for {m, s} <- found, {:ok, doc} <- [Extractor.extract(m, s)], do: doc
    posted_ids = MapSet.new(pairs, & &1["id"])

    # Message deleted or no longer indexable: nothing left to retry.
    gone = Enum.reject(ids, &MapSet.member?(posted_ids, &1))
    from(f in Failure, where: f.message_id in ^gone) |> Repo.delete_all()

    with true <- pairs != [], {:ok, resp} <- post(pairs, opts) do
      failed =
        for %{"id" => id} <- List.wrap(resp["errors"]), do: id

      ok_ids = Enum.reject(MapSet.to_list(posted_ids), &(&1 in failed))
      from(f in Failure, where: f.message_id in ^ok_ids) |> Repo.delete_all()
      record_errors(resp, pairs)
      length(ok_ids)
    else
      _ -> 0
    end
  end

  @doc """
  Hard-delete hook (`Sessions.delete_session/1`): drops the session's retry
  rows and, when indexing is on, asks memory-service to delete the session's
  docs — fire-and-forget under `OrcaHub.TaskSupervisor`, so a memory-service
  outage never fails or slows a deletion. A failure is logged; the orphaned
  docs stay searchable until a later explicit delete. Archiving is NOT
  deletion and never calls this.
  """
  def on_session_deleted(session_id) do
    from(f in Failure, where: f.session_id == ^session_id) |> Repo.delete_all()

    if enabled?() do
      Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
        case MemoryClient.delete_session_messages(session_id) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "SessionSearch: deleting indexed docs of session #{session_id} failed - #{inspect(reason, limit: 5)}"
            )
        end
      end)
    end

    :ok
  end

  # -- manual full reindex of one session -----------------------------------

  @doc """
  Re-posts every indexable message of one session (cursor untouched), in
  batches of `batch_size`. Returns `{:ok, docs_posted}` or the first error.
  Console tool for repairing a session; the sweep never needs it.
  """
  def reindex_session(session_id, opts \\ []) do
    size = Keyword.get(opts, :batch_size, batch_size())

    from(m in Message,
      join: s in Session,
      on: s.id == m.session_id,
      where: m.session_id == ^session_id,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: {m, s}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {m, s} ->
      with {:ok, d} <- Extractor.extract(m, s), do: [d], else: (_ -> [])
    end)
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, n} ->
      case post(batch, opts) do
        {:ok, resp} ->
          record_errors(resp, batch)
          {:cont, {:ok, n + length(batch)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # -- telemetry ------------------------------------------------------------

  @doc "Seconds between now and the cursor position (nil before the first advance)."
  def lag_seconds(name \\ @cursor_name) do
    case Repo.get(Cursor, name) do
      %Cursor{last_inserted_at: %NaiveDateTime{} = ts} ->
        NaiveDateTime.diff(NaiveDateTime.utc_now(), ts, :second)

      _ ->
        nil
    end
  end

  defp report(name, stats, result) do
    lag = lag_seconds(name)

    :telemetry.execute(
      [:orca_hub, :session_search, :tick],
      %{
        docs: stats.docs,
        errors: stats.errors,
        unembedded: stats.unembedded,
        lag_seconds: lag || 0
      },
      %{result: result, caught_up: not stats.behind}
    )

    if result == :ok and stats.docs > 0 do
      Logger.info(
        "SessionSearch.Indexer: indexed #{stats.docs} doc(s), #{stats.errors} rejected, " <>
          "#{stats.unembedded} unembedded chunk(s), lag #{lag}s, behind=#{stats.behind}"
      )
    end
  end
end
