defmodule OrcaHub.NodeConfigTest do
  # Uses only tmp-dir fixtures (never a real ~/.claude, ~/.codex, or
  # ~/.pi/agent), so this is safe to run async alongside everything else.
  use ExUnit.Case, async: true

  alias OrcaHub.NodeConfig

  setup do
    home = Path.join(System.tmp_dir!(), "node_config_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    {:ok, home: home, opts: [home_dir: home]}
  end

  describe "home_root/2" do
    test "resolves each backend's home under the injected base", %{home: home} do
      assert NodeConfig.home_root(:claude, home_dir: home) == Path.join(home, ".claude")
      assert NodeConfig.home_root(:codex, home_dir: home) == Path.join(home, ".codex")
      assert NodeConfig.home_root(:pi, home_dir: home) == Path.join([home, ".pi", "agent"])
    end
  end

  describe "list_config/2" do
    test "reports every catalog entry as missing when nothing exists on disk", %{opts: opts} do
      result = NodeConfig.list_config(:claude, opts)

      assert result.backend == :claude
      assert Enum.all?(result.entries, &(&1.exists? == false))
      assert Enum.find(result.entries, &(&1.path == "skills")).children == []
    end

    test "flags a file as existing once written", %{home: home, opts: opts} do
      File.mkdir_p!(Path.join(home, ".claude"))
      File.write!(Path.join([home, ".claude", "CLAUDE.md"]), "hi")

      result = NodeConfig.list_config(:claude, opts)
      entry = Enum.find(result.entries, &(&1.path == "CLAUDE.md"))
      assert entry.exists?
    end

    test "lists flat dir children (agents/, commands/, rules/)", %{home: home, opts: opts} do
      dir = Path.join([home, ".claude", "agents"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "reviewer.md"), "---\nname: reviewer\n---\n")
      File.write!(Path.join(dir, "planner.md"), "---\nname: planner\n---\n")

      result = NodeConfig.list_config(:claude, opts)
      agents_entry = Enum.find(result.entries, &(&1.path == "agents"))

      assert agents_entry.exists?

      assert agents_entry.children == [
               %{name: "planner.md", path: "agents/planner.md"},
               %{name: "reviewer.md", path: "agents/reviewer.md"}
             ]
    end

    test "lists skill_dirs children keyed by subdirectory, with SKILL.md presence", %{
      home: home,
      opts: opts
    } do
      base = Path.join([home, ".claude", "skills"])
      File.mkdir_p!(Path.join(base, "reviewer"))
      File.write!(Path.join([base, "reviewer", "SKILL.md"]), "---\ndescription: x\n---\n")
      # A skill subdirectory that exists but has no SKILL.md yet.
      File.mkdir_p!(Path.join(base, "empty-skill"))

      result = NodeConfig.list_config(:claude, opts)
      skills_entry = Enum.find(result.entries, &(&1.path == "skills"))

      assert skills_entry.children == [
               %{name: "empty-skill", path: "skills/empty-skill/SKILL.md", exists?: false},
               %{name: "reviewer", path: "skills/reviewer/SKILL.md", exists?: true}
             ]
    end

    test "excludes dot-prefixed subdirectories from skills/ (Codex's vendor .system/)", %{
      home: home,
      opts: opts
    } do
      base = Path.join([home, ".codex", "skills"])
      File.mkdir_p!(Path.join(base, ".system"))
      File.write!(Path.join([base, ".system", "SKILL.md"]), "vendor skill")
      File.mkdir_p!(Path.join(base, "my-skill"))
      File.write!(Path.join([base, "my-skill", "SKILL.md"]), "mine")

      result = NodeConfig.list_config(:codex, opts)
      skills_entry = Enum.find(result.entries, &(&1.path == "skills"))

      assert skills_entry.children == [
               %{name: "my-skill", path: "skills/my-skill/SKILL.md", exists?: true}
             ]
    end

    test "flags codex AGENTS.override.md conflict only when both files exist", %{
      home: home,
      opts: opts
    } do
      codex_home = Path.join(home, ".codex")
      File.mkdir_p!(codex_home)

      refute NodeConfig.list_config(:codex, opts).agents_override_conflict?

      File.write!(Path.join(codex_home, "AGENTS.md"), "base")
      refute NodeConfig.list_config(:codex, opts).agents_override_conflict?

      File.write!(Path.join(codex_home, "AGENTS.override.md"), "override")
      assert NodeConfig.list_config(:codex, opts).agents_override_conflict?
    end

    test "pi's trust.json is flagged view_only", %{opts: opts} do
      result = NodeConfig.list_config(:pi, opts)
      trust_entry = Enum.find(result.entries, &(&1.path == "trust.json"))
      assert :view_only in trust_entry.flags
    end
  end

  describe "read_entry/3, write_entry/4, delete_entry/3" do
    test "write_entry creates parent directories (covers Create)", %{home: home, opts: opts} do
      assert :ok = NodeConfig.write_entry(:claude, "CLAUDE.md", "# hi\n", opts)
      assert File.read!(Path.join([home, ".claude", "CLAUDE.md"])) == "# hi\n"
    end

    test "write_entry creates a new flat dir child, including the dir itself", %{
      home: home,
      opts: opts
    } do
      assert :ok = NodeConfig.write_entry(:codex, "rules/style.md", "# Style\n", opts)
      assert File.read!(Path.join([home, ".codex", "rules", "style.md"])) == "# Style\n"
    end

    test "write_entry creates a new skill (skill_dirs child)", %{home: home, opts: opts} do
      assert :ok =
               NodeConfig.write_entry(
                 :pi,
                 "skills/my-skill/SKILL.md",
                 "---\nname: my-skill\n---\n",
                 opts
               )

      assert File.exists?(Path.join([home, ".pi", "agent", "skills", "my-skill", "SKILL.md"]))
    end

    test "round-trips read/write/delete for a catalog file", %{opts: opts} do
      assert :ok = NodeConfig.write_entry(:claude, "settings.json", "{}\n", opts)
      assert {:ok, "{}\n"} = NodeConfig.read_entry(:claude, "settings.json", opts)
      assert :ok = NodeConfig.delete_entry(:claude, "settings.json", opts)
      assert {:error, :enoent} = NodeConfig.read_entry(:claude, "settings.json", opts)
    end

    test "refuses to write or delete a view_only entry (pi trust.json)", %{opts: opts} do
      assert {:error, :view_only} = NodeConfig.write_entry(:pi, "trust.json", "{}", opts)
      assert {:error, :view_only} = NodeConfig.delete_entry(:pi, "trust.json", opts)
    end

    test "read_entry still allows viewing a view_only entry", %{home: home, opts: opts} do
      pi_home = Path.join(home, ".pi/agent")
      File.mkdir_p!(pi_home)
      File.write!(Path.join(pi_home, "trust.json"), ~s({"trusted":[]}))

      assert {:ok, ~s({"trusted":[]})} = NodeConfig.read_entry(:pi, "trust.json", opts)
    end
  end

  describe "hard blocklist" do
    test "refuses to read a blocked file even if it exists on disk", %{home: home, opts: opts} do
      claude_home = Path.join(home, ".claude")
      File.mkdir_p!(claude_home)
      File.write!(Path.join(claude_home, ".credentials.json"), ~s({"token":"secret"}))

      assert {:error, :blocked} = NodeConfig.read_entry(:claude, ".credentials.json", opts)
    end

    test "refuses to write a blocked file", %{opts: opts} do
      assert {:error, :blocked} = NodeConfig.write_entry(:codex, "auth.json", "{}", opts)
      assert {:error, :blocked} = NodeConfig.write_entry(:pi, "auth.json", "{}", opts)
    end

    test "blocked files never appear in list_config entries", %{home: home, opts: opts} do
      claude_home = Path.join(home, ".claude")
      File.mkdir_p!(claude_home)
      File.write!(Path.join(claude_home, ".credentials.json"), "secret")

      result = NodeConfig.list_config(:claude, opts)
      refute Enum.any?(result.entries, &(&1.path == ".credentials.json"))
    end
  end

  describe "path safety" do
    test "rejects .. traversal", %{opts: opts} do
      assert {:error, :unsafe_path} = NodeConfig.read_entry(:claude, "../../etc/passwd", opts)

      assert {:error, :unsafe_path} =
               NodeConfig.write_entry(:claude, "agents/../CLAUDE.md", "x", opts)
    end

    test "rejects absolute paths", %{opts: opts} do
      assert {:error, :unsafe_path} = NodeConfig.read_entry(:claude, "/etc/passwd", opts)
    end

    test "rejects unknown top-level paths", %{opts: opts} do
      assert {:error, :unknown_path} = NodeConfig.read_entry(:claude, "not-in-catalog.txt", opts)
    end

    test "rejects nested paths beyond a flat dir's one level", %{opts: opts} do
      assert {:error, :unknown_path} =
               NodeConfig.read_entry(:claude, "agents/nested/deep.md", opts)
    end

    test "rejects a skill_dirs child that isn't SKILL.md", %{opts: opts} do
      assert {:error, :unknown_path} =
               NodeConfig.read_entry(:claude, "skills/my-skill/notes.md", opts)
    end

    test "rejects reaching into a dot-prefixed subdirectory (vendor exclusion)", %{opts: opts} do
      assert {:error, :unsafe_path} =
               NodeConfig.read_entry(:codex, "skills/.system/plugin-creator/SKILL.md", opts)
    end
  end

  describe "cli_installed?/2" do
    test "returns a boolean and never raises for a known backend" do
      assert is_boolean(NodeConfig.cli_installed?(:claude))
      assert is_boolean(NodeConfig.cli_installed?(:codex))
      assert is_boolean(NodeConfig.cli_installed?(:pi))
    end
  end

  describe "create_directory/3" do
    test "creates a known catalog directory that doesn't exist yet", %{home: home, opts: opts} do
      assert :ok = NodeConfig.create_directory(:claude, "skills", opts)
      assert File.dir?(Path.join([home, ".claude", "skills"]))
    end

    test "refuses an unknown directory path", %{opts: opts} do
      assert {:error, :unknown_path} = NodeConfig.create_directory(:claude, "not-a-dir", opts)
    end
  end
end
