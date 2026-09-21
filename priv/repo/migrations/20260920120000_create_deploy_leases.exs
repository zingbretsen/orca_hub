defmodule OrcaHub.Repo.Migrations.CreateDeployLeases do
  use Ecto.Migration

  # Mutual exclusion for project deploys (.context/deploy-jobs-design.md §2.1):
  # a LEASE WITH A TTL, not a lock. The holder can die — a crashed deploy must
  # EXPIRE rather than wedge a target forever — so every row carries its own
  # `expires_at`, and a lease is held iff `released_at IS NULL AND expires_at >
  # now`.
  #
  # `job_id`/`session_id` are plain :binary_id fields with NO foreign key,
  # matching the established convention for cross-entity references that must
  # outlive their creator (jobs.session_id, Session.parent_session_id): a lease
  # is the audit record of a deploy attempt and outlives the job row it was
  # taken for.
  def change do
    create table(:deploy_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The mutex KEY: a short deploy-registry target name ("orca_hub",
      # "content-studio", "video-search"). Not project_id (two of the three
      # deployable things have no projects row) and not directory
      # (deploy-orca-hub.sh touches two repos, so no single dir names it).
      add :target, :string, null: false

      add :job_id, :binary_id
      add :session_id, :binary_id
      add :runner_node, :string, null: false

      add :acquired_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      # NULL while held. Set on release AND on expiry-reaping, so a stolen
      # lease STAYS in the table as auditable history, never a silent
      # overwrite.
      add :released_at, :utc_datetime

      add :note, :string

      timestamps()
    end

    # THE mutual-exclusion mechanism. A partial unique index: at most one
    # unreleased lease per target, enforced by Postgres, never by an
    # application-level read-then-write. A double acquire surfaces as a
    # unique_violation that the context catches and reports as {:error, :held,
    # lease}.
    create unique_index(:deploy_leases, [:target],
             where: "released_at IS NULL",
             name: :deploy_leases_one_live_per_target
           )

    create index(:deploy_leases, [:job_id])
  end
end
