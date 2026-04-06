defmodule OrcaHub.MCP.UpstreamClient do
  @moduledoc """
  GenServer that manages connections to upstream MCP servers.

  Connects to each enabled upstream server via Streamable HTTP transport,
  initializes an MCP session, discovers available tools, and caches them.
  Proxies tool calls to the appropriate upstream server.
  """
  use GenServer
  require Logger

  @refresh_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all tools from all connected upstream servers, namespaced with their prefix."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  catch
    :exit, _ -> []
  end

  @doc "Calls a tool on an upstream server. Returns the tool result or {:error, reason}."
  def call_tool(tool_name, arguments) do
    GenServer.call(__MODULE__, {:call_tool, tool_name, arguments}, :infinity)
  catch
    :exit, _ -> error_result("Upstream client is not available")
  end

  @doc "Check if a tool name belongs to an upstream server."
  def upstream_tool?(tool_name) do
    GenServer.call(__MODULE__, {:upstream_tool?, tool_name})
  catch
    :exit, _ -> false
  end

  @doc "Force refresh all upstream connections."
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  catch
    :exit, _ -> :ok
  end

  # Callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "upstream_servers")
    send(self(), :connect_all)
    {:ok, %{connections: %{}}}
  end

  @impl true
  def handle_info(:connect_all, state) do
    connections =
      try do
        connect_all_upstreams()
      rescue
        e ->
          Logger.warning("Failed to connect to upstream servers: #{inspect(e)}")
          %{}
      end

    schedule_refresh()
    {:noreply, %{state | connections: connections}}
  end

  def handle_info(:refresh, state) do
    connections =
      try do
        connect_all_upstreams()
      rescue
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state.connections
      end

    schedule_refresh()
    {:noreply, %{state | connections: connections}}
  end

  def handle_info(:upstream_servers_changed, state) do
    connections =
      try do
        connect_all_upstreams()
      rescue
        e ->
          Logger.warning("Failed to connect upstream servers: #{inspect(e)}")
          state.connections
      end

    {:noreply, %{state | connections: connections}}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools =
      state.connections
      |> Enum.sort_by(fn {id, _conn} -> id end)
      |> Enum.flat_map(fn {_id, conn} ->
        Enum.map(conn.tools, fn tool ->
          prefixed_name = "#{conn.prefix}__#{tool["name"]}"

          tool
          |> Map.put("name", prefixed_name)
          |> Map.put("description", "[#{conn.name}] #{tool["description"] || ""}")
        end)
      end)

    {:reply, tools, state}
  end

  def handle_call({:upstream_tool?, tool_name}, _from, state) do
    result =
      Enum.any?(state.connections, fn {_id, conn} ->
        String.starts_with?(tool_name, "#{conn.prefix}__")
      end)

    {:reply, result, state}
  end

  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    result =
      Enum.find_value(state.connections, {:error, "No upstream server found for tool: #{tool_name}"}, fn {_id, conn} ->
        prefix = "#{conn.prefix}__"

        if String.starts_with?(tool_name, prefix) do
          original_name = String.replace_prefix(tool_name, prefix, "")
          {:ok, proxy_tool_call(conn, original_name, arguments)}
        end
      end)

    case result do
      {:ok, response} -> {:reply, response, state}
      {:error, reason} -> {:reply, error_result(reason), state}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    connections =
      try do
        connect_all_upstreams()
      rescue
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state.connections
      end

    {:reply, :ok, %{state | connections: connections}}
  end

  # Private

  defp connect_all_upstreams do
    OrcaHub.UpstreamServers.list_enabled_upstream_servers()
    |> Enum.reduce(%{}, fn server, acc ->
      case connect_upstream(server) do
        {:ok, conn} ->
          Logger.info("Connected to upstream MCP server: #{server.name} (#{length(conn.tools)} tools)")
          Map.put(acc, server.id, conn)

        {:error, reason} ->
          Logger.warning("Failed to connect to upstream MCP server #{server.name}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp connect_upstream(server) do
    headers = build_headers(server.headers)

    with {:ok, session_id, _init_result} <- initialize_session(server.url, headers),
         {:ok, tools} <- fetch_tools(server.url, headers, session_id) do
      {:ok,
       %{
         id: server.id,
         name: server.name,
         url: server.url,
         prefix: server.prefix || default_prefix(server.name),
         headers: headers,
         session_id: session_id,
         tools: tools
       }}
    end
  end

  defp initialize_session(url, headers) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "OrcaHub",
          "version" => "0.1.0"
        }
      }
    }

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: 200, headers: resp_headers} = resp} ->
        session_id = get_header(resp_headers, "mcp-session-id")

        # Send initialized notification
        notify_body = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        }

        notify_headers =
          if session_id do
            [{"mcp-session-id", session_id} | headers]
          else
            headers
          end

        Req.post(url, json: notify_body, headers: notify_headers)

        {:ok, session_id, parse_body(resp.body)}

      {:ok, resp} ->
        {:error, "HTTP #{resp.status}: #{inspect(resp.body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_tools(url, headers, session_id) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list"
    }

    req_headers =
      if session_id do
        [{"mcp-session-id", session_id} | headers]
      else
        headers
      end

    case Req.post(url, json: body, headers: req_headers) do
      {:ok, %{status: 200, body: raw_body}} ->
        case parse_body(raw_body) do
          %{"result" => %{"tools" => tools}} ->
            {:ok, tools}

          other ->
            Logger.warning("Unexpected tools/list response: #{inspect(other)}")
            {:ok, []}
        end

      {:ok, resp} ->
        {:error, "HTTP #{resp.status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp proxy_tool_call(conn, tool_name, arguments) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    }

    req_headers =
      if conn.session_id do
        [{"mcp-session-id", conn.session_id} | conn.headers]
      else
        conn.headers
      end

    case Req.post(conn.url, json: body, headers: req_headers) do
      {:ok, %{status: 200, body: raw_body}} ->
        case parse_body(raw_body) do
          %{"result" => result} ->
            result

          %{"error" => error} ->
            error_result("Upstream error: #{error["message"] || inspect(error)}")

          other ->
            error_result("Unexpected upstream response: #{inspect(other)}")
        end

      {:ok, resp} ->
        error_result("Upstream HTTP #{resp.status}")

      {:error, reason} ->
        error_result("Upstream request failed: #{inspect(reason)}")
    end
  end

  defp build_headers(nil), do: base_headers()

  defp build_headers(headers) when is_map(headers) do
    custom =
      Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    base_headers() ++ custom
  end

  defp base_headers do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]
  end

  defp get_header(headers, name) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(to_string(k)) == name end) do
      {_, value} when is_list(value) -> List.first(value)
      {_, value} -> value
      nil -> nil
    end
  end

  defp default_prefix(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  # Parse response body — handles both JSON (map) and SSE (string) formats
  defp parse_body(body) when is_map(body), do: body

  defp parse_body(body) when is_binary(body) do
    # SSE format: "event: message\r\ndata: {json}\r\n\r\n"
    body
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      case line do
        "data: " <> json_str ->
          case Jason.decode(json_str) do
            {:ok, decoded} -> decoded
            _ -> nil
          end

        _ ->
          nil
      end
    end) || %{}
  end

  defp parse_body(_), do: %{}

  defp error_result(message) do
    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
