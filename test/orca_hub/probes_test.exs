defmodule OrcaHub.ProbesTest do
  @moduledoc """
  Coverage for the ORCAHUB3-28 probe primitives — no DB, pure filesystem/git
  I/O, so this is a plain ExUnit.Case (not DataCase) and runs async.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Probes

  defp tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "probes-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git!(dir, args), do: {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp init_repo(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    dir
  end

  defp commit!(dir, filename, content, message) do
    File.write!(Path.join(dir, filename), content)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", message])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    String.trim(sha)
  end

  # ---------------------------------------------------------------------
  # git_status/1
  # ---------------------------------------------------------------------

  describe "git_status/1" do
    test "reports a clean tree" do
      dir = tmp_dir("status-clean") |> init_repo()
      commit!(dir, "a.txt", "hi", "initial")

      assert {:ok, %{clean: true, entries: []}} = Probes.git_status(dir)
    end

    test "reports a dirty tree with porcelain entries" do
      dir = tmp_dir("status-dirty") |> init_repo()
      commit!(dir, "a.txt", "hi", "initial")
      File.write!(Path.join(dir, "b.txt"), "new")
      File.write!(Path.join(dir, "a.txt"), "changed")

      assert {:ok, %{clean: false, entries: entries}} = Probes.git_status(dir)
      assert length(entries) == 2
      assert Enum.any?(entries, &(&1.path == "a.txt"))
      assert Enum.any?(entries, &(&1.path == "b.txt" and &1.status == "??"))
    end

    test "errors for a non-repo directory" do
      dir = tmp_dir("status-not-repo")
      assert {:error, msg} = Probes.git_status(dir)
      assert msg =~ "not a git repository"
    end

    test "errors (does not raise) for a missing directory" do
      assert {:error, msg} =
               Probes.git_status("/nonexistent/path/#{System.unique_integer([:positive])}")

      assert msg =~ "not a directory"
    end

    test "handles a git worktree (gitdir pointer file, not a directory)" do
      dir = tmp_dir("status-worktree") |> init_repo()
      commit!(dir, "a.txt", "hi", "initial")
      worktree_path = Path.join(dir, "wt")
      git!(dir, ["worktree", "add", "-q", worktree_path, "-b", "wt-branch"])

      assert {:ok, %{clean: true}} = Probes.git_status(worktree_path)
    end
  end

  # ---------------------------------------------------------------------
  # git_head/1
  # ---------------------------------------------------------------------

  describe "git_head/1" do
    test "returns sha/short_sha/subject" do
      dir = tmp_dir("head") |> init_repo()
      sha = commit!(dir, "a.txt", "hi", "initial commit")

      assert {:ok, %{sha: ^sha, short_sha: short_sha, subject: "initial commit"}} =
               Probes.git_head(dir)

      assert String.starts_with?(sha, short_sha)
    end

    test "errors for a repo with no commits" do
      dir = tmp_dir("head-empty") |> init_repo()
      assert {:error, _msg} = Probes.git_head(dir)
    end
  end

  # ---------------------------------------------------------------------
  # git_log/3
  # ---------------------------------------------------------------------

  describe "git_log/3" do
    test "returns commits newest first, clamped by limit" do
      dir = tmp_dir("log") |> init_repo()
      commit!(dir, "a.txt", "1", "first")
      commit!(dir, "a.txt", "2", "second")
      commit!(dir, "a.txt", "3", "third")

      assert {:ok, [%{subject: "third"}, %{subject: "second"}]} = Probes.git_log(dir, nil, 2)
    end

    test "scopes to a path" do
      dir = tmp_dir("log-path") |> init_repo()
      commit!(dir, "a.txt", "1", "touch a")
      commit!(dir, "b.txt", "1", "touch b")
      commit!(dir, "a.txt", "2", "touch a again")

      assert {:ok, commits} = Probes.git_log(dir, "a.txt", 10)
      assert Enum.map(commits, & &1.subject) == ["touch a again", "touch a"]
    end

    test "clamps an out-of-range limit instead of erroring" do
      dir = tmp_dir("log-clamp") |> init_repo()
      commit!(dir, "a.txt", "1", "only commit")

      assert {:ok, [%{subject: "only commit"}]} = Probes.git_log(dir, nil, 10_000)
      assert {:ok, [%{subject: "only commit"}]} = Probes.git_log(dir, nil, -5)
    end
  end

  # ---------------------------------------------------------------------
  # git_commit_touches_path?/3
  # ---------------------------------------------------------------------

  describe "git_commit_touches_path?/3" do
    test "true when the commit touches the path, false otherwise" do
      dir = tmp_dir("touches") |> init_repo()
      commit!(dir, "a.txt", "1", "base")
      sha = commit!(dir, "b.txt", "1", "touch b only")

      assert {:ok, true} = Probes.git_commit_touches_path?(dir, sha, "b.txt")
      assert {:ok, false} = Probes.git_commit_touches_path?(dir, sha, "a.txt")
    end

    test "rejects a non-hex revision instead of shelling out with it" do
      dir = tmp_dir("touches-injection") |> init_repo()
      commit!(dir, "a.txt", "1", "base")

      assert {:error, msg} =
               Probes.git_commit_touches_path?(dir, "--upload-pack=/bin/sh", "a.txt")

      assert msg =~ "invalid revision"
    end
  end

  # ---------------------------------------------------------------------
  # git_diff_stat/3
  # ---------------------------------------------------------------------

  describe "git_diff_stat/3" do
    test "structured per-file added/deleted counts between two shas" do
      dir = tmp_dir("diffstat") |> init_repo()
      from_sha = commit!(dir, "a.txt", "line1\n", "base")
      to_sha = commit!(dir, "a.txt", "line1\nline2\nline3\n", "grow a")

      assert {:ok, %{files_changed: 1, insertions: 2, deletions: 0, files: [file]}} =
               Probes.git_diff_stat(dir, from_sha, to_sha)

      assert file.path == "a.txt"
      assert file.added == 2
      assert file.deleted == 0
      assert file.binary == false
    end

    test "rejects non-hex revisions on either side" do
      dir = tmp_dir("diffstat-injection") |> init_repo()
      sha = commit!(dir, "a.txt", "1", "base")

      assert {:error, msg} = Probes.git_diff_stat(dir, "-c core.pager=x", sha)
      assert msg =~ "invalid revision"

      assert {:error, msg} = Probes.git_diff_stat(dir, sha, "--output=/tmp/pwned")
      assert msg =~ "invalid revision"
    end
  end

  describe "valid_rev?/1" do
    test "accepts hex shas of valid length" do
      assert Probes.valid_rev?("abc123")
      assert Probes.valid_rev?(String.duplicate("a", 40))
    end

    test "rejects flag-like and non-hex strings" do
      refute Probes.valid_rev?("--upload-pack=/bin/sh")
      refute Probes.valid_rev?("-c")
      refute Probes.valid_rev?("HEAD~2")
      refute Probes.valid_rev?("main")
      refute Probes.valid_rev?("")
      refute Probes.valid_rev?(nil)
    end
  end

  # ---------------------------------------------------------------------
  # stat_paths/2
  # ---------------------------------------------------------------------

  describe "stat_paths/2" do
    test "reports file/directory/missing metadata, preserving order" do
      dir = tmp_dir("stat")
      file = Path.join(dir, "f.txt")
      File.write!(file, "hello")
      missing = Path.join(dir, "nope")

      [file_result, dir_result, missing_result] = Probes.stat_paths([file, dir, missing])

      assert %{path: ^file, exists: true, type: "regular", size_bytes: 5} = file_result
      assert is_binary(file_result.mtime)

      assert %{path: ^dir, exists: true, type: "directory", entry_count: 1, truncated: false} =
               dir_result

      assert dir_result.total_size_bytes == 5

      assert %{path: ^missing, exists: false} = missing_result
    end

    test "truncates a directory walk at max_entries" do
      dir = tmp_dir("stat-truncate")
      for i <- 1..10, do: File.write!(Path.join(dir, "f#{i}.txt"), "x")

      [result] = Probes.stat_paths([dir], 3)
      assert result.truncated == true
      assert result.entry_count == 3
    end
  end

  # ---------------------------------------------------------------------
  # disk_free/1
  # ---------------------------------------------------------------------

  describe "disk_free/1" do
    test "returns plausible free/used/total bytes for a real path" do
      assert {:ok, info} = Probes.disk_free(System.tmp_dir!())

      assert is_binary(info.filesystem)
      assert is_binary(info.mounted_on)
      assert is_integer(info.total_bytes) and info.total_bytes > 0
      assert is_integer(info.used_bytes) and info.used_bytes >= 0
      assert is_integer(info.available_bytes) and info.available_bytes >= 0
    end
  end
end
