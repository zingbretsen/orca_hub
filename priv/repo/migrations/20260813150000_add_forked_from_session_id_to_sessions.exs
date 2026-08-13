defmodule OrcaHub.Repo.Migrations.AddForkedFromSessionIdToSessions do
  use Ecto.Migration

  # pi_fork_spec.md §3 "Persistence": the unambiguous fork discriminant.
  # `parent_session_id` is set for every child spawn, not just forks, so it
  # can't serve this role on its own. Nullable — only pi-backend fork
  # children ever set it.
  def change do
    alter table(:sessions) do
      add :forked_from_session_id,
          references(:sessions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sessions, [:forked_from_session_id])
  end
end
