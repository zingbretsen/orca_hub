defmodule OrcaHub.SkillSyncTest do
  @moduledoc """
  Coverage for `OrcaHub.SkillSync.sync/1` — the pure materialization pass,
  called directly (never via the GenServer, which is disabled entirely in
  `config/test.exs`; see that module's moduledoc). Always exercised against
  a tmp-dir home, same fixture convention as `OrcaHub.NodeConfigTest`.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.SkillSync

  setup do
    home = Path.join(System.tmp_dir!(), "skill_sync_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    {:ok, home: home}
  end

  defp skill(attrs) do
    Map.merge(
      %{
        name: "some-skill",
        description: "desc",
        body: "Body text.",
        enabled: true,
        backends: ["claude", "codex", "pi"]
      },
      attrs
    )
  end

  defp sync_all(home, skills, backends \\ [:claude, :codex, :pi]) do
    SkillSync.sync(
      home_dir: home,
      backends: backends,
      cli_installed?: fn _ -> true end,
      skills: skills
    )
  end

  defp skill_md_path(home, backend, name) do
    Path.join([home, home_dirname(backend), "skills", name, "SKILL.md"])
  end

  defp home_dirname(:claude), do: ".claude"
  defp home_dirname(:codex), do: ".codex"
  defp home_dirname(:pi), do: ".pi/agent"

  defp manifest_path(home, backend) do
    Path.join([home, home_dirname(backend), "skills", ".orca-managed.json"])
  end

  defp read_manifest_skills(home, backend) do
    case File.read(manifest_path(home, backend)) do
      {:ok, content} -> Jason.decode!(content)["skills"]
      {:error, :enoent} -> %{}
    end
  end

  describe "sync/1 basic materialization" do
    test "writes SKILL.md with rendered frontmatter for every installed backend", %{home: home} do
      s = skill(%{name: "my-skill", description: "Use when: doing X", body: "Do the thing.\n"})
      :ok = sync_all(home, [s])

      for backend <- [:claude, :codex, :pi] do
        path = skill_md_path(home, backend, "my-skill")
        assert File.regular?(path)
        content = File.read!(path)

        assert content ==
                 "---\nname: \"my-skill\"\ndescription: \"Use when: doing X\"\n---\n\nDo the thing.\n"
      end
    end

    test "only materializes into backends the skill targets", %{home: home} do
      s = skill(%{name: "claude-only", backends: ["claude"]})
      :ok = sync_all(home, [s])

      assert File.regular?(skill_md_path(home, :claude, "claude-only"))
      refute File.exists?(skill_md_path(home, :codex, "claude-only"))
      refute File.exists?(skill_md_path(home, :pi, "claude-only"))
    end

    test "only syncs backends deemed installed", %{home: home} do
      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:claude])

      assert File.regular?(skill_md_path(home, :claude, "my-skill"))
      refute File.exists?(Path.join([home, ".codex", "skills"]))
      refute File.exists?(Path.join([home, ".pi"]))
    end

    test "skips disabled skills", %{home: home} do
      s = skill(%{name: "off-skill", enabled: false})
      :ok = sync_all(home, [s])

      refute File.exists?(skill_md_path(home, :claude, "off-skill"))
    end

    test "records written skills in the ownership manifest", %{home: home} do
      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:claude])

      manifest = manifest_path(home, :claude) |> File.read!() |> Jason.decode!()
      assert %{"my-skill" => sha} = manifest["skills"]
      assert is_binary(sha) and byte_size(sha) == 64
    end

    test "escapes YAML-unsafe characters in the description", %{home: home} do
      s = skill(%{name: "my-skill", description: ~s(has "quotes", a: colon, and \\backslash)})
      :ok = sync_all(home, [s], [:claude])

      content = File.read!(skill_md_path(home, :claude, "my-skill"))
      assert content =~ ~s(description: "has \\"quotes\\", a: colon, and \\\\backslash")

      # round-trips as valid YAML frontmatter (sanity check via a minimal parse)
      [_, frontmatter, _body] = String.split(content, "---\n", parts: 3)
      assert frontmatter =~ "colon"
    end
  end

  describe "sync/1 collision protection" do
    test "skips and does not clobber an unmanaged pre-existing skill dir", %{home: home} do
      dir = Path.join([home, ".claude", "skills", "hand-made"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "hand-written content, do not touch")

      s = skill(%{name: "hand-made", body: "hub content"})
      :ok = sync_all(home, [s], [:claude])

      assert File.read!(Path.join(dir, "SKILL.md")) == "hand-written content, do not touch"
      refute Map.has_key?(read_manifest_skills(home, :claude), "hand-made")
    end

    test "re-writes a dir it already manages (no false collision on its own writes)", %{
      home: home
    } do
      s1 = skill(%{name: "my-skill", body: "v1"})
      :ok = sync_all(home, [s1], [:claude])

      s2 = skill(%{name: "my-skill", body: "v2"})
      :ok = sync_all(home, [s2], [:claude])

      assert File.read!(skill_md_path(home, :claude, "my-skill")) =~ "v2"
    end
  end

  describe "sync/1 removal" do
    test "disabling a skill removes its managed dir and manifest entry", %{home: home} do
      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:claude])
      assert File.exists?(skill_md_path(home, :claude, "my-skill"))

      disabled = skill(%{name: "my-skill", enabled: false})
      :ok = sync_all(home, [disabled], [:claude])

      refute File.exists?(Path.dirname(skill_md_path(home, :claude, "my-skill")))
      manifest = manifest_path(home, :claude) |> File.read!() |> Jason.decode!()
      refute Map.has_key?(manifest["skills"], "my-skill")
    end

    test "a skill no longer present in the DB set is removed on next sync", %{home: home} do
      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:claude])
      assert File.exists?(skill_md_path(home, :claude, "my-skill"))

      :ok = sync_all(home, [], [:claude])

      refute File.exists?(Path.dirname(skill_md_path(home, :claude, "my-skill")))
    end

    test "un-targeting a backend removes the managed dir there only", %{home: home} do
      s = skill(%{name: "my-skill", backends: ["claude", "codex"]})
      :ok = sync_all(home, [s])
      assert File.exists?(skill_md_path(home, :claude, "my-skill"))
      assert File.exists?(skill_md_path(home, :codex, "my-skill"))

      narrowed = skill(%{name: "my-skill", backends: ["claude"]})
      :ok = sync_all(home, [narrowed])

      assert File.exists?(skill_md_path(home, :claude, "my-skill"))
      refute File.exists?(Path.dirname(skill_md_path(home, :codex, "my-skill")))
    end
  end

  describe "managed_skill_names/2" do
    test "returns the manifest's skill names for that backend", %{home: home} do
      s1 = skill(%{name: "my-skill"})
      s2 = skill(%{name: "other-skill"})
      :ok = sync_all(home, [s1, s2], [:claude])

      assert SkillSync.managed_skill_names(:claude, home_dir: home) ==
               MapSet.new(["my-skill", "other-skill"])
    end

    test "is empty for a backend with no manifest yet", %{home: home} do
      assert SkillSync.managed_skill_names(:codex, home_dir: home) == MapSet.new()
    end

    test "excludes an unmanaged hand-made dir the manifest never listed", %{home: home} do
      dir = Path.join([home, ".claude", "skills", "hand-made"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "hand-written")

      s = skill(%{name: "managed-skill"})
      :ok = sync_all(home, [s], [:claude])

      names = SkillSync.managed_skill_names(:claude, home_dir: home)
      assert MapSet.member?(names, "managed-skill")
      refute MapSet.member?(names, "hand-made")
    end
  end

  describe "sync/1 leaves unrelated directories alone" do
    test "never touches an unmanaged dir it doesn't target", %{home: home} do
      other_dir = Path.join([home, ".claude", "skills", "unrelated"])
      File.mkdir_p!(other_dir)
      File.write!(Path.join(other_dir, "SKILL.md"), "unrelated content")

      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:claude])

      assert File.read!(Path.join(other_dir, "SKILL.md")) == "unrelated content"
    end

    test "never touches a dot-prefixed vendor dir (Codex's skills/.system/)", %{home: home} do
      vendor_dir = Path.join([home, ".codex", "skills", ".system", "plugin-creator"])
      File.mkdir_p!(vendor_dir)
      File.write!(Path.join(vendor_dir, "SKILL.md"), "vendor content")

      s = skill(%{name: "my-skill"})
      :ok = sync_all(home, [s], [:codex])

      assert File.read!(Path.join(vendor_dir, "SKILL.md")) == "vendor content"
      manifest = manifest_path(home, :codex) |> File.read!() |> Jason.decode!()
      refute Map.has_key?(manifest["skills"], ".system")
    end
  end
end
