defmodule Mix.Tasks.Orca.ReindexIssues do
  @moduledoc """
  Bulk (re)builds the pgvector issue index (`issue_chunks`) — the one-off
  counterpart to the steady-state `OrcaHub.Issues.IndexSweep`.

      mix orca.reindex_issues                     # only issues behind their watermark
      mix orca.reindex_issues --force             # visit every issue
      mix orca.reindex_issues --dry-run           # just count what would be visited
      mix orca.reindex_issues --concurrency 2     # be gentler on the embedding box
      mix orca.reindex_issues --limit 5           # trial run

  Needs `EMBEDDING_URL` configured (it is in `.env` for dev); without it the
  task exits with a clear message rather than pretending to work.

  In PROD there is no Mix — use the same logic through the release:

      bin/orca_hub rpc 'OrcaHub.Issues.Backfill.run(force: true) |> IO.inspect()'

  See `OrcaHub.Issues.Backfill` for the mechanics (keyset paging, bounded
  concurrency, abort-on-endpoint-failure).
  """

  use Mix.Task

  alias OrcaHub.Issues.Backfill

  @shortdoc "Rebuild the pgvector index for issues (issue_chunks)"

  @switches [
    force: :boolean,
    dry_run: :boolean,
    concurrency: :integer,
    limit: :integer
  ]

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)

    Mix.Task.run("app.start")

    case Backfill.run(Keyword.put(opts, :progress, &print_progress/1)) do
      {:error, :disabled} -> Mix.raise(disabled_message())
      {:ok, summary} when is_map(summary) -> report(summary, opts)
    end
  end

  @doc """
  Parses the flags, raising on an unknown one. Public (and called BEFORE
  `app.start`) so a typo'd flag fails immediately, and so the CLI layer is
  testable without booting — or recompiling — the app.
  """
  def parse_args(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    unless invalid == [] do
      Mix.raise("Unknown or malformed option(s): #{inspect(invalid)}")
    end

    opts
  end

  @doc false
  def disabled_message do
    "No embedding endpoint configured (EMBEDDING_URL is unset), so there is nothing to index."
  end

  defp print_progress(acc) do
    IO.write(
      "\r  #{acc.visited} visited · #{acc.indexed} indexed · #{acc.embedded} embedded · " <>
        "#{acc.deleted} deleted · #{acc.failed} failed   "
    )
  end

  @doc false
  def report(summary, opts) do
    IO.puts("")

    if opts[:dry_run] do
      IO.puts("Would visit #{summary.visited} issue(s). (--dry-run, nothing was indexed.)")
    else
      IO.puts("Issue reindex complete:")
      IO.puts("  Issues visited:    #{summary.visited}")
      IO.puts("  Issues indexed:    #{summary.indexed}")
      IO.puts("  Chunks embedded:   #{summary.embedded}")
      IO.puts("  Chunks unchanged:  #{summary.unchanged}")
      IO.puts("  Chunks deleted:    #{summary.deleted}")
      IO.puts("  Failures:          #{summary.failed}")
      IO.puts("  Duration:          #{summary.duration_ms}ms")

      if summary.aborted do
        IO.puts("\n  ABORTED (#{summary.aborted}) — the embedding endpoint looked unhealthy.")
        IO.puts("  Nothing already indexed was lost; re-run when it is back.")
      end

      for {id, reason} <- Enum.reverse(summary.errors) do
        IO.puts("  ! #{id || "(task exited)"}: #{inspect(reason)}")
      end
    end
  end
end
