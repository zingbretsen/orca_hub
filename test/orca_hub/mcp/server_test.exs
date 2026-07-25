defmodule OrcaHub.MCP.ServerTest do
  @moduledoc """
  Coverage for `OrcaHub.MCP.Server`'s `api_run` connection mode (Agent Runs
  API `submit_result`, docs/api.md): `tools/list` synthesizes a single
  `submit_result` tool from the run's `result_schema`, and `tools/call`
  validates + persists (or rejects) a submission — never dispatching any
  other orca/upstream tool on the connection.
  """

  # async: false — MCP.Server runs as a real GenServer process under the
  # shared OrcaHub.MCPSupervisor, so its DB calls (from a DIFFERENT process
  # than the test process) need the sandbox in SHARED mode (see
  # api_run_controller_test.exs for the same pattern/rationale).
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{ApiRuns, Sessions}
  alias OrcaHub.MCP.Server

  @weather_tool %{
    "name" => "get_weather",
    "description" => "Look up the current weather for a city.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  }

  @time_tool %{
    "name" => "get_time",
    "description" => "Look up the current local time for a city.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  }

  defp start_api_run_connection(schema) do
    {:ok, session} =
      Sessions.create_session(%{
        directory: "/tmp/mcp-server-test-#{System.unique_integer([:positive])}"
      })

    {:ok, run} = ApiRuns.create_run(%{session_id: session.id, result_schema: schema})

    {:ok, mcp_session_id} = Server.start_session(orca_session_id: session.id, api_run: true)
    on_exit(fn -> Server.stop_session(mcp_session_id) end)

    %{session: session, run: run, mcp_session_id: mcp_session_id}
  end

  defp start_client_tools_connection(client_tools, result_schema \\ nil) do
    {:ok, session} =
      Sessions.create_session(%{
        directory: "/tmp/mcp-server-test-#{System.unique_integer([:positive])}"
      })

    {:ok, run} =
      ApiRuns.create_run(%{
        session_id: session.id,
        client_tools: client_tools,
        result_schema: result_schema
      })

    {:ok, mcp_session_id} = Server.start_session(orca_session_id: session.id, api_run: true)
    on_exit(fn -> Server.stop_session(mcp_session_id) end)

    %{session: session, run: run, mcp_session_id: mcp_session_id}
  end

  defp tools_list(mcp_session_id) do
    Server.handle_jsonrpc(mcp_session_id, %{"method" => "tools/list", "id" => 1})
  end

  defp call_tool(mcp_session_id, name, arguments) do
    Server.handle_jsonrpc(mcp_session_id, %{
      "method" => "tools/call",
      "id" => 2,
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  defp result_text(response) do
    response["result"]["content"] |> hd() |> Map.get("text")
  end

  # A parked client tool call defers its JSON-RPC reply (see
  # OrcaHub.MCP.Server's "Client tool call parking" section) — calling it
  # via the plain synchronous `call_tool/3` helper would hang the test
  # process until it's resolved, so tests that expect to park run it in a
  # separate Task instead and resolve/await it explicitly.
  defp async_call_tool(mcp_session_id, name, arguments) do
    Task.async(fn -> call_tool(mcp_session_id, name, arguments) end)
  end

  # Simulates ApiRunController's real-time resolution broadcast (see
  # deliver_tool_result_realtime/3) directly, without going through the HTTP
  # layer or persisting the answer into pending_tool_call first — sufficient
  # for exercising MCP.Server's OWN broadcast-handling in isolation, since
  # `clear_pending_and_resume/2` only reads the DB to confirm the id still
  # matches, not to fetch the answer (that comes from `payload` here).
  defp resolve_via_broadcast(run_id, tool_call_id, payload) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "api_run:#{run_id}",
      {:client_tool_result, run_id, tool_call_id, payload}
    )
  end

  defp wait_for_pending(run_id, attempts \\ 100) do
    case ApiRuns.get_run(run_id).pending_tool_call do
      nil when attempts > 0 ->
        Process.sleep(5)
        wait_for_pending(run_id, attempts - 1)

      pending ->
        pending
    end
  end

  # MCP.Server replies to a parked caller BEFORE persisting the DB-side
  # clear/expiry (see resolve_parked/3, handle_info :client_tool_hold_timeout)
  # — deliberately, so the model isn't stalled on that write. That means
  # `Task.await/1` returning doesn't guarantee the DB write has landed yet;
  # assertions on `ApiRuns.get_run/1` right after need to poll briefly rather
  # than assume the write already happened.
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

  describe "tools/list — api_run connection" do
    test "returns exactly one synthesized submit_result tool; object schema passed through as-is" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}},
        "required" => ["answer"]
      }

      %{mcp_session_id: mcp_session_id} = start_api_run_connection(schema)

      response = tools_list(mcp_session_id)
      tools = response["result"]["tools"]

      assert [%{"name" => "submit_result", "inputSchema" => input_schema} = tool] = tools
      assert input_schema == schema
      assert tool["description"] =~ "Submit the final structured result"
    end

    test "wraps a non-object schema under a `result` property" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}

      %{mcp_session_id: mcp_session_id} = start_api_run_connection(schema)

      response = tools_list(mcp_session_id)
      [%{"inputSchema" => input_schema}] = response["result"]["tools"]

      assert input_schema == %{
               "type" => "object",
               "properties" => %{"result" => schema},
               "required" => ["result"]
             }
    end

    test "no matching run for the connection: empty tool list, no leakage of other tools" do
      {:ok, mcp_session_id} =
        Server.start_session(orca_session_id: Ecto.UUID.generate(), api_run: true)

      on_exit(fn -> Server.stop_session(mcp_session_id) end)

      response = tools_list(mcp_session_id)
      assert response["result"]["tools"] == []
    end
  end

  describe "tools/call submit_result — api_run connection" do
    @schema %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"]
    }

    test "valid submission completes the run and returns success text" do
      %{mcp_session_id: mcp_session_id, run: run} = start_api_run_connection(@schema)

      response = call_tool(mcp_session_id, "submit_result", %{"answer" => 42})

      assert response["result"]["isError"] == false
      assert result_text(response) =~ "accepted"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "completed"
      assert reloaded.result == %{"answer" => 42}
      assert reloaded.result_text == nil
    end

    test "wrapped (non-object) schema: unwraps the `result` key, validates it against the raw schema" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      %{mcp_session_id: mcp_session_id, run: run} = start_api_run_connection(schema)

      # A wrong-shaped `result` (not an array of strings) is unwrapped and
      # validated against the RAW (unwrapped) schema, not the wrapper —
      # proving unwrap happens before validation.
      response = call_tool(mcp_session_id, "submit_result", %{"result" => "not an array"})

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "Validation failed"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "running"
    end

    test "wrapped (non-object) schema: a schema-valid array submission still fails to persist gracefully " <>
           "(pre-existing api_runs.result :map column limitation, not a crash)" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}
      %{mcp_session_id: mcp_session_id, run: run} = start_api_run_connection(schema)

      response = call_tool(mcp_session_id, "submit_result", %{"result" => ["a", "b"]})

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "could not be stored"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "running"
    end

    test "invalid submission returns isError with validation messages; run stays running" do
      %{mcp_session_id: mcp_session_id, run: run} = start_api_run_connection(@schema)

      response = call_tool(mcp_session_id, "submit_result", %{"wrong" => true})

      assert response["result"]["isError"] == true
      text = result_text(response)
      assert text =~ "Validation failed"
      assert text =~ "answer"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "running"
    end

    test "already-completed run: noop success text, does not overwrite the stored result" do
      %{mcp_session_id: mcp_session_id, run: run} = start_api_run_connection(@schema)

      {:ok, run} = ApiRuns.update_run(run, %{status: "completed", result: %{"answer" => 1}})

      response = call_tool(mcp_session_id, "submit_result", %{"answer" => 999})

      assert response["result"]["isError"] == false
      assert result_text(response) =~ "already submitted"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.result == %{"answer" => 1}
    end

    test "any other tool name is rejected without dispatching" do
      %{mcp_session_id: mcp_session_id} = start_api_run_connection(@schema)

      response = call_tool(mcp_session_id, "open_file", %{"file_path" => "mix.exs"})

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "only exposes submit_result"
    end

    test "a raise inside handle_submit_result (e.g. a hub/DB blip) degrades to a tool error " <>
           "instead of crashing the GenServer" do
      # A malformed orca_session_id (never happens on the real /mcp?orca_session_id=...
      # path — SessionRunner always bakes a real session UUID — but stands in here for
      # any HubRPC call that raises, e.g. a hub outage's :erpc.call timeout/badrpc)
      # makes ApiRuns.get_run_by_session_id/1's Ecto query raise when casting the
      # `where: r.session_id == ^session_id` param, exercising the same code path a
      # raised exception from a hub blip would.
      {:ok, mcp_session_id} =
        Server.start_session(orca_session_id: "not-a-valid-uuid", api_run: true)

      on_exit(fn -> Server.stop_session(mcp_session_id) end)

      response = call_tool(mcp_session_id, "submit_result", %{"answer" => 42})

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "submit_result raised"

      # The GenServer survived the raise — a follow-up call on the SAME mcp_session_id
      # still gets a normal response rather than the "Invalid or missing session" 400
      # a crashed/orphaned MCP session would produce upstream in MCP.Plug.
      assert Server.session_exists?(mcp_session_id)
      follow_up = tools_list(mcp_session_id)
      assert %{"result" => %{"tools" => []}} = follow_up
    end
  end

  describe "tools/list — client_tools (docs/api.md, AG-UI-style frontend tools)" do
    test "client tools only (no result_schema): just the client tool, no submit_result" do
      %{mcp_session_id: mcp_session_id} = start_client_tools_connection([@weather_tool])

      response = tools_list(mcp_session_id)
      tools = response["result"]["tools"]

      assert [%{"name" => "get_weather"} = tool] = tools
      assert tool["inputSchema"] == @weather_tool["input_schema"]
      assert tool["description"] =~ "Look up the current weather"
      assert tool["description"] =~ "executed by the calling application"
      assert tool["description"] =~ "END YOUR TURN"
    end

    test "client tools + result_schema: both are listed, client tools before submit_result" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "integer"}}}
      %{mcp_session_id: mcp_session_id} = start_client_tools_connection([@weather_tool], schema)

      response = tools_list(mcp_session_id)
      names = response["result"]["tools"] |> Enum.map(& &1["name"])

      assert names == ["get_weather", "submit_result"]
    end

    test "wraps a non-object client tool input_schema under a result property" do
      tool = %{@weather_tool | "input_schema" => %{"type" => "string"}}
      %{mcp_session_id: mcp_session_id} = start_client_tools_connection([tool])

      response = tools_list(mcp_session_id)
      [%{"inputSchema" => input_schema}] = response["result"]["tools"]

      assert input_schema == %{
               "type" => "object",
               "properties" => %{"result" => %{"type" => "string"}},
               "required" => ["result"]
             }
    end
  end

  describe "tools/call — client_tools (docs/api.md, AG-UI-style frontend tools)" do
    test "parks the call: pending_tool_call recorded, run moves to awaiting_tool_result, and the " <>
           "tools/call reply stays open until resolved" do
      %{mcp_session_id: mcp_session_id, run: run} = start_client_tools_connection([@weather_tool])

      task = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      pending = wait_for_pending(run.id)

      assert %{"name" => "get_weather", "arguments" => %{"city" => "Boston"}, "id" => id} =
               pending

      assert is_binary(id)
      assert ApiRuns.get_run(run.id).status == "awaiting_tool_result"

      # Still parked — no reply yet.
      refute Task.yield(task, 50)

      resolve_via_broadcast(run.id, id, {:ok, %{"conditions" => "sunny"}})
      response = Task.await(task)

      assert response["result"]["isError"] == false
      assert result_text(response) =~ "sunny"

      reloaded =
        wait_until(fn ->
          ApiRuns.get_run(run.id).status == "running" && ApiRuns.get_run(run.id)
        end)

      assert reloaded.pending_tool_call == nil
    end

    test "an error answer resolves the parked call with an MCP error result" do
      %{mcp_session_id: mcp_session_id, run: run} = start_client_tools_connection([@weather_tool])

      task = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      %{"id" => id} = wait_for_pending(run.id)

      resolve_via_broadcast(run.id, id, {:error, "city not found"})
      response = Task.await(task)

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "city not found"
      assert wait_until(fn -> ApiRuns.get_run(run.id).pending_tool_call == nil end)
    end

    test "wrapped (non-object) input_schema: unwraps to the raw shape before storing arguments" do
      tool = %{@weather_tool | "input_schema" => %{"type" => "string"}}
      %{mcp_session_id: mcp_session_id, run: run} = start_client_tools_connection([tool])

      task = async_call_tool(mcp_session_id, "get_weather", %{"result" => "Boston"})
      pending = wait_for_pending(run.id)
      assert pending["arguments"] == "Boston"

      resolve_via_broadcast(run.id, pending["id"], {:ok, nil})
      Task.await(task)
    end

    test "a second call for the SAME tool name while one is parked re-parks against the existing " <>
           "pending call instead of creating a duplicate" do
      %{mcp_session_id: mcp_session_id, run: run} = start_client_tools_connection([@weather_tool])

      task1 = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      pending = wait_for_pending(run.id)

      task2 = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      # Parked too (not an immediate error) — and no NEW pending call was created.
      refute Task.yield(task2, 100)
      assert ApiRuns.get_run(run.id).pending_tool_call["id"] == pending["id"]

      resolve_via_broadcast(run.id, pending["id"], {:ok, %{"conditions" => "sunny"}})

      assert result_text(Task.await(task1)) =~ "sunny"
      assert result_text(Task.await(task2)) =~ "sunny"
    end

    test "a call for a DIFFERENT tool name while one is parked gets the one-at-a-time error" do
      %{mcp_session_id: mcp_session_id, run: run} =
        start_client_tools_connection([@weather_tool, @time_tool])

      task = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      %{"id" => id} = wait_for_pending(run.id)

      response = call_tool(mcp_session_id, "get_time", %{"city" => "Boston"})

      assert response["result"]["isError"] == true
      assert result_text(response) =~ "Call one frontend tool at a time"
      assert result_text(response) =~ "get_weather"

      resolve_via_broadcast(run.id, id, {:ok, %{}})
      Task.await(task)
    end

    test "restart mid-hold: a fresh connection re-parks against an existing unanswered " <>
           "pending_tool_call instead of creating a duplicate" do
      %{run: run} = start_client_tools_connection([@weather_tool])

      {:ok, run} =
        ApiRuns.update_run(run, %{
          status: "awaiting_tool_result",
          pending_tool_call: %{
            "id" => "call-existing",
            "name" => "get_weather",
            "arguments" => %{"city" => "Boston"}
          }
        })

      {:ok, mcp_session_id} = Server.start_session(orca_session_id: run.session_id, api_run: true)
      on_exit(fn -> Server.stop_session(mcp_session_id) end)

      task = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      refute Task.yield(task, 100)
      assert ApiRuns.get_run(run.id).pending_tool_call["id"] == "call-existing"

      resolve_via_broadcast(run.id, "call-existing", {:ok, %{"conditions" => "sunny"}})
      assert result_text(Task.await(task)) =~ "sunny"
    end

    test "restart mid-hold: an existing pending call already answered before anyone re-parked " <>
           "resolves immediately, without parking" do
      %{run: run} = start_client_tools_connection([@weather_tool])

      {:ok, run} =
        ApiRuns.update_run(run, %{
          status: "awaiting_tool_result",
          pending_tool_call: %{
            "id" => "call-existing",
            "name" => "get_weather",
            "arguments" => %{"city" => "Boston"},
            "result" => %{"conditions" => "cloudy"}
          }
        })

      {:ok, mcp_session_id} = Server.start_session(orca_session_id: run.session_id, api_run: true)
      on_exit(fn -> Server.stop_session(mcp_session_id) end)

      response = call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      assert result_text(response) =~ "cloudy"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "running"
      assert reloaded.pending_tool_call == nil
    end

    test "hold timeout: replies with the v1 placeholder and marks the pending call hold_expired " <>
           "(not cleared) instead of resolving it" do
      Application.put_env(:orca_hub, :api_run_tool_hold_cap_ms, 30)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_run_tool_hold_cap_ms) end)

      %{mcp_session_id: mcp_session_id, run: run} = start_client_tools_connection([@weather_tool])

      task = async_call_tool(mcp_session_id, "get_weather", %{"city" => "Boston"})
      response = Task.await(task, 2_000)

      assert response["result"]["isError"] == false
      assert result_text(response) =~ "END YOUR TURN"

      reloaded =
        wait_until(fn ->
          ApiRuns.get_run(run.id).pending_tool_call["hold_expired"] && ApiRuns.get_run(run.id)
        end)

      assert reloaded.status == "awaiting_tool_result"
      assert is_binary(reloaded.pending_tool_call["id"])
    end

    test "an unknown tool name is rejected, mentioning the available client tools + submit_result" do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "integer"}}}
      %{mcp_session_id: mcp_session_id} = start_client_tools_connection([@weather_tool], schema)

      response = call_tool(mcp_session_id, "open_file", %{})

      assert response["result"]["isError"] == true
      text = result_text(response)
      assert text =~ "get_weather"
      assert text =~ "submit_result"
    end

    test "submit_result still works normally alongside client_tools" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}},
        "required" => ["answer"]
      }

      %{mcp_session_id: mcp_session_id, run: run} =
        start_client_tools_connection([@weather_tool], schema)

      response = call_tool(mcp_session_id, "submit_result", %{"answer" => 42})

      assert response["result"]["isError"] == false
      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.status == "completed"
      assert reloaded.result == %{"answer" => 42}
    end
  end
end
