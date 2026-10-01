defmodule OrcaHub.Repo.Migrations.AddEndConditionsToTriggers do
  use Ecto.Migration

  # Calendar-style recurrence end conditions — "ends after N runs" / "ends on
  # date". run_count counts SUCCESSFUL fires only (a node-unavailable skip
  # doesn't count); TriggerExecutor auto-disables the trigger when run_count
  # reaches max_runs or the next fire would land after ends_at. nil max_runs /
  # ends_at mean "never ends".
  def change do
    alter table(:triggers) do
      add :max_runs, :integer
      add :run_count, :integer, null: false, default: 0
      add :ends_at, :utc_datetime
    end
  end
end
