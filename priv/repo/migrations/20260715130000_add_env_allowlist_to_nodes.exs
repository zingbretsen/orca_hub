defmodule OrcaHub.Repo.Migrations.AddEnvAllowlistToNodes do
  use Ecto.Migration

  # Per-node extension to OrcaHub.Env's strict_env/2 base allow-list — only
  # relevant when scrub_session_env is also true (see the
  # add_scrub_session_env_to_nodes migration). Each entry is an exact var
  # name or a NAME* prefix match (validated in OrcaHub.ClusterNodes.ClusterNode's
  # changeset), letting an operator allow through e.g. a node-specific
  # AWS_* credential set without disabling scrubbing entirely.
  def change do
    alter table(:nodes) do
      add :env_allowlist, {:array, :string}, null: false, default: []
    end
  end
end
