defmodule OrcaHub.ChurnSampler.AlertEvaluatorTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{AlertSubscriptions, Sessions}
  alias OrcaHub.ChurnSampler.AlertEvaluator
  alias OrcaHub.Sessions.{Churn, ChurnDetail, FileSurgery, SurgeryAlertPolicy}

  # Mirrors churn_sampler_test.exs's own fixture helpers — same shapes, same
  # reasoning (a fresh tmp dir per session, optionally a real git repo).
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

    {:ok, session} = Sessions.create_session(Map.merge(%{directory: dir}, attrs))
    session
  end

  defp plain_session(prefix, attrs) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} = Sessions.create_session(Map.merge(%{directory: dir}, attrs))
    session
  end

  defp tool_use_message(session_id, tool_name) do
    Sessions.create_message(%{
      session_id: session_id,
      data: %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "name" => tool_name, "input" => %{}}]
        }
      }
    })
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

  defp edit_message(session_id, file_path) do
    Sessions.create_message(%{
      session_id: session_id,
      data: %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => file_path}}
          ]
        }
      }
    })
  end

  # A git repo with a real tracked source file, so the D1 half of the
  # suppression policy ("path not tracked by git") can answer honestly.
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

  # A failed editor call: the assistant `tool_use` block plus the matching
  # `tool_result` with `is_error: true`. EditFailure pairs them by id.
  defp failed_edit(session_id, file_path, error, opts \\ []) do
    id = Keyword.get(opts, :id, "toolu_#{System.unique_integer([:positive])}")
    old_string = Keyword.get(opts, :old_string, "needle")

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => id,
                "name" => "Edit",
                "input" => %{"file_path" => file_path, "old_string" => old_string}
              }
            ]
          }
        }
      })

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => id,
                "is_error" => true,
                "content" => error
              }
            ]
          }
        }
      })

    :ok
  end

  # A SUCCESSFUL editor call. `edit_message/2` above is not one: it emits a
  # `tool_use` with no id and no `tool_result`, which EditFailure classifies
  # as UNKNOWN — deliberately neither a failure nor a streak reset, so that a
  # window boundary landing between a call and its result cannot erase a real
  # streak. Resetting the streak needs a real success.
  defp successful_edit(session_id, file_path) do
    id = "toolu_ok_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => id,
                "name" => "Edit",
                "input" => %{"file_path" => file_path, "old_string" => "needle"}
              }
            ]
          }
        }
      })

    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => id,
                "is_error" => false,
                "content" => "The file has been updated."
              }
            ]
          }
        }
      })

    :ok
  end

  # A git repo whose only commit is backdated, so `no_commit_for` has
  # something older than its threshold to fire on. `git_head_info/1` reads
  # the COMMITTER date (`%cI`), so GIT_COMMITTER_DATE is the one that counts.
  defp git_session_with_old_commit(prefix, attrs, minutes_ago) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    when_iso =
      DateTime.utc_now() |> DateTime.add(-minutes_ago, :minute) |> DateTime.to_iso8601()

    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    File.write!(Path.join(dir, "test.txt"), "initial")
    System.cmd("git", ["add", "."], cd: dir)

    System.cmd("git", ["commit", "-m", "initial"],
      cd: dir,
      stderr_to_stdout: true,
      env: [{"GIT_COMMITTER_DATE", when_iso}, {"GIT_AUTHOR_DATE", when_iso}]
    )

    {:ok, session} = Sessions.create_session(Map.merge(%{directory: dir}, attrs))
    session
  end

  defp subscribe(orchestrator_id, attrs) do
    {:ok, subscription} = AlertSubscriptions.upsert(orchestrator_id, attrs)
    subscription
  end

  describe "evaluate/3 — churn condition" do
    test "fires when the churn heuristic is suspected" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("alert-churn-test", %{
          status: "running",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-20, :minute)
        })

      Enum.each(1..30, fn _ -> tool_use_message(session.id, "Bash") end)

      subscription =
        subscribe(orchestrator_id, %{
          watch_children: false,
          session_ids: [session.id],
          conditions: %{"churn" => true}
        })

      assert {[alert], edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.session_id == session.id
      assert alert.condition == "churn"
      assert alert.orchestrator_session_id == orchestrator_id
      assert alert.message =~ "[Worker alert] churn"
      assert alert.message =~ session.id
      assert map_size(edge_state) == 1
    end

    test "does not fire when churn is not suspected" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        git_session("alert-no-churn-test", %{
          status: "running",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-1, :minute)
        })

      Enum.each(["Bash", "Edit", "Read", "Bash"], &tool_use_message(session.id, &1))

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — stall condition" do
    test "fires only for a running session with zero recent activity" do
      orchestrator_id = Ecto.UUID.generate()
      stalled = plain_session("alert-stall-test", %{status: "running"})
      idle = plain_session("alert-stall-idle-test", %{status: "idle"})

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [stalled.id, idle.id],
          conditions: %{"stall" => true}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.session_id == stalled.id
      assert alert.condition == "stall"
    end

    test "does not fire once there is recent activity" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-stall-active-test", %{status: "running"})
      {:ok, _} = tool_use_message(session.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"stall" => true}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — progress_stale condition" do
    test "fires once progress is older than the configured threshold" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("alert-progress-stale-test", %{
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-25, :minute)
        })

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"progress_stale" => 15}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "progress_stale"
      assert alert.message =~ "progress last updated 25m ago"
    end

    test "never fires when progress has not been reported yet, even with the condition enabled" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-progress-never-test", %{})

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"progress_stale" => 5}
        })

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end

    test "is not evaluated at all when absent from conditions" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("alert-progress-optout-test", %{
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-999, :minute)
        })

      subscription = subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — no_commit_for condition (opt-in)" do
    test "fires when running with tool activity but a stale/missing commit" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-no-commit-test", %{status: "running"})
      {:ok, _} = tool_use_message(session.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "no_commit_for"
    end

    test "does not fire without any tool-call activity" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-no-commit-idle-test", %{status: "running"})

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end

    test "does not fire with a fresh commit" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-no-commit-fresh-test", %{status: "running"})
      {:ok, _} = tool_use_message(session.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — rising edge + cooldown" do
    # Uses progress_stale rather than stall: its condition value is derived
    # from Churn.assess/4's injected `now` against a fixed DB timestamp, so
    # every transition here is driven by the `now` argument alone — no
    # reliance on activity_metadata/1's own real-wall-clock window (which
    # `stall` depends on and a test can't fast-forward).
    test "alerts only on false->true transition, re-alerts only after cooldown, and a fresh " <>
           "false->true fires immediately even inside the prior cooldown window" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("alert-cooldown-test", %{
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-20, :minute)
        })

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"progress_stale" => 15},
          cooldown_seconds: 600
        })

      now = DateTime.utc_now()

      # Rising edge: first evaluation while stale fires.
      assert {[_alert], edge_state} = AlertEvaluator.evaluate([subscription], now, %{})

      # Still stale, cooldown (600s) not elapsed: no re-alert.
      assert {[], edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 300, :second),
                 edge_state
               )

      # Still stale, cooldown elapsed: re-alerts.
      assert {[alert], edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 660, :second),
                 edge_state
               )

      assert alert.condition == "progress_stale"

      # Progress gets refreshed (condition clears): edge resets to false.
      {:ok, _} = Sessions.update_session(session, %{progress_updated_at: DateTime.utc_now()})

      assert {[], edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 665, :second),
                 edge_state
               )

      # Progress goes stale again right after: a FRESH false->true
      # transition, so it fires immediately even though we're still inside
      # the previous cooldown window.
      {:ok, _} =
        Sessions.update_session(session, %{
          progress_updated_at: DateTime.add(now, 665, :second) |> DateTime.add(-16, :minute)
        })

      assert {[alert], _edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 666, :second),
                 edge_state
               )

      assert alert.condition == "progress_stale"
    end
  end

  describe "evaluate/3 — watch set resolution" do
    test "watch_children resolves the orchestrator's current non-archived children fresh" do
      parent = plain_session("alert-watch-parent-test", %{})

      child =
        plain_session("alert-watch-child-test", %{parent_session_id: parent.id, status: "running"})

      subscription =
        subscribe(parent.id, %{
          watch_children: true,
          session_ids: [],
          conditions: %{"stall" => true}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.session_id == child.id
    end

    test "session_ids watches non-child sessions directly" do
      orchestrator_id = Ecto.UUID.generate()
      other = plain_session("alert-watch-other-test", %{status: "running"})

      subscription =
        subscribe(orchestrator_id, %{
          watch_children: false,
          session_ids: [other.id],
          conditions: %{"stall" => true}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.session_id == other.id
    end

    test "excludes archived sessions from the watched set" do
      parent = plain_session("alert-watch-archived-parent-test", %{})

      child =
        plain_session("alert-watch-archived-child-test", %{
          parent_session_id: parent.id,
          status: "running",
          archived_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      subscription =
        subscribe(parent.id, %{watch_children: true, conditions: %{"stall" => true}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
      refute is_nil(child.archived_at)
    end

    test "evaluates a watched session regardless of its own running status" do
      orchestrator_id = Ecto.UUID.generate()

      idle_session =
        plain_session("alert-watch-idle-churn-test", %{
          status: "idle",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-20, :minute)
        })

      Enum.each(1..30, fn _ -> tool_use_message(idle_session.id, "Bash") end)

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [idle_session.id],
          conditions: %{"churn" => true}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.session_id == idle_session.id
      assert alert.condition == "churn"
    end
  end

  describe "evaluate/3 — file-surgery suppression policy (ORCAHUB3-66)" do
    # The gate is `volumetric or (file_surgery and SurgeryAlertPolicy)`.
    # See `churn_alert_precision.md` and OrcaHub.Sessions.SurgeryAlertPolicy
    # for why the rule is D6 OR (D1 AND D2b) and nothing else.

    test "suppresses a surgery-only alert carrying no corroborating detail at all (D6)" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-surgery-d6-test", %{status: "running"})

      # One shell write and nothing else: no repo edits, no repeated
      # signature — the file-surgery sentence would be the entire alert.
      {:ok, _} = bash_message(session.id, "cat > lib/scratch.ex <<'EOF'\ndefmodule S do end\nEOF")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      churn =
        Churn.assess(
          Sessions.activity_metadata([session.id]) |> Map.get(session.id, %{}),
          session,
          nil,
          DateTime.utc_now(),
          FileSurgery.fetch(session.id, window_minutes: 10)
        )

      assert churn.file_surgery_suspected, "fixture must actually trip FileSurgery"

      assert churn.churn_suspected,
             "the raw OBSERVATION must still be true — we suppress the alert, not the detection"

      refute churn.volumetric_churn_suspected

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end

    test "preserves a surgery alert that carries corroborating detail" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session_with_tracked_file("alert-surgery-keep-test", %{status: "running"})

      cmd = "cat > lib/tracked.ex <<'EOF'\ndefmodule Tracked do end\nEOF"
      {:ok, _} = bash_message(session.id, cmd)
      {:ok, _} = bash_message(session.id, cmd)

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "churn"
      assert alert.message =~ "Repeated calls:"
      assert alert.message =~ "Advisory: wrote lib/tracked.ex from the shell"
    end

    test "a volumetric churn alert is never suppressed by the surgery policy" do
      orchestrator_id = Ecto.UUID.generate()

      # No git repo (D1 true) and the command reads back what it wrote
      # (D2b true), so the surgery half alone would be suppressed.
      session =
        plain_session("alert-volumetric-test", %{
          status: "running",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-30, :minute)
        })

      cmd = "cat > scratch.exs <<'EOF'\nIO.puts(1)\nEOF\n && cat scratch.exs"
      Enum.each(1..30, fn _ -> bash_message(session.id, cmd) end)

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      activity = Sessions.activity_metadata([session.id]) |> Map.get(session.id, %{})
      evidence = FileSurgery.fetch(session.id, window_minutes: 10)
      churn = Churn.assess(activity, session, nil, DateTime.utc_now(), evidence)

      assert churn.volumetric_churn_suspected
      assert churn.file_surgery_suspected

      # Precondition for this test to mean anything: the policy really does
      # want the surgery half gone (untracked path + same-command verify).
      refute SurgeryAlertPolicy.alertable_for_session?(
               session,
               evidence,
               ChurnDetail.fetch(session.id)
             ),
             "expected D1 AND D2b to suppress the surgery half of this fixture"

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "churn"
    end
  end

  describe "evaluate/3 — churn message format (ORCAHUB3-66)" do
    setup do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session_with_tracked_file("alert-message-test", %{status: "running"})

      cmd = "cat > lib/tracked.ex <<'EOF'\ndefmodule Tracked do end\nEOF"
      {:ok, _} = bash_message(session.id, cmd)
      {:ok, _} = bash_message(session.id, cmd)

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      {:ok, session: session, message: alert.message}
    end

    test "the corroborating detail LEADS and the flagged command FOLLOWS it", %{message: message} do
      detail_at = :binary.match(message, "Repeated calls:") |> elem(0)
      advisory_at = :binary.match(message, "Advisory: wrote") |> elem(0)
      command_at = :binary.match(message, "Command: ") |> elem(0)

      assert detail_at < advisory_at
      assert advisory_at < command_at
    end

    test "no confidence wording appears anywhere in the message", %{message: message} do
      refute message =~ "confidence"
      refute message =~ "paired"
      refute message =~ "unpaired"
      refute message =~ "rebuilding"
      refute message =~ "shell fragments"
    end

    test "the flagged command is advisory, not a diagnosis", %{message: message} do
      assert message =~ "Advisory: wrote lib/tracked.ex from the shell (write_to_tracked)"
      assert message =~ "judge from the detail above, not from this line"
    end

    test "the commit clause is replaced when the session made no repo edits",
         %{message: message} do
      assert message =~ "no repo edits in window"
      refute message =~ "no commit "
      refute message =~ "directory HEAD"
    end

    test "the commit age is labelled as a DIRECTORY fact, never as a session one",
         %{session: session} do
      # minutes_since_last_commit comes from `git log -1` with cd: directory —
      # no author filter, no session attribution, and fetch_commit_info_for/1
      # dedupes by {runner_node, directory}. In a shared worktree the number
      # is a sibling's commit, so it must not read as "this worker has not
      # committed".
      orchestrator_id = Ecto.UUID.generate()
      {:ok, _} = edit_message(session.id, "lib/tracked.ex")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.message =~ "Top edited files: lib/tracked.ex"
      assert alert.message =~ ~r/directory HEAD \d+m old/
      refute alert.message =~ "no commit "
      refute alert.message =~ "no repo edits in window"
    end
  end

  describe "evaluate/3 — edit-failure signal (ORCAHUB3-63 §1)" do
    # The whole point of this signal is that it is VOLUMETRICALLY INVISIBLE.
    # The motivating live case was two identical failed Edit calls at
    # tool_calls_15m = 4 with churn_suspected false. So the tests that matter
    # are the ones proving it fires with almost no activity behind it.

    test "fires at LOW volume — two failed edits and nothing else" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-edit-failure-low-vol", %{status: "running"})

      # `Edit` cannot create a file that does not exist; the worker retries
      # the identical call verbatim. Four tool calls in the window, total.
      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")
      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")

      activity = Sessions.activity_metadata([session.id]) |> Map.get(session.id, %{})
      churn = Churn.assess(activity, session, nil, DateTime.utc_now(), nil)

      # Preconditions — without these the test proves nothing.
      assert activity.tool_calls_15m < 25,
             "fixture must sit below @churn_min_calls or this is not a low-volume test"

      refute churn.volumetric_churn_suspected,
             "the volumetric half must be FALSE — this signal exists for the case it misses"

      refute churn.file_surgery_suspected,
             "no shell write here: the two populations are disjoint and must stay so"

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "churn"
      assert alert.message =~ "Cannot land an edit: 2 identical failed Edit calls"
      assert alert.message =~ "lib/new_thing.ex"
      assert alert.message =~ "Last error: File does not exist."
    end

    test "the finding sits above the detail block, not below it as an advisory" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-edit-failure-order", %{status: "running"})

      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")
      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")
      {:ok, _} = edit_message(session.id, "lib/other.ex")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])

      edit_failure_at = :binary.match(alert.message, "Cannot land an edit:") |> elem(0)
      detail_at = :binary.match(alert.message, "Top edited files:") |> elem(0)

      assert edit_failure_at < detail_at,
             "a P=0.89 finding must outrank the corroboration block it does not need"
    end

    test "a single failure is not a signal — one failed edit does not fire" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-edit-failure-single", %{status: "running"})

      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end

    test "a success between failures resets the streak and nothing fires" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-edit-failure-reset", %{status: "running"})

      :ok = failed_edit(session.id, "lib/new_thing.ex", "String not found.")
      :ok = successful_edit(session.id, "lib/new_thing.ex")
      :ok = failed_edit(session.id, "lib/new_thing.ex", "String not found.")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end

    test "SurgeryAlertPolicy never gates it — it fires where U1b would suppress" do
      # Same D6 shape that suppresses a file-surgery alert outright (no repo
      # edits, no repeated signatures), but with a failed-edit streak in it.
      # The surgery policy's clauses are about where a SHELL WRITE landed;
      # they must have no say over this signal.
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-edit-failure-ungated", %{status: "running"})

      {:ok, _} =
        bash_message(
          session.id,
          "cat > /tmp/scratch.txt <<'EOF'\nx\nEOF\n && cat /tmp/scratch.txt"
        )

      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")
      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")

      activity = Sessions.activity_metadata([session.id]) |> Map.get(session.id, %{})
      evidence = FileSurgery.fetch(session.id, window_minutes: 10)

      # Precondition: the surgery half of this fixture really is suppressed.
      refute SurgeryAlertPolicy.alertable_for_session?(
               session,
               evidence,
               ChurnDetail.fetch(session.id)
             ),
             "expected the surgery half of this fixture to be suppressed by U1b"

      refute Churn.assess(activity, session, nil, DateTime.utc_now(), evidence).volumetric_churn_suspected

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.message =~ "Cannot land an edit:"

      refute alert.message =~ "Advisory: wrote",
             "the surgery half is still suppressed; only the edit-failure half fired"
    end

    test "non-identical retries are reported without the identical qualifier" do
      orchestrator_id = Ecto.UUID.generate()
      session = git_session("alert-edit-failure-distinct", %{status: "running"})

      :ok = failed_edit(session.id, "lib/tracked.ex", "String not found.", old_string: "alpha")
      :ok = failed_edit(session.id, "lib/tracked.ex", "String not found.", old_string: "beta")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"churn" => true}})

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.message =~ "Cannot land an edit: 2 failed Edit calls"
      refute alert.message =~ "identical"
    end

    test "does not attach to a condition other than churn" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-edit-failure-stall", %{status: "running"})

      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")
      :ok = failed_edit(session.id, "lib/new_thing.ex", "File does not exist.")

      subscription =
        subscribe(orchestrator_id, %{session_ids: [session.id], conditions: %{"stall" => true}})

      # There IS tool activity, so "stall" is false and nothing fires at all —
      # the edit-failure evidence must not leak into an unrelated condition.
      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — no_commit_for message text (ORCAHUB3-66)" do
    test "the commit age is labelled as a DIRECTORY fact, not a session one" do
      # Identical reasoning to the churn clause worker B fixed:
      # minutes_since_last_commit comes from `git log -1` with cd: directory —
      # no author filter — and fetch_commit_info_for/1 dedupes by
      # {runner_node, directory}. "last commit 6m ago" read as a claim about
      # this worker; in a shared worktree it is a sibling's commit.
      orchestrator_id = Ecto.UUID.generate()
      session = git_session_with_old_commit("alert-no-commit-wording", %{status: "running"}, 90)
      {:ok, _} = tool_use_message(session.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.condition == "no_commit_for"
      assert alert.message =~ ~r/directory HEAD \d+m old/
      refute alert.message =~ "last commit"
    end

    test "says so of the DIRECTORY when there is no commit at all" do
      orchestrator_id = Ecto.UUID.generate()
      session = plain_session("alert-no-commit-none-wording", %{status: "running"})
      {:ok, _} = tool_use_message(session.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[alert], _edge_state} = AlertEvaluator.evaluate([subscription])
      assert alert.message =~ "no commit in the directory yet"
      refute alert.message =~ "no commit observed yet"
    end

    test "the CONDITION itself is unchanged — still fires on the same input" do
      # The brief fixed the rendered text only; no_commit_for?/4 still keys
      # off the same directory-level number. Whether that is the right gate is
      # ORCAHUB3-111's question, not this change's.
      orchestrator_id = Ecto.UUID.generate()
      fresh = git_session("alert-no-commit-cond-fresh", %{status: "running"})
      {:ok, _} = tool_use_message(fresh.id, "Bash")

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [fresh.id],
          conditions: %{"no_commit_for" => 45}
        })

      assert {[], _edge_state} = AlertEvaluator.evaluate([subscription])
    end
  end

  describe "evaluate/3 — no subscriptions" do
    test "returns no alerts and an unchanged edge_state" do
      assert AlertEvaluator.evaluate([], DateTime.utc_now(), %{seed: true}) == {[], %{seed: true}}
    end
  end

  describe "edge_state shape - discriminator key constraint" do
    # Per the issue: churn/stall/progress_stale/no_commit_for entries must be
    # byte-identical maps (%{state:, last_alerted_at:}) with NO discriminator key.
    # The discriminator key is ONLY present on pending_question edge entries.
    test "churn edge entry contains no discriminator key" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("discriminator-churn-test", %{
          status: "running",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-20, :minute)
        })

      Enum.each(1..30, fn _ -> tool_use_message(session.id, "Bash") end)

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"churn" => true}
        })

      {[_alert], edge_state} = AlertEvaluator.evaluate([subscription])

      # Verify the edge_state has exactly one key
      assert map_size(edge_state) == 1

      # Get the edge entry and verify it has no discriminator key
      {{_, _, _}, edge_entry} = Enum.at(Map.to_list(edge_state), 0)
      refute Map.has_key?(edge_entry, :discriminator)
      assert edge_entry == %{state: true, last_alerted_at: edge_entry.last_alerted_at}
    end

    test "claude pending_question edge entry includes discriminator key" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("discriminator-pending-test", %{
          backend: "claude",
          status: "waiting"
        })

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"pending_question" => true},
          cooldown_seconds: 600
        })

      {[_alert], edge_state} = AlertEvaluator.evaluate([subscription])

      # Verify the edge_state has exactly one key
      assert map_size(edge_state) == 1

      # Get the edge entry and verify it has the discriminator key
      {{_, _, _}, edge_entry} = Enum.at(Map.to_list(edge_state), 0)
      assert Map.has_key?(edge_entry, :discriminator)
      assert edge_entry.discriminator == :claude_waiting
    end

    test "condition evaluating FALSE produces NO alert" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("churn-false-test", %{
          status: "running",
          progress_updated_at: DateTime.utc_now() |> DateTime.add(-1, :minute)
        })

      # No tool calls - churn.churn_suspected will be false

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"churn" => true}
        })

      assert {[], edge_state} = AlertEvaluator.evaluate([subscription])
      assert map_size(edge_state) == 1
      # Get the key from the map entry (subscription.id is the auto-generated primary key)
      {{sub_id, sess_id, cond}, edge_entry} = Enum.at(Map.to_list(edge_state), 0)
      assert sub_id == subscription.id
      assert sess_id == session.id
      assert cond == "churn"
      assert edge_entry.state == false
    end

    # Claude sessions use a constant discriminator (:claude_waiting) - same ID always
    test "claude waiting session alerts once and respects cooldown" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("claude-pending-test", %{
          backend: "claude",
          status: "waiting"
        })

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"pending_question" => true},
          cooldown_seconds: 600
        })

      now = DateTime.utc_now()

      # First evaluation: rising edge fires
      {[alert], edge_state} = AlertEvaluator.evaluate([subscription], now, %{})
      assert alert.condition == "pending_question"

      # Same discriminator (:claude_waiting), within cooldown (300s < 600s) - no re-alert
      assert {[], edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 300, :second),
                 edge_state
               )

      # Cooldown elapsed (660s > 600s) - re-alerts
      assert {[alert], _edge_state} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 660, :second),
                 edge_state
               )

      assert alert.condition == "pending_question"
    end

    # Pi sessions use real question IDs as discriminators - changed ID fires immediately
    test "pi session A->A->B transition: same question inside cooldown does not re-alert, changed question does" do
      orchestrator_id = Ecto.UUID.generate()

      session =
        plain_session("pi-question-transition-test", %{
          backend: "pi"
        })

      # Insert pending question "A"
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "pi_ui_request",
          "id" => "req-A",
          "method" => "input",
          "title" => "Question A",
          "message" => "Please enter A",
          "options" => []
        }
      })

      subscription =
        subscribe(orchestrator_id, %{
          session_ids: [session.id],
          conditions: %{"pending_question" => true},
          cooldown_seconds: 600
        })

      # Step 1: First question "A" pending - rising edge fires, discriminator is "A"
      now = DateTime.utc_now()
      {[alert_a1], edge_state_a} = AlertEvaluator.evaluate([subscription], now, %{})
      assert alert_a1.condition == "pending_question"

      # Verify edge_state has the discriminator key with value "A"
      # Key is {subscription.id, session.id, "pending_question"}
      edge_key = {subscription.id, session.id, "pending_question"}
      assert Map.has_key?(edge_state_a, edge_key)
      edge_entry_a = Map.get(edge_state_a, edge_key)
      assert edge_entry_a.discriminator == "req-A"

      # Step 2: Same question "A" still pending, within cooldown - no re-alert
      assert {[], edge_state_a} =
               AlertEvaluator.evaluate(
                 [subscription],
                 DateTime.add(now, 300, :second),
                 edge_state_a
               )

      # Step 3: Question changes to "B", still within cooldown - MUST fire (new rising edge)
      # First, remove question A by adding a response, then add question B
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "pi_ui_response",
          "id" => "req-A",
          "value" => "answered-A"
        }
      })

      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "pi_ui_request",
          "id" => "req-B",
          "method" => "select",
          "title" => "Question B",
          "message" => "Please select B",
          "options" => ["option1", "option2"]
        }
      })

      # New question "B" should fire immediately (different discriminator), ignoring cooldown
      # Use 400 seconds (inside the 600s cooldown) to prove discriminator change overrides cooldown
      {[alert_b], edge_state_b} =
        AlertEvaluator.evaluate([subscription], DateTime.add(now, 400, :second), edge_state_a)

      assert alert_b.condition == "pending_question"
      # Verify the discriminator changed to "B"
      edge_key_b = {subscription.id, session.id, "pending_question"}
      edge_entry_b = Map.get(edge_state_b, edge_key_b)
      assert edge_entry_b.discriminator == "req-B"
    end
  end
end
