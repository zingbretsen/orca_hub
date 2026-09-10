defmodule OrcaHub.MemorySync.Cleanup do
  @moduledoc """
  One-time, per-node cleanup of `OrcaHub.MemorySync`'s leftover files, now
  that agent memory has centralized into the external memory-service
  (`OrcaHub.MemoryClient`) and the mechanical cross-backend mirror pass
  (`OrcaHub.MemoryGit.Server` used to run it after every snapshot) has been
  removed.

  Removes, on THIS node only:

    1. Every Claude->Codex mirror file, `~/.codex/memories/claude--*.md`.
    2. The generated Codex->Claude file, `~/.claude/memories-from-codex.md`.
    3. The `@`-import line (and its marker comment) that pointed
       `~/.claude/CLAUDE.md` at that generated file — the rest of
       `CLAUDE.md` is never touched.

  Idempotent: a second run finds nothing left to remove and is a no-op.
  `:home_dir` is injectable the same way as `OrcaHub.MemoryGit` (falls
  back to `:orca_hub, :memory_git_home`, then `System.user_home!/0`), so
  tests never touch a real `~/.claude`/`~/.codex`.

  Deliberately not run automatically anywhere — a deploy worker invokes
  `mix orca.memory_sync_cleanup` (or this module directly from a release)
  per node.
  """

  alias OrcaHub.MemoryGit

  @mirror_prefix "claude--"
  @generated_filename "memories-from-codex.md"
  @import_marker "<!-- orca-sync: import generated Codex memories (do not remove) -->"
  @import_line "@~/.claude/memories-from-codex.md"

  @doc """
  Runs the cleanup. Returns `%{mirrors_deleted: count, generated_file_deleted:
  boolean, claude_md_updated: boolean}`.
  """
  def run(opts \\ []) do
    claude_home = MemoryGit.claude_home_dir(opts)
    codex_dir = MemoryGit.codex_memories_dir(opts)

    %{
      mirrors_deleted: delete_mirrors(codex_dir),
      generated_file_deleted: delete_generated_file(claude_home),
      claude_md_updated: cleanup_claude_md(claude_home)
    }
  end

  defp delete_mirrors(codex_dir) do
    case File.ls(codex_dir) do
      {:ok, entries} ->
        mirrors = Enum.filter(entries, &mirror_filename?/1)
        Enum.each(mirrors, &File.rm!(Path.join(codex_dir, &1)))
        length(mirrors)

      {:error, _} ->
        0
    end
  end

  defp mirror_filename?(name),
    do: String.starts_with?(name, @mirror_prefix) and String.ends_with?(name, ".md")

  defp delete_generated_file(claude_home) do
    path = Path.join(claude_home, @generated_filename)

    case File.rm(path) do
      :ok -> true
      {:error, _} -> false
    end
  end

  defp cleanup_claude_md(claude_home) do
    path = Path.join(claude_home, "CLAUDE.md")

    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, @import_marker) or String.contains?(content, @import_line) do
          new_content =
            content
            |> String.split("\n")
            |> Enum.reject(&(&1 == @import_marker or &1 == @import_line))
            |> Enum.join("\n")
            |> String.replace(~r/\n{3,}\z/, "\n\n")

          File.write!(path, new_content)
          true
        else
          false
        end

      {:error, _} ->
        false
    end
  end
end
