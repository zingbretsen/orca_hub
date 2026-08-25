defmodule OrcaHub.Repo.Migrations.AddPinnedAtToIssuesAndTerminals do
  use Ecto.Migration

  # Nullable timestamp, not a boolean — same storage cost, but lets pins be
  # ordered by when they were pinned (IssueLive.Index's "Pinned" section).
  # Partial index since only a handful of issues/terminals are ever expected
  # to be pinned at once; a full index would mostly index NULLs.
  def change do
    alter table(:issues) do
      add :pinned_at, :utc_datetime
    end

    create index(:issues, [:pinned_at], where: "pinned_at IS NOT NULL")

    alter table(:terminals) do
      add :pinned_at, :utc_datetime
    end

    create index(:terminals, [:pinned_at], where: "pinned_at IS NOT NULL")
  end
end
