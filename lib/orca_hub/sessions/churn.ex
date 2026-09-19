defmodule OrcaHub.Sessions.Churn do
  @moduledoc """
  Server-side worker-churn heuristic for detecting stuck sessions.

  `churn_suspected` is now VOLUMETRIC OR QUALITATIVE:

    - Volumetric (the original ORCAHUB3-44 heuristic): a high call rate AND
      high repetition ratio AND no recent commit AND no recent progress
      update. Good at catching a worker spinning fast in circles.
    - Qualitative (ORCAHUB3-61, `OrcaHub.Sessions.FileSurgery`): a worker
      rebuilding a tracked source file from shell fragments (`cat file |
      head -215 > /tmp/x`) instead of retrying its editor tool. This is the
      opposite shape — deliberate, low-volume, destructive — and the
      observed incident had every volumetric gate false (3 tool calls/5min,
      repetition 0.07-0.27), so a rate-and-repetition detector alone is
      structurally blind to it.

  All four volumetric threshold constants are advisory heuristics (see
  ORCAHUB3-44).

  ## This module OBSERVES; it does not decide what is worth alerting on

  `churn_suspected` stays exactly as measured — volumetric OR file-surgery.
  ORCAHUB3-66's suppression policy deliberately lives OUTSIDE this module, in
  `OrcaHub.Sessions.SurgeryAlertPolicy`, and is applied by
  `OrcaHub.ChurnSampler.AlertEvaluator` to the ALERT only, so detection here
  stays intact. Do not fold the policy in here. See
  `churn_alert_precision.md` (repo root) for the measurement that authorises
  it.

  **A suppressed detection now leaves a durable trace — and before
  2026-09-19 it did not, which makes the old data unreadable.**
  `OrcaHub.ChurnSampler.run_sweep/1` used to call `assess/3` — the arity-3
  form, which defaults `file_surgery` to nil — so `churn_samples` never
  carried a file-surgery detection at all (`churn_samples.churn_suspected` was
  true 0 times in 1,480 samples while 229 file-surgery alerts were being
  delivered). File surgery was computed only on the alert path and in the
  heartbeat digest, and the only record of an alert was the DELIVERED message
  in the orchestrator's feed.

  The sampler now calls `assess/5` with batched `FileSurgery.fetch_many/2`
  evidence and persists the detection plus `SurgeryAlertPolicy`'s decision.
  **Every `churn_samples` row written before that change has a void
  `churn_suspected`** — uniformly false for reasons unrelated to churn. See
  `OrcaHub.Sessions.ChurnSample`'s moduledoc for the full warning and for how
  to identify those rows.

  `volumetric_churn_suspected` is exposed separately for the same reason —
  an alert driven by the volumetric half must never be suppressed by a
  file-surgery policy.
  """

  alias OrcaHub.Sessions.FileSurgery

  @churn_min_calls 25
  @churn_min_repetition 0.5
  @churn_max_commit_age_minutes 30
  @churn_max_progress_age_minutes 15

  @doc """
  Assess whether a session appears to be exhibiting churn behavior.

  Returns a map with churn indicators and the computed `churn_suspected` flag.

  ## Parameters
    - `activity`: an `activity_metadata/1` entry (map with tool call counts)
    - `session`: a `Session` struct with `progress_updated_at` (DateTime or NaiveDateTime)
    - `commit_info`: a `git_head_info/1` map or nil (may lack `committed_at` on older nodes)
    - `now`: the current UTC DateTime (defaults to `DateTime.utc_now()`)
    - `file_surgery`: a pre-fetched `FileSurgery.detect/1` evidence map, or nil
      (defaults to nil, so existing callers on `assess/3`/`assess/4` are unaffected)
  """
  def assess(activity, session, commit_info, now \\ DateTime.utc_now(), file_surgery \\ nil)

  def assess(activity, session, commit_info, now, file_surgery) do
    tool_calls_15m = Map.get(activity, :tool_calls_15m, 0)
    tool_calls_30m = Map.get(activity, :tool_calls_30m, 0)
    distinct_tools_15m = Map.get(activity, :distinct_tools_15m, 0)
    distinct_tools_30m = Map.get(activity, :distinct_tools_30m, 0)

    repetition_ratio_15m =
      if tool_calls_15m >= 10 do
        (1.0 - distinct_tools_15m / tool_calls_15m)
        |> Float.round(2)
      else
        nil
      end

    repetition_ratio_30m =
      if tool_calls_30m >= 10 do
        (1.0 - distinct_tools_30m / tool_calls_30m)
        |> Float.round(2)
      else
        nil
      end

    progress_dt = to_datetime(Map.get(session, :progress_updated_at))

    minutes_since_progress_update =
      if progress_dt do
        DateTime.diff(now, progress_dt, :minute)
      else
        nil
      end

    committed_at = Map.get(commit_info || %{}, :committed_at)

    minutes_since_last_commit =
      if committed_at do
        DateTime.diff(now, committed_at, :minute)
      else
        nil
      end

    file_surgery_suspected = not is_nil(file_surgery)

    volumetric_churn_suspected =
      tool_calls_15m >= @churn_min_calls and
        repetition_ratio_15m != nil and
        repetition_ratio_15m >= @churn_min_repetition and
        (is_nil(minutes_since_last_commit) or
           minutes_since_last_commit > @churn_max_commit_age_minutes) and
        (is_nil(minutes_since_progress_update) or
           minutes_since_progress_update > @churn_max_progress_age_minutes)

    churn_suspected = volumetric_churn_suspected or file_surgery_suspected

    %{
      tool_calls_15m: tool_calls_15m,
      tool_calls_30m: tool_calls_30m,
      distinct_tools_15m: distinct_tools_15m,
      distinct_tools_30m: distinct_tools_30m,
      repetition_ratio_15m: repetition_ratio_15m,
      repetition_ratio_30m: repetition_ratio_30m,
      minutes_since_progress_update: minutes_since_progress_update,
      minutes_since_last_commit: minutes_since_last_commit,
      file_surgery: file_surgery,
      file_surgery_suspected: file_surgery_suspected,
      volumetric_churn_suspected: volumetric_churn_suspected,
      churn_suspected: churn_suspected
    }
  end

  @doc """
  Convenience wrapper: fetches recent `FileSurgery` evidence for `session`
  (10-minute window, matching the sweep cadence) and calls `assess/5`.

  If `session` has no `:id` (e.g. a fixture/plain map in tests), passes nil
  for `file_surgery` rather than raising.
  """
  def assess_with_detail(activity, session, commit_info, now \\ DateTime.utc_now())

  def assess_with_detail(activity, session, commit_info, now) do
    file_surgery =
      case Map.get(session, :id) do
        nil -> nil
        session_id -> FileSurgery.fetch(session_id, window_minutes: 10)
      end

    assess(activity, session, commit_info, now, file_surgery)
  end

  # Normalize progress_updated_at to DateTime for diff computation.
  # Session.progress_updated_at is %DateTime{}; older commits or other contexts
  # may provide %NaiveDateTime{}. The assess function must handle both.
  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(nil), do: nil
end
