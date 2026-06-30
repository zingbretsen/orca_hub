defmodule OrcaHub.Repo.Migrations.CreateNodeCredentials do
  use Ecto.Migration

  # Per-node Claude Code OAuth tokens captured via the "Log in this node"
  # flow (`claude setup-token`). Keyed by the node's Erlang node name so the
  # correct credential can be injected into `claude` ports spawned on that
  # node. Hub-only table; agents read/write via HubRPC.
  def change do
    create table(:node_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_name, :string, null: false
      add :oauth_token, :text, null: false

      timestamps()
    end

    create unique_index(:node_credentials, [:node_name])
  end
end
