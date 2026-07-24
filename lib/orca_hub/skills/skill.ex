defmodule OrcaHub.Skills.Skill do
  @moduledoc """
  Schema for a hub-managed global skill.

  A skill fans out to every backend CLI listed in `backends` — see
  `OrcaHub.SkillSync` for how a row here becomes an on-disk `SKILL.md`.
  `body` is the markdown AFTER the frontmatter; the `---\nname: ...\n
  description: ...\n---` block is rendered at sync time from `name` and
  `description`, not stored here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @known_backends ~w(claude codex pi)

  schema "skills" do
    field :name, :string
    field :description, :string
    field :body, :string
    field :enabled, :boolean, default: true
    field :backends, {:array, :string}, default: @known_backends

    timestamps()
  end

  @doc "The three backend keys a skill can target, as strings."
  def known_backends, do: @known_backends

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :description, :body, :enabled, :backends])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: "must be lowercase alphanumeric with hyphens (kebab-case)"
    )
    |> validate_subset(:backends, @known_backends)
    |> unique_constraint(:name)
  end
end
