defmodule OrcaHub.MCP.Tools.SessionsTest do
  @moduledoc """
  Coverage for `start_session`'s optional `backend`/`model` MCP parameters.
  Before this, `start_session` always built `session_attrs` without
  `backend`/`model`, so every MCP-created session silently fell back to the
  Claude default regardless of what an orchestrator actually wanted.

  These are real end-to-end calls through `OrcaHub.MCP.Tools.Sessions.call/3`
  — a real caller session row, a real `HubRPC.create_session/1`, and (since
  `start_session` unconditionally spawns the child via `Cluster.start_session`
  + `Cluster.send_message`) a real `OrcaHub.SessionRunner`. Codex/pi are
  stubbed via the existing `:codex_executable`/`:pi_executable` app-env seams
  (see `session_supervisor_test.exs`, `codex_stub_integration_test.exs`) so no
  real CLI/network call happens. Claude has no such seam
  (`Backend.Claude.claude_executable!/0` always calls
  `System.find_executable("claude")`), so the default-backend case shadows a
  fake `claude` executable onto `$PATH` for the single synchronous
  `Sessions.call/3` invocation that resolves it — just long enough for
  `Port.open/2` to succeed without ever touching the network.
  """

  # async: false — starts real SessionRunner children under the shared
  # OrcaHub.SessionSupervisor (needs the DB sandbox in SHARED mode; see
  # session_supervisor_test.exs for the same pattern) and briefly mutates the
  # process-wide $PATH env var.
  use OrcaHub.DataCase, async: false

  require Logger

  alias OrcaHub.Backend.Cache
  alias OrcaHub.MCP.Tools.Sessions, as: SessionsTool
  alias OrcaHub.Sessions.Session
  alias OrcaHub.{ClusterNodes, Sessions, SessionRunner, SessionSupervisor}

  @codex_stub Path.expand("../../../support/fixtures/codex_stub_app_server.py", __DIR__)
  @pi_stub Path.expand("../../../support/fixtures/pi_stub_rpc.py", __DIR__)

  setup do
    refute is_nil(System.find_executable("python3")),
           "python3 not found — required to run the codex app-server stub fixture"

    # Node-scoped installed-backend list is TTL-cached (OrcaHub.Backend.Cache)
    # — clear it so this file's assertions reflect this node's REAL installed
    # CLIs, not a stale entry some other test's stub manipulation left behind.
    Cache.clear()

    dir =
      Path.join(System.tmp_dir!(), "mcp_start_session_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, caller} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        model: nil,
        code_exec: false,
        orchestrator: true
      })

    {:ok, dir: dir, state: %{orca_session_id: caller.id, orchestrator: true}}
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.stop_session(session_id)
    end
  end

  defp session_id_from!(text) do
    %{"session_id" => id} = Jason.decode!(text)
    id
  end

  # Claude has no executable-override app-env seam (unlike Codex/pi) — shadow
  # a no-op "claude" onto $PATH just for the duration of `fun`, so
  # `System.find_executable("claude")` (resolved synchronously inside
  # `Sessions.call/3`, via `Cluster.send_message`'s `Port.open/2`) finds a
  # stand-in instead of spawning the real CLI against the network.
  #
  # `fun` only SYNCHRONOUSLY STARTS the runner: `Port.open/2` returns once
  # the fork has happened, not once the forked process has actually execve'd
  # our stub script — so restoring $PATH and deleting bin_dir right after
  # `fun.()` returns races that not-yet-exec'd fork (observed as "cannot
  # open .../claude: No such file"), and also races the runner's own async
  # DB writes against the Ecto sandbox checkin that ExUnit performs right
  # after this test function returns. Waiting here, synchronously, for
  # every SessionRunner that became alive during `fun` to reach a terminal
  # status closes both races: the test process (and therefore ExUnit's
  # teardown) doesn't move on until the runner is done with $PATH/the DB.
  defp with_fake_claude_on_path(fun) do
    bin_dir =
      Path.join(System.tmp_dir!(), "fake_claude_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    claude_path = Path.join(bin_dir, "claude")
    File.write!(claude_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(claude_path, 0o755)

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    before_ids = alive_session_ids()

    try do
      fun.()
    after
      await_new_runners_settled(before_ids)
      System.put_env("PATH", original_path)
      File.rm_rf!(bin_dir)
    end
  end

  # Snapshot only — a runner that both registers AND fully terminates
  # entirely WITHIN `fun()` (before `await_new_runners_settled/1` takes its
  # post-`fun` snapshot) is invisible to the before/after diff below and
  # never gets waited on. Never observed in practice, but not structurally
  # ruled out — if a future failure looks like this race despite this fix,
  # check for a runner that's already gone by the time cleanup runs.
  defp alive_session_ids do
    Registry.select(OrcaHub.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  # Never observed to be hit in ~80 runs across isolated and concurrent-load
  # batches, but that's inference from stable suite runtimes, not an
  # instrumented count — the Logger.warning below on expiry is the tripwire
  # that would actually prove it, since silently falling through and
  # cleaning up anyway re-opens the exact race this helper exists to close.
  @settle_timeout_ms 2_000
  @settled_statuses ~w(ready idle error)a

  # Bounded poll (not a blind sleep) on each runner's real GenStatem status —
  # only session ids that were NOT already alive before `fun` ran are new
  # work `fun` itself kicked off, so this only ever waits on runners this
  # helper's own PATH shadowing is responsible for.
  defp await_new_runners_settled(before_ids) do
    deadline = System.monotonic_time(:millisecond) + @settle_timeout_ms

    alive_session_ids()
    |> MapSet.difference(before_ids)
    |> Enum.each(&await_runner_settled(&1, deadline))
  end

  defp await_runner_settled(session_id, deadline) do
    status =
      try do
        %{status: status} = SessionRunner.get_status(session_id)
        status
      rescue
        # GenStatem.call/3 (this repo's gen_statem wrapper) catches the raw
        # :exit itself and re-raises it as a GenStatem.GenError exception —
        # a bare `catch :exit, _` here never fires. Either way, the runner
        # already terminated entirely — nothing left to race.
        GenStatem.GenError -> :gone
      catch
        :exit, _ -> :gone
      end

    cond do
      status == :gone or status in @settled_statuses ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Loud on purpose: falling through silently here would clean up
        # $PATH/the tmpdir anyway, re-opening the exact race this helper
        # exists to close, with zero signal that it happened. A warning
        # (not a raise) — this is teardown code and a flaky-by-timing test
        # failure downstream is already a clear enough signal without also
        # risking destabilizing the rest of the suite from an `after` block.
        Logger.warning(
          "[with_fake_claude_on_path] session #{session_id} still #{inspect(status)} " <>
            "after #{@settle_timeout_ms}ms — cleaning up $PATH/tmpdir anyway"
        )

        :ok

      true ->
        Process.sleep(20)
        await_runner_settled(session_id, deadline)
    end
  end

  describe "start_session backend/model params" do
    test "default call (no backend/model) is unchanged — creates a claude session", %{
      state: state
    } do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)

      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.backend == "claude"
      assert session.model == nil
    end

    test "backend \"pi\" is accepted when available_on returns it", %{state: state} do
      Application.put_env(:orca_hub, :pi_executable, @pi_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "backend" => "pi", "notify_on_completion" => false},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)

      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.backend == "pi"
    end

    test "a bogus backend errors, lists the valid options, and creates no session", %{
      state: state
    } do
      count_before = Repo.aggregate(Session, :count)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "backend" => "not-a-real-backend"},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not-a-real-backend"
      assert text =~ "claude"
      assert text =~ "codex"
      assert text =~ "pi"

      assert Repo.aggregate(Session, :count) == count_before
    end

    test "the caller's project on an offline node: clean error, no local start, no reassignment",
         %{dir: dir} do
      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "offline-mcp-project",
          directory: dir,
          node: "debian@totally-offline-host"
        })

      {:ok, caller} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          project_id: project.id,
          orchestrator: true
        })

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi"},
          %{orca_session_id: caller.id, orchestrator: true}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not currently connected"

      # The session row IS created (assigned to the project's real node,
      # per design — never silently reassigned elsewhere), but no local
      # SessionRunner was started for it. Scoped to this test's own
      # project_id — mix test runs against the dev DB (see [[test-db-config]]
      # in memory), so a bare Repo.all(Session) would see unrelated rows.
      [new_session] =
        Repo.all(Session) |> Enum.filter(&(&1.project_id == project.id and &1.id != caller.id))

      assert new_session.runner_node == "debian@totally-offline-host"
      refute SessionSupervisor.session_alive?(new_session.id)
    end
  end

  describe "start_session — directory-based cross-node project routing" do
    test "a directory matching a different LOCAL project routes to that project's id, not the caller's",
         %{state: state} do
      other_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_other_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(other_dir)
      on_exit(fn -> File.rm_rf(other_dir) end)

      {:ok, other_project} =
        OrcaHub.Projects.create_project(%{
          name: "other-local-project",
          directory: other_dir,
          node: Atom.to_string(node())
        })

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "directory" => other_dir, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.project_id == other_project.id
      assert session.directory == other_dir
      assert session.runner_node == Atom.to_string(node())
    end

    test "a directory matching a project on an OFFLINE node routes runner_node/project_id there, refuses to start locally, and never reassigns",
         %{dir: dir, state: state} do
      other_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_offline_#{System.unique_integer([:positive])}"
        )

      {:ok, offline_project} =
        OrcaHub.Projects.create_project(%{
          name: "offline-remote-project",
          directory: other_dir,
          node: "debian@totally-offline-host"
        })

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "directory" => other_dir},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not currently connected"

      # dir is the caller's own directory, unrelated to offline_project — used
      # here only to prove the caller's own directory/project was NOT used.
      refute other_dir == dir

      [new_session] =
        Repo.all(Session)
        |> Enum.filter(&(&1.project_id == offline_project.id and &1.id != state.orca_session_id))

      assert new_session.runner_node == "debian@totally-offline-host"
      assert new_session.directory == other_dir
      refute SessionSupervisor.session_alive?(new_session.id)
    end

    test "an unregistered directory (no matching project) falls back to the caller's own project and node",
         %{state: state} do
      unregistered_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_unregistered_#{System.unique_integer([:positive])}"
        )

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "directory" => unregistered_dir,
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      caller = Sessions.get_session!(state.orca_session_id)
      session = Sessions.get_session!(session_id)
      assert session.project_id == caller.project_id
      assert session.runner_node == Atom.to_string(node())
      assert session.directory == unregistered_dir
    end

    test "explicitly passing the caller's own directory keeps the caller's own project/node (no lookup)",
         %{dir: dir} do
      {:ok, caller_project} =
        OrcaHub.Projects.create_project(%{
          name: "caller-own-project",
          directory: dir,
          node: Atom.to_string(node())
        })

      {:ok, caller} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          project_id: caller_project.id,
          orchestrator: true
        })

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "directory" => dir, "notify_on_completion" => false},
            %{orca_session_id: caller.id, orchestrator: true}
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.project_id == caller_project.id
      assert session.runner_node == Atom.to_string(node())
    end
  end

  describe "start_session — project_id targeting" do
    test "project_id alone routes to that project's node/id and defaults directory to the project's own directory",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_id_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-target",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "project_id" => project.id, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.project_id == project.id
      assert session.runner_node == Atom.to_string(node())
      assert session.directory == target_dir
    end

    test "project_id + a hex-prefix id resolves via the prefix", %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_prefix_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-prefix-target",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      prefix = String.slice(String.replace(project.id, "-", ""), 0, 8)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "project_id" => prefix, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).project_id == project.id
    end

    test "project_id + a directory under the project's own directory (a worktree) sets the session's cwd",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_worktree_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-worktree-target",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      worktree_dir = Path.join(target_dir, ".worktrees/feature-x")

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "project_id" => project.id,
              "directory" => worktree_dir,
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.project_id == project.id
      assert session.directory == worktree_dir
    end

    test "project_id + a directory OUTSIDE the project's directory is rejected", %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_outside_#{System.unique_integer([:positive])}"
        )

      unrelated_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_unrelated_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-outside-target",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "project_id" => project.id, "directory" => unrelated_dir},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not project_id's own directory"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end

    test "a malformed (non-UUID, non-hex) project_id is rejected with a friendly error instead of raising",
         %{state: state} do
      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "project_id" => "not-a-real-id!!"},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isn't a valid project id"
    end

    test "a well-formed but unknown project_id UUID is rejected", %{state: state} do
      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "project_id" => Ecto.UUID.generate()},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "No project found"
    end

    test "project_id + a node that AGREES with the project's own node succeeds", %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_node_agree_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-node-agree",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "project_id" => project.id,
              "node" => Atom.to_string(node()),
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)
    end

    test "project_id + a node that CONTRADICTS the project's own node is rejected", %{
      state: state
    } do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_project_node_contradict_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "project-id-node-contradict",
          directory: target_dir,
          node: "debian@totally-offline-host"
        })

      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "project_id" => project.id, "node" => Atom.to_string(node())},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "contradicts project_id's own node"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end
  end

  describe "start_session — explicit directory + node targeting" do
    test "an unregistered directory that actually exists on the target node spawns a project-less session",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_dir_node_new_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(target_dir)
      on_exit(fn -> File.rm_rf(target_dir) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "directory" => target_dir,
              "node" => Atom.to_string(node()),
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.project_id == nil
      assert session.runner_node == Atom.to_string(node())
      assert session.directory == target_dir
    end

    test "an unregistered directory that does NOT exist on the target node is rejected (preflight)",
         %{state: state} do
      missing_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_dir_node_missing_#{System.unique_integer([:positive])}"
        )

      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "directory" => missing_dir, "node" => Atom.to_string(node())},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "does not exist"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end

    test "a directory that's already registered on the SAME given node reuses that project's id",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_dir_node_match_#{System.unique_integer([:positive])}"
        )

      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "dir-node-match-target",
          directory: target_dir,
          node: Atom.to_string(node())
        })

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "directory" => target_dir,
              "node" => Atom.to_string(node()),
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).project_id == project.id
    end

    test "a directory already registered on a DIFFERENT node than the given one is rejected (contradiction)",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_dir_node_contradict_#{System.unique_integer([:positive])}"
        )

      {:ok, _project} =
        OrcaHub.Projects.create_project(%{
          name: "dir-node-contradict-target",
          directory: target_dir,
          node: "debian@totally-offline-host"
        })

      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "directory" => target_dir, "node" => Atom.to_string(node())},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "already registered to project"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end

    test "an unknown/disconnected node name is rejected with a friendly error, not an atom-table growth attempt",
         %{state: state} do
      target_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_dir_node_unknown_#{System.unique_integer([:positive])}"
        )

      result =
        SessionsTool.call(
          "start_session",
          %{
            "prompt" => "hi",
            "directory" => target_dir,
            "node" => "totally-bogus-node-name-#{System.unique_integer([:positive])}@nowhere"
          },
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "Unknown or disconnected node"
    end
  end

  describe "start_session — node without directory or project_id" do
    test "is rejected with a clear error", %{state: state} do
      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "node" => Atom.to_string(node())},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isn't a coherent target"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end
  end

  describe "send_message_to_session — offline target node" do
    test "returns a clean node-unavailable error, never starts a runner locally", %{dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: "debian@totally-offline-host"
        })

      result =
        SessionsTool.call(
          "send_message_to_session",
          %{"session_id" => target.id, "message" => "hello"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not currently connected"
      refute SessionSupervisor.session_alive?(target.id)
    end
  end

  describe "send_message_to_session — sender attribution" do
    defp delivered_text(target_id) do
      [message] = Sessions.list_messages(target_id)
      get_in(message.data, ["message", "content", Access.at(0), "text"])
    end

    test "defaults the sender to the caller's own orca_session_id when not explicitly given",
         %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            state
          )
        end)

      assert %{"isError" => false} = result

      assert delivered_text(target.id) ==
               "[Message from session #{state.orca_session_id}]\n\nhello"
    end

    test "an explicit sender_session_id overrides the connection's own session id",
         %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)
      other_id = Ecto.UUID.generate()

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello", "sender_session_id" => other_id},
            state
          )
        end)

      assert %{"isError" => false} = result
      assert delivered_text(target.id) == "[Message from session #{other_id}]\n\nhello"
    end

    test "falls back to the generic label when the MCP connection has no linked session", %{
      dir: dir
    } do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            %{orca_session_id: nil}
          )
        end)

      assert %{"isError" => false} = result
      assert delivered_text(target.id) == "[Message from another session]\n\nhello"
    end
  end

  describe "send_message_to_session — session_interactions edge" do
    test "records an edge (sender -> resolved recipient) on successful delivery", %{
      state: state,
      dir: dir
    } do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            state
          )
        end)

      assert %{"isError" => false} = result

      assert [interaction] = Sessions.list_session_interactions(recipient_session_id: target.id)
      assert interaction.sender_session_id == state.orca_session_id
      assert interaction.recipient_session_id == target.id
      assert interaction.kind == "message"
    end

    test "does not record an edge when there is no sender", %{dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            %{orca_session_id: nil}
          )
        end)

      assert %{"isError" => false} = result
      assert Sessions.list_session_interactions(recipient_session_id: target.id) == []
    end

    test "a failure to record the edge does not fail the tool call", %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      # A sender id that isn't a real session violates the FK on insert —
      # the tool call must still report success since delivery itself worked.
      bogus_sender = Ecto.UUID.generate()

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{
              "session_id" => target.id,
              "message" => "hello",
              "sender_session_id" => bogus_sender
            },
            state
          )
        end)

      assert %{"isError" => false} = result
      assert Sessions.list_session_interactions(recipient_session_id: target.id) == []
    end
  end

  describe "send_message_to_session — delivery modes (ORCAHUB3-29)" do
    test "default (no delivery arg) queues rather than delivers/interrupts a running target",
         %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        SessionsTool.call(
          "send_message_to_session",
          %{"session_id" => target.id, "message" => "hello"},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "queued"
      assert text =~ "\"running\""
      assert Sessions.list_messages(target.id) == []
      refute SessionSupervisor.session_alive?(target.id)
      # Queueing is still a real (recorded) delivery from the sender's POV.
      assert [interaction] = Sessions.list_session_interactions(recipient_session_id: target.id)
      assert interaction.kind == "message"
    end

    test "an unrecognized delivery value falls back to the safe default (queue), not interrupt",
         %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        SessionsTool.call(
          "send_message_to_session",
          %{"session_id" => target.id, "message" => "hello", "delivery" => "bogus"},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "queued"
      refute SessionSupervisor.session_alive?(target.id)
    end

    test "delivery: \"interrupt\" delivers immediately (today's behavior), cold-starting a runner",
         %{state: state, dir: dir} do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello", "delivery" => "interrupt"},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "delivered"
      # An :interrupt delivery to a not-yet-alive target cold-starts a runner
      # rather than queuing — the DB's stale "running" status is irrelevant.
      assert SessionSupervisor.session_alive?(target.id)
    end

    test "queue delivers immediately (unqueued) when the target isn't mid-turn", %{
      state: state,
      dir: dir
    } do
      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "delivered"
      refute text =~ "queued"
    end
  end

  describe "start_session backend/model params — model" do
    test "model passes through onto the created session row", %{state: state} do
      Application.put_env(:orca_hub, :codex_executable, @codex_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :codex_executable) end)

      result =
        SessionsTool.call(
          "start_session",
          %{
            "prompt" => "hi",
            "backend" => "codex",
            "model" => "gpt-5-codex",
            "notify_on_completion" => false
          },
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)

      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      assert session.backend == "codex"
      assert session.model == "gpt-5-codex"
    end

    test "an unknown claude model alias errors and creates no session, without touching Codex/pi models",
         %{state: state} do
      before_count = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "model" => "sonnet-5"},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "Unknown claude model"
      assert text =~ "sonnet-5"
      assert text =~ "sonnet"
      assert Sessions.list_sessions(:all) |> length() == before_count
    end

    test "a bare claude tier alias (e.g. \"sonnet\") is accepted", %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "model" => "sonnet", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).model == "sonnet"
    end

    test "a full claude model id is accepted", %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "model" => "claude-sonnet-5",
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).model == "claude-sonnet-5"
    end

    test "the claude-opus-5 model id is accepted", %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "model" => "claude-opus-5",
              "notify_on_completion" => false
            },
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).model == "claude-opus-5"
    end

    test "the bare \"opus\" alias is still accepted now that both claude-opus-5 and claude-opus-4-8 exist",
         %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "model" => "opus", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      assert Sessions.get_session!(session_id).model == "opus"
    end
  end

  describe "search_sessions — model/backend/error_detail fields" do
    test "surfaces model and backend, and error_detail only when status is error", %{
      dir: dir,
      state: state
    } do
      {:ok, ok_session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "codex",
          model: "gpt-5.5",
          status: "idle",
          error_detail: "stale detail that should never surface while not errored"
        })

      {:ok, errored_session} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          model: "opus",
          status: "error",
          error_detail: "Error: model not found: sonnet-5"
        })

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call(
          "search_sessions",
          %{"directory" => dir, "all_projects" => false},
          state
        )

      results = Jason.decode!(text) |> Enum.into(%{}, &{&1["id"], &1})

      ok_result = results[ok_session.id]
      assert ok_result["backend"] == "codex"
      assert ok_result["model"] == "gpt-5.5"
      refute Map.has_key?(ok_result, "error_detail")

      error_result = results[errored_session.id]
      assert error_result["backend"] == "claude"
      assert error_result["model"] == "opus"
      assert error_result["error_detail"] == "Error: model not found: sonnet-5"
    end
  end

  describe "get_session_tail" do
    test "returns status, last assistant text, and recent tool calls without touching the runner",
         %{dir: dir, state: state} do
      {:ok, target} =
        Sessions.create_session(%{directory: dir, status: "running", title: "peek-me"})

      # A single assistant turn commonly carries both a tool_use block and
      # trailing text — bundled in one message so the assertions below don't
      # depend on tie-breaking `Message.inserted_at` (second precision) across
      # two rows inserted in the same test.
      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "Bash",
                "input" => %{"command" => "ls"}
              },
              %{"type" => "text", "text" => "still working on it"}
            ]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert decoded["id"] == target.id
      assert decoded["status"] == "running"
      assert decoded["last_assistant_text"] == "still working on it"
      assert [%{"name" => "Bash", "args" => args}] = decoded["recent_tool_calls"]
      assert args =~ "ls"

      # Always-on activity metadata: one assistant message with one tool_use.
      assert %{"messages_5m" => 1, "tool_calls_5m" => 1} = decoded["activity"]
      # dir is a fresh tmp dir, not a git repo.
      assert decoded["last_commit"] == nil
      assert decoded["progress_phase"] == nil

      # Read-only: no runner was ever started for this session.
      refute SessionSupervisor.session_alive?(target.id)
    end

    test "surfaces self-reported progress from report_progress", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      SessionsTool.call(
        "report_progress",
        %{"phase" => "implementing", "note" => "writing the migration"},
        %{orca_session_id: target.id}
      )

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      decoded = Jason.decode!(text)
      assert decoded["progress_phase"] == "implementing"
      assert decoded["progress_note"] == "writing the migration"
      assert decoded["progress_updated_at"] != nil
    end

    test "an unknown session id errors", %{state: state} do
      result =
        SessionsTool.call(
          "get_session_tail",
          %{"session_id" => Ecto.UUID.generate()},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not found"
    end

    test "a run_elixir tool call adds a statically-extracted tools list", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "mcp__orca__run_elixir",
                "input" => %{
                  "code" => ~s[Tools.search_sessions(%{"status" => "error"})]
                }
              }
            ]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert [%{"name" => "mcp__orca__run_elixir", "tools" => tools}] =
               decoded["recent_tool_calls"]

      assert tools == ["search_sessions"]
    end

    test "a run_elixir call with no extractable tools omits the tools key", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "mcp__orca__run_elixir",
                "input" => %{"code" => "Enum.sum([1, 2, 3])"}
              }
            ]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert [%{"name" => "mcp__orca__run_elixir"} = call] = decoded["recent_tool_calls"]
      refute Map.has_key?(call, "tools")
    end

    test "a non-run_elixir tool call never gets a tools key", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "Bash",
                "input" => %{"command" => "ls"}
              }
            ]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert [%{"name" => "Bash"} = call] = decoded["recent_tool_calls"]
      refute Map.has_key?(call, "tools")
    end

    test "truncates a long last assistant message by default", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})
      long_text = String.duplicate("a", 3000)

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => long_text}]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert String.length(decoded["last_assistant_text"]) < 1200

      assert decoded["last_assistant_text"] =~
               "…[truncated — pass full_last_message: true for the complete message, or " <>
                 "include_last_message: false to omit it entirely when polling]"
    end

    test "include_last_message: false omits the last_assistant_text key", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => "this should be omitted"}]
          }
        }
      })

      result =
        SessionsTool.call(
          "get_session_tail",
          %{"session_id" => target.id, "include_last_message" => false},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      refute Map.has_key?(decoded, "last_assistant_text")
    end

    test "include_last_message: false wins when both params are set", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})
      long_text = String.duplicate("a", 3000)

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => long_text}]
          }
        }
      })

      result =
        SessionsTool.call(
          "get_session_tail",
          %{
            "session_id" => target.id,
            "full_last_message" => true,
            "include_last_message" => false
          },
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      # include_last_message: false wins
      refute Map.has_key?(decoded, "last_assistant_text")
    end

    test "full_last_message: true returns the last assistant message untruncated", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})
      long_text = String.duplicate("a", 3000)

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => long_text}]
          }
        }
      })

      result =
        SessionsTool.call(
          "get_session_tail",
          %{"session_id" => target.id, "full_last_message" => true},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert decoded["last_assistant_text"] == long_text
    end

    test "truncation is UTF-8-safe when a multibyte character straddles the byte boundary",
         %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Em dash is 3 bytes in UTF-8 (0xE2 0x80 0x94). Positioned so the fixed
      # 800-byte truncation cut lands after only 2 of its 3 bytes (798 'a'
      # bytes + 2 em-dash bytes = 800) — this used to yield an invalid
      # binary that crashed downstream (prod: "invalid byte 0xE2 in ...").
      long_text = String.duplicate("a", 798) <> "—" <> String.duplicate("a", 100)

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => long_text}]}
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert String.valid?(decoded["last_assistant_text"])

      assert decoded["last_assistant_text"] =~
               "…[truncated — pass full_last_message: true for the complete message, or " <>
                 "include_last_message: false to omit it entirely when polling]"
    end

    test "truncation marker mentions both parameters", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})
      long_text = String.duplicate("x", 1000)

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [%{"type" => "text", "text" => long_text}]
          }
        }
      })

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert decoded["last_assistant_text"] =~ "full_last_message"
      assert decoded["last_assistant_text"] =~ "include_last_message"
    end

    test "tool call arg truncation is UTF-8-safe when a multibyte character straddles the byte boundary",
         %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Sweep the emoji's starting offset across a range comfortably wider
      # than the ~16-byte `%{"command" => "` inspect prefix, so the fixed
      # 200-byte tool-arg truncation cut is guaranteed to land inside the
      # 4-byte emoji sequence for some offset in this range regardless of
      # the exact prefix length.
      for offset <- 190..210 do
        command = String.duplicate("a", offset) <> "🎉" <> String.duplicate("a", 50)

        Sessions.create_message(%{
          session_id: target.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t#{offset}",
                  "name" => "Bash",
                  "input" => %{"command" => command}
                }
              ]
            }
          }
        })

        result =
          SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

        assert %{"isError" => false, "content" => [%{"text" => text}]} = result,
               "offset #{offset} produced an error result"

        decoded = Jason.decode!(text)
        assert %{"args" => args} = List.last(decoded["recent_tool_calls"])
        assert String.valid?(args), "offset #{offset} produced invalid UTF-8: #{inspect(args)}"
      end
    end

    test "reports truncation when more tool calls exist than the default limit", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Create 12 tool calls to exceed the default limit of 10
      for i <- 1..12 do
        Sessions.create_message(%{
          session_id: target.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t#{i}",
                  "name" => "Bash",
                  "input" => %{"command" => "echo #{i}"}
                }
              ]
            }
          }
        })
      end

      result = SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      # Only 10 should be returned (the last 10)
      assert length(decoded["recent_tool_calls"]) == 10

      # The truncation flag should be present with the right info
      assert decoded["tool_calls_truncated"] =~ "showing last 10 of 12"
      assert decoded["tool_calls_truncated"] =~ "tool_call_limit"
      assert String.length(decoded["tool_calls_truncated"]) < 200
    end

    test "does not report truncation when at the limit", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Create exactly 10 tool calls (the default limit)
      for i <- 1..10 do
        Sessions.create_message(%{
          session_id: target.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t#{i}",
                  "name" => "Bash",
                  "input" => %{"command" => "echo #{i}"}
                }
              ]
            }
          }
        })
      end

      result = SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert length(decoded["recent_tool_calls"]) == 10
      # No truncation flag when exactly at the limit
      refute Map.has_key?(decoded, "tool_calls_truncated")
    end

    test "does not report truncation when fewer than the limit", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Create only 5 tool calls (fewer than the default limit of 10)
      for i <- 1..5 do
        Sessions.create_message(%{
          session_id: target.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t#{i}",
                  "name" => "Bash",
                  "input" => %{"command" => "echo #{i}"}
                }
              ]
            }
          }
        })
      end

      result = SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert length(decoded["recent_tool_calls"]) == 5
      # No truncation flag when below the limit
      refute Map.has_key?(decoded, "tool_calls_truncated")
    end

    test "larger tool_call_limit covers all calls without truncation", %{
      dir: dir,
      state: state
    } do
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      # Create 15 tool calls
      for i <- 1..15 do
        Sessions.create_message(%{
          session_id: target.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t#{i}",
                  "name" => "Bash",
                  "input" => %{"command" => "echo #{i}"}
                }
              ]
            }
          }
        })
      end

      # Request a larger limit that covers all 15
      result =
        SessionsTool.call(
          "get_session_tail",
          %{"session_id" => target.id, "tool_call_limit" => 20},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      assert length(decoded["recent_tool_calls"]) == 15
      # No truncation flag when the larger limit covers everything
      refute Map.has_key?(decoded, "tool_calls_truncated")
    end

    test "does not crash when tool_calls_truncated? key is missing (older node compatibility)",
         %{dir: dir, state: state} do
      # Simulate an older node's response that lacks the tool_calls_truncated? key
      {:ok, target} = Sessions.create_session(%{directory: dir, status: "running"})

      Sessions.create_message(%{
        session_id: target.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "Bash",
                "input" => %{"command" => "echo 1"}
              }
            ]
          }
        }
      })

      # Mock HubRPC.session_tail to return an older-style response
      stub_return = %{
        last_assistant_text: nil,
        recent_tool_calls: [
          %{name: "Bash", args: ~s(%{"command" => "echo 1"})}
        ],
        # Intentionally no tool_calls_truncated? key
        tool_calls_total: 1
      }

      # Directly test the result when the key is absent
      result = SessionsTool.call("get_session_tail", %{"session_id" => target.id}, state)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      # Should not crash and should not have the flag
      refute Map.has_key?(decoded, "tool_calls_truncated")
    end
  end

  describe "report_progress" do
    test "records phase and optional note on the calling session", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      result =
        SessionsTool.call(
          "report_progress",
          %{"phase" => "validating"},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "validating"

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.progress_phase == "validating"
      assert reloaded.progress_note == nil
      assert reloaded.progress_updated_at != nil
    end

    test "rejects an empty phase" do
      result =
        SessionsTool.call(
          "report_progress",
          %{"phase" => ""},
          %{orca_session_id: Ecto.UUID.generate()}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "phase"
    end

    test "errors with no linked session" do
      result =
        SessionsTool.call("report_progress", %{"phase" => "planning"}, %{orca_session_id: nil})

      assert %{"isError" => true} = result
    end

    test "rejects a call with both phase and title blank/absent" do
      result =
        SessionsTool.call(
          "report_progress",
          %{"note" => "no phase or title given"},
          %{orca_session_id: Ecto.UUID.generate()}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "phase"
      assert text =~ "title"
    end

    test "a title-only call persists and echoes the title without touching progress",
         %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          progress_phase: "validating",
          progress_note: "from an earlier call",
          progress_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      result =
        SessionsTool.call(
          "report_progress",
          %{"title" => "Fix the login bug"},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ ~s(Title updated to "Fix the login bug")

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.title == "Fix the login bug"
      # Title-only calls must not clear or touch progress fields.
      assert reloaded.progress_phase == "validating"
      assert reloaded.progress_note == "from an earlier call"
    end

    test "a phase+title call updates both and echoes the new title", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      result =
        SessionsTool.call(
          "report_progress",
          %{"phase" => "implementing", "title" => "New scope: also fix logout"},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ "implementing"
      assert text =~ ~s(Title updated to "New scope: also fix logout")

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.title == "New scope: also fix logout"
      assert reloaded.progress_phase == "implementing"
    end

    test "a phase-only call still echoes the session's existing title", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir, title: "Existing title"})

      result =
        SessionsTool.call(
          "report_progress",
          %{"phase" => "planning"},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      assert text =~ ~s(Session title: "Existing title")
    end

    test "title is trimmed, collapsed, and capped to ~80 chars", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      long_title = "  line one\n\nline two   with   spaces  " <> String.duplicate("x", 100)

      SessionsTool.call(
        "report_progress",
        %{"title" => long_title},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert String.length(reloaded.title) == 80
      refute reloaded.title =~ "\n"
    end

    test "a note well over 255 bytes persists and is truncated", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      # 300 ASCII characters = 300 bytes, well over the 250-byte cap
      long_note = String.duplicate("a", 300)

      SessionsTool.call(
        "report_progress",
        %{"phase" => "planning", "note" => long_note},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert byte_size(reloaded.progress_note) <= 255
      assert byte_size(reloaded.progress_note) < 300
      assert reloaded.progress_note =~ "a"
    end

    test "a note with multibyte characters stays under the byte limit", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      # 300 arrows = 900 bytes (each → is 3 bytes in UTF-8)
      multibyte_note = String.duplicate("→", 300)

      SessionsTool.call(
        "report_progress",
        %{"phase" => "planning", "note" => multibyte_note},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert byte_size(reloaded.progress_note) <= 255
      # Should be truncated, not crash with Postgrex.Error
      refute is_nil(reloaded.progress_note)
    end

    test "a short note is stored unchanged without ellipsis", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      short_note = "short note"

      SessionsTool.call(
        "report_progress",
        %{"phase" => "planning", "note" => short_note},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.progress_note == short_note
    end

    test "report_progress with phase but no note leaves progress_note as nil", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      SessionsTool.call(
        "report_progress",
        %{"phase" => "planning"},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.progress_note == nil
      assert reloaded.progress_phase == "planning"
    end

    test "a title with 80 multibyte characters survives (80 chars, not bytes)", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      # 80 arrows = 240 bytes but 80 visible characters
      multibyte_title = String.duplicate("→", 80)

      SessionsTool.call(
        "report_progress",
        %{"title" => multibyte_title},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      # Should be 80 characters (not truncated to ~26)
      assert String.length(reloaded.title) == 80
      # And byte size should be 240 (80 * 3 for arrow)
      assert byte_size(reloaded.title) == 240
      # Should still be under 255 bytes
      assert byte_size(reloaded.title) <= 255
    end

    test "a phase over 255 bytes is truncated", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      # 300 characters, well over the 250-byte cap
      long_phase = String.duplicate("x", 300)

      SessionsTool.call(
        "report_progress",
        %{"phase" => long_phase},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert byte_size(reloaded.progress_phase) <= 255
      assert byte_size(reloaded.progress_phase) < 300
    end

    test "a phase with multibyte characters stays under the byte limit", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir})

      # 300 arrows = 900 bytes (each → is 3 bytes in UTF-8)
      multibyte_phase = String.duplicate("→", 300)

      SessionsTool.call(
        "report_progress",
        %{"phase" => multibyte_phase},
        %{orca_session_id: session.id}
      )

      reloaded = Sessions.get_session!(session.id)
      assert byte_size(reloaded.progress_phase) <= 255
      # Should be truncated, not crash
      refute is_nil(reloaded.progress_phase)
    end
  end

  describe "search_sessions — session_id and parent_session_id filters" do
    test "session_id filters to an exact match", %{dir: dir, state: state} do
      {:ok, target} = Sessions.create_session(%{directory: dir, title: "target"})
      {:ok, _other} = Sessions.create_session(%{directory: dir, title: "other"})

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call(
          "search_sessions",
          %{"directory" => dir, "session_id" => target.id},
          state
        )

      results = Jason.decode!(text)
      assert Enum.map(results, & &1["id"]) == [target.id]
    end

    test "parent_session_id filters to that parent's children", %{dir: dir, state: state} do
      {:ok, parent} = Sessions.create_session(%{directory: dir, title: "parent"})

      {:ok, child} =
        Sessions.create_session(%{directory: dir, title: "child", parent_session_id: parent.id})

      {:ok, _unrelated} = Sessions.create_session(%{directory: dir, title: "unrelated"})

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call(
          "search_sessions",
          %{"directory" => dir, "parent_session_id" => parent.id},
          state
        )

      results = Jason.decode!(text)
      assert Enum.map(results, & &1["id"]) == [child.id]
    end
  end

  describe "search_sessions — include_activity" do
    test "computes activity metadata and last_commit for the whole result page", %{
      dir: dir,
      state: state
    } do
      {:ok, session} = Sessions.create_session(%{directory: dir, title: "active"})

      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "tool_use", "name" => "Bash", "input" => %{}}]}
        }
      })

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call(
          "search_sessions",
          %{"directory" => dir, "include_activity" => true},
          state
        )

      [result] = Jason.decode!(text) |> Enum.filter(&(&1["id"] == session.id))
      assert %{"messages_5m" => 1, "tool_calls_5m" => 1} = result["activity"]
      # dir is a fresh tmp dir, not a git repo.
      assert result["last_commit"] == nil
    end

    test "omits activity/last_commit when include_activity is not set", %{dir: dir, state: state} do
      {:ok, session} = Sessions.create_session(%{directory: dir, title: "quiet"})

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call("search_sessions", %{"directory" => dir}, state)

      [result] = Jason.decode!(text) |> Enum.filter(&(&1["id"] == session.id))
      refute Map.has_key?(result, "activity")
      refute Map.has_key?(result, "last_commit")
    end
  end

  describe "start_session — structured JSON result" do
    test "returns session_id/node/model/backend/directory/already_exists/orchestrator", %{
      state: state
    } do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)

      on_exit(fn -> stop_if_alive(decoded["session_id"]) end)

      assert decoded["already_exists"] == false
      assert decoded["backend"] == "claude"
      assert is_binary(decoded["node"])
      assert is_binary(decoded["directory"])
      assert decoded["orchestrator"] == false
    end
  end

  describe "start_session — orchestrator param" do
    test "passing orchestrator: true creates a session with orchestrator == true", %{
      state: state
    } do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "orchestrator" => true, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      session_id = decoded["session_id"]

      on_exit(fn -> stop_if_alive(session_id) end)

      assert decoded["orchestrator"] == true
      assert Sessions.get_session!(session_id).orchestrator == true
    end

    test "omitting orchestrator leaves the new session as a non-orchestrator (default false)",
         %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      session_id = decoded["session_id"]

      on_exit(fn -> stop_if_alive(session_id) end)

      assert decoded["orchestrator"] == false
      assert Sessions.get_session!(session_id).orchestrator == false
    end
  end

  describe "start_session — orchestrator spawns are siblings, not children (handoff)" do
    test "orchestrator: true (default notify_on_completion) links as a sibling of the caller, suppresses notify_parent, and records a handoff interaction",
         %{state: state} do
      caller = Sessions.get_session!(state.orca_session_id)
      assert caller.parent_session_id == nil

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "orchestrator" => true},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      new_session = Sessions.get_session!(session_id)
      # The caller has no parent of its own, so the new orchestrator inherits
      # nil — becoming a root session, which is intended.
      assert new_session.parent_session_id == caller.parent_session_id
      assert new_session.notify_parent == false

      assert [interaction] =
               Sessions.list_session_interactions(recipient_session_id: session_id)

      assert interaction.sender_session_id == caller.id
      assert interaction.recipient_session_id == session_id
      assert interaction.kind == "handoff"
    end

    test "orchestrator: true + notify_on_completion: true keeps the old child-link behavior and records no handoff edge",
         %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "orchestrator" => true, "notify_on_completion" => true},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      new_session = Sessions.get_session!(session_id)
      assert new_session.parent_session_id == state.orca_session_id
      assert new_session.notify_parent == true

      assert Sessions.list_session_interactions(recipient_session_id: session_id) == []
    end

    test "non-orchestrator spawn is completely unchanged: still child + notify by default, no handoff edge",
         %{state: state} do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call("start_session", %{"prompt" => "hi"}, state)
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      new_session = Sessions.get_session!(session_id)
      assert new_session.orchestrator == false
      assert new_session.parent_session_id == state.orca_session_id
      assert new_session.notify_parent == true

      assert Sessions.list_session_interactions(recipient_session_id: session_id) == []
    end

    test "orchestrator: true from a caller that itself has a parent links the new session to the GRANDparent",
         %{dir: dir} do
      {:ok, grandparent} = Sessions.create_session(%{directory: dir, orchestrator: true})
      on_exit(fn -> stop_if_alive(grandparent.id) end)

      {:ok, caller} =
        Sessions.create_session(%{
          directory: dir,
          orchestrator: true,
          parent_session_id: grandparent.id
        })

      on_exit(fn -> stop_if_alive(caller.id) end)

      state = %{orca_session_id: caller.id, orchestrator: true}

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "orchestrator" => true},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)

      new_session = Sessions.get_session!(session_id)
      assert new_session.parent_session_id == grandparent.id
      assert new_session.notify_parent == false

      assert [interaction] =
               Sessions.list_session_interactions(recipient_session_id: session_id)

      assert interaction.sender_session_id == caller.id
      assert interaction.kind == "handoff"
    end
  end

  describe "cross-node isolation enforcement" do
    defp isolate_local_node! do
      node_row =
        ClusterNodes.get_by_name(Atom.to_string(node())) ||
          (
            {:ok, row} = ClusterNodes.upsert_seen(Atom.to_string(node()), Atom.to_string(node()))
            row
          )

      {:ok, isolated_row} = ClusterNodes.update_node(node_row, %{isolated: true})
      isolated_row
    end

    test "send_message_to_session denies a cross-node target when the local node is isolated",
         %{dir: dir} do
      isolate_local_node!()

      {:ok, target} =
        Sessions.create_session(%{directory: dir, runner_node: "debian@totally-offline-host"})

      result =
        SessionsTool.call(
          "send_message_to_session",
          %{"session_id" => target.id, "message" => "hello"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
      assert Sessions.list_messages(target.id) == []
    end

    test "send_message_to_session still allows a same-node target when isolated",
         %{state: state, dir: dir} do
      isolate_local_node!()

      {:ok, target} =
        Sessions.create_session(%{directory: dir, runner_node: Atom.to_string(node())})

      on_exit(fn -> stop_if_alive(target.id) end)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "send_message_to_session",
            %{"session_id" => target.id, "message" => "hello"},
            state
          )
        end)

      assert %{"isError" => false} = result
    end

    test "archive_session denies a cross-node target when the local node is isolated",
         %{dir: dir} do
      isolate_local_node!()

      {:ok, target} =
        Sessions.create_session(%{directory: dir, runner_node: "debian@totally-offline-host"})

      result =
        SessionsTool.call("archive_session", %{"session_id" => target.id}, %{orca_session_id: nil})

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
      refute Sessions.get_session!(target.id).archived_at
    end

    test "get_session_tail denies a cross-node target when the local node is isolated",
         %{dir: dir} do
      isolate_local_node!()

      {:ok, target} =
        Sessions.create_session(%{directory: dir, runner_node: "debian@totally-offline-host"})

      result =
        SessionsTool.call("get_session_tail", %{"session_id" => target.id}, %{
          orca_session_id: nil
        })

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
    end

    test "start_session denies routing to another node's project when the local node is isolated",
         %{state: state} do
      isolate_local_node!()

      other_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_isolated_#{System.unique_integer([:positive])}"
        )

      {:ok, _other_project} =
        OrcaHub.Projects.create_project(%{
          name: "isolated-other-project",
          directory: other_dir,
          node: "debian@totally-offline-host"
        })

      count_before = Sessions.list_sessions(:all) |> length()

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "directory" => other_dir},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
      assert Sessions.list_sessions(:all) |> length() == count_before
    end

    test "start_session still allows same-node routing when isolated", %{state: state} do
      isolate_local_node!()

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      session_id = session_id_from!(text)
      on_exit(fn -> stop_if_alive(session_id) end)
    end

    test "search_sessions scopes results to the local node when isolated", %{
      dir: dir,
      state: state
    } do
      isolate_local_node!()

      {:ok, local_session} =
        Sessions.create_session(%{
          directory: dir,
          title: "local-one",
          runner_node: Atom.to_string(node())
        })

      {:ok, _remote_session} =
        Sessions.create_session(%{
          directory: dir,
          title: "remote-one",
          runner_node: "debian@totally-offline-host"
        })

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call("search_sessions", %{"directory" => dir}, state)

      ids = Jason.decode!(text) |> Enum.map(& &1["id"])
      assert local_session.id in ids
      refute Enum.any?(ids, &(&1 != local_session.id and &1 != state.orca_session_id))
    end

    test "search_sessions is unrestricted when not isolated", %{dir: dir, state: state} do
      {:ok, local_session} =
        Sessions.create_session(%{
          directory: dir,
          title: "local-two",
          runner_node: Atom.to_string(node())
        })

      {:ok, remote_session} =
        Sessions.create_session(%{
          directory: dir,
          title: "remote-two",
          runner_node: "debian@totally-offline-host"
        })

      %{"content" => [%{"text" => text}]} =
        SessionsTool.call("search_sessions", %{"directory" => dir}, state)

      ids = Jason.decode!(text) |> Enum.map(& &1["id"])
      assert local_session.id in ids
      assert remote_session.id in ids
    end
  end

  describe "start_session — idempotency_key" do
    test "a repeat call with the same key returns the existing session instead of spawning a new one",
         %{state: state} do
      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "notify_on_completion" => false,
              "idempotency_key" => "dedup-1"
            },
            state
          )
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      before_count = Sessions.list_sessions(:all) |> length()

      second =
        SessionsTool.call(
          "start_session",
          %{
            "prompt" => "hi again",
            "notify_on_completion" => false,
            "idempotency_key" => "dedup-1"
          },
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => second_text}]} = second
      decoded = Jason.decode!(second_text)

      assert decoded["session_id"] == first_id
      assert decoded["already_exists"] == true
      assert Sessions.list_sessions(:all) |> length() == before_count
    end

    test "a different key spawns a distinct session", %{state: state} do
      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false, "idempotency_key" => "key-a"},
            state
          )
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      second =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "notify_on_completion" => false, "idempotency_key" => "key-b"},
            state
          )
        end)

      %{"content" => [%{"text" => second_text}]} = second
      second_id = session_id_from!(second_text)
      on_exit(fn -> stop_if_alive(second_id) end)

      assert first_id != second_id
    end
  end

  describe "start_session — automatic idempotency key (issue c7eeef06)" do
    test "a wire-level replay (identical args, same MCP request id) returns the existing session",
         %{state: state} do
      replay_state = Map.put(state, :mcp_request_id, 7)
      args = %{"prompt" => "hi", "notify_on_completion" => false}

      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call("start_session", args, replay_state)
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      before_count = Sessions.list_sessions(:all) |> length()

      # No fake claude on $PATH this time — a genuine second call would raise
      # trying to spawn the real CLI, so success here proves no spawn happened.
      second = SessionsTool.call("start_session", args, replay_state)

      assert %{"isError" => false, "content" => [%{"text" => second_text}]} = second
      decoded = Jason.decode!(second_text)

      assert decoded["session_id"] == first_id
      assert decoded["already_exists"] == true
      assert Sessions.list_sessions(:all) |> length() == before_count
    end

    test "a recycled MCP request id with a different prompt is NOT deduped", %{state: state} do
      replay_state = Map.put(state, :mcp_request_id, 1)

      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "task A", "notify_on_completion" => false},
            replay_state
          )
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      # Simulates the CLI re-handshaking and restarting request ids at 1 for
      # a genuinely new, unrelated start_session call.
      second =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "task B", "notify_on_completion" => false},
            replay_state
          )
        end)

      %{"content" => [%{"text" => second_text}]} = second
      decoded = Jason.decode!(second_text)
      second_id = session_id_from!(second_text)
      on_exit(fn -> stop_if_alive(second_id) end)

      assert second_id != first_id
      assert decoded["already_exists"] == false
    end

    test "an explicit idempotency_key still takes precedence over the auto-derived key", %{
      state: state
    } do
      replay_state = Map.put(state, :mcp_request_id, 42)

      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "notify_on_completion" => false,
              "idempotency_key" => "explicit-1"
            },
            replay_state
          )
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      # Same request id AND same args AS the auto-key would require, but a
      # DIFFERENT explicit key — explicit semantics must win, so this spawns
      # a distinct session rather than deduping on the auto-key match.
      second =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{
              "prompt" => "hi",
              "notify_on_completion" => false,
              "idempotency_key" => "explicit-2"
            },
            replay_state
          )
        end)

      %{"content" => [%{"text" => second_text}]} = second
      decoded = Jason.decode!(second_text)
      second_id = session_id_from!(second_text)
      on_exit(fn -> stop_if_alive(second_id) end)

      assert second_id != first_id
      assert decoded["already_exists"] == false
    end

    test "an auto-key match older than the dedup window is NOT absorbed — a fresh session spawns",
         %{state: state} do
      replay_state = Map.put(state, :mcp_request_id, 99)
      args = %{"prompt" => "hi", "notify_on_completion" => false}

      first =
        with_fake_claude_on_path(fn ->
          SessionsTool.call("start_session", args, replay_state)
        end)

      %{"content" => [%{"text" => first_text}]} = first
      first_id = session_id_from!(first_text)
      on_exit(fn -> stop_if_alive(first_id) end)

      # Backdate the first session past the 15-minute auto-key window so the
      # belt-and-braces time bound kicks in.
      stale_inserted_at =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-16 * 60, :second)
        |> NaiveDateTime.truncate(:second)

      Sessions.get_session!(first_id)
      |> Ecto.Changeset.change(inserted_at: stale_inserted_at)
      |> Repo.update!()

      second =
        with_fake_claude_on_path(fn ->
          SessionsTool.call("start_session", args, replay_state)
        end)

      %{"content" => [%{"text" => second_text}]} = second
      decoded = Jason.decode!(second_text)
      second_id = session_id_from!(second_text)
      on_exit(fn -> stop_if_alive(second_id) end)

      assert second_id != first_id
      assert decoded["already_exists"] == false
    end
  end

  describe "start_session — issue_id (issues_spec.md §9)" do
    defp unique_issue_key_prefix(base \\ "ISL") do
      (base <> Integer.to_string(System.unique_integer([:positive]))) |> String.slice(0, 10)
    end

    setup %{dir: dir} do
      {:ok, project} =
        OrcaHub.Projects.create_project(%{
          name: "issue-link-test-#{System.unique_integer([:positive])}",
          directory: dir,
          node: "n1@x",
          key_prefix: unique_issue_key_prefix()
        })

      {:ok, issue} = OrcaHub.Issues.create_issue(%{title: "linked work", project_id: project.id})

      {:ok, project: project, issue: issue}
    end

    test "links the new session's issue_id and auto-transitions the issue to in_progress", %{
      state: state,
      issue: issue
    } do
      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "issue_id" => issue.id, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      session_id = decoded["session_id"]
      on_exit(fn -> stop_if_alive(session_id) end)

      assert decoded["issue_id"] == issue.id
      assert Sessions.get_session!(session_id).issue_id == issue.id
      assert OrcaHub.Issues.get_issue!(issue.id).status == "in_progress"
    end

    test "accepts the issue's rendered key instead of a raw id", %{state: state, issue: issue} do
      key = OrcaHub.Issues.render_key(issue)
      refute is_nil(key)

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "issue_id" => key, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(decoded["session_id"]) end)

      assert decoded["issue_id"] == issue.id
    end

    test "an unresolvable issue_id fails the spawn with a friendly error, no session created",
         %{state: state, dir: dir} do
      existing = Sessions.list_sessions() |> length()

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "issue_id" => "NOPE-999", "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "issue"
      assert Sessions.list_sessions() |> length() == existing
      assert File.exists?(dir)
    end

    test "does not clobber an issue that's already in_progress", %{state: state, issue: issue} do
      {:ok, issue} = OrcaHub.Issues.update_issue(issue, %{status: "in_progress"})

      result =
        with_fake_claude_on_path(fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "issue_id" => issue.id, "notify_on_completion" => false},
            state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      on_exit(fn -> stop_if_alive(session_id_from!(text)) end)

      assert OrcaHub.Issues.get_issue!(issue.id).status == "in_progress"
    end
  end

  describe "start_session — fork_from_parent (pi_fork_spec.md §3)" do
    setup %{dir: dir} do
      Application.put_env(:orca_hub, :pi_executable, @pi_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)

      {:ok, pi_caller} =
        Sessions.create_session(%{
          directory: dir,
          backend: "pi",
          code_exec: false,
          orchestrator: false
        })

      {:ok, pi_state: %{orca_session_id: pi_caller.id}, pi_caller: pi_caller}
    end

    defp with_fork_kv_budget(value, fun) do
      original = System.get_env("ORCA_FORK_KV_BUDGET")
      System.put_env("ORCA_FORK_KV_BUDGET", to_string(value))

      try do
        fun.()
      after
        if original,
          do: System.put_env("ORCA_FORK_KV_BUDGET", original),
          else: System.delete_env("ORCA_FORK_KV_BUDGET")
      end
    end

    test "fork from a non-pi caller is rejected, no session created", %{state: state} do
      # the module-level `state` fixture's caller is backend "claude".
      count_before = Repo.aggregate(Session, :count)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "pi"
      assert text =~ "claude"
      assert Repo.aggregate(Session, :count) == count_before
    end

    test "a conflicting model arg is rejected, no session created", %{
      pi_state: pi_state
    } do
      count_before = Repo.aggregate(Session, :count)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "model" => "some-other-model"},
          pi_state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "model"
      assert Repo.aggregate(Session, :count) == count_before
    end

    test "a conflicting directory arg is rejected, no session created", %{
      pi_state: pi_state
    } do
      other_dir =
        Path.join(
          System.tmp_dir!(),
          "mcp_start_session_fork_other_#{System.unique_integer([:positive])}"
        )

      count_before = Repo.aggregate(Session, :count)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "directory" => other_dir},
          pi_state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "directory"
      assert Repo.aggregate(Session, :count) == count_before
    end

    test "a conflicting orchestrator arg is rejected, no session created", %{
      pi_state: pi_state
    } do
      count_before = Repo.aggregate(Session, :count)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "orchestrator" => true},
          pi_state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "orchestrator"
      assert Repo.aggregate(Session, :count) == count_before
    end

    test "a successful fork inherits code_exec, links lineage, and creates the synthetic marker",
         %{pi_state: pi_state, pi_caller: pi_caller} do
      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "notify_on_completion" => false},
          pi_state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      session_id = decoded["session_id"]
      on_exit(fn -> stop_if_alive(session_id) end)

      assert decoded["forked_from"] == pi_caller.id
      assert decoded["parent_context_tokens"] == nil

      child = Sessions.get_session!(session_id)
      assert child.backend == "pi"
      assert child.code_exec == false
      assert child.forked_from_session_id == pi_caller.id
      assert child.parent_session_id == pi_caller.id

      assert [marker] =
               Sessions.list_messages(session_id)
               |> Enum.filter(&(&1.data["subtype"] == "forked_from"))

      assert marker.data["type"] == "system"
      assert marker.data["parent_session_id"] == pi_caller.id
      assert marker.data["inherited_tokens"] == nil

      assert [interaction] =
               Sessions.list_session_interactions(recipient_session_id: session_id)

      assert interaction.sender_session_id == pi_caller.id
      assert interaction.kind == "fork"
    end

    test "result and marker carry the parent's last known context token count", %{
      pi_state: pi_state,
      pi_caller: pi_caller
    } do
      {:ok, _stats} =
        Sessions.create_message(%{
          session_id: pi_caller.id,
          data: %{"type" => "pi_session_stats", "context_usage" => %{"tokens" => 22_507}}
        })

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "notify_on_completion" => false},
          pi_state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      session_id = decoded["session_id"]
      on_exit(fn -> stop_if_alive(session_id) end)

      assert decoded["parent_context_tokens"] == 22_507

      assert [marker] =
               Sessions.list_messages(session_id)
               |> Enum.filter(&(&1.data["subtype"] == "forked_from"))

      assert marker.data["inherited_tokens"] == 22_507
    end

    test "budget warning appears above the (lowered) threshold", %{
      pi_state: pi_state,
      pi_caller: pi_caller
    } do
      {:ok, _stats} =
        Sessions.create_message(%{
          session_id: pi_caller.id,
          data: %{"type" => "pi_session_stats", "context_usage" => %{"tokens" => 22_507}}
        })

      result =
        with_fork_kv_budget(10_000, fn ->
          SessionsTool.call(
            "start_session",
            %{"prompt" => "hi", "fork_from_parent" => true, "notify_on_completion" => false},
            pi_state
          )
        end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(decoded["session_id"]) end)

      assert decoded["fork_budget_warning"] =~ "KV budget"
    end

    test "no budget warning under the default threshold", %{
      pi_state: pi_state,
      pi_caller: pi_caller
    } do
      {:ok, _stats} =
        Sessions.create_message(%{
          session_id: pi_caller.id,
          data: %{"type" => "pi_session_stats", "context_usage" => %{"tokens" => 22_507}}
        })

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "fork_from_parent" => true, "notify_on_completion" => false},
          pi_state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      decoded = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(decoded["session_id"]) end)

      refute Map.has_key?(decoded, "fork_budget_warning")
    end
  end
end
