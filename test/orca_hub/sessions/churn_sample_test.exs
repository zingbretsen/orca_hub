defmodule OrcaHub.Sessions.ChurnSampleTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Sessions

  describe "insert_churn_samples/1" do
    test "bulk inserts churn samples" do
      samples = [
        %{
          session_id: Ecto.UUID.generate(),
          sampled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          session_status: "running",
          tool_calls_15m: 10,
          tool_calls_30m: 20,
          distinct_tools_15m: 5,
          distinct_tools_30m: 10,
          repetition_ratio_15m: 0.5,
          repetition_ratio_30m: 0.4,
          minutes_since_progress_update: 10,
          minutes_since_last_commit: 5,
          churn_suspected: false
        },
        %{
          session_id: Ecto.UUID.generate(),
          sampled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          session_status: "running",
          tool_calls_15m: 50,
          tool_calls_30m: 100,
          distinct_tools_15m: 2,
          distinct_tools_30m: 5,
          repetition_ratio_15m: 0.9,
          repetition_ratio_30m: 0.95,
          minutes_since_progress_update: 20,
          minutes_since_last_commit: 40,
          churn_suspected: true
        }
      ]

      assert {count, _} = Sessions.insert_churn_samples(samples)
      assert count == 2
    end

    test "inserts empty list successfully" do
      assert {0, nil} = Sessions.insert_churn_samples([])
    end
  end

  describe "list_churn_samples/1" do
    test "returns samples for a session, newest first" do
      session_id = Ecto.UUID.generate()

      # Insert samples with different timestamps
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Sessions.insert_churn_samples([
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -2, :minute) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: false
        },
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -1, :minute) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: true
        },
        %{
          session_id: session_id,
          sampled_at: now,
          session_status: "running",
          churn_suspected: false
        }
      ])

      samples = Sessions.list_churn_samples(session_id)
      assert length(samples) == 3

      # Newest first — DateTime.compare/2, never a bare >=/<= (Erlang's
      # default term ordering compares struct fields alphabetically, not
      # chronologically).
      assert DateTime.compare(hd(samples).sampled_at, Enum.at(samples, 1).sampled_at) != :lt

      assert DateTime.compare(Enum.at(samples, 1).sampled_at, Enum.at(samples, 2).sampled_at) !=
               :lt
    end

    test "returns empty list for non-existent session" do
      assert Sessions.list_churn_samples(Ecto.UUID.generate()) == []
    end
  end

  describe "prune_churn_samples/1" do
    test "removes samples older than 14 days" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Insert old sample (15 days ago)
      Sessions.insert_churn_samples([
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -15, :day) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: false
        },
        # Recent sample (7 days ago)
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -7, :day),
          session_status: "running",
          churn_suspected: true
        }
      ])

      # Verify both exist
      assert length(Sessions.list_churn_samples(session_id)) == 2

      # Prune old samples
      Sessions.prune_churn_samples(14)

      # Only recent sample remains
      samples = Sessions.list_churn_samples(session_id)
      assert length(samples) == 1
      assert DateTime.diff(now, hd(samples).sampled_at, :day) == 7
    end

    test "uses default 14 days when not specified" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Sessions.insert_churn_samples([
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -20, :day) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: false
        }
      ])

      Sessions.prune_churn_samples()

      assert Sessions.list_churn_samples(session_id) == []
    end

    test "respects custom older_than_days" do
      session_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Sessions.insert_churn_samples([
        %{
          session_id: session_id,
          sampled_at: DateTime.add(now, -5, :day),
          session_status: "running",
          churn_suspected: false
        }
      ])

      # A 3-day threshold means "older than 3 days" — the 5-day-old sample
      # is older than that cutoff and should be pruned even though it would
      # have survived the default 14-day threshold.
      Sessions.prune_churn_samples(3)

      assert Sessions.list_churn_samples(session_id) == []
    end
  end

  describe "list_running_sessions/0" do
    test "returns non-archived sessions with status running" do
      dir1 = Path.join(System.tmp_dir!(), "running-test-1")
      dir2 = Path.join(System.tmp_dir!(), "running-test-2")
      dir3 = Path.join(System.tmp_dir!(), "idle-test")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.mkdir_p!(dir3)

      on_exit(fn ->
        File.rm_rf(dir1)
        File.rm_rf(dir2)
        File.rm_rf(dir3)
      end)

      {:ok, session1} =
        Sessions.create_session(%{directory: dir1, status: "running", title: "Session 1"})

      {:ok, session2} =
        Sessions.create_session(%{directory: dir2, status: "running", title: "Session 2"})

      {:ok, session3} =
        Sessions.create_session(%{directory: dir3, status: "idle", title: "Session 3"})

      # Archive one
      Sessions.archive_session(session2)

      running = Sessions.list_running_sessions()
      session_ids = Enum.map(running, & &1.id)

      assert session1.id in session_ids
      refute session2.id in session_ids
      refute session3.id in session_ids
    end
  end
end
