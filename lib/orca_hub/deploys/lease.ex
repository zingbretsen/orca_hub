defmodule OrcaHub.Deploys.Lease do
  @moduledoc """
  Schema for a deploy lease — the mutual-exclusion primitive behind
  "one deploy at a time per target" (.context/deploy-jobs-design.md §2.1).

  A LEASE WITH A TTL, not a lock: the holder can die (a deploy that restarts
  the very hub that launched it is the motivating case), so a lease must
  EXPIRE rather than wedge its target forever. A lease is *held* iff
  `released_at IS NULL AND expires_at > now` — see `held?/2`.

  Exclusion itself is enforced by Postgres, not by this module: the partial
  unique index `deploy_leases_one_live_per_target` (`UNIQUE (target) WHERE
  released_at IS NULL`) makes a second live lease for a target physically
  impossible. `changeset/2` only declares that constraint so the violation
  comes back as a changeset error instead of raising — see
  `OrcaHub.Deploys.Leases.acquire/2` for how it is turned into
  `{:error, :held, lease}`.

  Expiry is *reaping*, never a silent overwrite: stealing an expired lease
  sets `released_at` on the old row and leaves it in the table, so the history
  of who held a target and how it ended stays auditable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deploy_leases" do
    field :target, :string
    field :job_id, :binary_id
    field :session_id, :binary_id
    field :runner_node, :string

    field :acquired_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :released_at, :utc_datetime

    field :note, :string

    timestamps()
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :target,
      :job_id,
      :session_id,
      :runner_node,
      :acquired_at,
      :expires_at,
      :released_at,
      :note
    ])
    |> validate_required([:target, :runner_node, :acquired_at, :expires_at])
    |> unique_constraint(:target,
      name: :deploy_leases_one_live_per_target,
      message: "already has a live lease"
    )
  end

  @doc """
  Whether this lease is currently held: unreleased AND unexpired.

  Pure — takes `now` rather than reading the clock, so callers can evaluate a
  batch of leases against one instant.
  """
  def held?(lease, now \\ DateTime.utc_now())
  def held?(%__MODULE__{released_at: released_at}, _now) when not is_nil(released_at), do: false

  def held?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  @doc """
  Whether this lease has expired without being released — the case the TTL
  exists for. A released lease is not "expired", it is done.
  """
  def expired?(lease, now \\ DateTime.utc_now())

  def expired?(%__MODULE__{released_at: released_at}, _now) when not is_nil(released_at),
    do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt
end
