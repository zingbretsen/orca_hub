defmodule OrcaHub.Repo.Migrations.AddEnvAllowlistToProjects do
  use Ecto.Migration

  # Project-level extension to OrcaHub.Env's strict_env/2 base allow-list —
  # combined with the owning node's own env_allowlist (see
  # add_env_allowlist_to_nodes migration) and only relevant when the node
  # also has scrub_session_env enabled.
  def change do
    alter table(:projects) do
      add :env_allowlist, {:array, :string}, null: false, default: []
    end
  end
end
