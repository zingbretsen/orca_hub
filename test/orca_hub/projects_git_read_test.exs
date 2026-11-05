defmodule OrcaHub.ProjectsGitReadTest do
  @moduledoc """
  The project page's git panels (git_log/git_branch/git_branches/
  git_worktree_list, and git_status for the index) run through
  `Projects.git_read/3`, which bounds each git call with coreutils
  `timeout`. System.cmd has no deadline of its own and a local Cluster.rpc
  is a plain apply, so a hung git used to hang the page mount.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Projects
  alias OrcaHub.Projects.Project

  setup do
    dir = Path.join(System.tmp_dir!(), "projects_git_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "T"], cd: dir)
    File.write!(Path.join(dir, "a.txt"), "a")
    {_, 0} = System.cmd("git", ["add", "a.txt"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "first commit"], cd: dir, stderr_to_stdout: true)

    {:ok, dir: dir}
  end

  test "the panel readers still return their parsed results", %{dir: dir} do
    project = %Project{directory: dir}

    assert [%{subject: "first commit", author: "T"}] = Projects.git_log(project)
    assert Projects.git_branch(project) == "main"
    assert Projects.git_branches(project) == ["main"]
    assert Projects.git_worktree_list(project) == []
    assert %{clean: true, error: nil} = Projects.git_status(project)
  end

  test "a git call that outlives the deadline is killed and reported", %{dir: dir} do
    # A shell alias makes git run `sleep`; `timeout` signals the whole
    # process group, so the sleep dies with git and System.cmd returns.
    {micros, {output, code}} =
      :timer.tc(fn -> Projects.git_read(dir, ["-c", "alias.hang=!sleep 30", "hang"], 1) end)

    assert code in [124, 137]
    assert output =~ "timed out after 1s"
    assert micros < 5_000_000
  end
end
