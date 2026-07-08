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

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OrcaHub.MCPSupervisor,
        {__MODULE__,
         session_id: session_id,
         orca_session_id: orca_session_id,
         orchestrator: orchestrator,
         code_exec: code_exec}
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

    Logger.info(
      "[MCP] session start: mcp_session_id=#{session_id} " <>
        "orca_session_id=#{inspect(orca_session_id)} orchestrator=#{orchestrator} " <>
        "code_exec=#{code_exec}"
    )

    # `initialize` does NO hub work. The connection role (orchestrator?) is
    # carried by the MCP connection itself (a query param set by
    # SessionRunner) rather than resolved via a hub/DB lookup. This keeps the
    # MCP handshake fast — no erpc, no DB — so tools/list is ready before the
    # model emits its first tool call, and a hub outage can't strip the
    # orchestrator tool set.
    {:ok,
     %{
       session_id: session_id,
       orca_session_id: orca_session_id,
       orchestrator: orchestrator,
       code_exec: code_exec,
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
  # connections — used as a smoking-gun check in the tools/list log line.
  @orchestrator_only_tools ~w(cancel_heartbeat archive_session start_session schedule_heartbeat)

  # Code-exec mode: collapse the surface to just the meta-tools (run_elixir,
  # search_tools). First-party + upstream tools are no longer
  # flattened here — they're reachable only as `Tools.*` functions inside
  # run_elixir. When the flag is OFF this clause never matches and tools/list
  # behaves exactly as before.
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

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}
    upstream? = OrcaHub.MCP.UpstreamClient.upstream_tool?(tool_name)

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
