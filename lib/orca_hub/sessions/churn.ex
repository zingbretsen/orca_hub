defmodule OrcaHub.Sessions.Churn do
  @moduledoc """
  Server-side worker-churn heuristic for detecting stuck sessions.

  This module provides a pure function `assess/4` that evaluates a session's
  activity metadata, progress state, and git commit history to determine if
  the session is likely stuck in a loop or otherwise not making forward progress.

  All four threshold constants are advisory heuristics (see ORCAHUB3-44).
  """

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
  """
  def assess(activity, session, commit_info, now \\ DateTime.utc_now())

  def assess(activity, session, commit_info, now) do
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

    churn_suspected =
      tool_calls_15m >= @churn_min_calls and
        repetition_ratio_15m != nil and
        repetition_ratio_15m >= @churn_min_repetition and
        (is_nil(minutes_since_last_commit) or
           minutes_since_last_commit > @churn_max_commit_age_minutes) and
        (is_nil(minutes_since_progress_update) or
           minutes_since_progress_update > @churn_max_progress_age_minutes)

    %{
      tool_calls_15m: tool_calls_15m,
      tool_calls_30m: tool_calls_30m,
      distinct_tools_15m: distinct_tools_15m,
      distinct_tools_30m: distinct_tools_30m,
      repetition_ratio_15m: repetition_ratio_15m,
      repetition_ratio_30m: repetition_ratio_30m,
      minutes_since_progress_update: minutes_since_progress_update,
      minutes_since_last_commit: minutes_since_last_commit,
      churn_suspected: churn_suspected
    }
  end

  # Normalize progress_updated_at to DateTime for diff computation.
  # Session.progress_updated_at is %DateTime{}; older commits or other contexts
  # may provide %NaiveDateTime{}. The assess function must handle both.
  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(nil), do: nil
end
