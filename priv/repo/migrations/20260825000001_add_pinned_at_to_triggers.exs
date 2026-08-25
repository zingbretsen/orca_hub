defmodule OrcaHub.Repo.Migrations.AddPinnedAtToTriggers do
  use Ecto.Migration

  # Nullable timestamp, not a boolean — same storage cost, but lets pins be
  # ordered by when they were pinned (TriggerLive.Index's "Pinned" section).
  # Partial index since only a handful of triggers are ever expected to be
  # pinned at once; a full index would mostly index NULLs.
  def change do
    alter table(:triggers) do
      add :pinned_at, :utc_datetime
    end

    create index(:triggers, [:pinned_at], where: "pinned_at IS NOT NULL")
  end
end
