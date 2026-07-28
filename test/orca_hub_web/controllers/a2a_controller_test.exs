defmodule OrcaHubWeb.A2AControllerTest do
  # async: false — the message/send tests start a real SessionRunner
  # (GenStatem) child under the shared OrcaHub.SessionSupervisor, which needs
  # the DB sandbox in SHARED mode (see ApiRunControllerTest for the same
  # pattern/rationale).
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{A2ATasks, Projects, SessionSupervisor, Sessions}

  @claude_stub Path.expand("../../support/fixtures/claude_stub_noop.sh", __DIR__)
  @token "test-a2a-token"

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

    test "-32602 when message.taskId is given (must use contextId for follow-ups)", %{
      conn: conn,
      project: project
    } do
      conn =
        rpc_post(conn, project.id, "message/send", %{
          "message" => Map.put(text_message("hi"), "taskId", "some-prior-task")
        })

      body = json_response(conn, 200)
      assert body["error"]["code"] == -32602
      assert body["error"]["message"] =~ "contextId"
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
  end
end
