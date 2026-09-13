defmodule OrcaHub.Triggers.SetupScriptTest do
  @moduledoc """
  Exercises the real port/`setsid` path — these tests spawn actual shell
  processes, so `async: false` (shared sandbox) both for the DB lookups
  `OrcaHub.NodePolicy` does while building the env and to keep concurrent
  tests from fighting over process-group signals.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.Triggers.SetupScript
  alias OrcaHub.Triggers.SetupScript.Result

  setup do
    dir = Path.join(System.tmp_dir!(), "setup_script_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "configured?/1 and timeout_seconds/1" do
    test "a nil or blank script is not configured" do
      refute SetupScript.configured?(%{setup_script: nil})
      refute SetupScript.configured?(%{setup_script: ""})
      refute SetupScript.configured?(%{setup_script: "   \n"})
      assert SetupScript.configured?(%{setup_script: "date -u"})
    end

    test "the timeout falls back to 120s for a nil/invalid column" do
      assert SetupScript.timeout_seconds(%{setup_timeout_seconds: 5}) == 5
      assert SetupScript.timeout_seconds(%{setup_timeout_seconds: nil}) == 120
      assert SetupScript.timeout_seconds(%{setup_timeout_seconds: 0}) == 120
      assert SetupScript.timeout_seconds(%{}) == 120
    end
  end

  describe "execute/4" do
    test "captures output of a successful script and reports exit code 0", %{dir: dir} do
      result = SetupScript.execute("echo hello-from-setup", dir, 10)

      assert result.exit_code == 0
      assert result.timed_out == false
      assert result.error == nil
      assert result.truncated_bytes == 0
      assert result.output =~ "hello-from-setup"
      refute Result.failed?(result)
    end

    # The motivating production case: `date -u` as a setup script instead of
    # "run `date -u` before you do anything else" in the prompt.
    test "the motivating `date -u` case works", %{dir: dir} do
      result = SetupScript.execute("date -u", dir, 10)

      assert result.exit_code == 0
      assert result.output =~ ~r/UTC|GMT/
    end

    test "stdout and stderr are combined", %{dir: dir} do
      result = SetupScript.execute("echo to-stdout; echo to-stderr >&2", dir, 10)

      assert result.exit_code == 0
      assert result.output =~ "to-stdout"
      assert result.output =~ "to-stderr"
    end

    test "runs in the session's directory", %{dir: dir} do
      result = SetupScript.execute("pwd", dir, 10)

      # macOS resolves /tmp through a symlink, so compare the realpath.
      assert String.trim(result.output) == File.cd!(dir, fn -> File.cwd!() end)
    end

    test "a non-zero exit is reported, not raised", %{dir: dir} do
      result = SetupScript.execute("echo about-to-fail; exit 3", dir, 10)

      assert result.exit_code == 3
      assert result.timed_out == false
      assert result.output =~ "about-to-fail"
      assert Result.failed?(result)
    end

    test "a missing directory becomes an error result rather than a crash" do
      result = SetupScript.execute("echo hi", "/definitely/not/a/real/dir", 10)

      assert result.exit_code == nil
      assert result.error =~ "does not exist"
      assert Result.failed?(result)
    end

    test "a script that runs long is killed at the timeout", %{dir: dir} do
      result = SetupScript.execute("echo starting; sleep 30", dir, 1)

      assert result.timed_out == true
      assert result.exit_code == nil
      assert result.output =~ "starting"
      assert Result.failed?(result)
      # Bounded: the 30s sleep must not have been waited out.
      assert result.duration_ms < 10_000
    end

    test "a timeout kills the whole process group, not just the direct child", %{dir: dir} do
      child_pid_file = Path.join(dir, "child.pid")

      script = """
      sh -c 'sleep 60' &
      echo $! > #{child_pid_file}
      sleep 60
      """

      result = SetupScript.execute(script, dir, 1)
      assert result.timed_out == true

      child_pid =
        child_pid_file
        |> File.read!()
        |> String.trim()
        |> String.to_integer()

      # Give the KILL a moment to be reaped, then confirm the grandchild the
      # script backgrounded is gone too — an orphaned `sleep 60` is exactly
      # what the setsid/process-group handling exists to prevent.
      Process.sleep(300)
      refute alive?(child_pid), "backgrounded child #{child_pid} survived the group kill"
    end

    test "output over 16KB keeps the TAIL and is marked as truncated", %{dir: dir} do
      # ~40KB of filler, then the marker that must survive.
      script = """
      i=0
      while [ $i -lt 400 ]; do
        echo "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
        i=$((i + 1))
      done
      echo THE-VERY-LAST-LINE
      """

      result = SetupScript.execute(script, dir, 20)

      assert result.exit_code == 0
      assert result.truncated_bytes > 0
      assert result.output =~ "[... truncated #{result.truncated_bytes} bytes ...]"
      # The tail (where an error would be) survives; the head does not.
      assert result.output =~ "THE-VERY-LAST-LINE"
      # 16KB cap plus the one-line marker.
      assert byte_size(result.output) < 16 * 1024 + 100
    end
  end

  describe "run/3" do
    setup %{dir: dir} do
      {:ok, project} = OrcaHub.Projects.create_project(%{name: "setup script", directory: dir})

      {:ok, session} =
        OrcaHub.Sessions.create_session(%{
          directory: dir,
          project_id: project.id,
          status: "ready"
        })

      {:ok, trigger} =
        OrcaHub.Triggers.create_trigger(%{
          name: "Setup trigger",
          prompt: "Do the thing",
          cron_expression: "0 3 * * *",
          project_id: project.id,
          setup_script: "echo ran-the-setup",
          setup_timeout_seconds: 10
        })

      %{project: project, session: session, trigger: trigger}
    end

    test "returns nil (and does nothing) when the trigger has no setup script", %{
      trigger: trigger,
      session: session
    } do
      {:ok, trigger} = OrcaHub.Triggers.update_trigger(trigger, %{setup_script: nil})

      assert SetupScript.run(trigger, session.id, node()) == nil
      assert setup_events(session.id) == []
    end

    test "runs the script and persists a system event", %{trigger: trigger, session: session} do
      result = SetupScript.run(trigger, session.id, node())

      assert %Result{exit_code: 0} = result
      assert result.output =~ "ran-the-setup"

      assert [event] = setup_events(session.id)
      assert event["type"] == "system"
      assert event["subtype"] == "setup_script"
      assert event["trigger_id"] == trigger.id
      assert event["trigger_name"] == "Setup trigger"
      assert event["script"] == "echo ran-the-setup"
      assert event["exit_code"] == 0
      assert event["timed_out"] == false
      assert event["failed"] == false
      assert event["output"] =~ "ran-the-setup"
    end

    test "a failing script still persists an event flagged as failed", %{
      trigger: trigger,
      session: session
    } do
      {:ok, trigger} = OrcaHub.Triggers.update_trigger(trigger, %{setup_script: "exit 7"})

      result = SetupScript.run(trigger, session.id, node())

      assert result.exit_code == 7
      assert [event] = setup_events(session.id)
      assert event["exit_code"] == 7
      assert event["failed"] == true
    end

    test "an unavailable runner node degrades to an error result, not a raise", %{
      trigger: trigger,
      session: session
    } do
      result = SetupScript.run(trigger, session.id, :"orca@totally-offline-host")

      assert %Result{} = result
      assert result.error =~ "could not run the setup script"
      assert Result.failed?(result)
      # Still visible to a human even though nothing ran.
      assert [event] = setup_events(session.id)
      assert event["failed"] == true
    end
  end

  describe "block/1 and prepend/2" do
    test "a nil result leaves the prompt untouched" do
      assert SetupScript.prepend(nil, "the prompt") == "the prompt"
    end

    test "success reads as success and carries exit code, duration and output" do
      block =
        SetupScript.block(%Result{
          output: "Sat Sep 13 08:00:00 UTC 2026",
          exit_code: 0,
          duration_ms: 12
        })

      assert block =~ "<setup_script>"
      assert block =~ "</setup_script>"
      assert block =~ "status: success (exit code 0)"
      assert block =~ "duration: 12ms"
      assert block =~ "<setup_output>"
      assert block =~ "Sat Sep 13 08:00:00 UTC 2026"
      refute block =~ "did NOT complete successfully"
    end

    test "a non-zero exit is unmistakable" do
      block = SetupScript.block(%Result{output: "fatal: not a git repository", exit_code: 128})

      assert block =~ "status: FAILED — exit code 128"
      assert block =~ "did NOT complete successfully"
    end

    test "a timeout says so, and that children were killed" do
      block = SetupScript.block(%Result{output: "", timed_out: true, duration_ms: 120_000})

      assert block =~ "status: FAILED — timed out after 120.0s"
      assert block =~ "child processes were killed"
      assert block =~ "did NOT complete successfully"
    end

    test "an infrastructure error surfaces in the status line" do
      block = SetupScript.block(%Result{error: "node down"})

      assert block =~ "status: FAILED — node down"
    end

    test "prepend puts the block ahead of the prompt" do
      prompt = SetupScript.prepend(%Result{output: "ok", exit_code: 0}, "Do the thing")

      assert String.starts_with?(prompt, "<setup_script>")
      assert prompt =~ "Do the thing"

      [block, rest] = String.split(prompt, "</setup_script>", parts: 2)
      assert block =~ "ok"
      assert rest =~ "Do the thing"
    end
  end

  defp setup_events(session_id) do
    import Ecto.Query

    from(m in OrcaHub.Sessions.Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'subtype' = 'setup_script'", m.data),
      order_by: [asc: m.inserted_at],
      select: m.data
    )
    |> OrcaHub.Repo.all()
  end

  defp alive?(pid) when is_integer(pid) do
    {out, _} = System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null && echo alive || echo dead"])
    String.trim(out) == "alive"
  end
end
