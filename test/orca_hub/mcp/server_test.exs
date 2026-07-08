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
end
