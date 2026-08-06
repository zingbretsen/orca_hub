defmodule OrcaHub.IssuesKeyAllocationTest do
  @moduledoc """
  Coverage for the concurrency guarantee behind `OrcaHub.Issues.create_issue/1`'s
  atomic key allocation (issues_spec.md §3.2.2): two concurrent creates
  against the SAME project must land on distinct `key_number`s, never a
  duplicate. Split out from `OrcaHub.IssuesTest` because it needs a shared
  (non-async) sandbox so spawned `Task`s can use the test's DB connection —
  see `OrcaHub.DataCase`'s `shared: not tags[:async]` sandbox setup.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "issues_key_alloc_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "issues-key-alloc-test",
        directory: dir,
        node: "n1@x",
        key_prefix: "KA" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  test "two concurrent create_issue/1 calls against the same project allocate distinct key_numbers",
       %{project: project} do
    tasks =
      for n <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(OrcaHub.Repo, self(), self())
          Issues.create_issue(%{title: "concurrent issue #{n}", project_id: project.id})
        end)
      end

    results = Task.await_many(tasks, 5_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    key_numbers = Enum.map(results, fn {:ok, issue} -> issue.key_number end)

    assert Enum.sort(key_numbers) == [1, 2]
    assert length(Enum.uniq(key_numbers)) == 2
  end

  test "N concurrent create_issue/1 calls against the same project never duplicate a key_number",
       %{project: project} do
    n = 8

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(OrcaHub.Repo, self(), self())
          Issues.create_issue(%{title: "burst issue #{i}", project_id: project.id})
        end)
      end

    results = Task.await_many(tasks, 10_000)
    key_numbers = Enum.map(results, fn {:ok, issue} -> issue.key_number end)

    assert Enum.sort(key_numbers) == Enum.to_list(1..n)
    assert Repo.get!(OrcaHub.Projects.Project, project.id).issue_counter == n
  end
end
