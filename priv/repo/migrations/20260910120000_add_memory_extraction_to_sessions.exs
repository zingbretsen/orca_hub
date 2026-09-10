defmodule OrcaHub.Repo.Migrations.AddMemoryExtractionToSessions do
  use Ecto.Migration

  # `memory_extract`: nullable per-session override of the default scope rule
  # (orchestrator or root session) for automatic memory extraction — nil
  # inherits the default rule, true/false force it on/off. See
  # OrcaHub.MemoryExtraction.in_scope?/1.
  #
  # `memory_extracted_at`: watermark — only messages inserted after this are
  # considered on the next extraction. Set when extraction is DISPATCHED
  # (not completed), so an idle-teardown followed by an archive minutes later
  # doesn't double-extract the same messages.
  def change do
    alter table(:sessions) do
      add :memory_extract, :boolean
      add :memory_extracted_at, :utc_datetime
    end
  end
end
