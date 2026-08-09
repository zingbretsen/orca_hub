defmodule OrcaHub.Repo.Migrations.AddPinnedAtToArtifacts do
  use Ecto.Migration

  # Nullable timestamp, not a boolean — same storage cost, but lets pins be
  # ordered by when they were pinned (ArtifactLive.Index's "Pinned" section).
  # Partial index since only a handful of artifacts are ever expected to be
  # pinned at once; a full index would mostly index NULLs.
  def change do
    alter table(:artifacts) do
      add :pinned_at, :utc_datetime
    end

    create index(:artifacts, [:pinned_at], where: "pinned_at IS NOT NULL")
  end
end
