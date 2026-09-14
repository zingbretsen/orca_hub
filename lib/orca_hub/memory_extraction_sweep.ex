defmodule OrcaHub.MemoryExtractionSweep do
  @moduledoc """
  Boot-time backstop for `kind == "memory_extraction"` sessions orphaned by
  a hub restart landing in the brief window between a child's turn ending
  and `OrcaHub.SessionRunner`'s self-archive hook
  (`OrcaHub.MemoryExtraction.finalize_self/2`) running — see that module's
  moduledoc's "Designation + self-archiving". This is the hub-only,
  cluster-wide analog of `OrcaHub.SessionResumer`'s own boot sweep: a
  single delayed one-shot check, not a repeating timer.

  Runs on the HUB only (unlike `SessionResumer`, which runs per-node) —
  archiving an extraction child is a pure DB write regardless of which
  node it ran on, so there is exactly one sweep to run for the whole
  cluster rather than one per node. Every unarchived extraction session in
  `idle`/`error`/`ready` whose `updated_at` is older than
  `@older_than_minutes` is archived with `extract_memories: false` (an
  extraction child must never itself trigger extraction), and its
  transcript file is best-effort deleted via `Cluster.rpc/5` against its
  own `runner_node` — a failure there (node unreachable, file already
  gone) never blocks the archive itself.

  No visibility message is posted back to the source session here (unlike
  the normal `finalize_self/2` path) — by the time this sweep runs, the
  source itself may be long gone/archived, and this is cleanup of a stale
  bookkeeping row, not a fresh completion report.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Cluster, HubRPC, MemoryExtraction}

  @initial_delay_ms 30_000
  @older_than_minutes 10

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, state}
  end

  # Public (not just called from handle_info/2) so tests can trigger a sweep
  # directly rather than waiting on the real 30s boot delay.
  @doc false
  def sweep do
    orphans = HubRPC.list_orphaned_memory_extraction_sessions(@older_than_minutes)

    unless orphans == [] do
      Logger.info(
        "MemoryExtractionSweep: cleaning up #{length(orphans)} orphaned extraction " <>
          "session(s) from a prior restart"
      )
    end

    Enum.each(orphans, &cleanup_orphan/1)
    length(orphans)
  rescue
    e ->
      Logger.warning("MemoryExtractionSweep: sweep failed: #{Exception.message(e)}")
      0
  end

  defp cleanup_orphan(session) do
    delete_transcript_file(session)
    HubRPC.archive_session(session, extract_memories: false)
  rescue
    e ->
      Logger.warning(
        "MemoryExtractionSweep: failed to clean up session #{session.id}: " <>
          Exception.message(e)
      )
  end

  defp delete_transcript_file(session) do
    source_id = session.parent_session_id

    file_path =
      MemoryExtraction.transcript_file_path(%{directory: session.directory, id: source_id})

    case Cluster.runner_node_for(session) do
      nil ->
        :ok

      runner_node ->
        Cluster.rpc(runner_node, MemoryExtraction, :delete_transcript_file, [file_path])
    end
  end
end
