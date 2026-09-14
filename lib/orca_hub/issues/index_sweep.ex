defmodule OrcaHub.Issues.IndexSweep do
  @moduledoc """
  Periodic reconciliation of the pgvector issue index — the backstop for
  every reindex the write hooks in `OrcaHub.Issues` could not complete: the
  embedder was down, the hub restarted mid-Task, a row was edited straight
  in SQL, a deploy landed between the write and its index pass.

  Hub-only, registered in `Application.hub_children/1` next to
  `OrcaHub.ChurnSampler` and for the same reason: two nodes sweeping the
  same table would do the same work twice and race each other's upserts.

  ## Bounded, every tick, in two independent ways

  A tick reindexes at most `batch_size/0` (20) issues
  (`Indexer.stale_issue_ids/1` caps the candidate query itself — the whole
  backlog is never loaded), and stops early once it has embedded
  `chunk_budget/0` (400) chunks. The second bound matters because "20
  issues" is not a bound on work: one issue with a 35k-character `notes`
  blob is ~25 chunks on its own. Whatever a tick doesn't get to is simply
  still stale on the next one, `interval_seconds/0` (600) later.

  This shape is deliberate. The 2026-09-11 memory-service OOMKill was retry
  amplification against an unbounded synchronous scan; a sweep that loaded
  every stale issue and retried each one hard would rebuild it, pointed at
  a single shared GPU box that every other project on the LAN depends on.

  ## Failure handling, and the ChurnSampler lesson

  Each issue is reindexed independently: `Indexer.reindex_issue/1` never
  raises, so one poison issue yields an `{:error, _}` and the other 19 still
  get indexed. The whole tick is additionally wrapped in `rescue`/log so a
  DB outage can't take the timer loop down, and the next tick is scheduled
  BEFORE the sweep runs so even an unforeseen crash (which the supervisor
  would restart anyway) cannot end the loop.

  `OrcaHub.ChurnSampler`'s moduledoc warns that its outer `rescue` returns
  its alert edge state UNCHANGED, so a PERSISTENT failure silently ends
  alerting forever with only a log line — undetectable, because "no alerts"
  is that system's normal baseline. This module deliberately has no
  equivalent: **no in-process state gates progress.** The watermark is
  `issues.indexed_at` in Postgres, so a tick that fails entirely changes
  nothing and the next tick retries exactly the same candidate set. A
  persistent failure here degrades into "the index stops advancing and
  every tick logs why", which is also directly observable from outside
  via `Indexer.stale_count/0`.

  Two more anti-starvation details:

    * candidates come back newest-write-first (see `Indexer.stale_issue_ids/1`),
      so an issue that fails permanently — e.g. a chunk the server rejects
      with a hard 400 — costs one batch slot per tick instead of pinning the
      whole batch at the head of the queue forever;
    * a failure that clearly belongs to the ENDPOINT rather than to one
      issue (unreachable, 5xx, dimension mismatch, disabled mid-tick) aborts
      the rest of the tick immediately. Retrying 19 more issues against a
      server that just refused the connection is precisely the amplification
      worth avoiding, and they are all still stale next time.
  """

  use GenServer
  require Logger

  alias OrcaHub.Issues.Indexer

  @interval_seconds 600
  @batch_size 20
  @chunk_budget 400
  # A cold hub has better things to do for its first minute than embed.
  @initial_delay_seconds 60

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Interval between ticks, in seconds."
  def interval_seconds, do: @interval_seconds

  @doc "Maximum issues reindexed per tick."
  def batch_size, do: @batch_size

  @doc "Maximum chunks embedded per tick before the tick stops early."
  def chunk_budget, do: @chunk_budget

  @doc """
  Triggers a sweep on the running GenServer and returns its summary — for
  one-off audits from a console.
  """
  def sweep, do: GenServer.call(__MODULE__, :sweep, 120_000)

  @doc """
  Runs one reconciliation pass and returns
  `{:ok, %{candidates:, indexed:, embedded:, deleted:, failed:, aborted:}}`.

  A plain function rather than a GenServer call, following
  `OrcaHub.ChurnSampler.run_sweep/1`, so tests can drive it directly without
  starting a second copy of the singleton GenServer or waiting on a timer.

  Never raises. `opts[:limit]` overrides the per-tick issue cap (tests only —
  the default is the bound this module exists to enforce).
  """
  def run_sweep(opts \\ []) do
    if Indexer.enabled?() do
      do_sweep(Keyword.get(opts, :limit, @batch_size))
    else
      {:ok, empty_summary()}
    end
  rescue
    e ->
      Logger.error("Issue index sweep: failed - #{Exception.format(:error, e, __STACKTRACE__)}")
      {:ok, empty_summary()}
  catch
    :exit, reason ->
      Logger.error("Issue index sweep: exited - #{inspect(reason)}")
      {:ok, empty_summary()}
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @initial_delay_seconds * 1000)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:ok, summary} = run_sweep()
    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    # Scheduled FIRST: the loop must survive anything the sweep can do,
    # including a failure mode nobody anticipated.
    schedule_tick()
    run_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval_seconds * 1000)

  defp do_sweep(limit) do
    case Indexer.stale_issue_ids(limit) do
      [] ->
        Logger.debug("Issue index sweep: nothing stale")
        {:ok, empty_summary()}

      ids ->
        summary = Enum.reduce_while(ids, %{empty_summary() | candidates: length(ids)}, &step/2)
        log_summary(summary)
        {:ok, summary}
    end
  end

  defp step(id, acc) do
    case Indexer.reindex_issue(id) do
      {:ok, stats} ->
        acc = %{
          acc
          | indexed: acc.indexed + 1,
            embedded: acc.embedded + stats.embedded,
            deleted: acc.deleted + stats.deleted
        }

        if acc.embedded >= @chunk_budget do
          Logger.info(
            "Issue index sweep: chunk budget (#{@chunk_budget}) reached after " <>
              "#{acc.indexed} issue(s); the rest stay stale for the next tick"
          )

          {:halt, %{acc | aborted: :chunk_budget}}
        else
          {:cont, acc}
        end

      {:error, reason} ->
        acc = %{acc | failed: acc.failed + 1}
        Logger.warning("Issue index sweep: issue #{id} failed - #{inspect(reason)}")

        if Indexer.endpoint_failure?(reason) do
          Logger.warning(
            "Issue index sweep: aborting this tick — #{inspect(reason)} is an endpoint-level " <>
              "failure, so the remaining issues would fail the same way"
          )

          {:halt, %{acc | aborted: :endpoint}}
        else
          {:cont, acc}
        end
    end
  end

  defp empty_summary do
    %{candidates: 0, indexed: 0, embedded: 0, deleted: 0, failed: 0, aborted: nil}
  end

  defp log_summary(%{indexed: 0, failed: 0}), do: :ok

  defp log_summary(summary) do
    Logger.info(
      "Issue index sweep: #{summary.indexed}/#{summary.candidates} issue(s) indexed, " <>
        "#{summary.embedded} chunk(s) embedded, #{summary.deleted} deleted, " <>
        "#{summary.failed} failed#{if summary.aborted, do: " (aborted: #{summary.aborted})", else: ""}"
    )
  end
end
