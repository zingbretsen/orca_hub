defmodule OrcaHub.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  # Backing table for the Jobs subsystem (ORCAHUB3-25): durable records of
  # detached, OS-level background processes that OrcaHub only OBSERVES (never
  # supervises directly) — see OrcaHub.Jobs moduledoc. `session_id` is a
  # plain field (no FK/association), matching the established
  # loosely-coupled convention for cross-entity references that must outlive
  # their creator (Session.parent_session_id, Trigger.last_session_id) — a
  # job must survive its creating session being archived/deleted, since
  # durability independent of any session is the entire point of this table.
  def change do
    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, :binary_id
      add :directory, :string, null: false
      add :runner_node, :string, null: false
      add :label, :string
      add :command, :text, null: false
      add :verify_command, :text

      add :status, :string, null: false, default: "running"
      add :pid, :integer
      add :pgid, :integer
      add :exit_code, :integer
      add :verify_exit_code, :integer

      add :log_path, :string
      add :sentinel_path, :string

      # The job DECLARES its own progress metric — OrcaHub never infers one.
      # See OrcaHub.Jobs.Progress moduledoc for the field-report rationale.
      add :progress_kind, :string
      add :progress_path, :string
      add :progress_expect_bytes, :bigint
      add :progress_command, :text
      add :progress_value, :float
      add :progress_total, :float
      add :progress_note, :string
      add :progress_updated_at, :utc_datetime

      add :timeout_seconds, :integer
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps()
    end

    create index(:jobs, [:session_id])
    create index(:jobs, [:runner_node, :status])
    create index(:jobs, [:status])
  end
end
