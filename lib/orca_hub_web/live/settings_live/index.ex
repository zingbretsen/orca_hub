defmodule OrcaHubWeb.SettingsLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.UpstreamServers
  alias OrcaHub.UpstreamServers.UpstreamServer
  alias OrcaHub.Cluster
  alias OrcaHub.Cluster.CodeSync

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "upstream_servers")
    end

    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       servers: UpstreamServers.list_upstream_servers(),
       upstream_tools: upstream_tools,
       show_form: false,
       editing_server: nil,
       form: to_form(UpstreamServers.change_upstream_server(%UpstreamServer{})),
       header_pairs: [%{key: "", value: ""}],
       cluster_nodes: Cluster.node_info(),
       code_sync_result: nil,
       code_sync_loading: false,
       drift_results: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, show_form: false, editing_server: nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = UpstreamServers.change_upstream_server(%UpstreamServer{})

    socket
    |> assign(
      show_form: true,
      editing_server: nil,
      form: to_form(changeset),
      header_pairs: [%{key: "", value: ""}]
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    server = UpstreamServers.get_upstream_server!(id)
    changeset = UpstreamServers.change_upstream_server(server)

    header_pairs =
      case server.headers do
        headers when is_map(headers) and map_size(headers) > 0 ->
          Enum.map(headers, fn {k, v} -> %{key: k, value: v} end)

        _ ->
          [%{key: "", value: ""}]
      end

    socket
    |> assign(
      show_form: true,
      editing_server: server,
      form: to_form(changeset),
      header_pairs: header_pairs
    )
  end

  @impl true
  def handle_event("validate", %{"upstream_server" => params} = all_params, socket) do
    server = socket.assigns.editing_server || %UpstreamServer{}
    header_pairs = extract_header_pairs(all_params)
    headers = headers_from_pairs(header_pairs)
    params = Map.put(params, "headers", headers)
    changeset = UpstreamServers.change_upstream_server(server, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate), header_pairs: header_pairs)}
  end

  def handle_event("save", %{"upstream_server" => params} = all_params, socket) do
    header_pairs = extract_header_pairs(all_params)
    params = Map.put(params, "headers", headers_from_pairs(header_pairs))

    result =
      case socket.assigns.editing_server do
        nil -> UpstreamServers.create_upstream_server(params)
        server -> UpstreamServers.update_upstream_server(server, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           servers: UpstreamServers.list_upstream_servers(),
           show_form: false,
           editing_server: nil
         )
         |> put_flash(:info, "Upstream server saved")
         |> push_patch(to: ~p"/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    server = UpstreamServers.get_upstream_server!(id)
    {:ok, _} = UpstreamServers.delete_upstream_server(server)

    {:noreply,
     socket
     |> assign(servers: UpstreamServers.list_upstream_servers())
     |> put_flash(:info, "Upstream server deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    server = UpstreamServers.get_upstream_server!(id)
    {:ok, _} = UpstreamServers.update_upstream_server(server, %{enabled: !server.enabled})

    {:noreply, assign(socket, servers: UpstreamServers.list_upstream_servers())}
  end

  def handle_event("toggle_global", %{"id" => id}, socket) do
    server = UpstreamServers.get_upstream_server!(id)
    {:ok, _} = UpstreamServers.update_upstream_server(server, %{global: !server.global})

    {:noreply, assign(socket, servers: UpstreamServers.list_upstream_servers())}
  end

  def handle_event("add_header", _params, socket) do
    pairs = socket.assigns.header_pairs ++ [%{key: "", value: ""}]
    {:noreply, assign(socket, header_pairs: pairs)}
  end

  def handle_event("remove_header", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    pairs = List.delete_at(socket.assigns.header_pairs, idx)
    pairs = if pairs == [], do: [%{key: "", value: ""}], else: pairs
    {:noreply, assign(socket, header_pairs: pairs)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false, editing_server: nil)
     |> push_patch(to: ~p"/settings")}
  end

  def handle_event("push_all_code", _params, socket) do
    socket = assign(socket, code_sync_loading: true)
    send(self(), :do_push_all)
    {:noreply, socket}
  end

  def handle_event("push_changed_code", _params, socket) do
    socket = assign(socket, code_sync_loading: true)
    send(self(), :do_push_changed)
    {:noreply, socket}
  end

  def handle_event("push_to_node", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)
    socket = assign(socket, code_sync_loading: true)
    send(self(), {:do_push_to, target})
    {:noreply, socket}
  end

  def handle_event("check_drift", _params, socket) do
    drift = CodeSync.check_drift()
    {:noreply, assign(socket, drift_results: drift)}
  end

  def handle_event("restart_supervisor", %{"node" => node_str, "supervisor" => sup_str}, socket) do
    target = String.to_existing_atom(node_str)
    supervisor = String.to_existing_atom("Elixir." <> sup_str)

    case CodeSync.restart_supervisor(target, supervisor) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Restarted #{sup_str} on #{Cluster.node_name(target)}")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Failed to restart #{sup_str}: #{msg}")}
    end
  end

  def handle_event("refresh_connections", _params, socket) do
    OrcaHub.MCP.UpstreamClient.refresh()
    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()

    {:noreply,
     socket
     |> assign(upstream_tools: upstream_tools)
     |> put_flash(:info, "Refreshed upstream connections")}
  end

  @impl true
  def handle_info(:do_push_all, socket) do
    result = CodeSync.push_all()
    {:noreply, assign(socket, code_sync_result: result, code_sync_loading: false, cluster_nodes: Cluster.node_info())}
  end

  def handle_info(:do_push_changed, socket) do
    result = CodeSync.push_changed()
    {:noreply, assign(socket, code_sync_result: result, code_sync_loading: false, cluster_nodes: Cluster.node_info())}
  end

  def handle_info({:do_push_to, target}, socket) do
    result = CodeSync.push_to(target)
    {:noreply, assign(socket, code_sync_result: result, code_sync_loading: false, cluster_nodes: Cluster.node_info())}
  end

  def handle_info(:upstream_servers_changed, socket) do
    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()

    {:noreply,
     socket
     |> assign(
       servers: UpstreamServers.list_upstream_servers(),
       upstream_tools: upstream_tools
     )}
  end

  defp extract_header_pairs(params) do
    keys = params["header_keys"] || %{}
    values = params["header_values"] || %{}

    # Filter out LiveView's "_unused_" prefixed keys
    keys =
      keys
      |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_unused_") end)
      |> Map.new()

    if keys == %{} do
      [%{key: "", value: ""}]
    else
      keys
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.map(fn {idx, key} -> %{key: key, value: values[idx] || ""} end)
    end
  end

  defp headers_from_pairs(pairs) do
    pairs
    |> Enum.reject(fn %{key: k} -> k == "" end)
    |> Map.new(fn %{key: k, value: v} -> {k, v} end)
  end

  defp tool_count_for_server(upstream_tools, server) do
    prefix = "#{server.prefix}__"
    Enum.count(upstream_tools, fn tool -> String.starts_with?(tool["name"], prefix) end)
  end
end
