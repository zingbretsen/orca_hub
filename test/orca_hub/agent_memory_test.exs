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

    test "list/save/delete round-trip, skipping unknown subdirs and sqlite files", %{opts: opts} do
      dir = AgentMemory.codex_memories_dir(opts)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "note.md"), "A codex memory note.")
      File.mkdir_p!(Path.join(dir, "a_subdir"))
      File.write!(Path.join(dir, "state.sqlite"), "binary junk")

      assert {:ok, [%{filename: "note.md", group: nil, content: "A codex memory note."}]} =
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

    test "canonical files sort first in a fixed order, then other flat files alphabetically", %{
      opts: opts
    } do
      dir = AgentMemory.codex_memories_dir(opts)
      File.mkdir_p!(dir)
      # Written out of order on purpose, to prove the sort isn't accidental.
      File.write!(Path.join(dir, "raw_memories.md"), "raw")
      File.write!(Path.join(dir, "zzz_other.md"), "z")
      File.write!(Path.join(dir, "aaa_other.md"), "a")
      File.write!(Path.join(dir, "MEMORY.md"), "index")
      File.write!(Path.join(dir, "memory_summary.md"), "summary")

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)

      assert Enum.map(files, & &1.filename) == [
               "MEMORY.md",
               "memory_summary.md",
               "raw_memories.md",
               "aaa_other.md",
               "zzz_other.md"
             ]
    end

    test "includes flat subdirectories one level deep, grouped, ordered after flat files", %{
      opts: opts
    } do
      dir = AgentMemory.codex_memories_dir(opts)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "MEMORY.md"), "index")

      rollout_dir = Path.join(dir, "rollout_summaries")
      File.mkdir_p!(rollout_dir)
      File.write!(Path.join(rollout_dir, "2026-07-08.md"), "rollout summary body")
      File.write!(Path.join(rollout_dir, "2026-07-09.md"), "another rollout summary")

      skills_dir = Path.join(dir, "skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "my-skill.md"), "skill body")

      # Nested one level further should not be picked up (rollout_summaries
      # and skills are flat, unlike extensions/).
      File.mkdir_p!(Path.join(rollout_dir, "nested"))
      File.write!(Path.join(rollout_dir, "nested/too-deep.md"), "should not appear")

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)

      assert [memory_md, rollout1, rollout2, skill] = files
      assert memory_md.filename == "MEMORY.md"
      assert memory_md.group == nil

      assert rollout1.filename == "rollout_summaries/2026-07-08.md"
      assert rollout1.group == "rollout_summaries"
      assert rollout1.content == "rollout summary body"

      assert rollout2.filename == "rollout_summaries/2026-07-09.md"
      assert rollout2.group == "rollout_summaries"

      assert skill.filename == "skills/my-skill.md"
      assert skill.group == "skills"
    end

    test "includes extensions/<name>/<file> two levels deep, grouped as 'extensions'", %{
      opts: opts
    } do
      dir = AgentMemory.codex_memories_dir(opts)
      ad_hoc_dir = Path.join([dir, "extensions", "ad_hoc"])
      File.mkdir_p!(ad_hoc_dir)
      File.write!(Path.join(ad_hoc_dir, "instructions.md"), "Ad-hoc extension notes.")

      # A bare file directly under extensions/ (no extension-name level)
      # doesn't match the confirmed real shape and must be skipped.
      File.write!(Path.join(dir, "extensions") |> Path.join("stray.md"), "stray")

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)

      assert [%{filename: "extensions/ad_hoc/instructions.md", group: "extensions"} = entry] =
               files

      assert entry.content == "Ad-hoc extension notes."
    end

    test "reads/saves/deletes files inside flat subdirectories", %{opts: opts} do
      assert :ok =
               AgentMemory.save_codex_memory(
                 "rollout_summaries/session-1.md",
                 "Summary body.",
                 opts
               )

      assert {:ok, "Summary body."} =
               AgentMemory.read_codex_memory("rollout_summaries/session-1.md", opts)

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)
      assert [%{filename: "rollout_summaries/session-1.md", group: "rollout_summaries"}] = files

      assert :ok = AgentMemory.delete_codex_memory("rollout_summaries/session-1.md", opts)
      assert {:ok, []} = AgentMemory.list_codex_memories(opts)
    end

    test "reads/saves/deletes files inside extensions/<name>/", %{opts: opts} do
      assert :ok =
               AgentMemory.save_codex_memory(
                 "extensions/ad_hoc/instructions.md",
                 "Notes.",
                 opts
               )

      assert {:ok, "Notes."} =
               AgentMemory.read_codex_memory("extensions/ad_hoc/instructions.md", opts)

      assert {:ok, files} = AgentMemory.list_codex_memories(opts)
      assert [%{filename: "extensions/ad_hoc/instructions.md", group: "extensions"}] = files

      assert :ok = AgentMemory.delete_codex_memory("extensions/ad_hoc/instructions.md", opts)
      assert {:ok, []} = AgentMemory.list_codex_memories(opts)
    end

    test "rejects unknown subdirs, deeper nesting, and absolute paths for subdir paths", %{
      opts: opts
    } do
      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("unknown_subdir/file.md", "x", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("rollout_summaries/nested/file.md", "x", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("rollout_summaries/../MEMORY.md", "x", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.read_codex_memory("/etc/passwd", opts)

      # extensions/ requires exactly the <name>/<file> shape.
      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("extensions/stray.md", "x", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("extensions/ad_hoc/nested/too-deep.md", "x", opts)

      assert {:error, :unsafe_filename} =
               AgentMemory.save_codex_memory("extensions/../MEMORY.md", "x", opts)
    end
  end

  describe "codex_memories_enabled?/1" do
    test "false when ~/.codex/config.toml doesn't exist", %{opts: opts} do
      refute AgentMemory.codex_memories_enabled?(opts)
    end

    test "false when the config file exists but has no [features] table", %{
      home: home,
      opts: opts
    } do
      codex_dir = Path.join(home, ".codex")
      File.mkdir_p!(codex_dir)
      File.write!(Path.join(codex_dir, "config.toml"), "personality = \"pragmatic\"\n")

      refute AgentMemory.codex_memories_enabled?(opts)
    end

    test "false when [features] exists but memories isn't true", %{home: home, opts: opts} do
      codex_dir = Path.join(home, ".codex")
      File.mkdir_p!(codex_dir)

      File.write!(Path.join(codex_dir, "config.toml"), """
      [features]
      memories = false
      """)

      refute AgentMemory.codex_memories_enabled?(opts)
    end

    test "true when [features]\\nmemories = true is present", %{home: home, opts: opts} do
      codex_dir = Path.join(home, ".codex")
      File.mkdir_p!(codex_dir)

      File.write!(Path.join(codex_dir, "config.toml"), """
      personality = "pragmatic"

      [projects."/home/zach/orca_hub"]
      trust_level = "trusted"

      [features]
      memories = true
      """)

      assert AgentMemory.codex_memories_enabled?(opts)
    end

    test "doesn't leak a flag from a later table with the same key name", %{
      home: home,
      opts: opts
    } do
      codex_dir = Path.join(home, ".codex")
      File.mkdir_p!(codex_dir)

      File.write!(Path.join(codex_dir, "config.toml"), """
      [features]
      memories = false

      [other]
      memories = true
      """)

      refute AgentMemory.codex_memories_enabled?(opts)
    end
  end
end
