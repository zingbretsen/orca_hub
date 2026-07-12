defmodule OrcaHub.Repo.Migrations.AddIsolatedToNodes do
  use Ecto.Migration

  # Per-node isolation flag: when true, MCP tool calls made by sessions
  # running ON this node cannot message/inspect/spawn sessions on any OTHER
  # node, and search_sessions is scoped to this node only. Inbound traffic
  # (other nodes reaching sessions on an isolated node) is unaffected —
  # see OrcaHub.NodePolicy.
  def change do
    alter table(:nodes) do
      add :isolated, :boolean, null: false, default: false
    end
  end
end
