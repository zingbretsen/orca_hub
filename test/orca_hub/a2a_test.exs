defmodule OrcaHub.A2ATest do
  use ExUnit.Case, async: true

  alias OrcaHub.A2A
  alias OrcaHub.A2A.Server

  @stub OrcaHub.A2ATest.Stub

  defp server(test_name) do
    %Server{
      base_url: "http://a2a.test",
      token: "test-token",
      req_options: [plug: {Req.Test, {@stub, test_name}}]
    }
  end

  defp stub(test_name, fun) do
    Req.Test.stub({@stub, test_name}, fun)
  end

  describe "list_agents/1" do
    test "returns the agents list, unwrapping the \"agents\" envelope", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/a2a/agents"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        Req.Test.json(conn, %{
          "agents" => [%{"id" => "1", "name" => "Todos", "specialty" => "todos"}]
        })
      end)

      assert {:ok, [%{"id" => "1", "name" => "Todos"}]} = A2A.list_agents(server)
    end

    test "surfaces a non-2xx response as an http_error", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, {:http_error, 401, %{"error" => "unauthorized"}}} = A2A.list_agents(server)
    end
  end

  describe "send_message/4" do
    test "posts a message/send JSON-RPC request and returns the task result", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert conn.request_path == "/a2a/agents/agent-1"
        assert body["jsonrpc"] == "2.0"
        assert body["method"] == "message/send"
        assert %{"message" => message} = body["params"]
        assert message["role"] == "user"
        assert [%{"kind" => "text", "text" => "hello"}] = message["parts"]
        refute Map.has_key?(message, "contextId")
        assert is_binary(message["messageId"])

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{
            "id" => "task-1",
            "contextId" => "task-1",
            "kind" => "task",
            "status" => %{"state" => "submitted"}
          }
        })
      end)

      assert {:ok, %{"id" => "task-1", "status" => %{"state" => "submitted"}}} =
               A2A.send_message(server, "agent-1", "hello")
    end

    test "carries context_id onto the message to continue a conversation", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        message = body["params"]["message"]

        assert message["contextId"] == "prior-task-id"

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{
            "id" => "prior-task-id",
            "contextId" => "prior-task-id",
            "status" => %{"state" => "completed"}
          }
        })
      end)

      assert {:ok, %{"id" => "prior-task-id"}} =
               A2A.send_message(server, "agent-1", "follow up", context_id: "prior-task-id")
    end

    test "surfaces a JSON-RPC error envelope as {:error, {:rpc_error, _}}", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32602, "message" => "Invalid params"}
        })
      end)

      assert {:error, {:rpc_error, %{"code" => -32602, "message" => "Invalid params"}}} =
               A2A.send_message(server, "agent-1", "hello")
    end
  end

  describe "get_task/3 and cancel_task/3" do
    test "get_task posts tasks/get with the task id", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["method"] == "tasks/get"
        assert body["params"] == %{"id" => "task-1"}

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{"id" => "task-1", "status" => %{"state" => "working"}}
        })
      end)

      assert {:ok, %{"status" => %{"state" => "working"}}} =
               A2A.get_task(server, "agent-1", "task-1")
    end

    test "cancel_task posts tasks/cancel", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["method"] == "tasks/cancel"

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{"id" => "task-1", "status" => %{"state" => "canceled"}}
        })
      end)

      assert {:ok, %{"status" => %{"state" => "canceled"}}} =
               A2A.cancel_task(server, "agent-1", "task-1")
    end
  end

  describe "wait_for_result/4" do
    test "returns immediately once the task is already terminal", %{test: t} do
      server = server(t)

      stub(t, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"id" => "task-1", "status" => %{"state" => "completed"}}
        })
      end)

      assert {:ok, %{"status" => %{"state" => "completed"}}} =
               A2A.wait_for_result(server, "agent-1", "task-1", poll_interval_ms: 5)
    end

    test "polls through non-terminal states until completion", %{test: t} do
      server = server(t)
      agent = Agent.start_link(fn -> ["submitted", "working", "completed"] end) |> elem(1)

      stub(t, fn conn ->
        state =
          Agent.get_and_update(agent, fn [h | rest] ->
            {h, if(rest == [], do: [h], else: rest)}
          end)

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"id" => "task-1", "status" => %{"state" => state}}
        })
      end)

      assert {:ok, %{"status" => %{"state" => "completed"}}} =
               A2A.wait_for_result(server, "agent-1", "task-1", poll_interval_ms: 5)
    end

    test "returns {:error, :timeout} if the task never reaches a terminal state in time", %{
      test: t
    } do
      server = server(t)

      stub(t, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{"id" => "task-1", "status" => %{"state" => "working"}}
        })
      end)

      assert {:error, :timeout} =
               A2A.wait_for_result(server, "agent-1", "task-1",
                 timeout_ms: 20,
                 poll_interval_ms: 5
               )
    end
  end

  describe "reply_text/1" do
    test "joins text parts from a terminal task's status message" do
      task = %{
        "status" => %{
          "message" => %{"parts" => [%{"kind" => "text", "text" => "hi"}]}
        }
      }

      assert A2A.reply_text(task) == "hi"
    end

    test "returns nil when there is no status message" do
      assert A2A.reply_text(%{"status" => %{"state" => "working"}}) == nil
    end

    test "returns nil when parts contain no text kind" do
      task = %{"status" => %{"message" => %{"parts" => [%{"kind" => "file"}]}}}
      assert A2A.reply_text(task) == nil
    end
  end

  describe "terminal_state?/1" do
    test "true for completed/failed/canceled/rejected" do
      assert A2A.terminal_state?("completed")
      assert A2A.terminal_state?("failed")
      assert A2A.terminal_state?("canceled")
      assert A2A.terminal_state?("rejected")
    end

    test "false for submitted/working/input-required" do
      refute A2A.terminal_state?("submitted")
      refute A2A.terminal_state?("working")
      refute A2A.terminal_state?("input-required")
    end
  end
end
