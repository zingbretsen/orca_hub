defmodule OrcaHub.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  # Scoped, revocable API tokens (alongside the legacy global ORCA_API_TOKEN —
  # see OrcaHubWeb.Plugs.ApiAuth). `session_id` uses :delete_all, NOT
  # :nilify_all: nilifying a pin would silently BROADEN a token's access to
  # every session once its pinned session is deleted, so the session's
  # deletion must revoke the token instead.
  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :name, :string, null: false
      add :token_hash, :binary, null: false
      add :token_prefix, :string
      add :scopes, {:array, :string}, null: false, default: []

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all)

      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:session_id])
  end
end
