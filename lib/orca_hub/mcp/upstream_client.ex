defmodule OrcaHub.MCP.UpstreamClient do
  @moduledoc """
  GenServer that manages connections to upstream MCP servers.

  Connects to each enabled upstream server via Streamable HTTP transport,
  initializes an MCP session, discovers available tools, and caches them.
  Proxies tool calls to the appropriate upstream server.

  ## Session scoping

  Servers with `session_scoped: true` get one upstream MCP session **per Orca
  session** instead of a single shared one, so stateful upstreams (e.g.
  Playwright, which ties an isolated browser context to each MCP session) are
  isolated per Orca session. Scoped sessions live in `state.scoped`, keyed by
  `{server_id, orca_session_id}`; they are created lazily on the first
  `call_tool/3` carrying an `:orca_session_id`, reused afterwards, and cleaned
  up by: an idle TTL sweep, an LRU cap per server, eager teardown when the
  Orca session is archived, and teardown on server config change/removal.
  A scoped call whose upstream session has expired (e.g. HTTP 404) is
  re-initialized once and retried. Calls without an `:orca_session_id` — and
  all calls to non-scoped servers — use the shared session as before.
  """
  use GenServer
  require Logger

  alias OrcaHub.Mode

  @refresh_interval :timer.minutes(5)
  @rpc_timeout 10_000
  @scoped_sweep_interval :timer.minutes(5)
  @scoped_idle_ttl :timer.minutes(30)
  @max_scoped_per_server 20

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

  @doc """
  Calls a tool on an upstream server. Returns the tool result map.

  Options:

    * `:orca_session_id` — the calling Orca session's id. For servers with
      `session_scoped: true` this selects (lazily creating) that Orca
      session's own upstream MCP session; without it, scoped servers fall
      back to the shared session.
  """
  def call_tool(tool_name, arguments, opts \\ []) do
    if Mode.hub?() do
      GenServer.call(__MODULE__, {:call_tool, tool_name, arguments, opts}, :infinity)
    else
      # :infinity mirrors the local GenServer call; :erpc still fails fast
      # with noconnection if the hub goes down.
      hub_rpc(
        :call_tool,
        [tool_name, arguments, opts],
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
    # "sessions" carries every session's status/event stream; we only care
    # about {:status, :archived} for eager scoped-session teardown.
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    send(self(), :connect_all)
    schedule_scoped_sweep()
    {:ok, %{connections: %{}, scoped: %{}}}
  end

  @impl true
  def handle_info(:connect_all, state) do
    state =
      try do
        reconnect(state)
      rescue
        # Defensive boundary: connecting touches the DB and remote HTTP
        # servers, both of which can fail in many ways. A failure here must
        # not crash the GenServer — it just leaves connections empty.
        e ->
          Logger.warning("Failed to connect to upstream servers: #{inspect(e)}")
          put_cache(%{})
          %{state | connections: %{}}
      end

    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state =
      try do
        reconnect(state)
      rescue
        # Defensive boundary: keep prior connections on any refresh failure.
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state
      end

    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:upstream_servers_changed, state) do
    state =
      try do
        reconnect(state)
      rescue
        # Defensive boundary: keep prior connections on any reconnect failure.
        e ->
          Logger.warning("Failed to connect upstream servers: #{inspect(e)}")
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep_scoped, state) do
    scoped = sweep_scoped(state.scoped, System.monotonic_time(:millisecond))
    schedule_scoped_sweep()
    {:noreply, %{state | scoped: scoped}}
  end

  # Eager scoped-session teardown: an archived Orca session no longer needs
  # its per-session upstream sessions (e.g. its Playwright browser context).
  @impl true
  def handle_info({session_id, {:status, :archived}}, state) when is_binary(session_id) do
    {:noreply, %{state | scoped: drop_scoped_for_session(state.scoped, session_id)}}
  end

  # Ignore the rest of the "sessions" topic traffic (events, other statuses).
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:call_tool, tool_name, arguments, opts}, _from, state) do
    {result, scoped} =
      dispatch_call(state.connections, state.scoped, tool_name, arguments, opts)

    {:reply, result, %{state | scoped: scoped}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state =
      try do
        reconnect(state)
      rescue
        # Defensive boundary: keep prior connections on any refresh failure.
        e ->
          Logger.warning("Failed to refresh upstream connections: #{inspect(e)}")
          state
      end

    {:reply, :ok, state}
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

  # Reconcile shared connections against the DB, then drop scoped sessions
  # whose server changed config or disappeared. Scoped sessions on unchanged
  # servers are deliberately NOT health-checked or torn down here — call-time
  # retry (see `scoped_call/5`) covers expiry.
  defp reconnect(state) do
    connections =
      OrcaHub.UpstreamServers.list_enabled_upstream_servers()
      |> reconcile_connections(state.connections)

    put_cache(connections)
    %{state | connections: connections, scoped: reconcile_scoped(state.scoped, connections)}
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
            # `session_scoped` isn't part of same_config? (flipping it must
            # not kill the shared session), so re-read it from the DB row.
            {:ok, %{conn | tools: tools, session_scoped: server.session_scoped}}

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
         session_scoped: server.session_scoped,
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

  @doc false
  # Route a tool call to its connection and — for session-scoped servers with
  # a known orca_session_id — to that Orca session's own upstream session.
  # Returns {result_map, new_scoped}. Public for tests only.
  def dispatch_call(connections, scoped, tool_name, arguments, opts \\ []) do
    orca_session_id = Keyword.get(opts, :orca_session_id)

    case find_connection(connections, tool_name) do
      nil ->
        {error_result("No upstream server found for tool: #{tool_name}"), scoped}

      {conn, original_name} ->
        if conn.session_scoped and is_binary(orca_session_id) do
          scoped_call(conn, scoped, orca_session_id, original_name, arguments)
        else
          # Non-scoped server, or a scoped call without an orca_session_id —
          # fall back to the shared session.
          {unwrap_proxy(
             proxy_tool_call(conn.url, conn.headers, conn.session_id, original_name, arguments)
           ), scoped}
        end
    end
  end

  defp find_connection(connections, tool_name) do
    Enum.find_value(connections, fn {_id, conn} ->
      prefix = "#{conn.prefix}__"

      if String.starts_with?(tool_name, prefix) do
        {conn, String.replace_prefix(tool_name, prefix, "")}
      end
    end)
  end

  # ── Scoped sessions ───────────────────────────────────────────────────
  #
  # Scoped entries are %{server_id, session_id, url, headers, last_used_at,
  # lru} keyed by {server_id, orca_session_id}. `url`/`headers` are
  # snapshotted at creation so the entry can be DELETEd even after the server
  # config changes. `last_used_at` (monotonic ms) drives the idle TTL;
  # `lru` (a monotonic unique_integer) breaks ties for cap eviction, since
  # millisecond timestamps collide for back-to-back calls.

  defp scoped_call(conn, scoped, orca_session_id, tool_name, arguments) do
    key = {conn.id, orca_session_id}

    case Map.fetch(scoped, key) do
      {:ok, entry} ->
        case proxy_tool_call(conn.url, conn.headers, entry.session_id, tool_name, arguments) do
          {:ok, result} ->
            {result, touch_scoped(scoped, key)}

          {:error, reason} ->
            # Scoped session presumed expired (e.g. 404) — no DELETE, just
            # re-initialize once and retry the call.
            Logger.info(
              "Scoped upstream session for #{conn.name}/#{orca_session_id} failed " <>
                "(#{inspect(reason)}); re-initializing"
            )

            create_scoped_and_call(conn, Map.delete(scoped, key), key, tool_name, arguments)
        end

      :error ->
        create_scoped_and_call(conn, scoped, key, tool_name, arguments)
    end
  end

  defp create_scoped_and_call(conn, scoped, key, tool_name, arguments) do
    scoped = evict_over_cap(scoped, conn)

    case initialize_session(conn.url, conn.headers) do
      {:ok, session_id, _init_result} ->
        {_server_id, orca_session_id} = key
        Logger.info("Opened scoped upstream session for #{conn.name}/#{orca_session_id}")

        entry = %{
          server_id: conn.id,
          session_id: session_id,
          url: conn.url,
          headers: conn.headers,
          last_used_at: System.monotonic_time(:millisecond),
          lru: System.unique_integer([:monotonic])
        }

        # Even if this first call fails, keep the entry — the upstream
        # session exists and must stay tracked for cleanup.
        result =
          unwrap_proxy(proxy_tool_call(conn.url, conn.headers, session_id, tool_name, arguments))

        {result, Map.put(scoped, key, entry)}

      {:error, reason} ->
        {error_result("Failed to initialize upstream session: #{inspect(reason)}"), scoped}
    end
  end

  # Enforce the per-server cap BEFORE adding a new scoped session: evict the
  # least-recently-used entry for this server, with a best-effort DELETE.
  defp evict_over_cap(scoped, conn) do
    entries = Enum.filter(scoped, fn {{server_id, _}, _} -> server_id == conn.id end)

    if length(entries) >= @max_scoped_per_server do
      {key, entry} = Enum.min_by(entries, fn {_key, e} -> e.lru end)

      Logger.info(
        "Evicting LRU scoped upstream session for #{conn.name} (cap #{@max_scoped_per_server})"
      )

      terminate_session(entry)
      Map.delete(scoped, key)
    else
      scoped
    end
  end

  defp touch_scoped(scoped, key) do
    Map.update!(scoped, key, fn entry ->
      %{
        entry
        | last_used_at: System.monotonic_time(:millisecond),
          lru: System.unique_integer([:monotonic])
      }
    end)
  end

  @doc false
  # Drop (with best-effort DELETE) scoped sessions idle longer than `ttl`.
  # `now` is monotonic milliseconds. Public for tests only.
  def sweep_scoped(scoped, now, ttl \\ @scoped_idle_ttl) do
    {expired, kept} =
      Enum.split_with(scoped, fn {_key, entry} -> now - entry.last_used_at >= ttl end)

    Enum.each(expired, fn {_key, entry} -> terminate_session(entry) end)
    Map.new(kept)
  end

  @doc false
  # Drop (with best-effort DELETE) all scoped sessions belonging to an
  # archived Orca session. Public for tests only.
  def drop_scoped_for_session(scoped, orca_session_id) do
    {dropped, kept} =
      Enum.split_with(scoped, fn {{_server_id, osid}, _entry} -> osid == orca_session_id end)

    Enum.each(dropped, fn {_key, entry} -> terminate_session(entry) end)
    Map.new(kept)
  end

  @doc false
  # Keep scoped sessions only for servers still connected, still scoped, and
  # with unchanged url/headers; DELETE the rest. Public for tests only.
  def reconcile_scoped(scoped, connections) do
    {kept, dropped} =
      Enum.split_with(scoped, fn {{server_id, _osid}, entry} ->
        case Map.get(connections, server_id) do
          nil -> false
          conn -> conn.session_scoped and conn.url == entry.url and conn.headers == entry.headers
        end
      end)

    Enum.each(dropped, fn {_key, entry} -> terminate_session(entry) end)
    Map.new(kept)
  end

  # ── Proxying ──────────────────────────────────────────────────────────

  # Returns {:ok, result_map} for any well-formed MCP response (including
  # tool-level errors, which come back as error_result maps — those are NOT
  # session failures) and {:error, reason} for HTTP/transport failures, which
  # for scoped sessions signal a presumed-expired session worth a retry.
  defp proxy_tool_call(url, headers, session_id, tool_name, arguments) do
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
      if session_id do
        [{"mcp-session-id", session_id} | headers]
      else
        headers
      end

    case Req.post(url, [json: body, headers: req_headers] ++ req_opts()) do
      {:ok, %{status: 200, body: raw_body}} ->
        case parse_body(raw_body) do
          %{"result" => result} ->
            {:ok, result}

          %{"error" => error} ->
            {:ok, error_result("Upstream error: #{error["message"] || inspect(error)}")}

          other ->
            {:ok, error_result("Unexpected upstream response: #{inspect(other)}")}
        end

      {:ok, resp} ->
        {:error, {:http, resp.status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp unwrap_proxy({:ok, result}), do: result
  defp unwrap_proxy({:error, {:http, status}}), do: error_result("Upstream HTTP #{status}")

  defp unwrap_proxy({:error, {:transport, reason}}),
    do: error_result("Upstream request failed: #{inspect(reason)}")

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

  defp schedule_scoped_sweep do
    Process.send_after(self(), :sweep_scoped, @scoped_sweep_interval)
  end
end
