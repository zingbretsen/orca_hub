defmodule OrcaHub.Sessions.ChurnTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Sessions.Churn
  alias OrcaHub.Sessions.FileSurgery

  defp assistant_message(blocks) do
    %{data: %{"type" => "assistant", "message" => %{"content" => blocks}}}
  end

  defp tool_use(name, input) do
    %{"type" => "tool_use", "name" => name, "input" => input}
  end

  describe "assess/5 (ORCAHUB3-61 file-surgery integration)" do
    test "ORCAHUB3-61: the observed low-volume file-surgery incident sets churn_suspected" do
      # The real incident: 3 tool calls / 5 min, repetition ratio 0.07-0.27,
      # no commit, no recent progress — every volumetric gate false.
      activity = %{
        tool_calls_15m: 3,
        tool_calls_30m: 30,
        distinct_tools_15m: 3,
        distinct_tools_30m: 25
      }

      session = %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-60, :minute)
      }

      commit_info = nil
      now = DateTime.utc_now()

      messages = [
        assistant_message([
          tool_use("Bash", %{
            "command" =>
              "cat /home/zach/orca_hub/lib/orca_hub/pi_config_sync.ex | head -215 > /tmp/pi_config_part1.ex"
          })
        ])
      ]

      file_surgery = FileSurgery.detect(messages)
      assert file_surgery.path == "/home/zach/orca_hub/lib/orca_hub/pi_config_sync.ex"

      result = Churn.assess(activity, session, commit_info, now, file_surgery)

      # The volumetric gates genuinely stay false — this is not a wash.
      assert result.tool_calls_15m < 25
      refute result.repetition_ratio_15m != nil and result.repetition_ratio_15m >= 0.5

      assert result.churn_suspected == true
    end
  end

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

    test "handles %DateTime{} progress_updated_at correctly (real Session field type)" do
      activity = %{
        tool_calls_15m: 30,
        tool_calls_30m: 50,
        distinct_tools_15m: 10,
        distinct_tools_30m: 20
      }

      # Session.progress_updated_at is %DateTime{} (not NaiveDateTime)
      progress_dt = DateTime.utc_now() |> DateTime.add(-20, :minute)
      session = %{progress_updated_at: progress_dt}

      commit_info = %{
        committed_at: DateTime.utc_now() |> DateTime.add(-60, :minute)
      }

      result = Churn.assess(activity, session, commit_info)

      assert result.minutes_since_progress_update == 20
      assert result.churn_suspected == true
    end
  end
end
