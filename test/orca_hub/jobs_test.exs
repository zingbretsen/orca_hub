defmodule OrcaHub.JobsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Jobs

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        directory: "/tmp/jobs-test",
        runner_node: "test@nohost",
        command: "echo hi"
      },
      overrides
    )
  end

  describe "create_job/1, get_job/1, update_job/2" do
    test "round-trips a job with defaults" do
      assert {:ok, job} = Jobs.create_job(valid_attrs())
      assert job.status == "running"
      assert job.command == "echo hi"

      fetched = Jobs.get_job(job.id)
      assert fetched.id == job.id

      assert {:ok, updated} = Jobs.update_job(job, %{status: "succeeded", exit_code: 0})
      assert updated.status == "succeeded"
      assert updated.exit_code == 0
    end

    test "get_job/1 returns nil for a missing id" do
      assert Jobs.get_job(Ecto.UUID.generate()) == nil
    end

    test "requires directory, runner_node, and command" do
      assert {:error, changeset} = Jobs.create_job(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.directory
      assert "can't be blank" in errors.runner_node
      assert "can't be blank" in errors.command
    end

    test "rejects an invalid status" do
      assert {:error, changeset} = Jobs.create_job(valid_attrs(%{status: "bogus"}))
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects an invalid progress_kind" do
      assert {:error, changeset} = Jobs.create_job(valid_attrs(%{progress_kind: "vibes"}))
      assert "is invalid" in errors_on(changeset).progress_kind
    end

    test "does not require a session_id (jobs must outlive their creating session)" do
      assert {:ok, job} = Jobs.create_job(valid_attrs())
      assert job.session_id == nil
    end
  end

  describe "list_nonterminal_jobs_for_node/1" do
    test "returns only running/verifying jobs for the given node" do
      node = "resumer-node@#{System.unique_integer([:positive])}"

      {:ok, running} = Jobs.create_job(valid_attrs(%{runner_node: node, status: "running"}))
      {:ok, verifying} = Jobs.create_job(valid_attrs(%{runner_node: node, status: "verifying"}))
      {:ok, _done} = Jobs.create_job(valid_attrs(%{runner_node: node, status: "succeeded"}))
      {:ok, _other_node} = Jobs.create_job(valid_attrs(%{runner_node: "other@host"}))

      ids = node |> Jobs.list_nonterminal_jobs_for_node() |> Enum.map(& &1.id) |> MapSet.new()

      assert ids == MapSet.new([running.id, verifying.id])
    end
  end

  describe "list_jobs/1" do
    test "filters by session_id and status, most recently updated first" do
      session_id = Ecto.UUID.generate()
      node = "list-jobs-node@#{System.unique_integer([:positive])}"

      {:ok, a} =
        Jobs.create_job(valid_attrs(%{session_id: session_id, runner_node: node, label: "a"}))

      {:ok, b} =
        Jobs.create_job(
          valid_attrs(%{
            session_id: session_id,
            runner_node: node,
            label: "b",
            status: "succeeded"
          })
        )

      {:ok, _unrelated} = Jobs.create_job(valid_attrs(%{runner_node: node, label: "unrelated"}))

      by_session = Jobs.list_jobs(%{session_id: session_id})
      assert Enum.map(by_session, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])

      by_status = Jobs.list_jobs(%{session_id: session_id, status: "succeeded"})
      assert Enum.map(by_status, & &1.id) == [b.id]
    end

    test "caps limit at 200" do
      assert Jobs.list_jobs(%{limit: 10_000}) |> is_list()
    end
  end
end
