defmodule OrcaHub.MemoryGit.ServerTest do
  @moduledoc """
  `OrcaHub.MemoryGit.Server` — the singleton that serializes a node's
  snapshot+sync pass. `run_pass/2` is exercised directly (bypassing the
  GenServer and the `enabled?/0` test gate) against a tmp-dir home; the
  `enabled?/0` gate itself is covered by asserting `snapshot_session_async/1`
  is a no-op under `config/test.exs`.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.MemoryGit
  alias OrcaHub.MemoryGit.Server

  setup do
    home = tmp_home()
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp tmp_home do
    path =
      Path.join(System.tmp_dir!(), "memory_git_server_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp git_log(dir) do
    {out, 0} = System.cmd("git", ["log", "--oneline"], cd: dir)
    String.split(out, "\n", trim: true)
  end

  test "config/test.exs disables the idle-hook entry point by default" do
    refute MemoryGit.enabled?()
  end

  test "snapshot_session_async/1 no-ops (no Task even started) when disabled" do
    # A private, uniquely-named Task.Supervisor (not the shared global
    # OrcaHub.TaskSupervisor other async tests spawn children under) so this
    # assertion is deterministic instead of racing unrelated process churn.
    {:ok, sup} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :kill) end)

    assert :ok = Server.snapshot_session_async(%{id: "s1", title: "hi"}, task_supervisor: sup)
    assert Task.Supervisor.children(sup) == []
  end

  describe "run_pass/2" do
    test "ensures both repos, snapshots agent-written memories, then mirrors via sync", %{
      home: home
    } do
      claude_dir = MemoryGit.claude_projects_dir(home_dir: home)
      codex_dir = MemoryGit.codex_memories_dir(home_dir: home)

      # First pass bootstraps both (empty) repos, as if this node had gone
      # through an earlier idle transition before any memory existed yet.
      assert :ok = Server.run_pass("bootstrap", home_dir: home)
      assert File.dir?(Path.join(claude_dir, ".git"))
      assert File.dir?(Path.join(codex_dir, ".git"))

      File.mkdir_p!(Path.join([claude_dir, "proj1", "memory"]))
      File.write!(Path.join([claude_dir, "proj1", "memory", "foo.md"]), "Foo body.")

      assert :ok = Server.run_pass("session abc123", home_dir: home)

      # Claude repo: the new agent-written memory file landed in its own
      # session-labeled commit.
      claude_log = git_log(claude_dir)
      assert Enum.any?(claude_log, &(&1 =~ "snapshot: session abc123"))

      # Codex repo: got the mirror, committed under a separate "sync:" commit.
      mirror_path = Path.join(codex_dir, "claude--proj1--foo.md")
      assert File.exists?(mirror_path)

      codex_log = git_log(codex_dir)
      assert Enum.any?(codex_log, &(&1 =~ "sync: mechanical cross-backend mirror"))
    end

    test "a second pass with nothing new produces no additional commits", %{home: home} do
      claude_dir = MemoryGit.claude_projects_dir(home_dir: home)
      codex_dir = MemoryGit.codex_memories_dir(home_dir: home)
      File.mkdir_p!(Path.join([claude_dir, "proj1", "memory"]))
      File.write!(Path.join([claude_dir, "proj1", "memory", "foo.md"]), "Foo body.")

      Server.run_pass("session abc123", home_dir: home)
      claude_log_1 = git_log(claude_dir)
      codex_log_1 = git_log(codex_dir)

      Server.run_pass("session abc123", home_dir: home)
      assert git_log(claude_dir) == claude_log_1
      assert git_log(codex_dir) == codex_log_1
    end
  end
end
