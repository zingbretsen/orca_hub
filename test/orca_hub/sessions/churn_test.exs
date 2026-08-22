defmodule OrcaHub.Sessions.ChurnTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Sessions.Churn

  describe "assess/4" do
    test "churn_suspected: true when all conditions are met" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      now = DateTime.utc_now()

      result = Churn.assess(activity, session, commit_info, now)

      assert result.churn_suspected == true
      assert result.tool_calls_15m == 30
      assert result.tool_calls_30m == 50
      assert result.distinct_tools_15m == 10
      assert result.distinct_tools_30m == 20
      assert result.repetition_ratio_15m == 0.67
      assert result.repetition_ratio_30m == 0.6
      assert result.minutes_since_progress_update == 20
      assert result.minutes_since_last_commit == 60
    end

    test "churn_suspected: false when tool_calls_15m < @churn_min_calls (25)" do
      activity = %{
        tool_calls_15m: 20,
        tool_calls_30m: 50,
        distinct_tools_15m: 5,
        distinct_tools_30m: 10
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.churn_suspected == false
      assert result.repetition_ratio_15m == 0.75
    end

    test "churn_suspected: false when repetition_ratio_15m < @churn_min_repetition (0.5)" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 20,
        distinct_tools_30m: 30
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.churn_suspected == false
      assert result.repetition_ratio_15m == 0.33
    end

    test "churn_suspected: false when commit is recent (< 30 minutes)" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      # Commit 10 minutes ago (recent)
      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-10, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.churn_suspected == false
      assert result.minutes_since_last_commit == 10
    end

    test "churn_suspected: false when progress is recent (< 15 minutes)" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      # Progress updated 10 minutes ago (recent)
      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-10, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.churn_suspected == false
      assert result.minutes_since_progress_update == 10
    end

    test "repetition_ratio_15m is nil when tool_calls_15m < 10 (meaningless on tiny samples)" do
      activity = %{
        tool_calls_15m: 5,
        tool_calls_30m: 30,
        distinct_tools_15m: 3,
        distinct_tools_30m: 10
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert is_nil(result.repetition_ratio_15m)
      assert result.repetition_ratio_30m == 0.67
    end

    test "tolerates missing committed_at (nil commit_info)" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      result = Churn.assess(activity, session, nil)

      assert result.churn_suspected == true
      assert is_nil(result.minutes_since_last_commit)
    end

    test "tolerates commit_info map without committed_at key" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{sha: "abc123", short_sha: "abc", subject: "test"}

      result = Churn.assess(activity, session, commit_info)

      assert result.churn_suspected == true
      assert is_nil(result.minutes_since_last_commit)
    end

    test "handles NaiveDateTime progress_updated_at correctly" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      # NaiveDateTime 20 minutes ago
      progress_naive = NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      session = %{progress_updated_at: progress_naive}

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.minutes_since_progress_update == 20
      assert result.churn_suspected == true
    end

    test "rounds repetition_ratio to 2 decimal places" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 30,
        distinct_tools_15m: 7,
        distinct_tools_30m: 7
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      }

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      # 1 - 7/30 = 0.7666... -> 0.77
      assert result.repetition_ratio_15m == 0.77
    end
  end
end
