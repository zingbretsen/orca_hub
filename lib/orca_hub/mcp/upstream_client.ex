defmodule OrcaHub.MCP.UpstreamClient do
  @moduledoc """
  GenServer that manages connections to upstream MCP servers.

  Connects to each enabled upstream server via Streamable HTTP transport,
  initializes an MCP session, discovers available tools, and caches them.
  Proxies tool calls to the appropriate upstream server.
  """
  use GenServer
  require Logger

  alias OrcaHub.Mode

  @refresh_interval :timer.minutes(5)
  @rpc_timeout 10_000

  # ETS cache of derived, read-only data (the prefixed tool list and the set of
  # upstream prefixes). Reads go straight to ETS so the hot MCP paths
  # (`tools/list`, `tools/call`) are NEVER gated on this GenServer — which can
  # be blocked for seconds inside a synchronous `connect_all_upstreams/0`
  # refresh doing HTTP to upstream servers. The GenServer owns/writes the table;
  # everyone else reads.
  @tools_cache :orca_upstream_tools_cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # The public API is hub-aware: this GenServer (and its ETS cache) only runs
  # on the hub node (see Application.hub_children/1), but callers — MCP.Server,
  # the code-exec dispatcher, settings LiveView — invoke it as plain local
  # calls on every node. On agent nodes each public function forwards to the
  # hub via :erpc (where Mode.hub?() is true, so the forwarded call takes the
  # local branch), degrading gracefully when the hub is unreachable.

  @doc "Returns all tools from all connected upstream servers, namespaced with their prefix."
  def list_tools do
    if Mode.hub?() do
      case :ets.lookup(@tools_cache, :tools) do
        [{:tools, tools}] -> tools
        _ -> []
      end
    else
      hub_rpc(:list_tools, [], [])
    end
  rescue
    # Table not created yet (GenServer not started / mid-restart).
    ArgumentError -> []
  end

  @doc "Calls a tool on an upstream server. Returns the tool result or {:error, reason}."
  def call_tool(tool_name, arguments) do
    if Mode.hub?() do
      GenServer.call(__MODULE__, {:call_tool, tool_name, arguments}, :infinity)
    else
      # :infinity mirrors the local GenServer call; :erpc still fails fast
      # with noconnection if the hub goes down.
      hub_rpc(
        :call_tool,
        [tool_name, arguments],
        error_result("Upstream client is not available"),
        :infinity
      )
    end
  catch
    :exit, _ -> error_result("Upstream client is not available")
  end

  @doc "Check if a tool name belongs to an upstream server."
  def upstream_tool?(tool_name) do
    if Mode.hub?() do
      case :ets.lookup(@tools_cache, :prefixes) do
        [{:prefixes, prefixes}] -> Enum.any?(prefixes, &String.starts_with?(tool_name, &1))
        _ -> false
      end
    else
      hub_rpc(:upstream_tool?, [tool_name], false)
    end
  rescue
    ArgumentError -> false
  end

  @doc "Force refresh all upstream connections."
  def refresh do
    if Mode.hub?() do
      GenServer.call(__MODULE__, :refresh, 30_000)
    else
      hub_rpc(:refresh, [], :ok, 30_000)
    end
  catch
    :exit, _ -> :ok
  end

  # Forward a public API call to the hub node, falling back to `default` when
  # the hub is unreachable (no hub in cluster, node down, timeout).
  defp hub_rpc(fun, args, default, timeout \\ @rpc_timeout) do
    :erpc.call(Mode.hub_node(), __MODULE__, fun, args, timeout)
  catch
    _, _ -> default
  end

  # Callbacks

  @impl true
  def init(_opts) do
    # `:protected` (default) — owner writes, any process reads; `read_concurrency`
    # because reads (MCP hot path) vastly outnumber the ~5-min writes.
    :ets.new(@tools_cache, [:named_table, :protected, read_concurrency: true])
    put_cache(%{})

    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "upstream_servers")
    send(self(), :connect_all)
    {:ok, %{connections: %{}}}
  end

  @impl true
  def handle_info(:connect_all, state) do
    connections =
      try do
        connect_all_upstreams(state.connections)
      rescue
        # Defensive boundary: connecting touches the DB and remote HTTP
        # servers, both of which can fail in many ways. A failure here must
        # not crash the GenServer — it just leaves connections empty.
        e ->
          Logger.warning("Failed to connect to upstream servers: #{inspect(e)}")
          %{}
      end

    put_cache(connections)
    schedule_refresh()
    {:noreply, %{state | connections: connections}}
  end

  @impl true
  def handle_info(:refresh, state) do
    connections =
      try do
        connect_all_upstreams(state.connections)
      rescue
        # Defensive boundary: keep prior connections on any refresh failure.
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state.connections
      end

    put_cache(connections)
    schedule_refresh()
    {:noreply, %{state | connections: connections}}
  end

  @impl true
  def handle_info(:upstream_servers_changed, state) do
    connections =
      try do
        connect_all_upstreams(state.connections)
      rescue
        # Defensive boundary: keep prior connections on any reconnect failure.
        e ->
          Logger.warning("Failed to connect upstream servers: #{inspect(e)}")
          state.connections
      end

    put_cache(connections)
    {:noreply, %{state | connections: connections}}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, state) do
    result =
      Enum.find_value(
        state.connections,
        {:error, "No upstream server found for tool: #{tool_name}"},
        fn {_id, conn} ->
          prefix = "#{conn.prefix}__"

          if String.starts_with?(tool_name, prefix) do
            original_name = String.replace_prefix(tool_name, prefix, "")
            {:ok, proxy_tool_call(conn, original_name, arguments)}
          end
        end
      )

    case result do
      {:ok, response} -> {:reply, response, state}
      {:error, reason} -> {:reply, error_result(reason), state}
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    connections =
      try do
        connect_all_upstreams(state.connections)
      rescue
        # Defensive boundary: keep prior connections on any refresh failure.
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state.connections
      end

    put_cache(connections)
    {:reply, :ok, %{state | connections: connections}}
  end

  # Private

  # Recompute the derived read-only data from the live connections and publish
  # it to the ETS cache that `list_tools/0` and `upstream_tool?/1` read.
  defp put_cache(connections) do
    tools =
      connections
      |> Enum.sort_by(fn {id, _conn} -> id end)
      |> Enum.flat_map(fn {_id, conn} ->
        Enum.map(conn.tools, fn tool ->
          prefixed_name = "#{conn.prefix}__#{tool["name"]}"

          tool
          |> Map.put("name", prefixed_name)
          |> Map.put("description", "[#{conn.name}] #{tool["description"] || ""}")
        end)
      end)

    prefixes = Enum.map(connections, fn {_id, conn} -> "#{conn.prefix}__" end)

    :ets.insert(@tools_cache, {:tools, tools})
    :ets.insert(@tools_cache, {:prefixes, prefixes})
    :ok
  end

  defp connect_all_upstreams(existing) do
    OrcaHub.UpstreamServers.list_enabled_upstream_servers()
    |> reconcile_connections(existing)
  end

  @doc false
  # Reconcile the enabled server list against the existing connections.
  # Upstream MCP sessions can be stateful (e.g. Playwright MCP ties a browser
  # context to the session), so an existing session is KEPT — not
  # re-initialized — when the server config is unchanged and the session
  # still answers `tools/list`. A fresh `initialize` only happens for new
  # servers, changed configs, or failed health checks. Public for tests only.
  def reconcile_connections(servers, existing) do
    connections =
      Enum.reduce(servers, %{}, fn server, acc ->
        case connect_or_keep(server, Map.get(existing, server.id)) do
          {:ok, conn} ->
            Map.put(acc, server.id, conn)

          {:error, reason} ->
            Logger.warning(
              "Failed to connect to upstream MCP server #{server.name}: #{inspect(reason)}"
            )

            acc
        end
      end)

    # Best-effort cleanup of sessions whose server dropped out of the enabled
    # list, so stateful upstreams can release session-bound resources.
    server_ids = MapSet.new(servers, & &1.id)

    for {id, conn} <- existing, id not in server_ids do
      terminate_session(conn)
    end

    connections
  end

  # No prior connection — fresh connect.
  defp connect_or_keep(server, nil), do: connect_upstream(server)

  defp connect_or_keep(server, conn) do
    cond do
      not same_config?(server, conn) ->
        # Config changed — the old session belongs to the old config; clean
        # it up best-effort and start fresh.
        terminate_session(conn)
        connect_upstream(server)

      true ->
        # Health-check the existing session: a tools/list with the stored
        # session id both verifies liveness and refreshes the cached tools.
        case fetch_tools(conn.url, conn.headers, conn.session_id) do
          {:ok, tools} ->
            {:ok, %{conn | tools: tools}}

          {:error, reason} ->
            # Session presumed dead (e.g. 404 on an expired session) — no
            # DELETE, just re-initialize.
            Logger.info(
              "Upstream session for #{server.name} failed health check " <>
                "(#{inspect(reason)}); re-initializing"
            )

            connect_upstream(server)
        end
    end
  end

  defp same_config?(server, conn) do
    conn.url == server.url and
      conn.name == server.name and
      conn.prefix == (server.prefix || default_prefix(server.name)) and
      conn.headers == build_headers(server.headers)
  end

  # Best-effort HTTP DELETE with the session id so stateful upstreams can
  # clean up. Failures (and sessions without an id) are ignored.
  defp terminate_session(%{session_id: nil}), do: :ok

  defp terminate_session(conn) do
    Req.delete(
      conn.url,
      [headers: [{"mcp-session-id", conn.session_id} | conn.headers]] ++ req_opts()
    )

    :ok
  rescue
    _ -> :ok
  end

  defp connect_upstream(server) do
    headers = build_headers(server.headers)

    with {:ok, session_id, _init_result} <- initialize_session(server.url, headers),
         {:ok, tools} <- fetch_tools(server.url, headers, session_id) do
      Logger.info("Connected to upstream MCP server: #{server.name} (#{length(tools)} tools)")

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

    case Req.post(url, [json: body, headers: headers] ++ req_opts()) do
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

        Req.post(url, [json: notify_body, headers: notify_headers] ++ req_opts())

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

    case Req.post(url, [json: body, headers: req_headers] ++ req_opts()) do
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

    case Req.post(conn.url, [json: body, headers: req_headers] ++ req_opts()) do
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

  # Extra Req options merged into every upstream request — the injection
  # point for `Req.Test` plug stubs in tests.
  defp req_opts, do: Application.get_env(:orca_hub, :upstream_req_options, [])

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
