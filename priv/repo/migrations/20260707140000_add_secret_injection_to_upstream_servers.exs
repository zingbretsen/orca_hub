defmodule OrcaHub.Repo.Migrations.AddSecretInjectionToUpstreamServers do
  use Ecto.Migration

  # Opt-in per upstream server: when true, UpstreamClient injects
  # OrcaHub-managed secret values into request arguments (matched by exact
  # key-name string) and masks secret values out of tool responses. Additive
  # column with a default — safe against a live DB.
  def change do
    alter table(:upstream_servers) do
      add :secret_injection, :boolean, default: false, null: false
    end
  end
end
