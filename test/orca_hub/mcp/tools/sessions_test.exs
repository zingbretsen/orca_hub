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
  end
end
