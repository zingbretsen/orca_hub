defmodule OrcaHub.AgentMemoryTest do
  # Uses only tmp-dir fixtures (never the real ~/.claude or ~/.codex), so
  # this is safe to run async alongside everything else.
  use ExUnit.Case, async: true

  alias OrcaHub.AgentMemory

  setup do
    home = Path.join(System.tmp_dir!(), "agent_memory_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    project_dir =
      Path.join(System.tmp_dir!(), "agent_memory_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(project_dir)
    on_exit(fn -> File.rm_rf(project_dir) end)

    {:ok, home: home, project_dir: project_dir, opts: [home_dir: home]}
  end

  describe "slugify/1" do
    test "replaces every non-alphanumeric char with -" do
      assert AgentMemory.slugify("/home/zach/orca_hub") == "-home-zach-orca-hub"
    end
  end

  describe "claude_memory_dir/2" do
    test "computes the slug-based path under the injected home", %{home: home} do
      assert AgentMemory.claude_memory_dir("/home/zach/orca_hub", home_dir: home) ==
               Path.join([home, ".claude", "projects", "-home-zach-orca-hub", "memory"])
    end
  end

  describe "list_claude_memories/2" do
    test "returns :no_memory_dir when the dir doesn't exist", %{project_dir: dir, opts: opts} do
      assert AgentMemory.list_claude_memories(dir, opts) == {:error, :no_memory_dir}
    end

    test "parses frontmatter, links, orphans, and dangling entries", %{
      project_dir: dir,
      opts: opts
    } do
      memory_dir = AgentMemory.claude_memory_dir(dir, opts)
      File.mkdir_p!(memory_dir)

      File.write!(Path.join(memory_dir, "foo.md"), """
      ---
      name: foo
      description: "A \\"quoted\\" description"
      metadata:
        node_type: memory
        type: feedback
        originSessionId: abc-123
      ---

      Body for foo, with a [[bar]] link.
      """)

      # Orphaned: exists on disk but not linked from the index.
      File.write!(Path.join(memory_dir, "orphan.md"), """
      ---
      name: orphan
      ---

      Nobody links to me.
      """)

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      # Memory Index

      - [foo.md](foo.md) - A quoted description
      - [missing.md](missing.md) - Dangling entry, file was deleted
      """)

      assert {:ok, result} = AgentMemory.list_claude_memories(dir, opts)

      assert result.dangling == ["missing.md"]
      assert result.orphaned == ["orphan.md"]

      assert [foo, orphan] = result.memories
      assert foo.filename == "foo.md"
      assert foo.name == "foo"
      assert foo.description == "A \"quoted\" description"
      assert foo.type == "feedback"
      assert foo.content =~ "Body for foo"

      assert orphan.filename == "orphan.md"
      assert orphan.name == "orphan"
    end

    test "falls back to the filename stem when frontmatter has no name", %{
      project_dir: dir,
      opts: opts
    } do
      memory_dir = AgentMemory.claude_memory_dir(dir, opts)
      File.mkdir_p!(memory_dir)
      File.write!(Path.join(memory_dir, "no-frontmatter.md"), "Just a body, no frontmatter.")

      assert {:ok, %{memories: [memory]}} = AgentMemory.list_claude_memories(dir, opts)
      assert memory.name == "no-frontmatter"
      assert memory.description == ""
      assert memory.type == nil
    end
  end

  describe "save_claude_memory/4 and delete_claude_memory/3" do
    test "save creates the memory dir and file if needed", %{project_dir: dir, opts: opts} do
      assert :ok =
               AgentMemory.save_claude_memory(dir, "new.md", "---\nname: new\n---\nBody", opts)

      memory_dir = AgentMemory.claude_memory_dir(dir, opts)
      assert File.read!(Path.join(memory_dir, "new.md")) == "---\nname: new\n---\nBody"
    end

    test "delete removes the file and its MEMORY.md index line", %{
      project_dir: dir,
      opts: opts
    } do
      memory_dir = AgentMemory.claude_memory_dir(dir, opts)
      File.mkdir_p!(memory_dir)
      File.write!(Path.join(memory_dir, "keep.md"), "---\nname: keep\n---\nKeep me.")
      File.write!(Path.join(memory_dir, "drop.md"), "---\nname: drop\n---\nDrop me.")

      File.write!(Path.join(memory_dir, "MEMORY.md"), """
      # Memory Index

      - [keep.md](keep.md) - Keep this one
      - [drop.md](drop.md) - Drop this one
      """)

      assert :ok = AgentMemory.delete_claude_memory(dir, "drop.md", opts)

      refute File.exists?(Path.join(memory_dir, "drop.md"))
      assert File.exists?(Path.join(memory_dir, "keep.md"))

      index = File.read!(Path.join(memory_dir, "MEMORY.md"))
      assert index =~ "keep.md"
      refute index =~ "drop.md"
    end

    test "rejects filenames that try to escape the memory dir", %{
      project_dir: dir,
      opts: opts
    } do
      assert {:error, :unsafe_filename} =
               AgentMemory.save_claude_memory(dir, "../../etc/passwd", "pwned", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.save_claude_memory(dir, "nested/path.md", "pwned", opts)

      assert {:error, :unsafe_filename} = AgentMemory.delete_claude_memory(dir, "..", opts)
      assert {:error, :unsafe_filename} = AgentMemory.delete_claude_memory(dir, "a/b.md", opts)
    end
  end

  describe "save_claude_index/3" do
    test "overwrites MEMORY.md raw content", %{project_dir: dir, opts: opts} do
      assert :ok = AgentMemory.save_claude_index(dir, "# Memory Index\n\n- nothing yet\n", opts)

      memory_dir = AgentMemory.claude_memory_dir(dir, opts)
      assert File.read!(Path.join(memory_dir, "MEMORY.md")) == "# Memory Index\n\n- nothing yet\n"
    end
  end

  describe "AGENTS.md project memory section" do
    @agents_md """
    # AGENTS

    Some preamble text.

    ## Project memory

    - First fact about the project.
    - Second fact about the project.

    ### A subsection under Project memory, not another top-level section

    - Not a memory bullet at the top level, but still inside the section since ### isn't ##.

    ## Another Section

    - Unrelated bullet, must never be touched.
    """

    test "list_agents_md_memories/1 returns :no_file when AGENTS.md is missing", %{
      project_dir: dir
    } do
      assert AgentMemory.list_agents_md_memories(dir) == :no_file
    end

    test "list_agents_md_memories/1 returns :no_section when the heading is missing", %{
      project_dir: dir
    } do
      File.write!(Path.join(dir, "AGENTS.md"), "# AGENTS\n\nNo project memory here.\n")
      assert AgentMemory.list_agents_md_memories(dir) == :no_section
    end

    test "list_agents_md_memories/1 returns bullets with stable indices", %{project_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), @agents_md)

      assert {:ok, bullets} = AgentMemory.list_agents_md_memories(dir)

      assert bullets == [
               %{index: 0, text: "First fact about the project."},
               %{index: 1, text: "Second fact about the project."},
               %{
                 index: 2,
                 text:
                   "Not a memory bullet at the top level, but still inside the section since ### isn't ##."
               }
             ]
    end

    test "update_agents_md_memory/3 rewrites only the targeted bullet, byte-for-byte elsewhere",
         %{
           project_dir: dir
         } do
      path = Path.join(dir, "AGENTS.md")
      File.write!(path, @agents_md)

      assert :ok = AgentMemory.update_agents_md_memory(dir, 1, "Updated second fact.")

      new_content = File.read!(path)
      assert new_content =~ "- Updated second fact."
      refute new_content =~ "Second fact about the project."

      # Everything else — including the unrelated section below — must be
      # byte-for-byte unchanged.
      expected =
        String.replace(
          @agents_md,
          "- Second fact about the project.",
          "- Updated second fact."
        )

      assert new_content == expected
    end

    test "update_agents_md_memory/3 collapses embedded newlines into spaces", %{project_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), @agents_md)

      assert :ok = AgentMemory.update_agents_md_memory(dir, 0, "Line one\nLine two")

      assert File.read!(Path.join(dir, "AGENTS.md")) =~ "- Line one Line two"
    end

    test "update_agents_md_memory/3 with an out-of-range index errors", %{project_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), @agents_md)
      assert {:error, :invalid_index} = AgentMemory.update_agents_md_memory(dir, 99, "nope")
    end

    test "delete_agents_md_memory/2 removes only the targeted bullet line", %{project_dir: dir} do
      path = Path.join(dir, "AGENTS.md")
      File.write!(path, @agents_md)

      assert :ok = AgentMemory.delete_agents_md_memory(dir, 0)

      new_content = File.read!(path)
      refute new_content =~ "First fact about the project."
      assert new_content =~ "Second fact about the project."
      assert new_content =~ "Unrelated bullet, must never be touched."

      expected = String.replace(@agents_md, "- First fact about the project.\n", "")
      assert new_content == expected
    end

    test "AGENTS.md operations never touch the unrelated section", %{project_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), @agents_md)

      assert :ok = AgentMemory.update_agents_md_memory(dir, 2, "Rewrote the subsection bullet.")

      content = File.read!(Path.join(dir, "AGENTS.md"))
      assert content =~ "- Unrelated bullet, must never be touched."
      assert content =~ "## Another Section"
    end
  end

  describe "codex native memories" do
    test "list_codex_memories/1 returns :not_enabled when the dir doesn't exist", %{opts: opts} do
      assert AgentMemory.list_codex_memories(opts) == {:error, :not_enabled}
    end

    test "list/save/delete round-trip, skipping subdirs and sqlite files", %{opts: opts} do
      dir = AgentMemory.codex_memories_dir(opts)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.md"), "A codex memory note.")
      File.mkdir_p!(Path.join(dir, "a_subdir"))
      File.write!(Path.join(dir, "state.sqlite"), "binary junk")

      assert {:ok, [%{filename: "note.md", content: "A codex memory note."}]} =
               AgentMemory.list_codex_memories(opts)

      assert :ok = AgentMemory.save_codex_memory("second.md", "Another note.", opts)

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)
      assert Enum.map(files, & &1.filename) == ["note.md", "second.md"]

      assert {:ok, "A codex memory note."} = AgentMemory.read_codex_memory("note.md", opts)

      assert :ok = AgentMemory.delete_codex_memory("note.md", opts)
      assert {:ok, [%{filename: "second.md"}]} = AgentMemory.list_codex_memories(opts)
    end

    test "rejects unsafe filenames on read/save/delete", %{opts: opts} do
      assert {:error, :unsafe_filename} = AgentMemory.read_codex_memory("../secret", opts)
      assert {:error, :unsafe_filename} = AgentMemory.save_codex_memory("a/b", "x", opts)
      assert {:error, :unsafe_filename} = AgentMemory.delete_codex_memory("..", opts)
    end
  end
end
