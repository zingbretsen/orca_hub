defmodule OrcaHub.Repo.Migrations.AddBackendToSessions do
  use Ecto.Migration

  # Phase 1 of backend_abstraction_spec.md §4/§8: per-session agent-CLI
  # backend selection. NOT NULL with a "claude" default so existing rows and
  # every existing create-session call site (which don't pass `backend`) are
  # unaffected. Additive column with a default — safe against a live DB
  # (no rewrite beyond what Postgres does for a defaulted column add, no
  # backfill needed).
  def change do
    alter table(:sessions) do
      add :backend, :string, default: "claude", null: false
    end
  end
end
