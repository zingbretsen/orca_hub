defmodule OrcaHub.MCP.Tools.ProbesTest do
  @moduledoc """
  Coverage for the ORCAHUB3-28 probe MCP tools: `git_probe`, `stat_paths`,
  `disk_free`. Everything here targets the LOCAL node (the only node
  available in a non-distributed test run) — see the module's moduledoc
  for why `resolve_node/1` refuses to guess at an unconnected node name,
  which also means the cross-node isolation-DENIED path (as opposed to the
  same-node isolation-ALLOWED path, which IS covered here) needs a second
  real connected node and isn't exercised by this file.
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.MCP.Tools.Probes, as: ProbesTool
  alias OrcaHub.{ClusterNodes, Projects, Sessions}

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

  defp tmp_dir(label) do
    dir =
      Path.join(System.tmp_dir!(), "mcp-probes-#{label}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  setup do
    project_dir = tmp_dir("project") |> init_repo()
    commit!(project_dir, "a.txt", "hi", "initial commit")

    {:ok, project} =
      Projects.create_project(%{
        name: "mcp-probes-test-#{System.unique_integer([:positive])}",
        directory: project_dir,
        node: Atom.to_string(node())
      })

    {:ok, session} = Sessions.create_session(%{directory: project_dir, project_id: project.id})

    %{
      project_dir: project_dir,
      state: %{orca_session_id: session.id}
    }
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: Jason.decode!(body)
  defp error_text(%{"content" => [%{"text" => body}]}), do: body

  describe "list/0" do
    test "exposes all three tools with directory/action required appropriately" do
      names = ProbesTool.list() |> Enum.map(& &1["name"])
      assert names == ~w(git_probe stat_paths disk_free)

      git_probe = Enum.find(ProbesTool.list(), &(&1["name"] == "git_probe"))
      assert git_probe["inputSchema"]["required"] == ["directory", "action"]

      stat_paths = Enum.find(ProbesTool.list(), &(&1["name"] == "stat_paths"))
      assert stat_paths["inputSchema"]["required"] == ["paths"]

      disk_free = Enum.find(ProbesTool.list(), &(&1["name"] == "disk_free"))
      assert disk_free["inputSchema"]["required"] == ["path"]
    end
  end

  describe "git_probe" do
    test "status: reports a clean tree for the session's own directory", %{
      state: state,
      project_dir: dir
    } do
      result = ProbesTool.call("git_probe", %{"directory" => dir, "action" => "status"}, state)
      assert %{"isError" => false} = result
      assert %{"clean" => true, "entries" => []} = decode(result)
    end

    test "head: returns sha/short_sha/subject", %{state: state, project_dir: dir} do
      result = ProbesTool.call("git_probe", %{"directory" => dir, "action" => "head"}, state)
      assert %{"isError" => false} = result

      assert %{"subject" => "initial commit", "sha" => sha, "short_sha" => short_sha} =
               decode(result)

      assert String.starts_with?(sha, short_sha)
    end

    test "log: scoped to a path, with a custom limit", %{state: state, project_dir: dir} do
      commit!(dir, "b.txt", "1", "touch b")
      commit!(dir, "a.txt", "2", "touch a again")

      result =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "log", "path" => "a.txt", "limit" => 5},
          state
        )

      assert %{"isError" => false} = result
      subjects = decode(result) |> Enum.map(& &1["subject"])
      assert subjects == ["touch a again", "initial commit"]
    end

    test "touches: true/false depending on the commit", %{state: state, project_dir: dir} do
      sha = commit!(dir, "b.txt", "1", "touch b only")

      result =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "touches", "commit" => sha, "path" => "b.txt"},
          state
        )

      assert %{"isError" => false} = result
      assert decode(result) == true

      result2 =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "touches", "commit" => sha, "path" => "a.txt"},
          state
        )

      assert decode(result2) == false
    end

    test "touches: requires commit and path", %{state: state, project_dir: dir} do
      result = ProbesTool.call("git_probe", %{"directory" => dir, "action" => "touches"}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "requires commit"
    end

    test "diff_stat: structured per-file counts between two shas", %{
      state: state,
      project_dir: dir
    } do
      from_sha = commit!(dir, "a.txt", "line1\n", "base")
      to_sha = commit!(dir, "a.txt", "line1\nline2\n", "grow a")

      result =
        ProbesTool.call(
          "git_probe",
          %{
            "directory" => dir,
            "action" => "diff_stat",
            "from_sha" => from_sha,
            "to_sha" => to_sha
          },
          state
        )

      assert %{"isError" => false} = result
      assert %{"files_changed" => 1, "insertions" => 1, "deletions" => 0} = decode(result)
    end

    test "diff_stat: requires both from_sha and to_sha", %{state: state, project_dir: dir} do
      result =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "diff_stat", "from_sha" => "abc123"},
          state
        )

      assert %{"isError" => true} = result
      assert error_text(result) =~ "requires both from_sha and to_sha"
    end

    test "rejects an unknown action", %{state: state, project_dir: dir} do
      result = ProbesTool.call("git_probe", %{"directory" => dir, "action" => "nope"}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "action must be one of"
    end

    test "rejects a non-hex revision instead of ever reaching git argv", %{
      state: state,
      project_dir: dir
    } do
      result =
        ProbesTool.call(
          "git_probe",
          %{
            "directory" => dir,
            "action" => "touches",
            "commit" => "--upload-pack=/bin/sh",
            "path" => "a.txt"
          },
          state
        )

      assert %{"isError" => true} = result
      assert error_text(result) =~ "invalid revision"
    end

    test "denies a directory outside any registered project or the caller's own directory",
         %{state: state} do
      outside = tmp_dir("outside") |> init_repo()

      result =
        ProbesTool.call("git_probe", %{"directory" => outside, "action" => "status"}, state)

      assert %{"isError" => true} = result
      assert error_text(result) =~ "outside this session's scoped directories"
    end

    test "allows a directory scoped to a DIFFERENT registered project (not the caller's own)",
         %{state: state} do
      other_dir = tmp_dir("other-project") |> init_repo()
      commit!(other_dir, "x.txt", "1", "other project commit")

      {:ok, _other_project} =
        Projects.create_project(%{
          name: "mcp-probes-other-#{System.unique_integer([:positive])}",
          directory: other_dir,
          node: Atom.to_string(node())
        })

      result =
        ProbesTool.call("git_probe", %{"directory" => other_dir, "action" => "head"}, state)

      assert %{"isError" => false} = result
      assert %{"subject" => "other project commit"} = decode(result)
    end

    test "allows the caller's own session directory even when it's not a registered project" do
      ad_hoc_dir = tmp_dir("ad-hoc-session") |> init_repo()
      commit!(ad_hoc_dir, "x.txt", "1", "ad hoc commit")

      {:ok, session} = Sessions.create_session(%{directory: ad_hoc_dir})
      state = %{orca_session_id: session.id}

      result =
        ProbesTool.call("git_probe", %{"directory" => ad_hoc_dir, "action" => "head"}, state)

      assert %{"isError" => false} = result
      assert %{"subject" => "ad hoc commit"} = decode(result)
    end

    test "allows a sub-path of a registered project directory (e.g. a worktree)", %{
      state: state,
      project_dir: dir
    } do
      sub = Path.join(dir, "nested")
      File.mkdir_p!(sub)

      # A sub-directory that ISN'T exactly the registered project directory
      # string still passes scoping (prefix match, not exact match) and
      # reaches the actual git call — git itself walks up to the parent
      # repo, same as running `git status` from a subdirectory locally.
      result = ProbesTool.call("git_probe", %{"directory" => sub, "action" => "status"}, state)
      assert %{"isError" => false} = result
    end

    test "resolves an explicit node argument matching the local node", %{
      state: state,
      project_dir: dir
    } do
      result =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "head", "node" => Atom.to_string(node())},
          state
        )

      assert %{"isError" => false} = result
    end

    test "rejects an unknown/disconnected node name", %{state: state, project_dir: dir} do
      result =
        ProbesTool.call(
          "git_probe",
          %{"directory" => dir, "action" => "head", "node" => "orca@totally-fake-host"},
          state
        )

      assert %{"isError" => true} = result
      assert error_text(result) =~ "Unknown or disconnected node"
    end

    test "still allows a same-node target when the local node is isolated", %{
      state: state,
      project_dir: dir
    } do
      node_row =
        ClusterNodes.get_by_name(Atom.to_string(node())) ||
          (
            {:ok, row} = ClusterNodes.upsert_seen(Atom.to_string(node()), Atom.to_string(node()))
            row
          )

      {:ok, _isolated_row} = ClusterNodes.update_node(node_row, %{isolated: true})

      result = ProbesTool.call("git_probe", %{"directory" => dir, "action" => "head"}, state)
      assert %{"isError" => false} = result
    end
  end

  describe "stat_paths" do
    test "batch-stats files/dirs, denying out-of-scope paths without failing the whole call",
         %{state: state, project_dir: dir} do
      file = Path.join(dir, "a.txt")
      outside = tmp_dir("stat-outside")

      result =
        ProbesTool.call("stat_paths", %{"paths" => [file, dir, outside]}, state)

      assert %{"isError" => false} = result
      [file_result, dir_result, outside_result] = decode(result)

      assert %{"path" => ^file, "exists" => true, "type" => "regular"} = file_result
      assert %{"path" => ^dir, "exists" => true, "type" => "directory"} = dir_result
      assert %{"path" => ^outside, "denied" => true} = outside_result
    end

    test "rejects an empty paths list", %{state: state} do
      result = ProbesTool.call("stat_paths", %{"paths" => []}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "non-empty list"
    end

    test "rejects a batch over the max size", %{state: state, project_dir: dir} do
      paths = for _ <- 1..26, do: dir
      result = ProbesTool.call("stat_paths", %{"paths" => paths}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "Too many paths"
    end

    test "a missing path reports exists: false, not an error", %{state: state, project_dir: dir} do
      missing = Path.join(dir, "does-not-exist")
      result = ProbesTool.call("stat_paths", %{"paths" => [missing]}, state)
      assert %{"isError" => false} = result
      assert [%{"path" => ^missing, "exists" => false}] = decode(result)
    end
  end

  describe "disk_free" do
    test "returns free/used/total bytes for the session's own directory", %{
      state: state,
      project_dir: dir
    } do
      result = ProbesTool.call("disk_free", %{"path" => dir}, state)
      assert %{"isError" => false} = result
      assert %{"total_bytes" => total, "available_bytes" => avail} = decode(result)
      assert is_integer(total) and total > 0
      assert is_integer(avail) and avail >= 0
    end

    test "denies a path outside scope", %{state: state} do
      outside = tmp_dir("disk-outside")
      result = ProbesTool.call("disk_free", %{"path" => outside}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "outside this session's scoped directories"
    end

    test "requires path", %{state: state} do
      result = ProbesTool.call("disk_free", %{}, state)
      assert %{"isError" => true} = result
      assert error_text(result) =~ "path is required"
    end
  end
end
