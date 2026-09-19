defmodule OrcaHub.Sessions.SurgeryAlertPolicyTest do
  # No DB and no cluster: `alertable?/2` is a pure predicate and
  # `git_tracked?/2` runs against real tmp directories on this node.
  use ExUnit.Case, async: true

  alias OrcaHub.Sessions.SurgeryAlertPolicy

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        path: "lib/orca_hub/foo.ex",
        command: "cat > lib/orca_hub/foo.ex <<'EOF' ... EOF",
        kind: :write_to_tracked,
        paired_with_failed_edit: false,
        verified_in_command: false,
        same_path_matches: 1
      },
      overrides
    )
  end

  defp context(tracked, corroborated),
    do: %{tracked_in_git: tracked, has_corroborating_detail: corroborated}

  describe "alertable?/2 — the U1b truth table (suppress on D6 OR (D1 AND D2b))" do
    # D6 = no corroborating detail. It suppresses on its own, whatever git
    # and the same-command verification say.
    test "D6 alone suppresses, for every git state and every verification state" do
      for tracked <- [true, false, nil], verified <- [true, false] do
        refute SurgeryAlertPolicy.alertable?(
                 evidence(%{verified_in_command: verified}),
                 context(tracked, false)
               ),
               "expected D6 to suppress with tracked_in_git=#{inspect(tracked)} " <>
                 "verified_in_command=#{verified}"
      end
    end

    test "D1 AND D2b together suppress: untracked path, verified in the same command" do
      refute SurgeryAlertPolicy.alertable?(
               evidence(%{verified_in_command: true}),
               context(false, true)
             )
    end

    test "D1 without D2b does NOT suppress — D1 alone loses 2 of 3 true positives" do
      assert SurgeryAlertPolicy.alertable?(
               evidence(%{verified_in_command: false}),
               context(false, true)
             )
    end

    test "D2b without D1 does NOT suppress — a tracked path stays alertable" do
      assert SurgeryAlertPolicy.alertable?(
               evidence(%{verified_in_command: true}),
               context(true, true)
             )
    end

    test "a corroborated, tracked, unverified write is alertable" do
      assert SurgeryAlertPolicy.alertable?(evidence(), context(true, true))
    end

    test "tracked_in_git: nil is UNKNOWN and must not suppress, even with D2b" do
      assert SurgeryAlertPolicy.alertable?(
               evidence(%{verified_in_command: true}),
               context(nil, true)
             )

      assert SurgeryAlertPolicy.alertable?(
               evidence(%{verified_in_command: false}),
               context(nil, true)
             )
    end

    test "a missing verified_in_command field fails toward alerting" do
      bare = evidence() |> Map.delete(:verified_in_command)

      assert SurgeryAlertPolicy.alertable?(bare, context(false, true))
    end

    test "same_path_matches is informational only and never gates (D4 is rejected)" do
      for matches <- [1, 2, 7] do
        assert SurgeryAlertPolicy.alertable?(
                 evidence(%{same_path_matches: matches}),
                 context(true, true)
               )

        refute SurgeryAlertPolicy.alertable?(
                 evidence(%{same_path_matches: matches, verified_in_command: true}),
                 context(false, true)
               )
      end
    end

    test "paired_with_failed_edit is not a gate either (D3 is an off switch)" do
      # Kept in the evidence map for mining; requiring it would suppress 100%
      # of the corpus and lose 3/3 true positives.
      assert SurgeryAlertPolicy.alertable?(
               evidence(%{paired_with_failed_edit: false}),
               context(true, true)
             )
    end

    test "no evidence at all is not alertable" do
      refute SurgeryAlertPolicy.alertable?(nil, context(true, true))
    end
  end

  describe "alertable?/2 — churn_alert_precision.md §E ground truth" do
    test "the deploy-runner shape is suppressed" do
      # `sed -e 's/^SHA=<old>/SHA=<new>/' run-<old>.sh > run-<new>.sh &&
      #  chmod +x run-<new>.sh && diff ...` — outside any repo, verified in
      # the same command, and the window carried neither edited files nor
      # repeated signatures. 12/12 of these fired in production; U1b kills
      # all 12 (11 via D6, all 12 via D1 AND D2b).
      deploy_runner =
        evidence(%{
          path: "run-dc6d8cc.sh",
          command:
            "cd /home/zach/orca-hub-deploy-logs && sed -e 's/^SHA=e62debf$/SHA=dc6d8cc/' " <>
              "run-e62debf.sh > run-dc6d8cc.sh && chmod +x run-dc6d8cc.sh && diff run-e62debf.sh run-dc6d8cc.sh",
          kind: :write_to_tracked,
          verified_in_command: true
        })

      refute SurgeryAlertPolicy.alertable?(deploy_runner, context(false, false)), "D6 arm"
      refute SurgeryAlertPolicy.alertable?(deploy_runner, context(false, true)), "D1 AND D2b arm"
    end

    test "the nohup/until-loop shape is PRESERVED" do
      # Worker b5cf3756, 2026-09-19 00:23 — the one alert ORCAHUB3-66 must
      # not damage. It also writes outside git (a scratch harness under
      # tmp/voice2c/), which is exactly why D1 alone is rejected; it survives
      # because it does NOT verify in the same command and it DOES carry a
      # `Repeated calls:` block (the `until grep -q ...; sleep 10; done` loop).
      poll_loop =
        evidence(%{
          path: "build_clips.py",
          command: "python3 - <<'PY'\n...patch build_clips.py...\nPY",
          kind: :programmatic_write,
          verified_in_command: false
        })

      assert SurgeryAlertPolicy.alertable?(poll_loop, context(false, true))
    end

    test "the §C.4 live specimen (three writes to a scratch script) is suppressed" do
      # `cat > probe1.exs <<'EOF' ... EOF && mix run ... probe1.exs` — outside
      # any repo, EXECUTES what it just wrote (D2a misses this; D2b catches
      # it), and same_path_matches == 3, which D4 would have read as a repair
      # loop. D4 is not consulted.
      specimen =
        evidence(%{
          path: "/home/zach/orca-hub-churn-analysis/probe1.exs",
          command:
            "cat > /home/zach/orca-hub-churn-analysis/probe1.exs <<'EOF' ... EOF\n" <>
              "export $(grep -E '^DB_' .env | xargs) && mix run --no-start --no-compile " <>
              "/home/zach/orca-hub-churn-analysis/probe1.exs 2>&1 | head -80",
          kind: :write_to_tracked,
          verified_in_command: true,
          same_path_matches: 3
        })

      refute SurgeryAlertPolicy.alertable?(specimen, context(false, true))
    end
  end

  describe "corroborating_detail?/1" do
    test "true when either top_edited_files or top_repeated_signatures is non-empty" do
      assert SurgeryAlertPolicy.corroborating_detail?(%{
               top_edited_files: [%{path: "lib/a.ex", count: 3}],
               top_repeated_signatures: [],
               failing_tests: []
             })

      assert SurgeryAlertPolicy.corroborating_detail?(%{
               top_edited_files: [],
               top_repeated_signatures: [%{tool: "Bash", count: 2, sample: "until grep -q"}],
               failing_tests: []
             })
    end

    test "false when both are empty — failing_tests alone does not count (§D's D6)" do
      refute SurgeryAlertPolicy.corroborating_detail?(%{
               top_edited_files: [],
               top_repeated_signatures: [],
               failing_tests: [%{summary: "3 tests, 1 failure", failing_test_names: []}]
             })
    end

    test "a nil detail carries nothing" do
      refute SurgeryAlertPolicy.corroborating_detail?(nil)
    end
  end

  describe "git_tracked?/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "surgery-policy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "lib"))
      on_exit(fn -> File.rm_rf(dir) end)

      System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "lib/tracked.ex"), "defmodule Tracked do end\n")
      System.cmd("git", ["add", "lib/tracked.ex"], cd: dir)
      System.cmd("git", ["commit", "-m", "initial"], cd: dir, stderr_to_stdout: true)

      {:ok, dir: dir}
    end

    test "true for a committed path", %{dir: dir} do
      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "lib/tracked.ex") == true
    end

    test "false for an untracked path inside the repo", %{dir: dir} do
      File.write!(Path.join(dir, "lib/scratch.ex"), "scratch\n")
      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "lib/scratch.ex") == false
    end

    test "false for a path that does not exist at all", %{dir: dir} do
      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "lib/nope.ex") == false
    end

    test "false for an absolute path outside the repo", %{dir: dir} do
      outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.sh")
      File.write!(outside, "#!/bin/bash\n")
      on_exit(fn -> File.rm_rf(outside) end)

      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, outside) == false
    end

    test "false when the working directory is not a git repository at all" do
      plain = Path.join(System.tmp_dir!(), "surgery-norepo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      File.write!(Path.join(plain, "notes.md"), "hi\n")
      on_exit(fn -> File.rm_rf(plain) end)

      assert SurgeryAlertPolicy.git_tracked?(%{directory: plain}, "notes.md") == false
    end

    test "nil (UNKNOWN) when the directory is gone" do
      gone = Path.join(System.tmp_dir!(), "surgery-gone-#{System.unique_integer([:positive])}")
      assert SurgeryAlertPolicy.git_tracked?(%{directory: gone}, "lib/a.ex") == nil
    end

    test "nil (UNKNOWN) for a missing directory or a blank path", %{dir: dir} do
      assert SurgeryAlertPolicy.git_tracked?(%{directory: nil}, "lib/tracked.ex") == nil
      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, nil) == nil
      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "   ") == nil
    end

    test "nil (UNKNOWN) when the session's runner node is unreachable — never a local fallback",
         %{dir: dir} do
      # The path IS tracked locally; routing it to the assigned (dead) node
      # must still answer UNKNOWN rather than quietly answering from here.
      session = %{directory: dir, runner_node: "orca@definitely-not-a-real-node-66"}

      assert SurgeryAlertPolicy.git_tracked?(session, "lib/tracked.ex") == nil
    end

    test "a path containing shell metacharacters is never interpreted", %{dir: dir} do
      canary = Path.join(dir, "pwned")

      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "lib/x.ex; touch pwned") == false
      refute File.exists?(canary)

      assert SurgeryAlertPolicy.git_tracked?(%{directory: dir}, "$(touch pwned)") == false
      refute File.exists?(canary)
    end
  end
end
