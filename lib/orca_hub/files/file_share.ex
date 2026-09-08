defmodule OrcaHub.Files.FileShare do
  @moduledoc """
  Schema for an explicit visibility grant on a `OrcaHub.Files.File` — shares
  one file with either a session or a project (exactly one of the two, see
  `changeset/2`). Deliberately not FK-linked to sessions/projects (plain
  `session_id`/`project_id` fields), so a later session or project deletion
  never needs to touch this table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "file_shares" do
    field :project_id, :binary_id
    field :session_id, :binary_id
    field :shared_by_session_id, :binary_id

    belongs_to :file, OrcaHub.Files.File

    timestamps()
  end

  def changeset(file_share, attrs) do
    file_share
    |> cast(attrs, [:file_id, :project_id, :session_id, :shared_by_session_id])
    |> validate_required([:file_id])
    |> validate_share_target()
    |> foreign_key_constraint(:file_id)
  end

  defp validate_share_target(changeset) do
    project_id = get_field(changeset, :project_id)
    session_id = get_field(changeset, :session_id)

    if is_nil(project_id) == is_nil(session_id) do
      add_error(changeset, :base, "exactly one of project_id or session_id must be set")
    else
      changeset
    end
  end
end
