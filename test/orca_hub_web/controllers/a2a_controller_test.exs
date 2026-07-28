defmodule OrcaHubWeb.A2AControllerTest do
  # async: false — the message/send tests start a real SessionRunner
  # (GenStatem) child under the shared OrcaHub.SessionSupervisor, which needs
  # the DB sandbox in SHARED mode (see ApiRunControllerTest for the same
  # pattern/rationale).
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{A2ATasks, ClusterNodes, Projects, SessionSupervisor, Sessions}
  alias OrcaHub.MCP.ToolCallHolder.A2ATaskHolder

  @claude_stub Path.expand("../../support/fixtures/claude_stub_noop.sh", __DIR__)
  @token "test-a2a-token"
  @local_name Atom.to_string(node())

  setup do
    Application.put_env(:orca_hub, :api_token, @token)
    on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp insert_assistant_message(session, text) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })

    :ok
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id),
      do: SessionSupervisor.stop_session(session_id)
  end

  # Mirrors NodePolicyTest's pattern: the local node already has a `nodes`
  # row from hub boot (ClusterNodeTracker), so restore its previous
  # default_backend on exit rather than leaving a non-claude default behind
  # for the shared dev DB other tests run against.
  defp with_local_default_backend(backend, fun) do
    node_row = ClusterNodes.get_by_name(@local_name) || insert_local_row()
    previous_default_backend = node_row.default_backend

    {:ok, _} = ClusterNodes.update_node(node_row, %{default_backend: backend})

    on_exit(fn ->
      if row = ClusterNodes.get_by_name(@local_name) do
        ClusterNodes.update_node(row, %{default_backend: previous_default_backend})
      end
    end)

    fun.()
  end

  defp insert_local_row do
    {:ok, node_row} = ClusterNodes.upsert_seen(@local_name, @local_name)
    node_row
  end

  defp rpc_post(conn, agent_id, method, params, rpc_id \\ 1) do
    conn
    |> authed()
    |> post(~p"/a2a/agents/#{agent_id}", %{
      "jsonrpc" => "2.0",
      "id" => rpc_id,
      "method" => method,
      "params" => params
    })
  end

  defp text_message(text), do: %{"parts" => [%{"kind" => "text", "text" => text}]}

  defp create_project(name \\ "A2A Test") do
    dir = Path.join(System.tmp_dir!(), "a2a_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "#{name} #{System.unique_integer()}", directory: dir})

    project
  end

  # ---------------------------------------------------------------------
  # v2 (docs/a2a.md "v2: client tools + structured results") shared fixtures
  # ---------------------------------------------------------------------

  @weather_tool %{
    "name" => "get_weather",
    "description" => "Look up the current weather for a city.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  }

  @answer_schema %{
    "type" => "object",
    "properties" => %{"summary" => %{"type" => "string"}},
    "required" => ["summary"]
  }

  defp data_answer_message(task_id, tool_call_id, answer_fields, extra \\ %{}) do
    %{
      "messageId" => Ecto.UUID.generate(),
      "role" => "user",
      "taskId" => task_id,
      "parts" => [
        %{"kind" => "data", "data" => Map.merge(%{"tool_call_id" => tool_call_id}, answer_fields)}
      ]
    }
    |> Map.merge(extra)
  end

  defp wait_for_pending(task_id, attempts \\ 100) do
    case A2ATasks.get_task(task_id).pending_tool_call do
      nil when attempts > 0 ->
        Process.sleep(5)
        wait_for_pending(task_id, attempts - 1)

      pending ->
        pending
    end
  end

  # See OrcaHub.MCP.Server's resolve_parked/3: it replies to the parked
  # caller BEFORE persisting the DB-side clear, so `Task.await/1` returning
  # doesn't guarantee the write has landed yet.
  defp wait_until(fun, attempts \\ 100) do
    case fun.() do
      truthy when truthy not in [nil, false] ->
        truthy

      _falsy when attempts > 0 ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)

      falsy ->
        falsy
    end
  end

  describe "auth" do
    test "401 with no Authorization header", %{conn: conn} do
      conn = get(conn, ~p"/a2a/agents")
      assert json_response(conn, 401)
    end

    test "401 with a mismatched token", %{conn: conn} do
      conn =
        conn |> put_req_header("authorization", "Bearer wrong-token") |> get(~p"/a2a/agents")

      assert json_response(conn, 401)
    end
  end

  describe "GET /a2a/agents" do
    test "lists non-deleted projects as agents", %{conn: conn} do
      project = create_project()

      {:ok, deleted} = Projects.create_project(%{name: "Deleted", directory: "/tmp/a2a-deleted"})
      {:ok, _} = Projects.delete_project(deleted)

      conn = conn |> authed() |> get(~p"/a2a/agents")
      body = json_response(conn, 200)

      ids = Enum.map(body["agents"], & &1["id"])
      assert project.id in ids
      refute deleted.id in ids

      entry = Enum.find(body["agents"], &(&1["id"] == project.id))
      assert entry["name"] == project.name
      assert entry["description"] == project.directory
    end
  end

  describe "GET /a2a/agents/:id/.well-known/agent-card.json" do
    test "returns an A2A agent card for the project", %{conn: conn} do
      project = create_project()

      conn = conn |> authed() |> get(~p"/a2a/agents/#{project.id}/.well-known/agent-card.json")
      body = json_response(conn, 200)

      assert body["name"] == project.name
      assert body["protocolVersion"] == "0.3.0"
      assert body["url"] =~ "/a2a/agents/#{project.id}"
      assert body["capabilities"] == %{"streaming" => false, "pushNotifications" => false}
      assert body["defaultInputModes"] == ["text/plain"]
      assert body["defaultOutputModes"] == ["text/plain"]
      assert [%{"id" => _, "name" => _, "description" => _}] = body["skills"]
    end

    test "404 for an unknown project", %{conn: conn} do
      conn =
        conn
        |> authed()
        |> get(~p"/a2a/agents/#{Ecto.UUID.generate()}/.well-known/agent-card.json")

      assert json_response(conn, 404)
    end

    test "404 for a malformed id", %{conn: conn} do
      conn = conn |> authed() |> get(~p"/a2a/agents/not-a-uuid/.well-known/agent-card.json")
      assert json_response(conn, 404)
    end
  end

  describe "POST /a2a/agents/:agent_id envelope validation" do
    test "-32600 when jsonrpc isn't \"2.0\"", %{conn: conn} do
      project = create_project()

      conn =
        conn
        |> authed()
        |> post(~p"/a2a/agents/#{project.id}", %{
          "id" => 1,
          "method" => "tasks/get",
          "params" => %{}
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32600
    end

    test "-32601 for an unknown method", %{conn: conn} do
      project = create_project()
      conn = rpc_post(conn, project.id, "totally/bogus", %{})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32601
    end

    test "404 for an unknown agent id", %{conn: conn} do
      conn = rpc_post(conn, Ecto.UUID.generate(), "tasks/get", %{"id" => "x"})
      assert json_response(conn, 404)
    end
  end

  describe "POST /a2a/agents/:agent_id unsupported methods" do
    test "-32004 for message/stream, tasks/resubscribe, tasks/list", %{conn: conn} do
      project = create_project()

      for method <- ~w(message/stream tasks/resubscribe tasks/list) do
        conn = rpc_post(conn, project.id, method, %{})
        body = json_response(conn, 200)
        assert body["error"]["code"] == -32004, "expected -32004 for #{method}"
      end
    end

    test "-32003 for tasks/pushNotificationConfig/*", %{conn: conn} do
      project = create_project()

      for method <- ~w(tasks/pushNotificationConfig/set tasks/pushNotificationConfig/get) do
        conn = rpc_post(conn, project.id, method, %{})
        body = json_response(conn, 200)
        assert body["error"]["code"] == -32003, "expected -32003 for #{method}"
      end
    end
  end

  describe "message/send — new session" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)
      %{project: create_project()}
    end

    test "creates a new session + task, returns a submitted/working task", %{
      conn: conn,
      project: project
    } do
      conn = rpc_post(conn, project.id, "message/send", %{"message" => text_message("say hi")})
      body = json_response(conn, 200)

      task = body["result"]
      assert task["kind"] == "task"
      assert task["status"]["state"] in ["submitted", "working"]
      assert is_binary(task["id"])
      assert is_binary(task["contextId"])

      session = Sessions.get_session!(task["contextId"])
      assert session.project_id == project.id
      assert session.directory == project.directory
      assert session.triggered == true
      assert session.title == "say hi"

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "-32602 when the message has no text parts", %{conn: conn, project: project} do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => %{"parts" => [%{"kind" => "file"}]}
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "-32602 when params.message is missing", %{conn: conn, project: project} do
      conn = rpc_post(conn, project.id, "message/send", %{})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    # v2 (docs/a2a.md "Tool-call loop") narrows v1's blanket -32602 on
    # message.taskId — it's now how a caller answers a parked client-tool
    # call. A taskId that doesn't resolve to any real task is -32001 (task
    # not found), not -32602 — see the "v2 tool-call answers" describe block
    # below for the full taskId-bearing-send matrix.
    test "-32001 when message.taskId doesn't match any task (text part, no data part)", %{
      conn: conn,
      project: project
    } do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => Map.put(text_message("hi"), "taskId", "some-prior-task")
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end

    test "metadata.no_tools: true creates the session with an empty tool allow-list", %{
      conn: conn,
      project: project
    } do
      message = Map.put(text_message("say hi"), "metadata", %{"no_tools" => true})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)

      task = body["result"]
      session = Sessions.get_session!(task["contextId"])
      assert session.tools == ""

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "no metadata leaves tools unset (nil)", %{conn: conn, project: project} do
      conn = rpc_post(conn, project.id, "message/send", %{"message" => text_message("say hi")})
      body = json_response(conn, 200)

      task = body["result"]
      session = Sessions.get_session!(task["contextId"])
      assert session.tools == nil

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "metadata.no_tools: false leaves tools unset (nil)", %{conn: conn, project: project} do
      message = Map.put(text_message("say hi"), "metadata", %{"no_tools" => false})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)

      task = body["result"]
      session = Sessions.get_session!(task["contextId"])
      assert session.tools == nil

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "unknown metadata keys are ignored", %{conn: conn, project: project} do
      message = Map.put(text_message("say hi"), "metadata", %{"some_other_key" => "value"})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)

      task = body["result"]
      assert task["kind"] == "task"

      session = Sessions.get_session!(task["contextId"])
      assert session.tools == nil

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "-32602 when no_tools is requested but the node defaults to a non-claude backend", %{
      conn: conn,
      project: project
    } do
      with_local_default_backend("codex", fn ->
        message = Map.put(text_message("say hi"), "metadata", %{"no_tools" => true})
        conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
        body = json_response(conn, 200)

        assert body["error"]["code"] == -32602
        assert body["error"]["message"] =~ "claude"
      end)
    end
  end

  describe "message/send — continuation (contextId)" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "idle",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)

      %{project: project, session: session}
    end

    test "delivers into the existing session instead of creating a new one", %{
      conn: conn,
      project: project,
      session: session
    } do
      before_count = Sessions.count_messages(session.id)

      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => Map.put(text_message("continue please"), "contextId", session.id)
        })

      body = json_response(conn, 200)
      task = body["result"]
      assert task["contextId"] == session.id

      fetched = A2ATasks.get_task(task["id"])
      assert fetched.session_id == session.id
      assert fetched.baseline_message_count == before_count

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.status == "running"
    end

    test "metadata.no_tools is ignored on a continuation — the session's tool surface is already baked in",
         %{conn: conn, project: project, session: session} do
      refute session.tools == ""

      message =
        text_message("continue please")
        |> Map.put("contextId", session.id)
        |> Map.put("metadata", %{"no_tools" => true})

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["result"]["contextId"] == session.id

      reloaded = Sessions.get_session!(session.id)
      assert reloaded.tools == session.tools
    end

    test "-32001 when contextId belongs to a session in a DIFFERENT project", %{
      conn: conn,
      session: session
    } do
      other_project = create_project("Other")

      conn =
        rpc_post(conn, other_project.id, "message/send", %{
          "message" => Map.put(text_message("hi"), "contextId", session.id)
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end

    test "-32001 when contextId doesn't match any session", %{conn: conn, project: project} do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => Map.put(text_message("hi"), "contextId", Ecto.UUID.generate())
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end
  end

  describe "tasks/get lifecycle" do
    setup do
      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{directory: project.directory, project_id: project.id})

      %{project: project, session: session}
    end

    test "working while the session is running, completed with reply text once idle", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, session} = Sessions.update_session(session, %{status: "running"})
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id})

      conn1 = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body1 = json_response(conn1, 200)
      assert body1["result"]["status"]["state"] == "working"
      refute Map.has_key?(body1["result"]["status"], "message")

      insert_assistant_message(session, "final reply")
      {:ok, _} = Sessions.update_session(session, %{status: "idle"})

      conn2 = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body2 = json_response(conn2, 200)
      assert body2["result"]["status"]["state"] == "completed"

      assert body2["result"]["status"]["message"]["parts"] == [
               %{"kind" => "text", "text" => "final reply"}
             ]
    end

    test "stale-reply guard on a continuation task: stays working until a NEW message lands", %{
      conn: conn,
      project: project,
      session: session
    } do
      insert_assistant_message(session, "old reply from a previous turn")
      baseline = Sessions.count_messages(session.id)
      {:ok, session} = Sessions.update_session(session, %{status: "idle"})

      {:ok, task} =
        A2ATasks.create_task(%{session_id: session.id, baseline_message_count: baseline})

      conn1 = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body1 = json_response(conn1, 200)
      assert body1["result"]["status"]["state"] == "working"

      insert_assistant_message(session, "new reply for this task")

      conn2 = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body2 = json_response(conn2, 200)
      assert body2["result"]["status"]["state"] == "completed"

      assert body2["result"]["status"]["message"]["parts"] == [
               %{"kind" => "text", "text" => "new reply for this task"}
             ]
    end

    test "-32001 for an unknown task id", %{conn: conn, project: project} do
      conn = rpc_post(conn, project.id, "tasks/get", %{"id" => Ecto.UUID.generate()})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end

    test "-32001 for a malformed task id", %{conn: conn, project: project} do
      conn = rpc_post(conn, project.id, "tasks/get", %{"id" => "not-a-uuid"})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end
  end

  describe "tasks/cancel" do
    setup do
      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{directory: project.directory, project_id: project.id})

      %{project: project, session: session}
    end

    test "cancels a non-terminal task", %{conn: conn, project: project, session: session} do
      {:ok, task} = A2ATasks.create_task(%{session_id: session.id, status: "working"})

      conn = rpc_post(conn, project.id, "tasks/cancel", %{"id" => task.id})
      body = json_response(conn, 200)
      assert body["result"]["status"]["state"] == "canceled"

      assert A2ATasks.get_task(task.id).status == "canceled"
    end

    test "-32002 when the task is already terminal", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, task} =
        A2ATasks.create_task(%{session_id: session.id, status: "completed", result_text: "done"})

      conn = rpc_post(conn, project.id, "tasks/cancel", %{"id" => task.id})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32002

      assert A2ATasks.get_task(task.id).status == "completed"
    end

    test "-32001 for an unknown task id", %{conn: conn, project: project} do
      conn = rpc_post(conn, project.id, "tasks/cancel", %{"id" => Ecto.UUID.generate()})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32001
    end
  end

  # Wire-compatibility proof: OrcaHub.A2A (docs/a2a.md's referenced outbound
  # client) drives THIS controller end-to-end via Req's :plug adapter,
  # in-process — no real HTTP socket, same technique Phoenix.ConnTest uses.
  describe "symmetry: the OrcaHub.A2A client can drive this controller end-to-end" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)
      %{project: create_project()}
    end

    defp a2a_server do
      %OrcaHub.A2A.Server{
        base_url: "http://a2a.test",
        token: @token,
        req_options: [plug: OrcaHubWeb.Endpoint]
      }
    end

    test "list_agents, get_agent_card, send_message, get_task, reply_text", %{
      conn: _conn,
      project: project
    } do
      server = a2a_server()

      assert {:ok, agents} = OrcaHub.A2A.list_agents(server)
      assert Enum.any?(agents, &(&1["id"] == project.id))

      assert {:ok, card} = OrcaHub.A2A.get_agent_card(server, project.id)
      assert card["protocolVersion"] == "0.3.0"

      assert {:ok, task} = OrcaHub.A2A.send_message(server, project.id, "say hi via a2a client")
      assert task["kind"] == "task"
      assert task["status"]["state"] in ["submitted", "working"]

      session_id = task["contextId"]
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      insert_assistant_message(session, "hello back")
      {:ok, _} = Sessions.update_session(session, %{status: "idle"})

      assert {:ok, fetched} = OrcaHub.A2A.get_task(server, project.id, task["id"])
      assert fetched["id"] == task["id"]
      assert fetched["status"]["state"] == "completed"
      assert OrcaHub.A2A.reply_text(fetched) == "hello back"
      assert OrcaHub.A2A.terminal_state?(fetched["status"]["state"])
    end

    # v2 full loop (docs/a2a.md "v2: client tools + structured results"),
    # driven entirely through the OrcaHub.A2A client — plus the triple combo
    # metadata.no_tools composes independently with client_tools/result_schema
    # (same posture as the Agent Runs API's identical no_tools + client_tools
    # combo, docs/api.md): the built-in tool surface is emptied while the
    # synthesized submit_result/client-tools MCP surface stays fully wired up.
    test "v2: declare (no_tools + client_tools + result_schema) -> input-required -> " <>
           "answer via taskId -> submit_result -> completed with validated result",
         %{project: project} do
      server = a2a_server()

      metadata = %{
        "no_tools" => true,
        "client_tools" => [@weather_tool],
        "result_schema" => @answer_schema
      }

      assert {:ok, task} =
               OrcaHub.A2A.send_message(server, project.id, "what's the weather in Boston?",
                 metadata: metadata
               )

      session_id = task["contextId"]
      on_exit(fn -> stop_if_alive(session_id) end)

      session = Sessions.get_session!(session_id)
      # no_tools emptied the BUILT-IN tool allow-list...
      assert session.tools == ""
      # ...independently of the synthesized api_run MCP surface, which is
      # still wired up (code_exec disabled so it's the ONLY thing reachable).
      assert session.code_exec == false

      # Simulate the agent-side MCP tools/call parking — the real Claude CLI
      # would call this itself; @claude_stub above is a no-op stand-in.
      {:ok, mcp_session_id} =
        OrcaHub.MCP.Server.start_session(orca_session_id: session_id, api_run: true)

      on_exit(fn -> OrcaHub.MCP.Server.stop_session(mcp_session_id) end)

      parked =
        Task.async(fn ->
          OrcaHub.MCP.Server.handle_jsonrpc(mcp_session_id, %{
            "method" => "tools/call",
            "id" => 1,
            "params" => %{"name" => "get_weather", "arguments" => %{"city" => "Boston"}}
          })
        end)

      pending = wait_for_pending(task["id"])

      assert {:ok, fetched} = OrcaHub.A2A.get_task(server, project.id, task["id"])
      assert fetched["status"]["state"] == "input-required"

      assert OrcaHub.A2A.pending_tool_call(fetched) == %{
               "tool_call_id" => pending["id"],
               "name" => "get_weather",
               "arguments" => %{"city" => "Boston"}
             }

      assert {:ok, answered} =
               OrcaHub.A2A.answer_tool_call(
                 server,
                 project.id,
                 task["id"],
                 pending["id"],
                 {:result, %{"conditions" => "sunny", "temp_f" => 72}}
               )

      assert answered["status"]["state"] == "working"

      response = Task.await(parked)
      assert response["result"]["isError"] == false

      # The model's next turn calls submit_result directly (simulating what
      # the real CLI would do after receiving the tool result above).
      result =
        OrcaHub.MCP.Server.handle_jsonrpc(mcp_session_id, %{
          "method" => "tools/call",
          "id" => 2,
          "params" => %{
            "name" => "submit_result",
            "arguments" => %{"summary" => "It's sunny and 72°F in Boston."}
          }
        })

      assert result["result"]["isError"] == false

      assert {:ok, completed} = OrcaHub.A2A.get_task(server, project.id, task["id"])
      assert completed["status"]["state"] == "completed"

      assert OrcaHub.A2A.result_data(completed) == %{
               "summary" => "It's sunny and 72°F in Boston."
             }

      # Idempotent re-answer of the SAME tool_call_id after the task has
      # moved on to "completed" — always succeeds, no state change.
      assert {:ok, reanswered} =
               OrcaHub.A2A.answer_tool_call(
                 server,
                 project.id,
                 task["id"],
                 pending["id"],
                 {:result, %{"conditions" => "should not matter"}}
               )

      assert reanswered["status"]["state"] == "completed"

      assert OrcaHub.A2A.result_data(reanswered) == %{
               "summary" => "It's sunny and 72°F in Boston."
             }
    end
  end

  describe "message/send — v2 declaration (new session)" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)
      %{project: create_project()}
    end

    test "declares client_tools + result_schema: session gets code_exec: false, task stores both",
         %{conn: conn, project: project} do
      message =
        text_message("what's the weather")
        |> Map.put("metadata", %{
          "client_tools" => [@weather_tool],
          "result_schema" => @answer_schema
        })

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      task = body["result"]

      session = Sessions.get_session!(task["contextId"])
      on_exit(fn -> stop_if_alive(session.id) end)
      assert session.code_exec == false

      stored = A2ATasks.get_task(task["id"])
      assert stored.client_tools == [@weather_tool]
      assert stored.result_schema == @answer_schema
      assert stored.max_validation_attempts == 3
    end

    test "client_tools alone (no result_schema): code_exec still disabled", %{
      conn: conn,
      project: project
    } do
      message = text_message("hi") |> Map.put("metadata", %{"client_tools" => [@weather_tool]})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)

      session = Sessions.get_session!(body["result"]["contextId"])
      on_exit(fn -> stop_if_alive(session.id) end)
      assert session.code_exec == false
    end

    test "no declaration: code_exec left at the session default (true)", %{
      conn: conn,
      project: project
    } do
      conn = rpc_post(conn, project.id, "message/send", %{"message" => text_message("hi")})
      body = json_response(conn, 200)

      session = Sessions.get_session!(body["result"]["contextId"])
      on_exit(fn -> stop_if_alive(session.id) end)
      assert session.code_exec == true
    end

    test "no_tools + client_tools + result_schema compose independently: tools emptied, " <>
           "api_run surface still wired up",
         %{conn: conn, project: project} do
      message =
        text_message("hi")
        |> Map.put("metadata", %{
          "no_tools" => true,
          "client_tools" => [@weather_tool],
          "result_schema" => @answer_schema
        })

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)

      session = Sessions.get_session!(body["result"]["contextId"])
      on_exit(fn -> stop_if_alive(session.id) end)
      assert session.tools == ""
      assert session.code_exec == false
    end

    test "-32602 for invalid client_tools (reserved submit_result name)", %{
      conn: conn,
      project: project
    } do
      bad_tool = %{
        "name" => "submit_result",
        "description" => "x",
        "input_schema" => %{"type" => "object"}
      }

      message = text_message("hi") |> Map.put("metadata", %{"client_tools" => [bad_tool]})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "-32602 for a non-object result_schema", %{conn: conn, project: project} do
      message = text_message("hi") |> Map.put("metadata", %{"result_schema" => "not an object"})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "-32602 for a non-positive max_validation_attempts", %{conn: conn, project: project} do
      message = text_message("hi") |> Map.put("metadata", %{"max_validation_attempts" => 0})
      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end
  end

  describe "message/send — v2 continuation: rejection + inheritance" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "idle",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)

      {:ok, first_task} =
        A2ATasks.create_task(%{
          session_id: session.id,
          client_tools: [@weather_tool],
          result_schema: @answer_schema,
          max_validation_attempts: 5,
          status: "completed",
          result_text: "done"
        })

      %{project: project, session: session, first_task: first_task}
    end

    test "-32602 when client_tools is declared on a continuation", %{
      conn: conn,
      project: project,
      session: session
    } do
      message =
        text_message("hi")
        |> Map.put("contextId", session.id)
        |> Map.put("metadata", %{"client_tools" => [@weather_tool]})

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "-32602 when result_schema is declared on a continuation", %{
      conn: conn,
      project: project,
      session: session
    } do
      message =
        text_message("hi")
        |> Map.put("contextId", session.id)
        |> Map.put("metadata", %{"result_schema" => @answer_schema})

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "-32602 when max_validation_attempts is declared ALONE on a continuation", %{
      conn: conn,
      project: project,
      session: session
    } do
      message =
        text_message("hi")
        |> Map.put("contextId", session.id)
        |> Map.put("metadata", %{"max_validation_attempts" => 7})

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "a rejected continuation declaration creates no new task (rejected BEFORE any state change)",
         %{conn: conn, project: project, session: session, first_task: first_task} do
      message =
        text_message("hi")
        |> Map.put("contextId", session.id)
        |> Map.put("metadata", %{"client_tools" => [@weather_tool]})

      rpc_post(conn, project.id, "message/send", %{"message" => message})

      assert A2ATasks.get_task_by_session_id(session.id).id == first_task.id
    end

    test "inheritance: a continuation task copies client_tools/result_schema/" <>
           "max_validation_attempts from the prior task",
         %{conn: conn, project: project, session: session} do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => Map.put(text_message("continue"), "contextId", session.id)
        })

      body = json_response(conn, 200)
      task2 = A2ATasks.get_task(body["result"]["id"])

      assert task2.client_tools == [@weather_tool]
      assert task2.result_schema == @answer_schema
      assert task2.max_validation_attempts == 5
    end
  end

  describe "v2 tool-call loop + idempotency (docs/a2a.md)" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)

      {:ok, task} =
        A2ATasks.create_task(%{
          session_id: session.id,
          client_tools: [@weather_tool],
          status: "working"
        })

      {:ok, mcp_session_id} =
        OrcaHub.MCP.Server.start_session(orca_session_id: session.id, api_run: true)

      on_exit(fn -> OrcaHub.MCP.Server.stop_session(mcp_session_id) end)

      %{project: project, session: session, task: task, mcp_session_id: mcp_session_id}
    end

    defp park_weather(mcp_session_id) do
      Task.async(fn ->
        OrcaHub.MCP.Server.handle_jsonrpc(mcp_session_id, %{
          "method" => "tools/call",
          "id" => 1,
          "params" => %{"name" => "get_weather", "arguments" => %{"city" => "Boston"}}
        })
      end)
    end

    test "tasks/get on input-required renders the pending tool_call DataPart", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      parked = park_weather(mcp_session_id)
      pending = wait_for_pending(task.id)

      conn = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body = json_response(conn, 200)

      assert body["result"]["status"]["state"] == "input-required"

      assert body["result"]["status"]["message"]["parts"] == [
               %{
                 "kind" => "data",
                 "data" => %{
                   "tool_call_id" => pending["id"],
                   "name" => "get_weather",
                   "arguments" => %{"city" => "Boston"}
                 },
                 "metadata" => %{"orcahub_part" => "tool_call"}
               }
             ]

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        A2ATaskHolder.topic(task.id),
        {:client_tool_result, task.id, pending["id"], {:ok, %{}}}
      )

      Task.await(parked)
    end

    test "answering via taskId resolves the parked call in real time; task moves to working", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      parked = park_weather(mcp_session_id)
      pending = wait_for_pending(task.id)

      message =
        data_answer_message(task.id, pending["id"], %{"result" => %{"conditions" => "sunny"}})

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["result"]["status"]["state"] == "working"

      response = Task.await(parked)
      assert response["result"]["isError"] == false
      text = response["result"]["content"] |> hd() |> Map.get("text")
      assert text =~ "sunny"

      reloaded =
        wait_until(fn ->
          t = A2ATasks.get_task(task.id)
          t.status == "working" && t
        end)

      assert reloaded.pending_tool_call == nil
    end

    test "dup answer for the SAME tool_call_id after the task has moved on to completed: " <>
           "idempotent ack, task unchanged",
         %{conn: conn, project: project, task: task, mcp_session_id: mcp_session_id} do
      parked = park_weather(mcp_session_id)
      pending = wait_for_pending(task.id)
      tool_call_id = pending["id"]

      conn1 =
        rpc_post(conn, project.id, "message/send", %{
          "message" =>
            data_answer_message(task.id, tool_call_id, %{"result" => %{"conditions" => "sunny"}})
        })

      json_response(conn1, 200)
      Task.await(parked)
      wait_until(fn -> A2ATasks.get_task(task.id).status == "working" end)

      {:ok, _completed} =
        A2ATasks.update_task(A2ATasks.get_task(task.id), %{
          status: "completed",
          result_text: "It's sunny."
        })

      conn2 =
        rpc_post(conn, project.id, "message/send", %{
          "message" =>
            data_answer_message(task.id, tool_call_id, %{
              "result" => %{"conditions" => "should be ignored"}
            })
        })

      body2 = json_response(conn2, 200)
      assert body2["result"]["status"]["state"] == "completed"
      assert body2["result"]["id"] == task.id

      unchanged = A2ATasks.get_task(task.id)
      assert unchanged.status == "completed"
      assert unchanged.result_text == "It's sunny."
    end

    test "never-issued tool_call_id while input-required: -32602", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      parked = park_weather(mcp_session_id)
      pending = wait_for_pending(task.id)

      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => data_answer_message(task.id, "never-issued", %{"result" => %{}})
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        A2ATaskHolder.topic(task.id),
        {:client_tool_result, task.id, pending["id"], {:ok, %{}}}
      )

      Task.await(parked)
    end

    test "never-issued tool_call_id while the task has never had ANY pending call: -32602 " <>
           "(state-independent — not just an input-required gate)",
         %{conn: conn, project: project, task: task} do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => data_answer_message(task.id, "never-issued", %{"result" => %{}})
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
    end

    test "contextId mismatch: -32602", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      parked = park_weather(mcp_session_id)
      pending = wait_for_pending(task.id)

      message =
        data_answer_message(task.id, pending["id"], %{"result" => %{}}, %{
          "contextId" => Ecto.UUID.generate()
        })

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        A2ATaskHolder.topic(task.id),
        {:client_tool_result, task.id, pending["id"], {:ok, %{}}}
      )

      Task.await(parked)
    end

    test "hold_expired: answer delivered as a new session message; task moves to working", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      Application.put_env(:orca_hub, :api_run_tool_hold_cap_ms, 30)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_run_tool_hold_cap_ms) end)

      parked = park_weather(mcp_session_id)
      response = Task.await(parked, 2_000)
      assert response["result"]["isError"] == false

      reloaded =
        wait_until(fn ->
          t = A2ATasks.get_task(task.id)
          (t.pending_tool_call || %{})["hold_expired"] && t
        end)

      assert reloaded.status == "input-required"

      message =
        data_answer_message(task.id, reloaded.pending_tool_call["id"], %{
          "result" => %{"conditions" => "sunny"}
        })

      conn = rpc_post(conn, project.id, "message/send", %{"message" => message})
      body = json_response(conn, 200)
      assert body["result"]["status"]["state"] == "working"

      final = A2ATasks.get_task(task.id)
      assert final.status == "working"
      assert final.pending_tool_call == nil

      last_text =
        Sessions.list_messages(task.session_id)
        |> List.last()
        |> get_in([Access.key(:data), "message", "content", Access.at(0), "text"])

      assert last_text =~ "sunny"
      assert last_text =~ "Continue the task."
    end

    test "cancel while input-required: abandons the parked call, moves to canceled", %{
      conn: conn,
      project: project,
      task: task,
      mcp_session_id: mcp_session_id
    } do
      Application.put_env(:orca_hub, :api_run_tool_hold_cap_ms, 30)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_run_tool_hold_cap_ms) end)

      parked = park_weather(mcp_session_id)
      wait_for_pending(task.id)

      conn = rpc_post(conn, project.id, "tasks/cancel", %{"id" => task.id})
      body = json_response(conn, 200)
      assert body["result"]["status"]["state"] == "canceled"
      assert A2ATasks.get_task(task.id).status == "canceled"

      # Abandoned, never answered — the parked MCP tools/call resolves on
      # its own hold-timeout, harmlessly (docs/a2a.md "Tool-call loop").
      Task.await(parked, 2_000)
    end
  end

  describe "v2 structured results — validation retries (docs/a2a.md)" do
    setup do
      project = create_project()

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "idle",
          runner_node: Atom.to_string(node())
        })

      %{project: project, session: session}
    end

    test "corrective retry stays \"working\" — never observable as a distinct task state", %{
      conn: conn,
      project: project,
      session: session
    } do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)
      on_exit(fn -> stop_if_alive(session.id) end)

      insert_assistant_message(session, ~s({"wrong": true}))

      {:ok, task} =
        A2ATasks.create_task(%{
          session_id: session.id,
          result_schema: @answer_schema,
          max_validation_attempts: 3,
          status: "working"
        })

      conn = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body = json_response(conn, 200)
      assert body["result"]["status"]["state"] == "working"

      reloaded = A2ATasks.get_task(task.id)
      assert reloaded.validation_attempts == 1
      assert reloaded.status == "working"
    end

    test "exhausted attempts: failed with a TextPart of the last raw response, no result DataPart",
         %{conn: conn, project: project, session: session} do
      insert_assistant_message(session, ~s({"wrong": true}))

      {:ok, task} =
        A2ATasks.create_task(%{
          session_id: session.id,
          result_schema: @answer_schema,
          max_validation_attempts: 1,
          validation_attempts: 1,
          status: "working"
        })

      conn = rpc_post(conn, project.id, "tasks/get", %{"id" => task.id})
      body = json_response(conn, 200)

      assert body["result"]["status"]["state"] == "failed"

      assert body["result"]["status"]["message"]["parts"] == [
               %{"kind" => "text", "text" => ~s({"wrong": true})}
             ]
    end
  end
end
