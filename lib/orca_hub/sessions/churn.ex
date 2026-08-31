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
    IO.inspect({:assess, now, file_surgery, session.progress_updated_at}, label: "DEBUG Churn.assess")
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
