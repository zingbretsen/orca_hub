defmodule OrcaHub.MCP.Tools.PhxAgentsTest do
  # async: false — tests set the global :phx_app_a2a_token/:phx_app_a2a_req_options app env.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.Tools.PhxAgents

  @stub OrcaHub.MCP.Tools.PhxAgentsStub

  setup do
    Application.put_env(:orca_hub, :phx_app_a2a_token, "test-token")
    Application.put_env(:orca_hub, :phx_app_a2a_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:orca_hub, :phx_app_a2a_token)
      Application.delete_env(:orca_hub, :phx_app_a2a_req_options)
    end)

    :ok
  end

  describe "list/0" do
    test "exposes phx_list_agents, phx_send_to_agent, phx_get_task" do
      assert PhxAgents.list() |> Enum.map(& &1["name"]) == [
               "phx_list_agents",
               "phx_send_to_agent",
               "phx_get_task"
             ]
    end

    test "phx_send_to_agent requires agent_id and message" do
      [_list_tool, send_tool, _get_tool] = PhxAgents.list()
      assert send_tool["inputSchema"]["required"] == ["agent_id", "message"]
    end

    test "phx_send_to_agent description mentions contextId continuation" do
      [_list_tool, send_tool, _get_tool] = PhxAgents.list()
      assert send_tool["description"] =~ "context_id"
      assert send_tool["description"] =~ "CONTINU"
    end

    test "phx_get_task requires agent_id and task_id" do
      [_list_tool, _send_tool, get_tool] = PhxAgents.list()
      assert get_tool["inputSchema"]["required"] == ["agent_id", "task_id"]
    end
  end

  describe "call/3 argument validation" do
    test "phx_send_to_agent rejects a missing agent_id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call("phx_send_to_agent", %{"message" => "hi"}, %{})

      assert msg =~ "agent_id"
    end

    test "phx_send_to_agent rejects a missing message" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call("phx_send_to_agent", %{"agent_id" => "1"}, %{})

      assert msg =~ "message"
    end

    test "phx_get_task rejects a missing task_id" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call("phx_get_task", %{"agent_id" => "1"}, %{})

      assert msg =~ "task_id"
    end
  end

  describe "call/3 without a configured token" do
    test "phx_list_agents fails clearly" do
      Application.delete_env(:orca_hub, :phx_app_a2a_token)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call("phx_list_agents", %{}, %{})

      assert msg =~ "PHX_APP_A2A_TOKEN"
    end
  end

  describe "call/3 phx_list_agents against the API" do
    test "returns agents, filtered client-side by query" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/a2a/agents"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        Req.Test.json(conn, %{
          "agents" => [
            %{
              "id" => "1",
              "name" => "Todos",
              "description" => "Manages todos",
              "specialty" => "todos"
            },
            %{
              "id" => "2",
              "name" => "Chores",
              "description" => "Manages chores",
              "specialty" => "chores"
            }
          ]
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               PhxAgents.call("phx_list_agents", %{"query" => "chore"}, %{})

      assert [%{"id" => "2", "name" => "Chores"}] = Jason.decode!(text)
    end

    test "surfaces an HTTP error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call("phx_list_agents", %{}, %{})

      assert msg =~ "500"
    end
  end

  describe "call/3 phx_send_to_agent, wait: true (default)" do
    test "sends the message and polls tasks/get until terminal" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        case body["method"] do
          "message/send" ->
            assert body["params"]["message"]["parts"] == [%{"kind" => "text", "text" => "hi"}]
            refute Map.has_key?(body["params"]["message"], "contextId")

            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{
                "id" => "task-1",
                "contextId" => "task-1",
                "status" => %{"state" => "submitted"}
              }
            })

          "tasks/get" ->
            assert body["params"] == %{"id" => "task-1"}

            Req.Test.json(conn, %{
              "jsonrpc" => "2.0",
              "id" => body["id"],
              "result" => %{
                "id" => "task-1",
                "contextId" => "task-1",
                "status" => %{
                  "state" => "completed",
                  "message" => %{"parts" => [%{"kind" => "text", "text" => "done!"}]}
                }
              }
            })
        end
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               PhxAgents.call(
                 "phx_send_to_agent",
                 %{"agent_id" => "agent-1", "message" => "hi", "timeout" => 5},
                 %{}
               )

      decoded = Jason.decode!(text)
      assert decoded["state"] == "completed"
      assert decoded["reply_text"] == "done!"
      assert decoded["task_id"] == "task-1"
      assert decoded["context_id"] == "task-1"
    end

    test "carries context_id through to continue a conversation" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        if body["method"] == "message/send" do
          assert body["params"]["message"]["contextId"] == "prior-task"
        end

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{
            "id" => "prior-task",
            "contextId" => "prior-task",
            "status" => %{
              "state" => "completed",
              "message" => %{"parts" => [%{"kind" => "text", "text" => "ok"}]}
            }
          }
        })
      end)

      assert %{"isError" => false} =
               PhxAgents.call(
                 "phx_send_to_agent",
                 %{
                   "agent_id" => "agent-1",
                   "message" => "follow up",
                   "context_id" => "prior-task",
                   "timeout" => 5
                 },
                 %{}
               )
    end

    test "returns a timeout error if the task never reaches a terminal state" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        result =
          case body["method"] do
            "message/send" ->
              %{"id" => "task-1", "contextId" => "task-1", "status" => %{"state" => "submitted"}}

            "tasks/get" ->
              %{"id" => "task-1", "contextId" => "task-1", "status" => %{"state" => "working"}}
          end

        Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})
      end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call(
                 "phx_send_to_agent",
                 %{"agent_id" => "agent-1", "message" => "hi", "timeout" => 1},
                 %{}
               )

      assert msg =~ "Timed out"
      assert msg =~ "task-1"
    end

    test "surfaces a JSON-RPC error envelope" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32602, "message" => "Invalid params"}
        })
      end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               PhxAgents.call(
                 "phx_send_to_agent",
                 %{"agent_id" => "agent-1", "message" => "hi"},
                 %{}
               )

      assert msg =~ "-32602"
      assert msg =~ "Invalid params"
    end
  end

  describe "call/3 phx_send_to_agent, wait: false" do
    test "returns the task id immediately without polling" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["method"] == "message/send"

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{
            "id" => "task-1",
            "contextId" => "task-1",
            "status" => %{"state" => "submitted"}
          }
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               PhxAgents.call(
                 "phx_send_to_agent",
                 %{"agent_id" => "agent-1", "message" => "hi", "wait" => false},
                 %{}
               )

      decoded = Jason.decode!(text)
      assert decoded["state"] == "submitted"
      assert decoded["task_id"] == "task-1"
      assert decoded["reply_text"] == nil
    end
  end

  describe "call/3 phx_get_task" do
    test "returns the current state and reply text once terminal" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["method"] == "tasks/get"
        assert body["params"] == %{"id" => "task-1"}

        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => body["id"],
          "result" => %{
            "id" => "task-1",
            "contextId" => "task-1",
            "status" => %{
              "state" => "completed",
              "message" => %{"parts" => [%{"kind" => "text", "text" => "the answer"}]}
            }
          }
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               PhxAgents.call(
                 "phx_get_task",
                 %{"agent_id" => "agent-1", "task_id" => "task-1"},
                 %{}
               )

      decoded = Jason.decode!(text)
      assert decoded["state"] == "completed"
      assert decoded["reply_text"] == "the answer"
    end

    test "returns non-terminal state with nil reply text" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{
            "id" => "task-1",
            "contextId" => "task-1",
            "status" => %{"state" => "working"}
          }
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               PhxAgents.call(
                 "phx_get_task",
                 %{"agent_id" => "agent-1", "task_id" => "task-1"},
                 %{}
               )

      decoded = Jason.decode!(text)
      assert decoded["state"] == "working"
      assert decoded["reply_text"] == nil
    end
  end
end
