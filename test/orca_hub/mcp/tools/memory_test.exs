defmodule OrcaHub.MCP.Tools.MemoryTest do
  @moduledoc """
  Coverage for the memory-service MCP tools. Uses a real session/project
  (same fixture convention as `OrcaHub.MCP.Tools.FilesTest`) and stubs the
  underlying HTTP call the same way `OrcaHub.MemoryClientTest` does —
  `async: false` since both set global `:memory_service_*` app env.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Memory, as: MemoryTool
  alias OrcaHub.{Projects, Sessions}

  @stub OrcaHub.MCP.Tools.MemoryStub

  setup do
    Application.put_env(:orca_hub, :memory_service_url, "https://memory.example.com")
    Application.put_env(:orca_hub, :memory_service_token, "test-token")
    Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.put_env(:orca_hub, :memory_service_url, nil)
      Application.put_env(:orca_hub, :memory_service_token, nil)
      Application.delete_env(:orca_hub, :memory_service_req_options)
    end)

    dir = "/tmp/mcp_memory_test_#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(%{
        name: "mcp-memory-test-#{System.unique_integer([:positive])}",
        directory: dir,
        node: Atom.to_string(node())
      })

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        backend: "claude",
        runner_node: Atom.to_string(node())
      })

    {:ok, project: project, session: session, state: %{orca_session_id: session.id}}
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: Jason.decode!(body)

  describe "list/0" do
    test "exposes exactly the seven memory tools" do
      names = MemoryTool.list() |> Enum.map(& &1["name"])

      assert names == [
               "remember",
               "recall",
               "update_memory",
               "retire_memory",
               "verify_memory",
               "merge_memories",
               "list_memories"
             ]
    end

    test "remember requires text and kind" do
      [remember | _] = MemoryTool.list()
      assert remember["inputSchema"]["required"] == ["text", "kind"]
    end
  end

  describe "with_calling_session — linked session no longer exists" do
    test "remember returns an error instead of crashing" do
      missing_id = Ecto.UUID.generate()

      result =
        MemoryTool.call(
          "remember",
          %{"text" => "x", "kind" => "fact"},
          %{orca_session_id: missing_id}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not found"
    end
  end

  describe "remember" do
    test "scopes the memory to app/project/session/backend/node and returns near_duplicates",
         %{state: state, project: project, session: session} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["text"] == "always use bin/test"
        assert body["kind"] == "procedure"
        assert body["app"] == "orcahub"
        assert body["session_id"] == session.id
        assert body["backend"] == "claude"
        assert body["node"] == Atom.to_string(node())
        assert body["created_by"] == "agent"
        assert body["project"]["id"] == project.id
        assert body["project"]["name"] == project.name
        assert body["project"]["slug"] == String.replace(project.directory, ~r/[^a-zA-Z0-9]/, "-")

        Req.Test.json(conn, %{
          "memory" => %{"id" => "mem-1", "text" => body["text"], "kind" => body["kind"]},
          "near_duplicates" => [%{"id" => "mem-old", "hook" => "similar", "score" => 0.9}]
        })
      end)

      result =
        MemoryTool.call(
          "remember",
          %{"text" => "always use bin/test", "kind" => "procedure"},
          state
        )

      assert %{"isError" => false} = result
      decoded = decode(result)
      assert decoded["memory"]["id"] == "mem-1"

      assert decoded["near_duplicates"] == [
               %{"id" => "mem-old", "hook" => "similar", "score" => 0.9}
             ]

      assert decoded["hint"] =~ "update_memory"
    end

    test "omits the hint when there are no near_duplicates", %{state: state} do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-2"}, "near_duplicates" => []})
      end)

      result = MemoryTool.call("remember", %{"text" => "a fact", "kind" => "fact"}, state)
      decoded = decode(result)
      refute Map.has_key?(decoded, "hint")
    end

    test "rejects a missing kind", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("remember", %{"text" => "a fact"}, state)

      assert msg =~ "kind is required"
    end

    test "rejects an empty text", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("remember", %{"text" => "   ", "kind" => "fact"}, state)

      assert msg =~ "text is required"
    end

    test "surfaces a disabled memory service clearly", %{state: state} do
      Application.put_env(:orca_hub, :memory_service_url, nil)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("remember", %{"text" => "a fact", "kind" => "fact"}, state)

      assert msg =~ "not configured"
    end
  end

  describe "recall" do
    test "scopes the search to the session's project slug and defaults", %{
      state: state,
      project: project
    } do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/search"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["query"] == "postgres provisioning"
        assert body["project_slug"] == String.replace(project.directory, ~r/[^a-zA-Z0-9]/, "-")
        assert body["include_global"] == true
        assert body["include_shared"] == true
        assert body["include_other_projects"] == false

        Req.Test.json(conn, %{"hits" => [%{"memory" => %{"id" => "mem-3"}, "score" => 0.8}]})
      end)

      result = MemoryTool.call("recall", %{"query" => "postgres provisioning"}, state)
      assert %{"isError" => false} = result
      assert %{"hits" => [%{"memory" => %{"id" => "mem-3"}}]} = decode(result)
    end

    test "rejects an empty query", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("recall", %{"query" => ""}, state)

      assert msg =~ "query is required"
    end
  end

  describe "update_memory" do
    test "PATCHes only the provided fields" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v1/memories/mem-4"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"importance" => 5}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-4", "importance" => 5}})
      end)

      result = MemoryTool.call("update_memory", %{"id" => "mem-4", "importance" => 5}, %{})
      assert %{"isError" => false} = result
    end

    test "rejects a missing id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("update_memory", %{"importance" => 5}, %{})

      assert msg =~ "id"
    end

    test "rejects an update with no fields besides id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("update_memory", %{"id" => "mem-4"}, %{})

      assert msg =~ "at least one field"
    end
  end

  describe "retire_memory" do
    test "POSTs reason and superseded_by" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-5/retire"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"reason" => "stale", "superseded_by" => "mem-6"}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-5", "status" => "retired"}})
      end)

      result =
        MemoryTool.call(
          "retire_memory",
          %{"id" => "mem-5", "reason" => "stale", "superseded_by" => "mem-6"},
          %{}
        )

      assert %{"isError" => false} = result
    end

    test "rejects a missing reason" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call("retire_memory", %{"id" => "mem-5"}, %{})

      assert msg =~ "reason"
    end
  end

  describe "verify_memory" do
    test "POSTs /v1/memories/:id/verify" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-7/verify"
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-7"}})
      end)

      assert %{"isError" => false} = MemoryTool.call("verify_memory", %{"id" => "mem-7"}, %{})
    end
  end

  describe "merge_memories" do
    test "POSTs source_ids with the merged attrs" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/merge"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["source_ids"] == ["a", "b"]
        assert body["text"] == "combined fact"
        assert body["kind"] == "fact"

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-8"}, "supersedes" => ["a", "b"]})
      end)

      result =
        MemoryTool.call(
          "merge_memories",
          %{"source_ids" => ["a", "b"], "text" => "combined fact", "kind" => "fact"},
          %{}
        )

      assert %{"isError" => false} = result
    end

    test "rejects an empty source_ids" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               MemoryTool.call(
                 "merge_memories",
                 %{"source_ids" => [], "text" => "x", "kind" => "fact"},
                 %{}
               )

      assert msg =~ "source_ids"
    end
  end

  describe "list_memories" do
    test "scopes the listing to the session's project slug", %{state: state, project: project} do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories"

        assert conn.query_params["project_slug"] ==
                 String.replace(project.directory, ~r/[^a-zA-Z0-9]/, "-")

        assert conn.query_params["kind"] == "decision"

        Req.Test.json(conn, %{"memories" => []})
      end)

      result = MemoryTool.call("list_memories", %{"kind" => "decision"}, state)
      assert %{"isError" => false} = result
      assert %{"memories" => []} = decode(result)
    end
  end
end
