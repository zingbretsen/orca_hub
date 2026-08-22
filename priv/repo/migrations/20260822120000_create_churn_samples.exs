defmodule OrcaHub.Repo.Migrations.CreateChurnSamples do
  use Ecto.Migration

  def change do
    create table(:churn_samples, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :binary_id
      add :sampled_at, :utc_datetime, null: false
      add :session_status, :string
      add :tool_calls_15m, :integer
      add :tool_calls_30m, :integer
      add :distinct_tools_15m, :integer
      add :distinct_tools_30m, :integer
      add :repetition_ratio_15m, :float
      add :repetition_ratio_30m, :float
      add :minutes_since_progress_update, :integer
      add :minutes_since_last_commit, :integer
      add :churn_suspected, :boolean, null: false, default: false

      timestamps(type: :naive_datetime_usec, null: false)
    end

    create index(:churn_samples, [:session_id, :sampled_at],
             name: :churn_samples_session_id_sampled_at_idx
           )

    create index(:churn_samples, [:sampled_at], name: :churn_samples_sampled_at_idx)
  end
end
