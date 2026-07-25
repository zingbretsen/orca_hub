defmodule OrcaHub.MCP.Server do
  @moduledoc """
  GenServer managing an MCP session. Handles JSON-RPC message routing
  for the Streamable HTTP transport.
  """
  use GenServer
  require Logger

  alias OrcaHub.MCP.Tools

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def via(session_id), do: {:via, Registry, {OrcaHub.MCPRegistry, session_id}}

  def handle_jsonrpc(session_id, message) do
    GenServer.call(via(session_id), {:jsonrpc, message}, :infinity)
  end

  # Start an MCP session (called from the Plug on initialize)
  def start_session(opts \\ []) do
    session_id = generate_session_id()
    orca_session_id = Keyword.get(opts, :orca_session_id)
    orchestrator = Keyword.get(opts, :orchestrator, false)
    code_exec = Keyword.get(opts, :code_exec, false)
    api_run = Keyword.get(opts, :api_run, false)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OrcaHub.MCPSupervisor,
        {__MODULE__,
         session_id: session_id,
         orca_session_id: orca_session_id,
         orchestrator: orchestrator,
         code_exec: code_exec,
         api_run: api_run}
      )

    {:ok, session_id}
  end

  def stop_session(session_id) do
    case Registry.lookup(OrcaHub.MCPRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(OrcaHub.MCPSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  def session_exists?(session_id) do
    Registry.lookup(OrcaHub.MCPRegistry, session_id) != []
  end

  # Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    orca_session_id = Keyword.get(opts, :orca_session_id)
    orchestrator = Keyword.get(opts, :orchestrator, false)
    # The kill switch is honored at resolution time so a stale code_exec=true
    # query param can never re-enable the feature node-wide.
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Keyword.get(opts, :code_exec, false))
    # Agent Runs API (docs/api.md): whether this connection is scoped to the
    # api_run tool surface — a `submit_result` tool synthesized from a run's
    # result_schema, and/or caller-defined client (frontend) tools.
    api_run = Keyword.get(opts, :api_run, false)

    Logger.info(
      "[MCP] session start: mcp_session_id=#{session_id} " <>
        "orca_session_id=#{inspect(orca_session_id)} orchestrator=#{orchestrator} " <>
        "code_exec=#{code_exec} api_run=#{api_run}"
    )

    # `initialize` does NO hub work. The connection role (orchestrator?) is
    # carried by the MCP connection itself (a query param set by
    # SessionRunner) rather than resolved via a hub/DB lookup. This keeps the
    # MCP handshake fast — no erpc, no DB — so tools/list is ready before the
    # model emits its first tool call, and a hub outage can't strip the
    # orchestrator tool set. `api_run_config` (the run's actual result_schema
    # and/or client_tools) is fetched lazily at tools/list (and, defensively,
    # tools/call) time instead — see `ensure_api_run_config/1` — since THAT
    # round-trip can tolerate the latency (nothing to hand-shake against it).
    {:ok,
     %{
       session_id: session_id,
       orca_session_id: orca_session_id,
       orchestrator: orchestrator,
       code_exec: code_exec,
       api_run: api_run,
       api_run_config: nil,
       initialized: false
     }}
  end

  @impl true
  def handle_call({:jsonrpc, message}, _from, state) do
    {response, new_state} = dispatch(message, state)
    {:reply, response, new_state}
  end

  # JSON-RPC dispatch

  defp dispatch(%{"method" => "initialize", "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{
          "tools" => %{}
        },
        "serverInfo" => %{
          "name" => "OrcaHub",
          "version" => "0.1.0"
        }
      }
    }

    {response, %{state | initialized: true}}
  end

  defp dispatch(%{"method" => "notifications/initialized"}, state) do
    {:accepted, state}
  end

  defp dispatch(%{"method" => "ping", "id" => id}, state) do
    {%{"jsonrpc" => "2.0", "id" => id, "result" => %{}}, state}
  end

  # Orchestrator-only tools we explicitly assert are present for orchestrator
  # connections — used as a smoking-gun check in the tools/list log line, not
  # an exhaustive list of every orchestrator-only tool (search_sessions is
  # also orchestrator-only, just not part of this particular sanity check).
  # start_session/archive_session moved OUT of this list: regular sessions can
  # now spawn/peek-at/archive children too (see Tools.@regular_session_tools)
  # — only the heartbeat tools remain orchestrator-only here.
  @orchestrator_only_tools ~w(cancel_heartbeat schedule_heartbeat)

  # Agent Runs API (docs/api.md): an api_run connection's tool surface is
  # built entirely from the run's config — caller-defined client (frontend)
  # tools, plus a synthesized submit_result tool when the run has a
  # result_schema — no other orca tool, no code-exec meta-tools, no upstream
  # tools. `initialize` deliberately did no hub work (see init/1's doc), so
  # the config is fetched here, on first tools/list, and cached in state.
  defp dispatch(%{"method" => "tools/list", "id" => id}, %{api_run: true} = state) do
    # ensure_api_run_config/1 does a HubRPC call, which RAISES on erpc/hub
    # failures — same defensive wrapper as the general tools/call dispatcher
    # (and the api_run tools/call clauses below) so a hub blip degrades
    # to an empty tool list instead of crashing this GenServer.
    state =
      try do
        ensure_api_run_config(state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run tools/list raised: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          state
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run tools/list #{kind}: " <> Exception.format(kind, reason, __STACKTRACE__)
          )

          state
      end

    tools =
      case state.api_run_config do
        nil ->
          Logger.error(
            "[MCP] api_run tools/list: no run found for orca_session_id=" <>
              inspect(state.orca_session_id)
          )

          []

        %{result_schema: schema, client_tools: client_tools} ->
          Enum.map(client_tools, &client_tool_definition/1) ++
            if(is_map(schema), do: [submit_result_tool(schema)], else: [])
      end

    log_tools_list_size("api_run", state, tools)

    response = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}
    {response, state}
  end

  # Code-exec mode: collapse the surface to just the run_elixir meta-tool.
  # First-party + upstream tools are no longer flattened here — they're
  # reachable only as `Tools.*` functions inside run_elixir. When the flag is
  # OFF this clause never matches and tools/list behaves exactly as before.
  defp dispatch(%{"method" => "tools/list", "id" => id}, %{code_exec: true} = state) do
    all_tools = OrcaHub.MCP.CodeExec.MetaTools.list()

    log_tools_list_size("code_exec", state, all_tools)

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => all_tools}
    }

    {response, state}
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}, state) do
    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()
    orca_tools = Tools.list(state)
    all_tools = (orca_tools ++ upstream_tools) |> Enum.sort_by(& &1["name"])

    orca_tool_names = Enum.map(orca_tools, & &1["name"])
    orchestrator_tools_present? = Enum.all?(@orchestrator_only_tools, &(&1 in orca_tool_names))

    Logger.info(
      "[MCP] tools/list: orca_session_id=#{inspect(state.orca_session_id)} " <>
        "orchestrator=#{state.orchestrator} orca_tool_count=#{length(orca_tools)} " <>
        "orchestrator_tools_present=#{orchestrator_tools_present?} " <>
        "upstream_tool_count=#{length(upstream_tools)}"
    )

    log_tools_list_size("standard", state, all_tools)

    Logger.debug("[MCP] tools/list orca tools: #{inspect(orca_tool_names)}")

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => all_tools
      }
    }

    {response, state}
  end

  # Agent Runs API (docs/api.md): an api_run connection may only call
  # submit_result or one of the run's client (frontend) tools — every other
  # name is rejected outright rather than falling through to the general
  # dispatcher below. submit_result is matched here by literal name (it's
  # never a caller-supplied client tool name — see the validation in
  # ApiRuns.validate_client_tools/1); every other name goes through the
  # client-tool clause below.
  defp dispatch(
         %{
           "method" => "tools/call",
           "id" => id,
           "params" => %{"name" => "submit_result"} = params
         },
         %{api_run: true} = state
       ) do
    arguments = params["arguments"] || %{}

    # Same defensive wrapper the general tools/call dispatcher uses below —
    # this clause bypasses that dispatcher entirely, but handle_submit_result/2
    # does its own HubRPC calls (get_run_by_session_id, update_api_run), which
    # RAISE on erpc/hub failures. Without this, a hub blip mid-submission would
    # crash this GenServer and orphan the MCP session instead of just failing
    # the one tool call.
    result =
      try do
        handle_submit_result(arguments, state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run submit_result raised: " <> Exception.format(:error, e, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("submit_result raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run submit_result #{kind}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("submit_result failed: #{inspect(reason)}")
      end

    {%{"jsonrpc" => "2.0", "id" => id, "result" => result}, state}
  end

  # Client (frontend) tool call (docs/api.md, AG-UI-style): the tool call is
  # never dispatched locally — it's parked on the run as `pending_tool_call`
  # (status `awaiting_tool_result`) for the caller to pick up via `GET
  # /api/v1/runs/:id` and answer via `POST /api/v1/runs/:id/tool_result`.
  defp dispatch(
         %{"method" => "tools/call", "id" => id, "params" => params},
         %{api_run: true} = state
       ) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    # Same defensive wrapper the submit_result clause above uses —
    # handle_client_tool_call/3 does its own HubRPC calls, which RAISE on
    # erpc/hub failures.
    {result, state} =
      try do
        handle_client_tool_call(tool_name, arguments, state)
      rescue
        e ->
          Logger.error(
            "[MCP] api_run client tool call raised: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} raised: #{Exception.message(e)}"),
           state}
      catch
        kind, reason ->
          Logger.error(
            "[MCP] api_run client tool call #{kind}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          {OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} failed: #{inspect(reason)}"), state}
      end

    {%{"jsonrpc" => "2.0", "id" => id, "result" => result}, state}
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    upstream? = OrcaHub.MCP.UpstreamClient.upstream_tool?(tool_name)
    # Threaded through to Tools.call (and, for code-exec connections, into
    # run_elixir's CodeExec state) so side-effecting tools like start_session
    # can derive an automatic idempotency key that survives a transport-level
    # replay of this same JSON-RPC request — see issue c7eeef06. The id is
    # connection/turn-scoped (resets across CLI re-handshakes), so it's only
    # ever used ALONGSIDE the call's own arguments, never alone.
    state = Map.put(state, :mcp_request_id, id)

    Logger.info(
      "[MCP] tools/call: name=#{inspect(tool_name)} orchestrator=#{state.orchestrator} " <>
        "orca_session_id=#{inspect(state.orca_session_id)} path=#{if upstream?, do: "upstream", else: "local"}"
    )

    # Defensive wrapper: an exception/exit inside a tool implementation would
    # otherwise crash this GenServer, orphaning the MCP session and producing
    # the suspect "Invalid or missing session" 400s on subsequent requests.
    result =
      try do
        cond do
          # Code-exec mode: only the meta-tools are dispatchable here; every
          # other tool is reachable as Tools.<name> inside run_elixir.
          state.code_exec ->
            OrcaHub.MCP.CodeExec.MetaTools.call(tool_name, arguments, state)

          upstream? ->
            OrcaHub.MCP.UpstreamClient.call_tool(tool_name, arguments,
              orca_session_id: state.orca_session_id
            )

          true ->
            Tools.call(tool_name, arguments, state)
        end
      rescue
        e ->
          Logger.error(
            "[MCP] tools/call raised for name=#{inspect(tool_name)}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.error(
            "[MCP] tools/call #{kind} for name=#{inspect(tool_name)}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          OrcaHub.MCP.Tools.Result.error("Tool #{tool_name} failed: #{inspect(reason)}")
      end

    if is_map(result) and result["isError"] == true do
      error_text =
        case result["content"] do
          [%{"text" => text} | _] -> text
          _ -> inspect(result["content"])
        end

      Logger.warning(
        "[MCP] tools/call result: name=#{inspect(tool_name)} isError=true error=#{inspect(error_text)}"
      )
    else
      Logger.info("[MCP] tools/call result: name=#{inspect(tool_name)} isError=false")
    end

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }

    {response, state}
  end

  defp dispatch(%{"method" => method, "id" => id}, state) do
    Logger.warning(
      "[MCP] unknown method=#{inspect(method)} orca_session_id=#{inspect(state.orca_session_id)}"
    )

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_601,
        "message" => "Method not found: #{method}"
      }
    }

    {response, state}
  end

  # Notification we don't handle — just accept
  defp dispatch(%{"method" => _}, state) do
    {:accepted, state}
  end

  # ── Agent Runs API (api_run connections, docs/api.md) ─────────────────

  defp ensure_api_run_config(%{api_run_config: config} = state) when not is_nil(config),
    do: state

  defp ensure_api_run_config(state) do
    case OrcaHub.HubRPC.get_run_by_session_id(state.orca_session_id) do
      nil ->
        state

      run ->
        %{
          state
          | api_run_config: %{
              result_schema: run.result_schema,
              client_tools: run.client_tools || []
            }
        }
    end
  end

  # The caller's schema is used directly as the tool's inputSchema when it's
  # already a JSON object schema (the common case: `result_schema` describes
  # an object). Anything else (array, string, ...) is wrapped so submit_result
  # still has a valid object-shaped inputSchema — see `unwrap_wrapped_arguments/2`.
  defp submit_result_tool(schema) do
    %{
      "name" => "submit_result",
      "description" =>
        "Submit the final structured result for this run. Input must conform to the schema.",
      "inputSchema" => wrapped_input_schema(schema)
    }
  end

  # This tool is executed by the calling application, not this server — the
  # call is only ever parked as a pending_tool_call (see
  # handle_client_tool_call/3) and answered out-of-band via
  # POST /api/v1/runs/:id/tool_result.
  @client_tool_note "This tool is executed by the calling application. After calling it, " <>
                      "END YOUR TURN — the result will arrive as your next user message."

  defp client_tool_definition(tool) do
    schema = tool["input_schema"]

    %{
      "name" => tool["name"],
      "description" =>
        String.trim_trailing(tool["description"] || "") <> " " <> @client_tool_note,
      "inputSchema" => wrapped_input_schema(schema)
    }
  end

  defp wrapped_input_schema(%{"type" => "object"} = schema), do: schema

  defp wrapped_input_schema(schema) do
    %{"type" => "object", "properties" => %{"result" => schema}, "required" => ["result"]}
  end

  defp wrapped_schema?(%{"type" => "object"}), do: false
  defp wrapped_schema?(_schema), do: true

  defp unwrap_wrapped_arguments(arguments, schema) do
    if wrapped_schema?(schema), do: Map.get(arguments, "result"), else: arguments
  end

  defp handle_submit_result(arguments, state) do
    case OrcaHub.HubRPC.get_run_by_session_id(state.orca_session_id) do
      nil ->
        OrcaHub.MCP.Tools.Result.error(
          "No matching run found for orca_session_id=#{inspect(state.orca_session_id)}."
        )

      %{status: "completed"} ->
        OrcaHub.MCP.Tools.Result.text("Result already submitted.")

      run ->
        validate_and_complete_run(run, arguments)
    end
  end

  defp validate_and_complete_run(run, arguments) do
    submission = unwrap_wrapped_arguments(arguments, run.result_schema)

    case OrcaHub.ApiRuns.validate_against_schema(submission, run.result_schema) do
      :ok ->
        persist_completed_run(run, submission)

      {:error, errors} ->
        OrcaHub.MCP.Tools.Result.error(
          "Validation failed:\n" <> Enum.map_join(errors, "\n", &"- #{&1}")
        )

      {:schema_error, message} ->
        OrcaHub.MCP.Tools.Result.error("Invalid result_schema: #{message}")
    end
  end

  # A client (frontend) tool call is never dispatched locally — find the
  # named tool in the run's config, park it as pending_tool_call, and tell
  # the model to end its turn. Unknown names (not a client tool, and not
  # submit_result — that's matched by literal name in the dispatch clause
  # above) are rejected the same way the old submit_result-only surface
  # rejected everything else.
  defp handle_client_tool_call(tool_name, arguments, state) do
    state = ensure_api_run_config(state)

    case find_client_tool(state, tool_name) do
      nil ->
        Logger.warning(
          "[MCP] api_run tools/call: rejected name=#{inspect(tool_name)} — not a known " <>
            "client tool/submit_result on this connection"
        )

        {OrcaHub.MCP.Tools.Result.error(unknown_tool_message(tool_name, state)), state}

      tool ->
        {record_pending_tool_call(tool, arguments, state), state}
    end
  end

  defp find_client_tool(%{api_run_config: %{client_tools: client_tools}}, tool_name) do
    Enum.find(client_tools, &(&1["name"] == tool_name))
  end

  defp find_client_tool(_state, _tool_name), do: nil

  defp unknown_tool_message(tool_name, %{
         api_run_config: %{client_tools: client_tools, result_schema: schema}
       }) do
    names =
      Enum.map(client_tools, & &1["name"]) ++ if(is_map(schema), do: ["submit_result"], else: [])

    case names do
      [] -> "Unknown tool: #{tool_name}. This connection exposes no tools."
      _ -> "Unknown tool: #{tool_name}. This connection only exposes #{Enum.join(names, ", ")}."
    end
  end

  defp unknown_tool_message(tool_name, _state) do
    "Unknown tool: #{tool_name}. This connection only exposes submit_result."
  end

  # One frontend tool call in flight at a time: if the model calls a second
  # client tool before the caller has answered the first (e.g. two tool
  # calls in the same turn), only the first is recorded — the second gets
  # an error telling the model to wait.
  defp record_pending_tool_call(tool, arguments, state) do
    case OrcaHub.HubRPC.get_run_by_session_id(state.orca_session_id) do
      nil ->
        OrcaHub.MCP.Tools.Result.error(
          "No matching run found for orca_session_id=#{inspect(state.orca_session_id)}."
        )

      %{pending_tool_call: pending} when is_map(pending) ->
        OrcaHub.MCP.Tools.Result.error(
          "A frontend tool call (#{pending["name"]}, id #{pending["id"]}) is already " <>
            "pending. Call one frontend tool at a time — wait for its result before " <>
            "calling another."
        )

      run ->
        persist_pending_tool_call(run, tool, arguments)
    end
  end

  # The `api_runs.pending_tool_call` column casts as a plain map — arguments
  # are unwrapped back to the caller's raw shape (see wrapped_input_schema/1)
  # before being stored, so the caller sees exactly the shape matching the
  # `input_schema` they supplied, not an internal `{"result": ...}` wrapper.
  defp persist_pending_tool_call(run, tool, arguments) do
    tool_call_id = Ecto.UUID.generate()
    real_arguments = unwrap_wrapped_arguments(arguments, tool["input_schema"])

    pending_tool_call = %{
      "id" => tool_call_id,
      "name" => tool["name"],
      "arguments" => real_arguments
    }

    case OrcaHub.HubRPC.update_api_run(run, %{
           status: "awaiting_tool_result",
           pending_tool_call: pending_tool_call
         }) do
      {:ok, _run} ->
        OrcaHub.MCP.Tools.Result.text(
          "Forwarded #{tool["name"]} (id #{tool_call_id}) to the calling application. " <>
            "END YOUR TURN now and wait — the result will arrive as your next user message."
        )

      {:error, changeset} ->
        Logger.error(
          "[MCP] api_run client tool call: failed to persist pending_tool_call for run " <>
            "#{run.id}: #{inspect(changeset.errors)}"
        )

        OrcaHub.MCP.Tools.Result.error(
          "Tool call recorded but could not be stored: " <> inspect(changeset.errors)
        )
    end
  end

  # The `api_runs.result` column casts as a plain map (see ApiRun schema) —
  # a schema-valid but non-object top-level submission (e.g. a wrapped array
  # schema) fails THIS cast even though it passed JSON Schema validation.
  # Handled as an ordinary tool error rather than crashing the GenServer (the
  # general tools/call dispatcher's try/rescue doesn't cover this clause).
  defp persist_completed_run(run, submission) do
    case OrcaHub.HubRPC.update_api_run(run, %{
           status: "completed",
           result: submission,
           result_text: nil
         }) do
      {:ok, _run} ->
        OrcaHub.MCP.Tools.Result.text("Result accepted.")

      {:error, changeset} ->
        Logger.error(
          "[MCP] api_run submit_result: failed to persist run #{run.id}: " <>
            inspect(changeset.errors)
        )

        OrcaHub.MCP.Tools.Result.error(
          "Result passed schema validation but could not be stored: " <>
            inspect(changeset.errors)
        )
    end
  end

  # Token instrumentation: log the serialized payload size + tool count so the
  # before/after savings of code-exec mode can be measured.
  defp log_tools_list_size(mode, state, tools) do
    bytes = tools |> Jason.encode!() |> byte_size()

    Logger.info(
      "[MCP] tools/list payload: mode=#{mode} orca_session_id=#{inspect(state.orca_session_id)} " <>
        "tool_count=#{length(tools)} payload_bytes=#{bytes}"
    )
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
