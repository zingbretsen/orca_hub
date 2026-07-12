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

  alias OrcaHub.Backend.Cache
  alias OrcaHub.MCP.Tools.Sessions, as: SessionsTool
  alias OrcaHub.Sessions.Session
  alias OrcaHub.{Sessions, SessionSupervisor}

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
  defp with_fake_claude_on_path(fun) do
    bin_dir =
      Path.join(System.tmp_dir!(), "fake_claude_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    claude_path = Path.join(bin_dir, "claude")
    File.write!(claude_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(claude_path, 0o755)

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", bin_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
      File.rm_rf!(bin_dir)
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
    test "returns session_id/node/model/backend/directory/already_exists", %{state: state} do
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
end
