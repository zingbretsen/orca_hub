defmodule OrcaHub.MemoryClientSessionMessagesTest do
  use ExUnit.Case, async: false

  alias OrcaHub.MemoryClient

  @stub OrcaHub.MemoryClientSessionMessagesStub

  setup do
    Application.put_env(:orca_hub, :memory_service_url, "https://memory.example.com/")
    Application.put_env(:orca_hub, :memory_service_token, "test-token")
    Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.put_env(:orca_hub, :memory_service_url, nil)
      Application.put_env(:orca_hub, :memory_service_token, nil)
      Application.delete_env(:orca_hub, :memory_service_req_options)
    end)

    :ok
  end

  test "index_session_messages/1 POSTs {docs: ...} with the bearer token" do
    docs = [%{"id" => "m1", "group_id" => "s1", "text" => "hi", "fields" => %{"role" => "user"}}]

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert conn.method == "POST"
      assert conn.request_path == "/v1/collections/session-messages/docs"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert Jason.decode!(raw) == %{"docs" => docs}
      Req.Test.json(conn, %{"indexed" => 1, "chunks" => 1, "embedded" => 1, "errors" => []})
    end)

    assert {:ok, %{"indexed" => 1, "errors" => []}} = MemoryClient.index_session_messages(docs)
  end

  test "search_session_messages/1 POSTs the params" do
    params = %{"query" => "deploy", "limit" => 5, "filters" => %{"role" => "user"}}

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/v1/collections/session-messages/search"
      assert Jason.decode!(raw) == params
      Req.Test.json(conn, %{"results" => [], "degraded" => nil})
    end)

    assert {:ok, %{"results" => [], "degraded" => nil}} =
             MemoryClient.search_session_messages(params)
  end

  test "delete_session_messages/1 DELETEs the group, path-encoded" do
    Req.Test.stub(@stub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/collections/session-messages/groups/abc-123"
      Req.Test.json(conn, %{"deleted" => 4})
    end)

    assert {:ok, %{"deleted" => 4}} = MemoryClient.delete_session_messages("abc-123")
  end

  test "5xx is returned as an error and NOT retried" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(@stub, fn conn ->
      Agent.update(counter, &(&1 + 1))
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
    end)

    assert {:error, {:http_error, 503, _}} = MemoryClient.index_session_messages([])
    assert {:error, {:http_error, 503, _}} = MemoryClient.search_session_messages(%{})
    assert {:error, {:http_error, 503, _}} = MemoryClient.delete_session_messages("s")
    assert Agent.get(counter, & &1) == 3
  end

  test "transport failure returns {:error, _} instead of raising" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, {:request_failed, _}} = MemoryClient.index_session_messages([])
  end

  test "disabled when unconfigured" do
    Application.put_env(:orca_hub, :memory_service_token, nil)
    assert {:error, :disabled} = MemoryClient.index_session_messages([])
    assert {:error, :disabled} = MemoryClient.search_session_messages(%{})
    assert {:error, :disabled} = MemoryClient.delete_session_messages("s")
  end
end
