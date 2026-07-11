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
    [id] = Regex.run(~r/^Session (\S+) started/, text, capture: :all_but_first)
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
          SessionsTool.call("start_session", %{"prompt" => "hi"}, state)
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

      result = SessionsTool.call("start_session", %{"prompt" => "hi", "backend" => "pi"}, state)

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

  describe "start_session backend/model params — model" do
    test "model passes through onto the created session row", %{state: state} do
      Application.put_env(:orca_hub, :codex_executable, @codex_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :codex_executable) end)

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "backend" => "codex", "model" => "gpt-5-codex"},
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
          SessionsTool.call("start_session", %{"prompt" => "hi", "model" => "sonnet"}, state)
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
            %{"prompt" => "hi", "model" => "claude-sonnet-5"},
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

      # Read-only: no runner was ever started for this session.
      refute SessionSupervisor.session_alive?(target.id)
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
end
