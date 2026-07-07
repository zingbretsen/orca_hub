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
  # Streamable HTTP MCP server. `tools/call` echoes the serving session id in
  # the result text ("ok:<sess>") so tests can assert which upstream session
  # handled a call. With `session_ids: "base"`, each initialize mints a fresh
  # id ("base-1", "base-2", …); `reject_session:` 404s tools/list AND
  # tools/call for that id (an expired upstream session).
  defp mcp_stub(test_pid, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "sess-new")
    session_ids = Keyword.get(opts, :session_ids)
    tools = Keyword.get(opts, :tools, [%{"name" => "navigate", "description" => "nav"}])
    reject_session = Keyword.get(opts, :reject_session)
    counter = :counters.new(1, [])

    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw in ["", nil], do: %{}, else: Jason.decode!(raw)
      sess = conn |> Plug.Conn.get_req_header("mcp-session-id") |> List.first()
      send(test_pid, {:req, conn.method, conn.host, body["method"], sess})

      cond do
        conn.method == "DELETE" ->
          Plug.Conn.send_resp(conn, 200, "")

        body["method"] == "initialize" ->
          new_sess =
            if session_ids do
              :counters.add(counter, 1, 1)
              "#{session_ids}-#{:counters.get(counter, 1)}"
            else
              session_id
            end

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", new_sess)
          |> Req.Test.json(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => %{}})

        body["method"] == "notifications/initialized" ->
          Plug.Conn.send_resp(conn, 202, "")

        body["method"] in ["tools/list", "tools/call"] and reject_session != nil and
            sess == reject_session ->
          Plug.Conn.send_resp(conn, 404, "session expired")

        body["method"] == "tools/list" ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => %{"tools" => tools}
          })

        body["method"] == "tools/call" ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => body["id"],
            "result" => %{
              "content" => [%{"type" => "text", "text" => "ok:#{sess}"}],
              "isError" => false
            }
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

  describe "session-scoped servers" do
    defp result_text(%{"content" => [%{"text" => text} | _]}), do: text

    # A connected session_scoped server: shared session "shared", scoped
    # initializes mint "scoped-1", "scoped-2", … via the re-stub.
    defp scoped_setup do
      srv = server(session_scoped: true)
      conns = connect!(srv, session_id: "shared")
      Req.Test.stub(@stub, mcp_stub(self(), session_ids: "scoped"))
      {srv, conns}
    end

    test "creates one upstream session per orca session and reuses it" do
      {srv, conns} = scoped_setup()

      {r1, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      {r2, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-2"
        )

      {r3, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-1"
        )

      # Two Orca sessions → two initializes with distinct upstream sessions;
      # the third call reuses orca-1's session without re-initializing.
      assert result_text(r1) == "ok:scoped-1"
      assert result_text(r2) == "ok:scoped-2"
      assert result_text(r3) == "ok:scoped-1"
      assert map_size(scoped) == 2
      assert scoped[{srv.id, "orca-1"}].session_id == "scoped-1"
      assert scoped[{srv.id, "orca-2"}].session_id == "scoped-2"

      assert_received {:req, "POST", _, "initialize", nil}
      assert_received {:req, "POST", _, "initialize", nil}
      refute_received {:req, "POST", _, "initialize", _}
    end

    test "falls back to the shared session without an orca_session_id" do
      {_srv, conns} = scoped_setup()

      {result, scoped} = UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, [])

      assert result_text(result) == "ok:shared"
      assert scoped == %{}
      refute_received {:req, "POST", _, "initialize", _}
    end

    test "non-scoped servers use the shared session even with an orca_session_id" do
      srv = server()
      conns = connect!(srv, session_id: "shared")
      Req.Test.stub(@stub, mcp_stub(self()))

      {result, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      assert result_text(result) == "ok:shared"
      assert scoped == %{}
      refute_received {:req, "POST", _, "initialize", _}
    end

    test "re-initializes once and retries when a scoped session has expired" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      flush_requests()
      Req.Test.stub(@stub, mcp_stub(self(), session_ids: "fresh", reject_session: "scoped-1"))

      {result, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-1"
        )

      assert result_text(result) == "ok:fresh-1"
      assert scoped[{srv.id, "orca-1"}].session_id == "fresh-1"
      # Failed call on the dead session, then one initialize + retried call.
      assert_received {:req, "POST", _, "tools/call", "scoped-1"}
      assert_received {:req, "POST", _, "initialize", nil}
      assert_received {:req, "POST", _, "tools/call", "fresh-1"}
      refute_received {:req, "DELETE", _, _, _}
    end

    test "TTL sweep DELETEs idle scoped sessions and keeps active ones" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      now = System.monotonic_time(:millisecond)

      assert UpstreamClient.sweep_scoped(scoped, now) == scoped
      refute_received {:req, "DELETE", _, _, _}

      assert UpstreamClient.sweep_scoped(scoped, now + :timer.minutes(31)) == %{}
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-1"}
      assert Map.has_key?(scoped, {srv.id, "orca-1"})
    end

    test "evicts the least-recently-used scoped session at the per-server cap" do
      {srv, conns} = scoped_setup()

      scoped =
        Enum.reduce(1..20, %{}, fn i, scoped ->
          {_r, scoped} =
            UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
              orca_session_id: "orca-#{i}"
            )

          scoped
        end)

      # Reuse orca-1 so orca-2 becomes the LRU entry.
      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-1"
        )

      flush_requests()

      {r21, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-21"
        )

      assert result_text(r21) == "ok:scoped-21"
      assert map_size(scoped) == 20
      refute Map.has_key?(scoped, {srv.id, "orca-2"})
      assert Map.has_key?(scoped, {srv.id, "orca-1"})
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-2"}
    end

    test "config change tears down that server's scoped sessions" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      flush_requests()
      moved = %{srv | url: "http://upstream-b.test/mcp"}
      Req.Test.stub(@stub, mcp_stub(self(), session_id: "sess-new"))
      new_conns = UpstreamClient.reconcile_connections([moved], conns)

      assert UpstreamClient.reconcile_scoped(scoped, new_conns) == %{}
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-1"}
    end

    test "refresh with unchanged config keeps scoped sessions untouched" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      flush_requests()
      new_conns = UpstreamClient.reconcile_connections([srv], conns)

      assert UpstreamClient.reconcile_scoped(scoped, new_conns) == scoped
      refute_received {:req, "DELETE", _, _, _}
    end

    test "server removal and un-scoping tear down scoped sessions" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      flush_requests()

      # Removed from the enabled list entirely.
      assert UpstreamClient.reconcile_scoped(scoped, %{}) == %{}
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-1"}

      # session_scoped flipped off: shared connection stays, scoped drop.
      unscoped_conns = put_in(conns[srv.id].session_scoped, false)
      assert UpstreamClient.reconcile_scoped(scoped, unscoped_conns) == %{}
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-1"}
    end

    test "archiving an orca session drops only its scoped sessions" do
      {srv, conns} = scoped_setup()

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, %{}, "play__navigate", %{}, orca_session_id: "orca-1")

      {_r, scoped} =
        UpstreamClient.dispatch_call(conns, scoped, "play__navigate", %{},
          orca_session_id: "orca-2"
        )

      flush_requests()
      remaining = UpstreamClient.drop_scoped_for_session(scoped, "orca-1")

      assert Map.keys(remaining) == [{srv.id, "orca-2"}]
      assert_received {:req, "DELETE", "upstream-a.test", _, "scoped-1"}
      refute_received {:req, "DELETE", _, _, "scoped-2"}
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
