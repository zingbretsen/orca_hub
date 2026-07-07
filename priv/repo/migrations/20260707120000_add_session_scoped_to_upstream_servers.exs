defmodule OrcaHub.Repo.Migrations.AddSessionScopedToUpstreamServers do
  use Ecto.Migration

  # When true, UpstreamClient maintains one upstream MCP session per Orca
  # session (keyed by orca_session_id) instead of one shared session, so
  # stateful upstreams (e.g. Playwright's per-session browser context) are
  # isolated per Orca session. Additive column with a default — safe against
  # a live DB, no backfill needed; existing rows keep the shared behavior.
  def change do
    alter table(:upstream_servers) do
      add :session_scoped, :boolean, default: false, null: false
    end
  end
end
