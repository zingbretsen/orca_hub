defmodule OrcaHub.MemorySyncTest do
  @moduledoc """
  `OrcaHub.MemorySync.sync/1` — the pure mechanical mirror pass, called
  directly against a tmp-dir home (same fixture convention as
  `OrcaHub.MemoryGitTest`). Never goes through `OrcaHub.MemoryGit.Server`
  (disabled entirely in `config/test.exs`).
  """
  use ExUnit.Case, async: true

  alias OrcaHub.{MemoryGit, MemorySync}

  setup do
    home = tmp_home()
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp tmp_home do
    path = Path.join(System.tmp_dir!(), "memory_sync_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp claude_dir(home), do: MemoryGit.claude_projects_dir(home_dir: home)
  defp codex_dir(home), do: MemoryGit.codex_memories_dir(home_dir: home)
  defp claude_home(home), do: MemoryGit.claude_home_dir(home_dir: home)

  defp write_claude_memory(home, slug, filename, content) do
    dir = Path.join([claude_dir(home), slug, "memory"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
  end

  defp write_codex_memory(home, filename, content) do
    dir = codex_dir(home)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
  end

  defp sync(home), do: MemorySync.sync(home_dir: home)

  # ---------------------------------------------------------------------
  # Claude -> Codex
  # ---------------------------------------------------------------------

  describe "Claude -> Codex mirroring" do
    test "mirrors a project memory file, prefixed with a provenance marker", %{home: home} do
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")

      assert %{codex_changed: true} = sync(home)

      mirror_path = Path.join(codex_dir(home), "claude--proj1--foo.md")
      assert File.exists?(mirror_path)
      content = File.read!(mirror_path)
      assert content =~ "<!-- orca-sync source=claude project=proj1 file=foo.md -->"
      assert content =~ "Foo body."
    end

    test "skips MEMORY.md (the project index)", %{home: home} do
      write_claude_memory(home, "proj1", "MEMORY.md", "- index")
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")

      sync(home)

      refute File.exists?(Path.join(codex_dir(home), "claude--proj1--MEMORY.md"))
      assert File.exists?(Path.join(codex_dir(home), "claude--proj1--foo.md"))
    end

    test "mirrors across multiple projects", %{home: home} do
      write_claude_memory(home, "proj1", "a.md", "A")
      write_claude_memory(home, "proj2", "b.md", "B")

      sync(home)

      assert File.exists?(Path.join(codex_dir(home), "claude--proj1--a.md"))
      assert File.exists?(Path.join(codex_dir(home), "claude--proj2--b.md"))
    end

    test "second sync with no changes reports codex_changed: false", %{home: home} do
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")
      sync(home)

      assert %{codex_changed: false} = sync(home)
    end

    test "deletion propagation: removing the source file deletes the mirror", %{home: home} do
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")
      sync(home)
      mirror_path = Path.join(codex_dir(home), "claude--proj1--foo.md")
      assert File.exists?(mirror_path)

      File.rm!(Path.join([claude_dir(home), "proj1", "memory", "foo.md"]))
      assert %{codex_changed: true} = sync(home)

      refute File.exists?(mirror_path)
    end

    test "a project-memory file already carrying a provenance tag is never a source", %{
      home: home
    } do
      write_claude_memory(
        home,
        "proj1",
        "already-mirrored.md",
        "<!-- orca-sync source=codex file=x.md -->\n\nsome content"
      )

      sync(home)

      refute File.exists?(Path.join(codex_dir(home), "claude--proj1--already-mirrored.md"))
    end
  end

  # ---------------------------------------------------------------------
  # Codex -> Claude
  # ---------------------------------------------------------------------

  describe "Codex -> Claude compilation" do
    test "compiles native Codex files into one generated file", %{home: home} do
      write_codex_memory(home, "raw_memories.md", "Raw memory content.")
      write_codex_memory(home, "memory_summary.md", "Summary content.")

      assert %{claude_changed: true} = sync(home)

      generated = File.read!(Path.join(claude_home(home), "memories-from-codex.md"))
      assert generated =~ "GENERATED from ~/.codex/memories"
      assert generated =~ "## raw_memories.md"
      assert generated =~ "Raw memory content."
      assert generated =~ "## memory_summary.md"
      assert generated =~ "Summary content."
    end

    test "ensures the CLAUDE.md import line, appended once with a marker", %{home: home} do
      write_codex_memory(home, "raw_memories.md", "content")

      sync(home)

      claude_md = File.read!(Path.join(claude_home(home), "CLAUDE.md"))
      assert claude_md =~ "@~/.claude/memories-from-codex.md"
      assert claude_md =~ "orca-sync: import generated Codex memories"
    end

    test "never touches pre-existing CLAUDE.md content, only appends once", %{home: home} do
      File.mkdir_p!(claude_home(home))

      File.write!(
        Path.join(claude_home(home), "CLAUDE.md"),
        "# My instructions\n\nDo the thing.\n"
      )

      write_codex_memory(home, "raw_memories.md", "content")

      sync(home)
      first = File.read!(Path.join(claude_home(home), "CLAUDE.md"))
      assert first =~ "# My instructions"
      assert first =~ "Do the thing."
      assert first =~ "@~/.claude/memories-from-codex.md"

      # Idempotent: running again doesn't duplicate the import line.
      write_codex_memory(home, "another.md", "more")
      sync(home)
      second = File.read!(Path.join(claude_home(home), "CLAUDE.md"))
      assert Enum.count(String.split(second, "@~/.claude/memories-from-codex.md")) == 2
      assert second |> String.split("# My instructions") |> length() == 2
    end

    test "deletion propagation: a removed Codex file drops out of the regenerated file", %{
      home: home
    } do
      write_codex_memory(home, "raw_memories.md", "content")
      sync(home)
      generated_path = Path.join(claude_home(home), "memories-from-codex.md")
      assert File.read!(generated_path) =~ "raw_memories.md"

      File.rm!(Path.join(codex_dir(home), "raw_memories.md"))
      sync(home)

      refute File.read!(generated_path) =~ "raw_memories.md"
    end

    test "a Codex file already carrying a provenance tag is never a source", %{home: home} do
      write_codex_memory(
        home,
        "weird.md",
        "<!-- orca-sync source=claude project=x file=y.md -->\n\nbody"
      )

      sync(home)

      refute File.read!(Path.join(claude_home(home), "memories-from-codex.md")) =~ "weird.md"
    end
  end

  # ---------------------------------------------------------------------
  # Loop prevention
  # ---------------------------------------------------------------------

  describe "loop prevention" do
    test "a Claude->Codex mirror is never picked up as a Codex-native source", %{home: home} do
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")
      sync(home)
      assert File.exists?(Path.join(codex_dir(home), "claude--proj1--foo.md"))

      # Second pass: the mirror must not appear in the generated Codex->Claude file.
      sync(home)
      generated = File.read!(Path.join(claude_home(home), "memories-from-codex.md"))
      refute generated =~ "claude--proj1--foo.md"
      refute generated =~ "Foo body."
    end

    test "repeated syncs converge (no runaway mirror growth)", %{home: home} do
      write_claude_memory(home, "proj1", "foo.md", "Foo body.")
      write_codex_memory(home, "native.md", "Native body.")

      sync(home)
      sync(home)
      sync(home)

      codex_files = File.ls!(codex_dir(home)) |> Enum.sort()
      assert codex_files == ["claude--proj1--foo.md", "native.md"]
    end
  end
end
