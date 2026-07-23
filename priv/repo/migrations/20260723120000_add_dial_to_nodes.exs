defmodule OrcaHub.Repo.Migrations.AddDialToNodes do
  use Ecto.Migration

  # Per-node flag: when true, OrcaHub.NodeDialer (hub-only) actively
  # Node.connect/1's this node every tick instead of relying on the hub
  # merely accepting an inbound connection. Needed for LAN nodes the pod
  # network can't be dialed *into* — the hub has to dial *out*. Replaces
  # CLUSTER_NODES (libcluster Epmd strategy) as the steady-state dial-out
  # mechanism; CLUSTER_NODES remains supported as a bootstrap-only fallback.
  # See OrcaHub.NodeDialer and .context/clustering.md.
  def change do
    alter table(:nodes) do
      add :dial, :boolean, null: false, default: false
    end
  end
end
