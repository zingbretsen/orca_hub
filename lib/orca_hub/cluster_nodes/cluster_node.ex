defmodule OrcaHub.ClusterNodes.ClusterNode do
  @moduledoc "Schema for a known cluster node (currently or previously connected)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "nodes" do
    field :name, :string
    field :display_name, :string
    field :first_connected_at, :utc_datetime
    field :last_connected_at, :utc_datetime
    field :isolated, :boolean, default: false
    # When true, OrcaHub.NodeDialer (hub-only) actively dials this node every
    # tick — for LAN nodes the pod network can't dial into, only out of. See
    # OrcaHub.NodeDialer.
    field :dial, :boolean, default: false
    # When true, sessions/terminals spawned on this node get a strict
    # allow-list environment instead of the full BEAM environment — see
    # OrcaHub.NodePolicy.scrub_session_env?/0 and OrcaHub.Env.strict_env/1.
    field :scrub_session_env, :boolean, default: false
    # Extension to OrcaHub.Env's strict_env/2 base allow-list, only relevant
    # while scrub_session_env is true — see OrcaHub.NodePolicy.extra_env_allowlist/1.
    # Each entry is an exact var name or a NAME* prefix match.
    field :env_allowlist, {:array, :string}, default: []
    # Per-node defaults applied by OrcaHub.Sessions.create_session/1 when the
    # caller's attrs don't already specify that field. nil means "no default,
    # fall back to existing behavior" (see Sessions moduledoc for the
    # backend/model pairing rule).
    field :default_backend, :string
    field :default_model, :string

    timestamps()
  end

  @env_entry_regex ~r/^[A-Za-z_][A-Za-z0-9_]*\*?$/
  # Real Erlang distribution node names are always `basename@host` — enforced
  # here so a manually-added row (see OrcaHub.ClusterNodes.create_node/1)
  # can't silently be typo'd into something OrcaHub.NodeDialer will never be
  # able to String.to_atom/Node.connect its way to.
  @node_name_regex ~r/^[a-zA-Z0-9_\-]+@[a-zA-Z0-9_.\-]+$/

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :name,
      :display_name,
      :first_connected_at,
      :last_connected_at,
      :isolated,
      :dial,
      :scrub_session_env,
      :env_allowlist,
      :default_backend,
      :default_model
    ])
    |> validate_required([:name])
    |> validate_format(:name, @node_name_regex,
      message: "must look like basename@host (e.g. orca@my-laptop)"
    )
    |> unique_constraint(:name)
    |> validate_env_allowlist()
  end

  # Shared with OrcaHub.Projects.Project's changeset (same entry grammar —
  # exact var name, or NAME* for a prefix match).
  def validate_env_allowlist(changeset) do
    validate_change(changeset, :env_allowlist, fn :env_allowlist, entries ->
      entries
      |> Enum.reject(&Regex.match?(@env_entry_regex, &1))
      |> Enum.map(
        &{:env_allowlist,
         "invalid entry #{inspect(&1)} — use A-Z/0-9/_ names, optionally ending in *"}
      )
    end)
  end
end
