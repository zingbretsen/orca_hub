defmodule OrcaHub.MCP.Tools.JobsTest do
  @moduledoc """
  Coverage for the Jobs MCP tool surface (ORCAHUB3-25) — `start_job`
  launches REAL detached processes (no mocking, same reasoning as
  `OrcaHub.JobWatcherTest`), so this runs `async: false`.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.HubRPC
  alias OrcaHub.Jobs.Paths
  alias OrcaHub.MCP.Tools.Jobs, as: JobsTool
  alias OrcaHub.{Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp_jobs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "mcp-jobs-test", directory: dir, node: "n1@x"})

    {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})

    {:ok, project: project, session: session, state: %{orca_session_id: session.id}}
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: Jason.decode!(body)
  defp error_text(%{"content" => [%{"text" => body}]}), do: body

  defp cleanup(job_id) do
    [
      Paths.cmd_script_path(job_id),
      Paths.wrapper_script_path(job_id),
      Paths.log_path(job_id),
      Paths.sentinel_path(job_id),
      Paths.pid_path(job_id),
      Paths.verify_cmd_script_path(job_id),
      Paths.verify_wrapper_script_path(job_id),
      Paths.verify_log_path(job_id),
      Paths.verify_sentinel_path(job_id),
      Paths.verify_pid_path(job_id)
    ]
    |> Enum.each(&File.rm/1)
  end

  defp wait_for_status(job_id, statuses, tries \\ 100) do
    job = HubRPC.get_job(job_id)

    cond do
      job.status in statuses ->
        job

      tries <= 0 ->
        flunk("job #{job_id} never reached #{inspect(statuses)}, stuck at #{job.status}")

      true ->
        Process.sleep(50)
        wait_for_status(job_id, statuses, tries - 1)
    end
  end

  describe "list/0" do
    test "exposes all six tools" do
      names = JobsTool.list() |> Enum.map(& &1["name"])

      assert names ==
               ~w(start_job check_job list_jobs cancel_job wait_for_job update_job_progress_metric)

      start_job = Enum.find(JobsTool.list(), &(&1["name"] == "start_job"))
      assert start_job["inputSchema"]["required"] == ["command"]
    end
  end

  describe "start_job" do
    test "launches a real detached job scoped to the session's directory", %{
      state: state,
      session: session
    } do
      assert %{"isError" => false} =
               result = JobsTool.call("start_job", %{"command" => "echo hi; exit 0"}, state)

      body = decode(result)
      on_exit(fn -> cleanup(body["job_id"]) end)

      assert is_binary(body["job_id"])
      assert body["status"] == "running"

      job = HubRPC.get_job(body["job_id"])
      assert job.session_id == session.id
      assert job.directory == session.directory
      assert job.runner_node == Atom.to_string(node())

      final = wait_for_status(job.id, ~w(succeeded failed))
      assert final.status == "succeeded"
    end

    test "cwd overrides the session's directory", %{state: state} do
      other_dir = System.tmp_dir!()

      assert %{"isError" => false} =
               result =
               JobsTool.call("start_job", %{"command" => "exit 0", "cwd" => other_dir}, state)

      body = decode(result)
      on_exit(fn -> cleanup(body["job_id"]) end)

      assert HubRPC.get_job(body["job_id"]).directory == other_dir
    end

    test "declares a file_bytes progress metric", %{state: state} do
      path =
        Path.join(System.tmp_dir!(), "start-job-progress-#{System.unique_integer([:positive])}")

      File.write!(path, "hello")
      on_exit(fn -> File.rm(path) end)

      result =
        JobsTool.call(
          "start_job",
          %{"command" => "sleep 1", "progress_path" => path, "progress_expect_bytes" => 100},
          state
        )

      body = decode(result)
      on_exit(fn -> cleanup(body["job_id"]) end)

      job = HubRPC.get_job(body["job_id"])
      assert job.progress_kind == "file_bytes"
      assert job.progress_path == path
      assert job.progress_expect_bytes == 100

      wait_for_status(job.id, ~w(succeeded failed))
    end

    test "requires a non-empty command", %{state: state} do
      assert %{"isError" => true} = result = JobsTool.call("start_job", %{}, state)
      assert error_text(result) =~ "non-empty"
    end

    test "errors when no session is linked" do
      assert %{"isError" => true} =
               result =
               JobsTool.call("start_job", %{"command" => "exit 0"}, %{orca_session_id: nil})

      assert error_text(result) =~ "No OrcaHub session"
    end
  end

  describe "check_job" do
    test "reports status, progress age, exit codes, and a log tail", %{state: state} do
      body =
        JobsTool.call("start_job", %{"command" => "echo check-job-output; exit 0"}, state)
        |> decode()

      on_exit(fn -> cleanup(body["job_id"]) end)
      wait_for_status(body["job_id"], ~w(succeeded failed))

      result = JobsTool.call("check_job", %{"job_id" => body["job_id"]}, state)
      assert %{"isError" => false} = result
      view = decode(result)

      assert view["status"] == "succeeded"
      assert view["exit_code"] == 0
      assert view["log_tail"] =~ "check-job-output"
      assert is_nil(view["progress"]["updated_at_age_seconds"])
    end

    test "errors for an unknown job_id", %{state: state} do
      assert %{"isError" => true} =
               result = JobsTool.call("check_job", %{"job_id" => Ecto.UUID.generate()}, state)

      assert error_text(result) =~ "No job found"
    end
  end

  describe "list_jobs" do
    test "defaults to only this session's jobs; mine=false shows everything", %{state: state} do
      mine = JobsTool.call("start_job", %{"command" => "exit 0"}, state) |> decode()
      on_exit(fn -> cleanup(mine["job_id"]) end)

      {:ok, other_project} =
        Projects.create_project(%{
          name: "other-#{System.unique_integer([:positive])}",
          directory: System.tmp_dir!(),
          node: "n1@x"
        })

      {:ok, other_session} =
        Sessions.create_session(%{directory: System.tmp_dir!(), project_id: other_project.id})

      other =
        JobsTool.call("start_job", %{"command" => "exit 0"}, %{orca_session_id: other_session.id})
        |> decode()

      on_exit(fn -> cleanup(other["job_id"]) end)
      wait_for_status(mine["job_id"], ~w(succeeded failed))
      wait_for_status(other["job_id"], ~w(succeeded failed))

      only_mine = JobsTool.call("list_jobs", %{}, state) |> decode()
      ids = Enum.map(only_mine["jobs"], & &1["id"])
      assert mine["job_id"] in ids
      refute other["job_id"] in ids

      everything = JobsTool.call("list_jobs", %{"mine" => false}, state) |> decode()
      all_ids = Enum.map(everything["jobs"], & &1["id"])
      assert mine["job_id"] in all_ids
      assert other["job_id"] in all_ids
    end

    test "filters by status", %{state: state} do
      failed = JobsTool.call("start_job", %{"command" => "exit 1"}, state) |> decode()
      on_exit(fn -> cleanup(failed["job_id"]) end)
      wait_for_status(failed["job_id"], ~w(succeeded failed))

      result = JobsTool.call("list_jobs", %{"status" => "failed"}, state) |> decode()
      assert Enum.any?(result["jobs"], &(&1["id"] == failed["job_id"]))
      assert Enum.all?(result["jobs"], &(&1["status"] == "failed"))
    end
  end

  describe "cancel_job" do
    test "kills a running job", %{state: state} do
      body = JobsTool.call("start_job", %{"command" => "sleep 30"}, state) |> decode()
      on_exit(fn -> cleanup(body["job_id"]) end)

      assert %{"isError" => false} =
               JobsTool.call("cancel_job", %{"job_id" => body["job_id"]}, state)

      final = wait_for_status(body["job_id"], ~w(cancelled succeeded failed))
      assert final.status == "cancelled"
    end

    test "reports (without erroring) that an already-terminal job has nothing to cancel", %{
      state: state
    } do
      body = JobsTool.call("start_job", %{"command" => "exit 0"}, state) |> decode()
      on_exit(fn -> cleanup(body["job_id"]) end)
      wait_for_status(body["job_id"], ~w(succeeded failed))

      result = JobsTool.call("cancel_job", %{"job_id" => body["job_id"]}, state)
      assert %{"isError" => false} = result
      assert error_text(result) =~ "already reached a terminal status"
    end

    test "errors for an unknown job_id", %{state: state} do
      assert %{"isError" => true} =
               result = JobsTool.call("cancel_job", %{"job_id" => Ecto.UUID.generate()}, state)

      assert error_text(result) =~ "No job found"
    end
  end

  describe "wait_for_job" do
    test "returns the terminal state once the job finishes", %{state: state} do
      body = JobsTool.call("start_job", %{"command" => "sleep 1; exit 0"}, state) |> decode()
      on_exit(fn -> cleanup(body["job_id"]) end)

      result =
        JobsTool.call(
          "wait_for_job",
          %{"job_id" => body["job_id"], "max_wait_seconds" => 10},
          state
        )

      view = decode(result)
      assert view["status"] == "succeeded"
      refute Map.has_key?(view, "wait_timed_out")
    end

    test "returns the current (still-running) state when the budget runs out", %{state: state} do
      body = JobsTool.call("start_job", %{"command" => "sleep 5"}, state) |> decode()

      on_exit(fn ->
        cleanup(body["job_id"])
        JobsTool.call("cancel_job", %{"job_id" => body["job_id"]}, state)
      end)

      result =
        JobsTool.call(
          "wait_for_job",
          %{"job_id" => body["job_id"], "max_wait_seconds" => 1},
          state
        )

      view = decode(result)
      assert view["status"] == "running"
      assert view["wait_timed_out"] == true
    end
  end

  describe "update_job_progress_metric" do
    test "re-declares the metric mid-flight, taking effect on the next poll", %{state: state} do
      body = JobsTool.call("start_job", %{"command" => "sleep 1"}, state) |> decode()
      on_exit(fn -> cleanup(body["job_id"]) end)

      path = Path.join(System.tmp_dir!(), "update-metric-#{System.unique_integer([:positive])}")
      File.write!(path, "1234")
      on_exit(fn -> File.rm(path) end)

      result =
        JobsTool.call(
          "update_job_progress_metric",
          %{"job_id" => body["job_id"], "progress_path" => path},
          state
        )

      assert %{"isError" => false} = result

      job = HubRPC.get_job(body["job_id"])
      assert job.progress_kind == "file_bytes"
      assert job.progress_path == path

      wait_for_status(body["job_id"], ~w(succeeded failed))
    end

    test "errors when neither progress_path nor progress_command is given", %{state: state} do
      body = JobsTool.call("start_job", %{"command" => "exit 0"}, state) |> decode()
      on_exit(fn -> cleanup(body["job_id"]) end)
      wait_for_status(body["job_id"], ~w(succeeded failed))

      result = JobsTool.call("update_job_progress_metric", %{"job_id" => body["job_id"]}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "Provide either"
    end
  end
end
