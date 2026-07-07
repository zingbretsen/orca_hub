defmodule OrcaHub.MCP.UpstreamClientTest do
  # async: false — tests set the global :upstream_req_options app env.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.UpstreamClient
  alias OrcaHub.UpstreamServers.UpstreamServer

  @stub OrcaHub.MCP.UpstreamClientStub

  setup do
    Application.put_env(:orca_hub, :upstream_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:orca_hub, :upstream_req_options) end)
    :ok
  end

  defp server(attrs \\ []) do
    struct!(
      %UpstreamServer{
        id: Ecto.UUID.generate(),
        name: "play",
        url: "http://upstream-a.test/mcp",
        prefix: "play",
        headers: %{},
        enabled: true
      },
      attrs
    )
  end

  # Fake MCP server plug. Records every request to the test process as
  # {:req, http_method, host, rpc_method, mcp-session-id} and replies like a
  # Streamable HTTP MCP server.
  defp mcp_stub(test_pid, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "sess-new")
    tools = Keyword.get(opts, :tools, [%{"name" => "navigate", "description" => "nav"}])
    reject_session = Keyword.get(opts, :reject_session)

    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw in ["", nil], do: %{}, else: Jason.decode!(raw)
      sess = conn |> Plug.Conn.get_req_header("mcp-session-id") |> List.first()
      send(test_pid, {:req, conn.method, conn.host, body["method"], sess})

      cond do
        conn.method == "DELETE" ->
          Plug.Conn.send_resp(conn, 200, "")

        body["method"] == "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", session_id)
          |> Req.Test.json(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{}})

        body["method"] == "notifications/initialized" ->
          Plug.Conn.send_resp(conn, 202, "")

        body["method"] == "tools/list" and reject_session != nil and sess == reject_session ->
          Plug.Conn.send_resp(conn, 404, "session expired")

        body["method"] == "tools/list" ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => %{"tools" => tools}
          })
      end
    end
  end

  # Build a live connection for `srv` through the real connect path, then
  # clear the recorded requests so tests only assert on the reconcile under
  # test.
  defp connect!(srv, opts) do
    Req.Test.stub(@stub, mcp_stub(self(), opts))
    conns = UpstreamClient.reconcile_connections([srv], %{})
    flush_requests()
    conns
  end

  defp flush_requests do
    receive do
      {:req, _, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "initializes a new server and caches its tools" do
    Req.Test.stub(@stub, mcp_stub(self(), session_id: "sess-1"))
    srv = server()

    conns = UpstreamClient.reconcile_connections([srv], %{})

    assert %{session_id: "sess-1", tools: [%{"name" => "navigate"}]} = conns[srv.id]
    assert_received {:req, "POST", _, "initialize", nil}
    assert_received {:req, "POST", _, "notifications/initialized", "sess-1"}
    assert_received {:req, "POST", _, "tools/list", "sess-1"}
  end

  test "keeps the existing session when config is unchanged and health check passes" do
    srv = server()
    existing = connect!(srv, session_id: "sess-old")

    Req.Test.stub(@stub, mcp_stub(self(), tools: [%{"name" => "fresh_tool"}]))
    conns = UpstreamClient.reconcile_connections([srv], existing)

    assert conns[srv.id].session_id == "sess-old"
    assert [%{"name" => "fresh_tool"}] = conns[srv.id].tools
    assert_received {:req, "POST", _, "tools/list", "sess-old"}
    refute_received {:req, "POST", _, "initialize", _}
    refute_received {:req, "DELETE", _, _, _}
  end

  test "re-initializes when the health check fails, without DELETEing the dead session" do
    srv = server()
    existing = connect!(srv, session_id: "sess-old")

    Req.Test.stub(@stub, mcp_stub(self(), session_id: "sess-new", reject_session: "sess-old"))
    conns = UpstreamClient.reconcile_connections([srv], existing)

    assert conns[srv.id].session_id == "sess-new"
    assert_received {:req, "POST", _, "tools/list", "sess-old"}
    assert_received {:req, "POST", _, "initialize", nil}
    refute_received {:req, "DELETE", _, _, _}
  end

  test "re-initializes and DELETEs the old session when config changes" do
    srv = server()
    existing = connect!(srv, session_id: "sess-old")

    moved = %{srv | url: "http://upstream-b.test/mcp"}
    Req.Test.stub(@stub, mcp_stub(self(), session_id: "sess-new"))
    conns = UpstreamClient.reconcile_connections([moved], existing)

    assert conns[srv.id].session_id == "sess-new"
    assert conns[srv.id].url == "http://upstream-b.test/mcp"
    assert_received {:req, "DELETE", "upstream-a.test", _, "sess-old"}
    assert_received {:req, "POST", "upstream-b.test", "initialize", nil}
  end

  test "drops and DELETEs sessions for servers removed from the enabled list" do
    srv = server()
    existing = connect!(srv, session_id: "sess-old")

    Req.Test.stub(@stub, mcp_stub(self()))
    conns = UpstreamClient.reconcile_connections([], existing)

    assert conns == %{}
    assert_received {:req, "DELETE", "upstream-a.test", _, "sess-old"}
  end

  describe "agent mode" do
    setup do
      prev = Application.get_env(:orca_hub, :mode, :hub)
      Application.put_env(:orca_hub, :mode, :agent)
      on_exit(fn -> Application.put_env(:orca_hub, :mode, prev) end)
    end

    test "public API degrades gracefully when no hub node is reachable" do
      assert UpstreamClient.list_tools() == []
      refute UpstreamClient.upstream_tool?("play__navigate")

      assert %{"isError" => true, "content" => [%{"text" => "Upstream client is not available"}]} =
               UpstreamClient.call_tool("play__navigate", %{})

      assert UpstreamClient.refresh() == :ok
    end
  end

  test "keeps other connections when one server's connect fails" do
    srv_ok = server(name: "alpha", prefix: "alpha", url: "http://upstream-a.test/mcp")
    existing = connect!(srv_ok, session_id: "sess-ok")

    srv_bad =
      server(name: "beta", prefix: "beta", url: "http://upstream-down.test/mcp")

    Req.Test.stub(@stub, fn conn ->
      if conn.host == "upstream-down.test" do
        Plug.Conn.send_resp(conn, 500, "boom")
      else
        mcp_stub(self()).(conn)
      end
    end)

    conns = UpstreamClient.reconcile_connections([srv_ok, srv_bad], existing)

    assert conns[srv_ok.id].session_id == "sess-ok"
    refute Map.has_key?(conns, srv_bad.id)
  end
end
