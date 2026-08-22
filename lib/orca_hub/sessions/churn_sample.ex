defmodule OrcaHub.Sessions.ChurnSample do
  @moduledoc """
  Ecto schema for churn sampling records.

  Each row represents a single churn assessment snapshot taken at a point in
  time for a running session. These samples accumulate over time and are
  queried by ORCAHUB3-44's Grafana dashboard (ORCAHUB3-36) to show churn
  behavior trends.

  See `OrcaHub.Sessions.Churn` for the churn heuristic definition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "churn_samples" do
    field :session_id, :binary_id
    field :sampled_at, :utc_datetime
    field :session_status, :string
    field :tool_calls_15m, :integer
    field :tool_calls_30m, :integer
    field :distinct_tools_15m, :integer
    field :distinct_tools_30m, :integer
    field :repetition_ratio_15m, :float
    field :repetition_ratio_30m, :float
    field :minutes_since_progress_update, :integer
    field :minutes_since_last_commit, :integer
    field :churn_suspected, :boolean, default: false

    timestamps(type: :naive_datetime_usec, null: false)
  end

  @doc false
  def changeset(churn_sample, attrs) do
    churn_sample
    |> cast(attrs, [
      :session_id,
      :sampled_at,
      :session_status,
      :tool_calls_15m,
      :tool_calls_30m,
      :distinct_tools_15m,
      :distinct_tools_30m,
      :repetition_ratio_15m,
      :repetition_ratio_30m,
      :minutes_since_progress_update,
      :minutes_since_last_commit,
      :churn_suspected
    ])
    |> validate_required([
      :session_id,
      :sampled_at,
      :churn_suspected
    ])
  end
end
