defmodule OrcaHub.Files.File do
  @moduledoc """
  Schema for a cross-node file store entry — hub-owned metadata only, see
  `OrcaHub.Files` for the full design. `session_id` is a plain field
  recording the creating session, like other loose refs in this codebase
  (`Artifact.session_id`, `Trigger.last_session_id`) — no association, so a
  deleted session doesn't take its files with it. `project_id` nilifies on
  project delete rather than cascading, since a file may legitimately
  outlive the project it was uploaded under.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "files" do
    field :session_id, :binary_id
    field :name, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :sha256, :string
    field :object_key, :string

    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :project_id,
      :session_id,
      :name,
      :content_type,
      :size_bytes,
      :sha256,
      :object_key
    ])
    |> validate_required([:name, :size_bytes, :sha256, :object_key])
    |> foreign_key_constraint(:project_id)
  end
end
