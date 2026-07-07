defmodule OrcaHub.Repo.Migrations.CreateUpstreamSecrets do
  use Ecto.Migration

  # OrcaHub-managed secrets injected into upstream MCP tool calls (see
  # OrcaHub.Secrets). Values are encrypted at rest with AES-256-GCM; the
  # column stores iv <> tag <> ciphertext as one binary. Hub-only table —
  # agents read/write via HubRPC.
  def change do
    create table(:upstream_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value_encrypted, :binary, null: false

      timestamps()
    end

    create unique_index(:upstream_secrets, [:key])
  end
end
