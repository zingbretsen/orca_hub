defmodule OrcaHub.ChurnSamplerTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{ChurnSampler, Sessions}

  # OrcaHub.ChurnSampler is a singleton GenServer already started by
  # Application.hub_children/1 (mix test boots in hub mode), so tests don't
  # start/stop it — same pattern as OrcaHub.SessionHeartbeatTest. run_sweep/1
  # takes an explicit session list precisely so these tests don't have to
  # reason about whatever else is genuinely "running" in the shared dev DB.

  defp git_session(prefix, attrs) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "test.txt"), "initial")
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir, stderr_to_stdout: true)

    {:ok, session} =
      Sessions.create_session(Map.merge(%{directory: dir, status: "running"}, attrs))

    session
  end

  defp plain_session(prefix, attrs) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(Map.merge(%{directory: dir, status: "running"}, attrs))

    session
  end

  defp tool_use_message(session_id, tool_name) do
    Sessions.create_message(%{
      session_id: session_id,
      data: %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => tool_name, "input" => %{}}
          ]
        }
      }
    })
  end

  describe "run_sweep/1 with an explicit session list" do
    test "persists a sample per session and returns it" do
      session = git_session("churn-sampler-test", %{progress_updated_at: DateTime.utc_now()})

      assert {:ok, samples} = ChurnSampler.run_sweep([session])
      assert length(samples) == 1

      sample = hd(samples)
      assert sample.session_id == session.id
      assert sample.session_status == "running"
      assert is_integer(sample.tool_calls_15m)
      assert is_integer(sample.tool_calls_30m)
      assert is_integer(sample.distinct_tools_15m)
      assert is_integer(sample.distinct_tools_30m)
      assert is_boolean(sample.churn_suspected)
      assert %DateTime{} = sample.sampled_at

      assert [persisted] = Sessions.list_churn_samples(session.id)
      assert persisted.session_id == session.id
    end

    test "handles sessions without a git repo gracefully" do
      session = plain_session("no-commit-test", %{progress_updated_at: DateTime.utc_now()})

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])
      assert sample.session_id == session.id
      assert is_nil(sample.minutes_since_last_commit)
    end

    test "handles an empty session list" do
      assert {:ok, []} = ChurnSampler.run_sweep([])
    end
  end

  describe "run_sweep/1 churn detection" do
    test "marks churn_suspected when the churn heuristic fires" do
      # No git repo: Churn.assess/4 only fires when there's no commit info at
      # all, or the last commit is stale (> 30min) — a session with a FRESH
      # commit is, by design, never flagged regardless of tool-call churn.
      session =
        plain_session("churn-trigger-test", %{
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-20, :minute)
        })

      Enum.each(1..30, fn _ -> tool_use_message(session.id, "Bash") end)

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])
      assert sample.churn_suspected == true
      assert sample.tool_calls_15m >= 25
      assert sample.repetition_ratio_15m >= 0.5
    end

    test "marks churn_suspected false for a normal session" do
      session =
        git_session("normal-test", %{
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-5, :minute)
        })

      Enum.each(["Bash", "Edit", "Bash", "Read"], &tool_use_message(session.id, &1))

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])
      assert sample.churn_suspected == false
    end
  end

  describe "run_sweep/1 pruning" do
    test "prunes samples older than 14 days on each sweep" do
      session = git_session("prune-test", %{progress_updated_at: DateTime.utc_now()})

      Sessions.insert_churn_samples([
        %{
          session_id: session.id,
          sampled_at: DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: false
        },
        %{
          session_id: session.id,
          sampled_at: DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.truncate(:second),
          session_status: "running",
          churn_suspected: true
        }
      ])

      assert length(Sessions.list_churn_samples(session.id)) == 2

      assert {:ok, [_fresh_sample]} = ChurnSampler.run_sweep([session])

      samples = Sessions.list_churn_samples(session.id)
      # The 15-day-old sample is pruned; the 7-day-old one and this sweep's
      # fresh sample remain.
      assert length(samples) == 2
      refute Enum.any?(samples, &(DateTime.diff(DateTime.utc_now(), &1.sampled_at, :day) >= 14))
    end
  end

  describe "sweep/0 (routed through the Application-managed GenServer)" do
    test "responds without crashing and returns a sample list" do
      # Create a test session to ensure we have at least one real sample to assert on.
      # We don't assert on length because the shared dev DB may have other sessions.
      session = git_session("sweep-test", %{progress_updated_at: DateTime.utc_now()})

      assert {:ok, samples} = ChurnSampler.sweep()
      assert is_list(samples)

      # Find our test session's entry and assert on its structure.
      # This proves the GenServer returns actual sample structs, not garbage.
      our_sample = Enum.find(samples, &(&1.session_id == session.id))
      assert our_sample
      assert our_sample.session_id == session.id
      assert our_sample.session_status == "running"
      assert is_integer(our_sample.tool_calls_15m)
      assert is_integer(our_sample.distinct_tools_15m)
      assert is_boolean(our_sample.churn_suspected)
      assert %DateTime{} = our_sample.sampled_at
    end
  end

  describe "evaluate_and_deliver_alerts/1 (ORCAHUB3-44 Phase 2)" do
    alias OrcaHub.AlertSubscriptions

    test "returns {:ok, [], edge_state} unchanged when there are no enabled subscriptions" do
      assert ChurnSampler.evaluate_and_deliver_alerts(%{seed: true}) ==
               {:ok, [], %{seed: true}}
    end

    test "evaluates a real subscription, delivers best-effort, and threads edge_state through" do
      session = plain_session("alert-wiring-test", %{status: "running"})
      # A nonexistent orchestrator target: Cluster.find_session returns nil,
      # so delivery fails cleanly with {:error, :not_found} without ever
      # touching a live runner - exercising deliver_alert/1's failure path
      # without spawning a real session process.
      orchestrator_id = Ecto.UUID.generate()

      {:ok, _subscription} =
        AlertSubscriptions.upsert(orchestrator_id, %{
          watch_children: false,
          session_ids: [session.id],
          conditions: %{"stall" => true}
        })

      assert {:ok, [alert], new_edge_state} = ChurnSampler.evaluate_and_deliver_alerts(%{})
      assert alert.session_id == session.id
      assert alert.condition == "stall"
      assert map_size(new_edge_state) == 1

      # Same tick again immediately: rising edge already fired, cooldown not
      # elapsed - no repeat alert, edge_state carries forward unchanged.
      assert {:ok, [], ^new_edge_state} = ChurnSampler.evaluate_and_deliver_alerts(new_edge_state)
    end
  end
end
