defmodule OrcaHub.Skills do
  @moduledoc """
  Context for hub-managed global skills (Phase 1 of the global-skills
  initiative — see `OrcaHub.SkillSync` for how these rows get materialized
  onto each node's disk).

  Every successful create/update/delete broadcasts `{:skills_updated}` on
  PubSub topic `"skills"` — `Phoenix.PubSub` auto-distributes this to agent
  nodes via `:pg`, so `OrcaHub.SkillSync` on every node hears it and
  re-syncs, hub or agent, without any node-specific plumbing.
  """

  import Ecto.Query
  alias OrcaHub.{Repo, Skills.Skill}

  def list_skills do
    Repo.all(from s in Skill, order_by: [asc: s.name])
  end

  @doc "Enabled skills, in the shape `OrcaHub.SkillSync` consumes."
  def list_enabled_skills do
    Repo.all(from s in Skill, where: s.enabled == true, order_by: [asc: s.name])
  end

  def get_skill!(id), do: Repo.get!(Skill, id)
  def get_skill(id), do: Repo.get(Skill, id)
  def get_skill_by_name(name), do: Repo.get_by(Skill, name: name)

  def create_skill(attrs) do
    result =
      %Skill{}
      |> Skill.changeset(attrs)
      |> Repo.insert()

    with {:ok, _skill} <- result, do: notify_change()

    result
  end

  def update_skill(%Skill{} = skill, attrs) do
    result =
      skill
      |> Skill.changeset(attrs)
      |> Repo.update()

    with {:ok, _skill} <- result, do: notify_change()

    result
  end

  def delete_skill(%Skill{} = skill) do
    result = Repo.delete(skill)

    with {:ok, _skill} <- result, do: notify_change()

    result
  end

  def change_skill(%Skill{} = skill, attrs \\ %{}), do: Skill.changeset(skill, attrs)

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "skills", {:skills_updated})
  end
end
