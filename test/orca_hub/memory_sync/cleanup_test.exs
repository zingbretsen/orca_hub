defmodule OrcaHub.MemorySync.CleanupTest do
  @moduledoc """
  `OrcaHub.MemorySync.Cleanup.run/1` against a tmp-dir home (same fixture
  convention as `OrcaHub.MemoryGitTest`) — never touches a real home.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.MemoryGit
  alias OrcaHub.MemorySync.Cleanup

  setup do
    home = tmp_home()
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp tmp_home do
    path =
      Path.join(
        System.tmp_dir!(),
        "memory_sync_cleanup_home_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp codex_dir(home), do: MemoryGit.codex_memories_dir(home_dir: home)
  defp claude_home(home), do: MemoryGit.claude_home_dir(home_dir: home)

  test "deletes claude--*.md mirror files from ~/.codex/memories", %{home: home} do
    dir = codex_dir(home)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "claude--proj1--foo.md"), "mirror 1")
    File.write!(Path.join(dir, "claude--proj2--bar.md"), "mirror 2")
    File.write!(Path.join(dir, "native.md"), "not a mirror")

    result = Cleanup.run(home_dir: home)

    assert result.mirrors_deleted == 2
    refute File.exists?(Path.join(dir, "claude--proj1--foo.md"))
    refute File.exists?(Path.join(dir, "claude--proj2--bar.md"))
    assert File.exists?(Path.join(dir, "native.md"))
  end

  test "deletes ~/.claude/memories-from-codex.md", %{home: home} do
    dir = claude_home(home)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "memories-from-codex.md"), "generated content")

    result = Cleanup.run(home_dir: home)

    assert result.generated_file_deleted
    refute File.exists?(Path.join(dir, "memories-from-codex.md"))
  end

  test "removes the import marker + line from CLAUDE.md, leaving the rest intact", %{home: home} do
    dir = claude_home(home)
    File.mkdir_p!(dir)

    content = """
    ## Some existing section

    Existing content here.

    <!-- orca-sync: import generated Codex memories (do not remove) -->
    @~/.claude/memories-from-codex.md
    """

    File.write!(Path.join(dir, "CLAUDE.md"), content)

    result = Cleanup.run(home_dir: home)

    assert result.claude_md_updated
    new_content = File.read!(Path.join(dir, "CLAUDE.md"))
    refute new_content =~ "orca-sync: import"
    refute new_content =~ "@~/.claude/memories-from-codex.md"
    assert new_content =~ "Existing content here."
  end

  test "is idempotent — a second run finds nothing left to do", %{home: home} do
    codex = codex_dir(home)
    claude = claude_home(home)
    File.mkdir_p!(codex)
    File.mkdir_p!(claude)
    File.write!(Path.join(codex, "claude--proj1--foo.md"), "mirror")
    File.write!(Path.join(claude, "memories-from-codex.md"), "generated")

    File.write!(
      Path.join(claude, "CLAUDE.md"),
      "notes\n\n<!-- orca-sync: import generated Codex memories (do not remove) -->\n@~/.claude/memories-from-codex.md\n"
    )

    assert %{mirrors_deleted: 1, generated_file_deleted: true, claude_md_updated: true} =
             Cleanup.run(home_dir: home)

    assert %{mirrors_deleted: 0, generated_file_deleted: false, claude_md_updated: false} =
             Cleanup.run(home_dir: home)
  end

  test "no-ops cleanly when none of the target files/dirs exist", %{home: home} do
    assert %{mirrors_deleted: 0, generated_file_deleted: false, claude_md_updated: false} =
             Cleanup.run(home_dir: home)
  end
end
