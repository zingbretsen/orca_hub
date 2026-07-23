defmodule OrcaHubWeb.AgentModeGateTest do
  @moduledoc """
  OrcaHubWeb.Endpoint's `:agent_mode_gate` plug — in agent mode
  (`OrcaHub.Mode.agent?/0`), every request 404s except /mcp, /healthz, and
  /api/version. See lib/orca_hub_web/endpoint.ex.

  async: false — :orca_hub's :mode app env is global process state; an
  async:true test flipping it can race unrelated tests running concurrently
  (see test/orca_hub/cluster_distributed_test.exs for prior history of this
  exact flake).
  """

  use OrcaHubWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:orca_hub, :mode, :hub)
    on_exit(fn -> Application.put_env(:orca_hub, :mode, prev) end)
  end

  describe "hub mode (default)" do
    test "GET / is unaffected", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.status == 200
    end

    test "static asset paths are unaffected by the gate", %{conn: conn} do
      conn = get(conn, "/assets/does-not-exist.css")

      refute conn.status == 404 and conn.resp_body == "not found"
    end
  end

  describe "agent mode" do
    setup do
      Application.put_env(:orca_hub, :mode, :agent)
      :ok
    end

    test "GET / returns a plain-text 404", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.status == 404
      assert conn.resp_body == "not found"
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    end

    test "GET /sessions (LiveView page route) returns a plain-text 404", %{conn: conn} do
      conn = get(conn, "/sessions")

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "static asset paths 404", %{conn: conn} do
      conn = get(conn, "/assets/app.css")

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "webhook routes 404", %{conn: conn} do
      conn = post(conn, "/api/webhooks/some-secret", %{})

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "GET /healthz still works", %{conn: conn} do
      conn = get(conn, "/healthz")

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "GET /api/version still works", %{conn: conn} do
      conn = get(conn, "/api/version")

      assert conn.status == 200
      assert %{"sha" => _} = Jason.decode!(conn.resp_body)
    end

    test "requests under /mcp pass the gate through to the MCP plug", %{conn: conn} do
      conn = get(conn, "/mcp")

      # GET /mcp isn't a 404 from our gate — OrcaHub.MCP.Plug handles the
      # path and currently returns 405 for GET. What matters here is that
      # the gate let it through rather than short-circuiting with our
      # plain-text 404.
      refute conn.status == 404 and conn.resp_body == "not found"
    end
  end
end
