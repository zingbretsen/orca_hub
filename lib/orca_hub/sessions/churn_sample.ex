defmodule OrcaHub.Sessions.ChurnSample do
  @moduledoc """
  Ecto schema for churn sampling records.

  Each row represents a single churn assessment snapshot taken at a point in
  time for a running session. These samples accumulate over time and are
  queried by ORCAHUB3-44's Grafana dashboard (ORCAHUB3-36) to show churn
  behavior trends.

  See `OrcaHub.Sessions.Churn` for the churn heuristic definition.

  ## `churn_suspected` IS VOID FOR EVERY ROW WRITTEN BEFORE 2026-09-19

  Read this before treating any historical row as ground truth.

  Until ORCAHUB3-66, `OrcaHub.ChurnSampler.run_sweep/1` called
  `Churn.assess/3` — the arity-3 form, in which `file_surgery` takes its `nil`
  default — so **the sampler never computed file surgery at all**. The
  qualitative half of `churn_suspected` was structurally unable to be true
  here, and the volumetric half fired exactly once in seven weeks. Only the
  alert path (`OrcaHub.ChurnSampler.AlertEvaluator`) ever passed evidence, and
  the only record of an alert was the DELIVERED message in the orchestrator's
  feed.

  The resulting discrepancy is not subtle: `churn_suspected` was true **0 times
  in 1,480 samples** over the same weeks in which **229 file-surgery alerts
  were delivered**. Those 1,480 falses are not 1,480 clean sessions. They are
  1,480 rows on which the question was never asked.

  **The void rows are exactly those where `file_surgery_suspected` is `nil`.**
  That field is nullable with no default precisely so the discontinuity is
  visible in the data rather than only in prose: a default of `false` would
  have backfilled the old rows and made "never computed" indistinguishable
  from "computed, no surgery". Filter on the NULL, never on a date.

  See `churn_alert_precision.md` (repo root) and
  `priv/repo/migrations/20260919160000_add_file_surgery_to_churn_samples.exs`.

  ## The ORCAHUB3-66 fields

    * `file_surgery_suspected` — `nil` = never computed (pre-migration row),
      otherwise the sampler's computed answer.
    * `file_surgery_kind` / `file_surgery_path` — the `FileSurgery` evidence's
      `:kind` and `:path`, `nil` when there was no detection.
    * `surgery_alert_decision` — what `OrcaHub.Sessions.SurgeryAlertPolicy`
      would decide for this detection: `nil` = not evaluated (nothing to
      decide about), `"alert"`, or `"suppress:<reason>"`. This is the field
      that makes a SUPPRESSED detection leave a durable trace; without it, a
      suppressed alert is recorded nowhere at all.
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

    # No `default:` here, deliberately — see the moduledoc. `nil` means "the
    # sampler never computed this", which is a different claim from `false`.
    field :file_surgery_suspected, :boolean
    field :file_surgery_kind, :string
    field :file_surgery_path, :string
    field :surgery_alert_decision, :string

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
      :churn_suspected,
      :file_surgery_suspected,
      :file_surgery_kind,
      :file_surgery_path,
      :surgery_alert_decision
    ])
    |> validate_required([
      :session_id,
      :sampled_at,
      :churn_suspected
    ])
  end
end
