defmodule OrcaHub.Repo.Migrations.AddRunAtToTriggers do
  use Ecto.Migration

  # type: "once" triggers fire a single time at run_at (UTC). The row is the
  # durable source of truth — OrcaHub.OneOffTriggerSweep polls for enabled,
  # due ones, so a fire survives any number of hub restarts in between.
  def change do
    alter table(:triggers) do
      add :run_at, :utc_datetime
    end

    create index(:triggers, [:run_at], where: "type = 'once' AND enabled = true")
  end
end
