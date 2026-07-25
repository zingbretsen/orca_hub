defmodule OrcaHub.MemoryGitTest do
  @moduledoc """
  `OrcaHub.MemoryGit` exercised against a tmp-dir home + a stubbed Gitea
  (`Req.Test`), same fixture convention as `OrcaHub.SkillSyncTest` /
  `OrcaHub.AgentMemoryTest`. Every Gitea stub is passed via the `:req_options`
  opt (not global Application env) so these stay `async: true`-safe.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.MemoryGit

  @stub OrcaHub.MemoryGitTestStub

  setup do
    home = tmp_home()
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp tmp_home do
    path = Path.join(System.tmp_dir!(), "memory_git_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp git_ls_files(dir) do
    {out, 0} = System.cmd("git", ["ls-files"], cd: dir)
    String.split(out, "\n", trim: true)
  end

  defp git_log(dir) do
    {out, 0} = System.cmd("git", ["log", "--oneline"], cd: dir)
    String.split(out, "\n", trim: true)
  end

  defp git_remote_url(dir) do
    case System.cmd("git", ["remote", "get-url", "origin"], cd: dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _} -> nil
    end
  end

  # ---------------------------------------------------------------------
  # gitignore whitelist chain
  # ---------------------------------------------------------------------

  describe "ensure_repo/2 whitelist gitignore" do
    test "tracks only <slug>/memory/** files, never transcripts/settings", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.mkdir_p!(Path.join([dir, "proj1", "other"]))
      File.write!(Path.join([dir, "proj1", "memory", "foo.md"]), "mem")
      File.write!(Path.join([dir, "proj1", "memory", "MEMORY.md"]), "index")
      File.write!(Path.join([dir, "proj1", "transcript.jsonl"]), "transcript")
      File.write!(Path.join([dir, "proj1", "other", "settings.json"]), "settings")

      MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      tracked = git_ls_files(dir)
      assert "proj1/memory/foo.md" in tracked
      assert "proj1/memory/MEMORY.md" in tracked
      assert ".gitignore" in tracked
      refute "proj1/transcript.jsonl" in tracked
      refute "proj1/other/settings.json" in tracked
    end

    test "a second project's memory files are picked up too", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.mkdir_p!(Path.join([dir, "proj2", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")
      File.write!(Path.join([dir, "proj2", "memory", "b.md"]), "b")

      MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      tracked = git_ls_files(dir)
      assert "proj1/memory/a.md" in tracked
      assert "proj2/memory/b.md" in tracked
    end

    test "codex repo (whitelist_memory?: false) tracks the whole dir", %{home: home} do
      dir = MemoryGit.codex_memories_dir(home_dir: home)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "MEMORY.md"), "mem")
      File.write!(Path.join(dir, "notes.md"), "notes")

      MemoryGit.ensure_repo(dir, repo_name: "x-codex", home_dir: home)

      tracked = git_ls_files(dir)
      assert "MEMORY.md" in tracked
      assert "notes.md" in tracked
      refute File.exists?(Path.join(dir, ".gitignore"))
    end
  end

  # ---------------------------------------------------------------------
  # ensure_repo idempotency
  # ---------------------------------------------------------------------

  describe "ensure_repo/2 idempotency" do
    test "calling twice does not re-init or duplicate the initial commit", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")

      :ok =
        MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      first_log = git_log(dir)

      :ok =
        MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      second_log = git_log(dir)

      assert first_log == second_log
      assert length(first_log) == 1
    end

    test "never clobbers a pre-existing .gitignore in an already-initialized repo", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(dir)
      System.cmd("git", ["init"], cd: dir)
      File.write!(Path.join(dir, ".gitignore"), "hand-written-rule\n")

      MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      assert File.read!(Path.join(dir, ".gitignore")) == "hand-written-rule\n"
    end

    test "with no Gitea creds configured, soft-degrades to a local-only repo", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")

      assert :ok =
               MemoryGit.ensure_repo(dir,
                 whitelist_memory?: true,
                 repo_name: "x-claude",
                 home_dir: home,
                 gitea_url: nil,
                 gitea_token: nil
               )

      assert File.dir?(Path.join(dir, ".git"))
      assert git_remote_url(dir) == nil
    end
  end

  # ---------------------------------------------------------------------
  # Gitea remote creation
  # ---------------------------------------------------------------------

  describe "ensure_repo/2 Gitea remote" do
    test "creates the Gitea repo (404 on lookup) and wires the remote", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")

      Req.Test.stub(@stub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/repos/agent-memories/x-claude"} ->
            Plug.Conn.send_resp(conn, 404, "not found")

          {"POST", "/api/v1/orgs/agent-memories/repos"} ->
            Req.Test.json(conn, %{"full_name" => "agent-memories/x-claude"})
        end
      end)

      MemoryGit.ensure_repo(dir,
        whitelist_memory?: true,
        repo_name: "x-claude",
        home_dir: home,
        gitea_url: "https://gitea.example.com",
        gitea_token: "tok",
        req_options: [plug: {Req.Test, @stub}]
      )

      remote = git_remote_url(dir)
      assert remote =~ "gitea.example.com/agent-memories/x-claude.git"
      assert remote =~ "tok@"
    end

    test "skips creation (GET 200) and still wires the remote", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))

      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"full_name" => "agent-memories/x-claude"})
      end)

      MemoryGit.ensure_repo(dir,
        whitelist_memory?: true,
        repo_name: "x-claude",
        home_dir: home,
        gitea_url: "https://gitea.example.com",
        gitea_token: "tok",
        req_options: [plug: {Req.Test, @stub}]
      )

      assert git_remote_url(dir) =~ "x-claude.git"
    end

    test "an unreachable Gitea soft-degrades instead of crashing", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))

      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert :ok =
               MemoryGit.ensure_repo(dir,
                 whitelist_memory?: true,
                 repo_name: "x-claude",
                 home_dir: home,
                 gitea_url: "https://gitea.example.com",
                 gitea_token: "tok",
                 req_options: [plug: {Req.Test, @stub}, retry: false]
               )

      assert git_remote_url(dir) == nil
    end

    test "an already-configured remote is left alone (never re-created)", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(dir)
      System.cmd("git", ["init"], cd: dir)

      System.cmd("git", ["remote", "add", "origin", "https://existing.example.com/foo.git"],
        cd: dir
      )

      MemoryGit.ensure_repo(dir,
        whitelist_memory?: true,
        repo_name: "x-claude",
        home_dir: home,
        gitea_url: "https://gitea.example.com",
        gitea_token: "tok",
        req_options: [plug: {Req.Test, @stub}]
      )

      assert git_remote_url(dir) == "https://existing.example.com/foo.git"
    end
  end

  # ---------------------------------------------------------------------
  # snapshot/3
  # ---------------------------------------------------------------------

  describe "snapshot/3" do
    test "commits when dirty", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")
      MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      File.write!(Path.join([dir, "proj1", "memory", "b.md"]), "b")
      :ok = MemoryGit.snapshot(dir, "snapshot: test", home_dir: home)

      log = git_log(dir)
      assert length(log) == 2
      assert Enum.at(log, 0) =~ "snapshot: test"
    end

    test "is a no-op (no new commit) on a clean tree", %{home: home} do
      dir = MemoryGit.claude_projects_dir(home_dir: home)
      File.mkdir_p!(Path.join([dir, "proj1", "memory"]))
      File.write!(Path.join([dir, "proj1", "memory", "a.md"]), "a")
      MemoryGit.ensure_repo(dir, whitelist_memory?: true, repo_name: "x-claude", home_dir: home)

      before = git_log(dir)
      :ok = MemoryGit.snapshot(dir, "snapshot: should not land", home_dir: home)
      assert git_log(dir) == before
    end

    test "on a non-repo dir it's a harmless no-op", %{home: home} do
      dir = Path.join(home, "not-a-repo")
      File.mkdir_p!(dir)
      assert :ok = MemoryGit.snapshot(dir, "snapshot: nope", home_dir: home)
    end
  end

  # ---------------------------------------------------------------------
  # repo_name / node sanitization
  # ---------------------------------------------------------------------

  describe "repo_name/2" do
    test "sanitizes an arbitrary node name into a safe repo-name suffix" do
      assert MemoryGit.repo_name(:claude, node_name: "My.Node@Weird_01") ==
               "my-node-weird-01-claude"

      assert MemoryGit.repo_name(:codex, node_name: "orca-nuc") == "orca-nuc-codex"
    end
  end
end
