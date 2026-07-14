defmodule OrcaHub.Repo.Migrations.AddDefaultBackendAndModelToNodes do
  use Ecto.Migration

  # Per-node defaults applied by OrcaHub.Sessions.create_session/1 when the
  # caller's attrs don't already specify a backend/model — e.g. the Discord
  # bridge node defaulting every session it spawns to a particular model
  # without every creation path having to know that. Nullable: nil means "no
  # node default, fall back to existing behavior".
  def change do
    alter table(:nodes) do
      add :default_backend, :string
      add :default_model, :string
    end
  end
end
