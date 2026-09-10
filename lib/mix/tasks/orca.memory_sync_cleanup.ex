defmodule Mix.Tasks.Orca.MemorySyncCleanup do
  @moduledoc """
  One-time, per-node cleanup of `OrcaHub.MemorySync`'s leftover files, now
  that agent memory has centralized into the external memory-service.

  Deletes `~/.codex/memories/claude--*.md` mirrors, deletes
  `~/.claude/memories-from-codex.md`, and removes the `@`-import line (and
  its marker comment) from `~/.claude/CLAUDE.md`. Filesystem-only — never
  touches the DB, so it doesn't boot the app. Idempotent: safe to re-run.

  See `OrcaHub.MemorySync.Cleanup` for the implementation.

      mix orca.memory_sync_cleanup
  """

  use Mix.Task

  @shortdoc "Delete leftover OrcaHub.MemorySync mirror/generated files on this node"

  @impl Mix.Task
  def run(_args) do
    result = OrcaHub.MemorySync.Cleanup.run()

    IO.puts("Memory sync cleanup complete:")
    IO.puts("  Codex mirror files deleted: #{result.mirrors_deleted}")
    IO.puts("  ~/.claude/memories-from-codex.md deleted: #{result.generated_file_deleted}")
    IO.puts("  ~/.claude/CLAUDE.md import line removed: #{result.claude_md_updated}")
  end
end
