defmodule OrcaHub.AlertSubscriptions.AlertSubscription do
  @moduledoc """
  Ecto schema for one orchestrator's worker-alert configuration (ORCAHUB3-44
  Phase 2). One row per `orchestrator_session_id` (enforced by a unique
  index) — `set_worker_alerts` upserts in place, exactly like
  `schedule_heartbeat`. Unlike heartbeats, this is DB-persisted deliberately
  so a configured watch survives a deploy/restart.

  `conditions` is a map of condition name => value: boolean `true` for
  `"churn"`/`"stall"` (evaluated only when present and truthy), or an
  integer minute threshold for `"progress_stale"`/`"no_commit_for"`
  (evaluated only when present as an integer — both are opt-in). See
  `OrcaHub.ChurnSampler.AlertEvaluator` for how these are interpreted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "alert_subscriptions" do
    field :orchestrator_session_id, :binary_id
    field :watch_children, :boolean, default: true
    field :session_ids, {:array, :binary_id}, default: []
    field :conditions, :map, default: %{}
    field :cooldown_seconds, :integer, default: 900
    field :enabled, :boolean, default: true

    timestamps(type: :naive_datetime_usec, null: false)
  end

  @doc false
  def changeset(alert_subscription, attrs) do
    alert_subscription
    |> cast(attrs, [
      :orchestrator_session_id,
      :watch_children,
      :session_ids,
      :conditions,
      :cooldown_seconds,
      :enabled
    ])
    |> validate_required([:orchestrator_session_id])
    |> validate_number(:cooldown_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint(:orchestrator_session_id)
  end
end
