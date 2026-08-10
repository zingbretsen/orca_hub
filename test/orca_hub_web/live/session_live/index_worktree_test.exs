defmodule OrcaHubWeb.SessionLive.IndexWorktreeTest do
  @moduledoc """
  Regression coverage for the `/sessions` worktree branch-label bug: the old
  `split_worktree_sessions/2` called `Projects.git_worktree_list(project)`
  directly on the LOCAL node (never routed via `Cluster.rpc`), and did so
  synchronously and unconditionally on every `group_sessions/3` call —
  including every single broadcast on the global "sessions" PubSub topic
  (see `handle_info({_session_id, _payload}, socket)`). In prod that always
  resolves to a `cd`-failure and `[]` (hub pod has none of the agent-node
  project directories); in a single-node test it happens to "work" via a
  cheap local `System.cmd`, which is exactly why the fanout cost was
  invisible until routing was fixed on top of it — see the task this
  landed under (also documented in
  `~/.claude/projects/-home-zach-orca-hub/memory/project-sessions-index-worktree-labels-broken.md`).

  Three properties, each independently required:
  1. A cache hit within the TTL prevents a refetch (the fanout fix — proven
     by mutating the underlying git state between broadcasts and asserting
     the STALE label survives).
  2. An unavailable/erroring owning node degrades to the `Path.basename`
     label instead of crashing the LiveView.
  3. A reachable node's real git_worktree_list result eventually reaches
     the page (proves the async plumbing actually delivers, not just that
     it fails safe).
  """

  # async: false — real `git` subprocess calls against real temp
  # directories; not sharing OS-level state, but see rationale below re:
  # the offline-node test's Node.connect attempt (process-wide connection
  # attempt tracking).
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{Backend, Projects, Sessions}

  @git_timeout_ms 5_000

  defp unique_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # `-c user.email=/-c user.name=` scope the identity to this one
  # invocation only — never touches any git config file (global or
  # otherwise), unlike `git config --global`.
  defp init_git_repo!(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=test@example.com",
          "-c",
          "user.name=Test",
          "commit",
          "--allow-empty",
          "-q",
          "-m",
          "init"
        ],
        cd: dir
      )

    :ok
  end

  # Deliberately gives the worktree directory a DIFFERENT basename than its
  # branch, so a test can distinguish "real branch label" from "fell back
  # to Path.basename(dir)" — the two would be indistinguishable otherwise.
  defp add_worktree!(project_dir, dirname, branch) do
    wt_dir = Path.join([project_dir, ".worktrees", dirname])
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt_dir, "-b", branch], cd: project_dir)
    wt_dir
  end

  setup do
    Backend.Cache.clear()
    on_exit(fn -> Backend.Cache.clear() end)
    :ok
  end

  test "a reachable node's real branch name reaches the page via the async fetch", %{conn: conn} do
    dir = unique_tmp_dir("wt_ok_project")
    init_git_repo!(dir)
    wt_dir = add_worktree!(dir, "wt1", "feature-a")

    {:ok, project} =
      Projects.create_project(%{
        name: "wt-ok-#{System.unique_integer([:positive])}",
        directory: dir
      })

    {:ok, _main} = Sessions.create_session(%{directory: dir, project_id: project.id})
    {:ok, _wt} = Sessions.create_session(%{directory: wt_dir, project_id: project.id})

    {:ok, view, html} = live(conn, ~p"/sessions")

    # Before the async fetch lands: cache miss, so the fallback
    # Path.basename label shows ("wt1"), NOT the real branch.
    refute html =~ "feature-a"

    html = render_async(view, @git_timeout_ms)

    assert html =~ "feature-a"
  end

  test "an unavailable owning node degrades to the basename label instead of crashing", %{
    conn: conn
  } do
    dir = unique_tmp_dir("wt_offline_project")

    {:ok, project} =
      Projects.create_project(%{
        name: "wt-offline-#{System.unique_integer([:positive])}",
        directory: dir,
        node: "debian@totally-offline-host"
      })

    wt_dir = Path.join([dir, ".worktrees", "some-branch"])

    {:ok, _main} = Sessions.create_session(%{directory: dir, project_id: project.id})
    {:ok, _wt} = Sessions.create_session(%{directory: wt_dir, project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/sessions")

    # Doesn't crash — renders and lets the async task resolve.
    html = render_async(view, @git_timeout_ms)

    assert html =~ "some-branch"

    # The failure was actually routed to (and reported by) the project's
    # OWN offline node — never silently computed on the local node instead.
    assert {:ok, {:error, {:node_unavailable, :"debian@totally-offline-host"}}} =
             Backend.Cache.peek({:worktree_list, project.id})
  end

  test "memoization prevents a refetch within the TTL across repeated broadcasts", %{conn: conn} do
    dir = unique_tmp_dir("wt_fanout_project")
    init_git_repo!(dir)
    wt_dir = add_worktree!(dir, "wt1", "feature-a")

    {:ok, project} =
      Projects.create_project(%{
        name: "wt-fanout-#{System.unique_integer([:positive])}",
        directory: dir
      })

    {:ok, _main} = Sessions.create_session(%{directory: dir, project_id: project.id})
    {:ok, wt_session} = Sessions.create_session(%{directory: wt_dir, project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/sessions")
    html = render_async(view, @git_timeout_ms)
    assert html =~ "feature-a"

    # Mutate the underlying git state AFTER the cache is warm: the worktree
    # now reports a different branch. Against the pre-fix code (no cache,
    # direct synchronous git_worktree_list call on every broadcast), the
    # very next broadcast would immediately pick this up and render
    # "feature-b". With memoization, it must NOT — the TTL (8s) hasn't
    # expired, so no refetch happens.
    {_, 0} = System.cmd("git", ["checkout", "-q", "-b", "feature-b"], cd: wt_dir)

    html =
      Enum.reduce(1..5, nil, fn _, _ ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {wt_session.id, {:status, :idle}})
        render(view)
      end)

    assert html =~ "feature-a"
    refute html =~ "feature-b"
  end
end
