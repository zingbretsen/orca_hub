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

  defp bash_message(session_id, command) do
    Sessions.create_message(%{
      session_id: session_id,
      data: %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => command}}
          ]
        }
      }
    })
  end

  # A git repo with a real tracked source file, so the D1 half of
  # SurgeryAlertPolicy ("path not tracked by git") can answer honestly.
  defp git_session_with_tracked_file(prefix, attrs) do
    session = git_session(prefix, attrs)
    File.mkdir_p!(Path.join(session.directory, "lib"))
    File.write!(Path.join(session.directory, "lib/tracked.ex"), "defmodule Tracked do end\n")
    System.cmd("git", ["add", "lib/tracked.ex"], cd: session.directory)

    System.cmd("git", ["commit", "-m", "add tracked"],
      cd: session.directory,
      stderr_to_stdout: true
    )

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

  # ORCAHUB3-66. The sampler used to call Churn.assess/3, so `file_surgery`
  # took its nil default and file surgery was NEVER computed here — which is
  # the mechanical reason churn_samples.churn_suspected was true 0 times in
  # 1,480 samples while 229 file-surgery alerts were being delivered. These
  # tests pin that the sampler now computes it AND records what the
  # suppression policy would decide, since a suppressed alert would otherwise
  # leave no trace anywhere at all.
  describe "run_sweep/1 file-surgery observability (ORCAHUB3-66)" do
    test "records file-surgery evidence the sampler previously never computed" do
      session =
        git_session_with_tracked_file("sampler-surgery-test", %{
          progress_updated_at: DateTime.utc_now()
        })

      # Two shell writes to a tracked source file, plus a real repo edit so
      # the alert would carry corroborating detail (D6 false) — i.e. a
      # detection the policy would NOT suppress.
      cmd = "cat > lib/tracked.ex <<'EOF'\ndefmodule Tracked do end\nEOF"
      {:ok, _} = bash_message(session.id, cmd)
      {:ok, _} = bash_message(session.id, cmd)

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])

      assert sample.file_surgery_suspected == true,
             "the sampler must now compute file surgery — assess/3 never did"

      assert sample.file_surgery_kind == "write_to_tracked"
      assert sample.file_surgery_path == "lib/tracked.ex"
      assert sample.churn_suspected == true
      refute sample.repetition_ratio_15m && sample.repetition_ratio_15m >= 0.5

      assert [persisted] = Sessions.list_churn_samples(session.id)
      assert persisted.file_surgery_suspected == true
      assert persisted.file_surgery_kind == "write_to_tracked"
      assert persisted.file_surgery_path == "lib/tracked.ex"
    end

    test "records false (not nil) when the session has no file surgery" do
      # The distinction is load-bearing: `nil` is reserved to mean "this row
      # predates the migration and the question was never asked", which is
      # what makes churn_suspected void on every historical row.
      session = git_session("sampler-no-surgery-test", %{progress_updated_at: DateTime.utc_now()})
      Enum.each(["Bash", "Read"], &tool_use_message(session.id, &1))

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])
      assert sample.file_surgery_suspected == false
      refute is_nil(sample.file_surgery_suspected)
      assert is_nil(sample.file_surgery_kind)
      assert is_nil(sample.file_surgery_path)

      assert [persisted] = Sessions.list_churn_samples(session.id)
      assert persisted.file_surgery_suspected == false
      assert is_nil(persisted.surgery_alert_decision)
    end

    test "persists the suppression reason, and it round-trips through the DB" do
      # D6: one shell write and nothing else — no repo edits, no repeated
      # signature — so the file-surgery sentence would be the whole alert.
      session = plain_session("sampler-suppress-test", %{progress_updated_at: DateTime.utc_now()})
      {:ok, _} = bash_message(session.id, "cat > lib/scratch.ex <<'EOF'\ndefmodule S do end\nEOF")

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])

      assert sample.file_surgery_suspected == true,
             "the DETECTION must survive — we suppress the alert, not the detection"

      assert sample.surgery_alert_decision == "suppress:no_corroborating_detail"

      # The whole point of the migration: readable back out of the DB a month
      # later, not just present in the in-memory sample map.
      assert [persisted] = Sessions.list_churn_samples(session.id)
      assert persisted.surgery_alert_decision == "suppress:no_corroborating_detail"

      assert String.starts_with?(persisted.surgery_alert_decision, "suppress:"),
             "the encoding must stay prefix-queryable"
    end

    test "persists \"alert\" for a detection the policy would deliver" do
      session =
        git_session_with_tracked_file("sampler-alert-decision-test", %{
          progress_updated_at: DateTime.utc_now()
        })

      cmd = "cat > lib/tracked.ex <<'EOF'\ndefmodule Tracked do end\nEOF"
      {:ok, _} = bash_message(session.id, cmd)
      {:ok, _} = bash_message(session.id, cmd)

      assert {:ok, [sample]} = ChurnSampler.run_sweep([session])
      assert sample.surgery_alert_decision == "alert"

      assert [persisted] = Sessions.list_churn_samples(session.id)
      assert persisted.surgery_alert_decision == "alert"
    end

    test "telemetry metadata carries the new fields" do
      session =
        plain_session("sampler-telemetry-test", %{progress_updated_at: DateTime.utc_now()})

      {:ok, _} = bash_message(session.id, "cat > lib/scratch.ex <<'EOF'\ndefmodule S do end\nEOF")

      handler_id = "churn-sample-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:orca_hub, :churn, :sample],
        fn _event, _measurements, metadata, _config ->
          if metadata.session_id == session.id, do: send(test_pid, {:sample, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, [_sample]} = ChurnSampler.run_sweep([session])

      assert_received {:sample, metadata}
      assert metadata.file_surgery_suspected == true
      assert metadata.surgery_alert_decision == "suppress:no_corroborating_detail"
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
