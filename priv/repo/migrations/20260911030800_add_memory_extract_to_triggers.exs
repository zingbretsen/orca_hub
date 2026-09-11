defmodule OrcaHub.Repo.Migrations.AddMemoryExtractToTriggers do
  use Ecto.Migration

  # Nullable — nil (default) means "apply the normal session scope rule"
  # (OrcaHub.MemoryExtraction.in_scope?/1); a trigger can pin it to
  # true/false to force every session it spawns on or off, the same
  # override sessions.memory_extract already offers per-session. Automated
  # review-pass triggers (OrcaHub.MemoryReview) set this false — those
  # sessions must never themselves be memory-extracted.
  def change do
    alter table(:triggers) do
      add :memory_extract, :boolean
    end
  end
end
