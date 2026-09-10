defmodule OrcaHub.MemoryClientTest do
  # async: false — tests set the global :memory_service_url/:memory_service_token/
  # :memory_service_req_options app env (see config/test.exs, which disables the
  # feature by default).
  use ExUnit.Case, async: false

  alias OrcaHub.MemoryClient

  @stub OrcaHub.MemoryClientStub

  setup do
    Application.put_env(:orca_hub, :memory_service_url, "https://memory.example.com")
    Application.put_env(:orca_hub, :memory_service_token, "test-token")
    Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.put_env(:orca_hub, :memory_service_url, nil)
      Application.put_env(:orca_hub, :memory_service_token, nil)
      Application.delete_env(:orca_hub, :memory_service_req_options)
    end)

    :ok
  end

  describe "enabled?/0" do
    test "true when url and token are both set" do
      assert MemoryClient.enabled?()
    end

    test "false when url is missing" do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      refute MemoryClient.enabled?()
    end

    test "false when token is missing" do
      Application.put_env(:orca_hub, :memory_service_token, nil)
      refute MemoryClient.enabled?()
    end
  end

  describe "disabled behavior" do
    setup do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      :ok
    end

    test "every write/read function returns {:error, :disabled} without an HTTP call" do
      assert {:error, :disabled} = MemoryClient.remember(%{"text" => "x", "kind" => "fact"})
      assert {:error, :disabled} = MemoryClient.search(%{"query" => "x"})
      assert {:error, :disabled} = MemoryClient.get("id-1")
      assert {:error, :disabled} = MemoryClient.update("id-1", %{"text" => "y"})
      assert {:error, :disabled} = MemoryClient.retire("id-1", "stale")
      assert {:error, :disabled} = MemoryClient.verify("id-1")
      assert {:error, :disabled} = MemoryClient.merge(["a", "b"], %{"text" => "z"})
      assert {:error, :disabled} = MemoryClient.list(%{})
    end

    test "context_block/3 returns {:ok, nil} instead of an error" do
      assert {:ok, nil} = MemoryClient.context_block("proj-slug", "prompt")
    end
  end

  describe "remember/1" do
    test "POSTs the document and returns the memory + near_duplicates" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/memories"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["text"] == "always use bin/test"
        assert body["kind"] == "procedure"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "memory" => %{"id" => "mem-1", "text" => body["text"]},
          "near_duplicates" => []
        })
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-1"}, "near_duplicates" => []}} =
               MemoryClient.remember(%{"text" => "always use bin/test", "kind" => "procedure"})
    end

    test "surfaces a non-2xx as an error tuple" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => %{"code" => "invalid"}})
      end)

      assert {:error, {:http_error, 422, %{"error" => %{"code" => "invalid"}}}} =
               MemoryClient.remember(%{"text" => "", "kind" => "fact"})
    end
  end

  describe "search/1" do
    test "POSTs to /v1/memories/search and returns hits" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/search"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["query"] == "postgres provisioning"

        Req.Test.json(conn, %{"hits" => [%{"memory" => %{"id" => "mem-2"}, "score" => 0.9}]})
      end)

      assert {:ok, %{"hits" => [%{"memory" => %{"id" => "mem-2"}}]}} =
               MemoryClient.search(%{"query" => "postgres provisioning"})
    end
  end

  describe "get/1" do
    test "GETs /v1/memories/:id" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories/mem-3"
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-3"}})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-3"}}} = MemoryClient.get("mem-3")
    end
  end

  describe "update/2" do
    test "PATCHes /v1/memories/:id with the given fields" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v1/memories/mem-4"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"importance" => 5}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-4", "importance" => 5}})
      end)

      assert {:ok, %{"memory" => %{"importance" => 5}}} =
               MemoryClient.update("mem-4", %{"importance" => 5})
    end
  end

  describe "retire/3" do
    test "POSTs reason, omitting superseded_by when absent" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-5/retire"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"reason" => "no longer true"}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-5", "status" => "retired"}})
      end)

      assert {:ok, _} = MemoryClient.retire("mem-5", "no longer true")
    end

    test "includes superseded_by when given" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"reason" => "merged", "superseded_by" => "mem-6"}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-5", "status" => "retired"}})
      end)

      assert {:ok, _} = MemoryClient.retire("mem-5", "merged", superseded_by: "mem-6")
    end
  end

  describe "verify/1" do
    test "POSTs /v1/memories/:id/verify" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-7/verify"
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-7"}})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-7"}}} = MemoryClient.verify("mem-7")
    end
  end

  describe "merge/2" do
    test "POSTs source_ids merged with the given attrs" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/merge"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "source_ids" => ["a", "b"],
                 "text" => "combined",
                 "kind" => "fact"
               }

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-8"}, "supersedes" => ["a", "b"]})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-8"}}} =
               MemoryClient.merge(["a", "b"], %{"text" => "combined", "kind" => "fact"})
    end
  end

  describe "list/1" do
    test "GETs /v1/memories with query params" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories"
        assert conn.query_params["kind"] == "decision"

        Req.Test.json(conn, %{"memories" => []})
      end)

      assert {:ok, %{"memories" => []}} = MemoryClient.list(%{"kind" => "decision"})
    end
  end

  describe "tags/1" do
    test "GETs /v1/tags with query params" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/tags"
        assert conn.query_params["project_slug"] == "-home-zach-orca-hub"

        Req.Test.json(conn, [%{"tag" => "trunk-based-dev", "count" => 4}])
      end)

      assert {:ok, [%{"tag" => "trunk-based-dev", "count" => 4}]} =
               MemoryClient.tags(%{"project_slug" => "-home-zach-orca-hub"})
    end

    test "a 404 (the service may not implement this endpoint yet) comes back as an ordinary error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, {:http_error, 404, _body}} = MemoryClient.tags(%{"project_slug" => "x"})
    end
  end

  describe "context_block/3" do
    test "returns the rendered block on success" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/context"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["project_slug"] == "-home-zach-orca-hub"
        assert body["budget_tokens"] == 3000

        Req.Test.json(conn, %{
          "block" => "# Recalled memories\n- [fact] ...",
          "memory_ids" => ["mem-9"],
          "pinned_count" => 0,
          "recalled_count" => 1
        })
      end)

      assert {:ok, "# Recalled memories\n- [fact] ..."} =
               MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "collapses an HTTP error into {:ok, nil} rather than blocking a spawn" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:ok, nil} = MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "collapses a transport failure into {:ok, nil}" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, nil} = MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "passes through opts for budget/include flags" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["budget_tokens"] == 500
        assert body["include_global"] == false

        Req.Test.json(conn, %{"block" => "x"})
      end)

      assert {:ok, "x"} =
               MemoryClient.context_block("slug", "prompt",
                 budget_tokens: 500,
                 include_global: false
               )
    end
  end

  describe "context/3" do
    test "returns the full response — block, memory_ids, pinned_count, recalled_count" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/context"

        Req.Test.json(conn, %{
          "block" => "# Recalled memories\n- [fact] ...",
          "memory_ids" => ["mem-9", "mem-10"],
          "pinned_count" => 1,
          "recalled_count" => 1
        })
      end)

      assert {:ok,
              %{
                "block" => "# Recalled memories\n- [fact] ...",
                "memory_ids" => ["mem-9", "mem-10"],
                "pinned_count" => 1,
                "recalled_count" => 1
              }} = MemoryClient.context("-home-zach-orca-hub", "some prompt")
    end

    test "defaults memory_ids to [] when the service response omits it" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"block" => "- a fact", "pinned_count" => 0, "recalled_count" => 1})
      end)

      assert {:ok, %{"memory_ids" => []}} = MemoryClient.context("slug", "prompt")
    end

    test "collapses an HTTP error into {:ok, nil} rather than blocking a spawn" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:ok, nil} = MemoryClient.context("-home-zach-orca-hub", "some prompt")
    end

    test "returns {:ok, nil} when the service is disabled, no HTTP call" do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      assert {:ok, nil} = MemoryClient.context("slug", "prompt")
    end
  end
end
