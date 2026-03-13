defmodule Mix.Tasks.ImportClaudeSessions do
  @moduledoc """
  Imports Claude Code sessions from ~/.claude/ into OrcaHub.

  Creates projects for new directories and imports session transcripts
  with their messages. Skips sessions already managed by OrcaHub.

  ## Usage

      mix import_claude_sessions
      mix import_claude_sessions --verbose
  """

  use Mix.Task

  @shortdoc "Import Claude Code sessions from ~/.claude/ into OrcaHub"

  @impl Mix.Task
  def run(args) do
    verbose = "--verbose" in args

    Mix.Task.run("app.start")

    IO.puts("Scanning ~/.claude/projects/ for sessions...")
    result = OrcaHub.ClaudeImport.import_all(verbose: verbose)

    IO.puts("")
    IO.puts("Import complete:")
    IO.puts("  Sessions imported: #{result.sessions_imported}")
    IO.puts("  Sessions skipped:  #{result.sessions_skipped}")
    IO.puts("  Projects created:  #{result.projects_created}")

    if result.errors != [] do
      IO.puts("  Errors: #{length(result.errors)}")

      if verbose do
        Enum.each(result.errors, fn {session_id, reason} ->
          IO.puts("    #{session_id}: #{inspect(reason)}")
        end)
      end
    end
  end
end
