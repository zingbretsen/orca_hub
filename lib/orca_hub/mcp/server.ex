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

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OrcaHub.MCPSupervisor,
        {__MODULE__, session_id: session_id, orca_session_id: orca_session_id}
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
    {:ok, %{session_id: session_id, orca_session_id: orca_session_id, initialized: false}}
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

  defp dispatch(%{"method" => "tools/list", "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => Tools.list()
      }
    }

    {response, state}
  end

  defp dispatch(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    result = Tools.call(tool_name, arguments, state)

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }

    {response, state}
  end

  defp dispatch(%{"method" => method, "id" => id}, state) do
    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not found: #{method}"
      }
    }

    {response, state}
  end

  # Notification we don't handle — just accept
  defp dispatch(%{"method" => _}, state) do
    {:accepted, state}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
