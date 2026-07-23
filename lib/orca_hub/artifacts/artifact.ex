defmodule OrcaHub.Artifacts.Artifact do
  @moduledoc """
  Schema for an agent-generated artifact — rich HTML/SVG/markdown content,
  persisted per project and rendered client-side in a sandboxed iframe (see
  `OrcaHub.Artifacts` moduledoc for the full design rationale).

  `session_id` is a plain field recording the creating session, like other
  loose refs in this codebase (`Session.parent_session_id`,
  `Trigger.last_session_id`) — no association, so a deleted session doesn't
  take its artifacts with it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    field :name, :string
    field :kind, :string, default: "html"
    field :content, :string
    field :data, :map, default: %{}
    field :version, :integer, default: 1
    field :session_id, :binary_id

    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:project_id, :session_id, :name, :kind, :content, :data, :version])
    |> validate_required([:project_id, :name])
    |> validate_inclusion(:kind, ~w(html svg markdown))
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :name])
  end
end
