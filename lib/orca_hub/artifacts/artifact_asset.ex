defmodule OrcaHub.Artifacts.ArtifactAsset do
  @moduledoc """
  Schema linking an `OrcaHub.Artifacts.Artifact` to a file in the
  cross-node file store (`OrcaHub.Files.File`, ORCAHUB3-72) under a
  `name` unique per artifact — served at `GET /artifacts/:id/assets/:name`
  so the artifact's own HTML can reference it with a relative URL (e.g.
  `<img src="assets/hero.png">`), which resolves correctly inside the
  sandboxed iframe since it's loaded from `src=/artifacts/:id/raw`. Both
  FKs cascade on delete: an asset row is meaningless once either side is
  gone.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifact_assets" do
    field :name, :string

    belongs_to :artifact, OrcaHub.Artifacts.Artifact
    belongs_to :file, OrcaHub.Files.File

    timestamps()
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:artifact_id, :file_id, :name])
    |> validate_required([:artifact_id, :file_id, :name])
    |> foreign_key_constraint(:artifact_id)
    |> foreign_key_constraint(:file_id)
    |> unique_constraint([:artifact_id, :name])
  end
end
