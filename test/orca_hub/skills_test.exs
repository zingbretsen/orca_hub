defmodule OrcaHub.SkillsTest do
  @moduledoc """
  Coverage for the hub-managed global skills context — CRUD, validation,
  and the `{:skills_updated}` PubSub broadcast that `OrcaHub.SkillSync`
  listens for. Materialization onto disk is covered in `OrcaHub.SkillSyncTest`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Skills
  alias OrcaHub.Skills.Skill

  setup do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "skills")
    :ok
  end

  describe "create_skill/1" do
    test "creates a skill with defaults" do
      assert {:ok, %Skill{} = skill} =
               Skills.create_skill(%{name: "my-skill", description: "does a thing"})

      assert skill.enabled
      assert skill.backends == ["claude", "codex", "pi"]
      assert_receive {:skills_updated}
    end

    test "requires a name" do
      assert {:error, changeset} = Skills.create_skill(%{description: "x"})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "rejects a non-kebab-case name" do
      for bad <- ["My Skill", "my_skill", "MySkill", "-leading", "trailing-", "has space"] do
        assert {:error, changeset} = Skills.create_skill(%{name: bad})
        assert errors_on(changeset).name != nil, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "accepts a valid kebab-case name" do
      assert {:ok, _} = Skills.create_skill(%{name: "a-1-b-2-skill"})
    end

    test "rejects an unknown backend" do
      assert {:error, changeset} =
               Skills.create_skill(%{name: "my-skill", backends: ["claude", "bogus"]})

      assert "has an invalid entry" in errors_on(changeset).backends
    end

    test "enforces unique names" do
      assert {:ok, _} = Skills.create_skill(%{name: "dup-skill"})
      assert {:error, changeset} = Skills.create_skill(%{name: "dup-skill"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "does not broadcast on a failed create" do
      assert {:error, _} = Skills.create_skill(%{})
      refute_receive {:skills_updated}
    end
  end

  describe "update_skill/2" do
    test "updates fields and broadcasts" do
      {:ok, skill} = Skills.create_skill(%{name: "my-skill"})
      assert_receive {:skills_updated}

      assert {:ok, updated} = Skills.update_skill(skill, %{enabled: false, backends: ["claude"]})
      refute updated.enabled
      assert updated.backends == ["claude"]
      assert_receive {:skills_updated}
    end
  end

  describe "delete_skill/1" do
    test "deletes and broadcasts" do
      {:ok, skill} = Skills.create_skill(%{name: "my-skill"})
      assert_receive {:skills_updated}

      assert {:ok, _} = Skills.delete_skill(skill)
      assert Skills.get_skill(skill.id) == nil
      assert_receive {:skills_updated}
    end
  end

  describe "list_skills/0 and list_enabled_skills/0" do
    test "list_enabled_skills/0 excludes disabled skills" do
      {:ok, enabled} = Skills.create_skill(%{name: "enabled-skill"})
      {:ok, _disabled} = Skills.create_skill(%{name: "disabled-skill", enabled: false})

      names = Skills.list_enabled_skills() |> Enum.map(& &1.name)
      assert enabled.name in names
      refute "disabled-skill" in names

      all_names = Skills.list_skills() |> Enum.map(& &1.name)
      assert "disabled-skill" in all_names
    end
  end

  describe "get_skill_by_name/1" do
    test "fetches by name" do
      {:ok, skill} = Skills.create_skill(%{name: "findable-skill"})
      assert Skills.get_skill_by_name("findable-skill").id == skill.id
      assert Skills.get_skill_by_name("missing") == nil
    end
  end
end
