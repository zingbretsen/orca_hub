defmodule OrcaHub.MemorySync do
  @moduledoc """
  Mechanical (no LLM) bidirectional mirror between the two per-node memory
  stores `OrcaHub.MemoryGit` snapshots, run right after a snapshot pass by
  `OrcaHub.MemoryGit.Server`.

  **Claude → Codex**: every project's `~/.claude/projects/<slug>/memory/<name>.md`
  (skipping the `MEMORY.md` index and anything already provenance-tagged)
  mirrors to `~/.codex/memories/claude--<slug>--<name>.md`, prefixed with a
  leading HTML-comment provenance marker. A source file's deletion deletes
  its mirror (mirrors not in the freshly-computed desired set are removed).

  **Codex → Claude**: every Codex-native file directly under
  `~/.codex/memories/` (not `claude--*`, not provenance-tagged — i.e. not
  one of our own mirrors) is compiled wholesale into one generated file,
  `~/.claude/memories-from-codex.md`, fully regenerated on every sync (so
  a deleted Codex memory just falls out of the next regeneration — no
  separate deletion-tracking needed). `~/.claude/CLAUDE.md` is then
  idempotently given an `@`-import line pointing at it, appended once with
  a marker comment if missing; the rest of the file is never touched.

  **Loop prevention is by construction**, not a special case: a
  provenance-tagged file is never treated as a sync source in either
  direction, and the generated `memories-from-codex.md` lives outside both
  `~/.claude/projects/**` and the Codex mirror-source scan, so it can never
  itself become a source.

  All paths are injectable the same way as `OrcaHub.MemoryGit` (`:home_dir`
  opt / `:orca_hub, :memory_git_home` app env) — see that module's
  moduledoc.
  """

  alias OrcaHub.MemoryGit

  @provenance_prefix "<!-- orca-sync"
  @codex_mirror_prefix "claude--"
  @generated_filename "memories-from-codex.md"

  @generated_header """
  <!-- orca-sync: GENERATED from ~/.codex/memories — do not hand-edit, edit the source Codex memory file instead. Regenerated in full on every sync. -->

  # Codex memories
  """

  @import_marker "<!-- orca-sync: import generated Codex memories (do not remove) -->"
  @import_line "@~/.claude/memories-from-codex.md"

  @doc """
  Runs one full sync pass in both directions. Returns
  `%{codex_changed: boolean, claude_changed: boolean}` — `codex_changed?`
  tells the caller whether `~/.codex/memories` (a git-tracked dir) has new
  work to commit; `claude_changed?` is informational only, since
  `~/.claude/memories-from-codex.md` and `~/.claude/CLAUDE.md` both live
  outside the git-tracked `~/.claude/projects`.
  """
  def sync(opts \\ []) do
    %{
      codex_changed: sync_claude_to_codex(opts),
      claude_changed: sync_codex_to_claude(opts)
    }
  end

  # -------------------------------------------------------------------
  # Claude -> Codex
  # -------------------------------------------------------------------

  defp sync_claude_to_codex(opts) do
    claude_root = MemoryGit.claude_projects_dir(opts)
    codex_dir = MemoryGit.codex_memories_dir(opts)
    File.mkdir_p!(codex_dir)

    desired = desired_mirrors(claude_root)
    existing = existing_mirror_filenames(codex_dir)

    wrote? = write_mirrors(codex_dir, desired)
    deleted? = delete_stale_mirrors(codex_dir, existing, Map.keys(desired))

    wrote? or deleted?
  end

  defp write_mirrors(codex_dir, desired) do
    Enum.reduce(desired, false, fn {filename, content}, changed? ->
      path = Path.join(codex_dir, filename)

      case File.read(path) do
        {:ok, ^content} ->
          changed?

        _ ->
          File.write!(path, content)
          true
      end
    end)
  end

  defp delete_stale_mirrors(codex_dir, existing, desired_filenames) do
    stale = existing -- desired_filenames

    Enum.each(stale, fn filename -> File.rm!(Path.join(codex_dir, filename)) end)

    stale != []
  end

  # %{"claude--<slug>--<name>.md" => mirror_content}, across every project.
  defp desired_mirrors(claude_root) do
    case File.ls(claude_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(claude_root, &1)))
        |> Enum.flat_map(&project_mirrors(claude_root, &1))
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp project_mirrors(claude_root, slug) do
    memory_dir = Path.join([claude_root, slug, "memory"])

    case File.ls(memory_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != "MEMORY.md"))
        |> Enum.map(fn name -> {name, File.read!(Path.join(memory_dir, name))} end)
        |> Enum.reject(fn {_name, content} -> provenance_tagged?(content) end)
        |> Enum.map(fn {name, content} ->
          {"#{@codex_mirror_prefix}#{slug}--#{name}", mirror_content(slug, name, content)}
        end)

      {:error, _} ->
        []
    end
  end

  defp mirror_content(slug, name, content) do
    "#{@provenance_prefix} source=claude project=#{slug} file=#{name} -->\n\n" <> content
  end

  defp existing_mirror_filenames(codex_dir) do
    case File.ls(codex_dir) do
      {:ok, entries} ->
        Enum.filter(entries, fn name ->
          String.starts_with?(name, @codex_mirror_prefix) and
            File.regular?(Path.join(codex_dir, name))
        end)

      {:error, _} ->
        []
    end
  end

  # -------------------------------------------------------------------
  # Codex -> Claude
  # -------------------------------------------------------------------

  defp sync_codex_to_claude(opts) do
    codex_dir = MemoryGit.codex_memories_dir(opts)
    claude_home = MemoryGit.claude_home_dir(opts)
    File.mkdir_p!(claude_home)

    generated = render_generated_file(native_codex_memories(codex_dir))
    target = Path.join(claude_home, @generated_filename)

    changed? =
      case File.read(target) do
        {:ok, ^generated} ->
          false

        _ ->
          File.write!(target, generated)
          true
      end

    ensure_claude_md_import(claude_home)

    changed?
  end

  defp native_codex_memories(codex_dir) do
    case File.ls(codex_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          String.ends_with?(name, ".md") and
            not String.starts_with?(name, @codex_mirror_prefix) and
            File.regular?(Path.join(codex_dir, name))
        end)
        |> Enum.sort()
        |> Enum.map(fn name -> {name, File.read!(Path.join(codex_dir, name))} end)
        |> Enum.reject(fn {_name, content} -> provenance_tagged?(content) end)

      {:error, _} ->
        []
    end
  end

  defp render_generated_file(native) do
    sections = Enum.map(native, fn {name, content} -> "\n## #{name}\n\n#{content}" end)
    @generated_header <> Enum.join(sections)
  end

  defp ensure_claude_md_import(claude_home) do
    path = Path.join(claude_home, "CLAUDE.md")

    case File.read(path) do
      {:ok, content} ->
        unless String.contains?(content, @import_line) do
          separator = if String.ends_with?(content, "\n"), do: "\n", else: "\n\n"

          File.write!(
            path,
            content <> separator <> @import_marker <> "\n" <> @import_line <> "\n"
          )
        end

      {:error, _} ->
        File.write!(path, @import_marker <> "\n" <> @import_line <> "\n")
    end
  end

  # -------------------------------------------------------------------
  # Shared
  # -------------------------------------------------------------------

  defp provenance_tagged?(content) do
    String.starts_with?(String.trim_leading(content), @provenance_prefix)
  end
end
