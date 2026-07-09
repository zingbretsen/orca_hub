defmodule OrcaHubWeb.SettingsLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.BackendAuth
  alias OrcaHub.Cluster
  alias OrcaHub.Cluster.CodeSync
  alias OrcaHub.HubRPC
  alias OrcaHub.UpstreamServers.UpstreamServer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "upstream_servers")
    end

    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()
    cluster_nodes = Cluster.node_info()

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       servers: HubRPC.list_upstream_servers(),
       upstream_tools: upstream_tools,
       show_form: false,
       editing_server: nil,
       form: to_form(HubRPC.change_upstream_server(%UpstreamServer{})),
       header_pairs: [%{key: "", value: ""}],
       cluster_nodes: cluster_nodes,
       code_sync_result: nil,
       code_sync_loading: false,
       drift_results: nil,
       logged_in_nodes: HubRPC.list_logged_in_nodes(),
       login_node: nil,
       login_output: "",
       login_url: nil,
       login_status: nil,
       login_error: nil,
       secret_keys: HubRPC.list_secret_keys(),
       codex_status_by_node: codex_status_map(cluster_nodes),
       codex_env_conflict_by_node: codex_env_conflict_map(cluster_nodes),
       pi_providers_by_node: pi_providers_map(cluster_nodes),
       pi_provider_options: BackendAuth.pi_provider_options(),
       codex_login_node: nil,
       codex_login_mode: nil,
       codex_login_output: "",
       codex_login_url: nil,
       codex_login_code: nil,
       codex_login_status: nil,
       codex_login_error: nil,
       pi_key_node: nil,
       pi_key_sanity: nil
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
    changeset = HubRPC.change_upstream_server(%UpstreamServer{})

    socket
    |> assign(
      show_form: true,
      editing_server: nil,
      form: to_form(changeset),
      header_pairs: [%{key: "", value: ""}]
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    server = HubRPC.get_upstream_server!(id)
    changeset = HubRPC.change_upstream_server(server)

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
    changeset = HubRPC.change_upstream_server(server, params)

    {:noreply,
     assign(socket, form: to_form(changeset, action: :validate), header_pairs: header_pairs)}
  end

  def handle_event("save", %{"upstream_server" => params} = all_params, socket) do
    header_pairs = extract_header_pairs(all_params)
    params = Map.put(params, "headers", headers_from_pairs(header_pairs))

    result =
      case socket.assigns.editing_server do
        nil -> HubRPC.create_upstream_server(params)
        server -> HubRPC.update_upstream_server(server, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           servers: HubRPC.list_upstream_servers(),
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
    server = HubRPC.get_upstream_server!(id)
    {:ok, _} = HubRPC.delete_upstream_server(server)

    {:noreply,
     socket
     |> assign(servers: HubRPC.list_upstream_servers())
     |> put_flash(:info, "Upstream server deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    server = HubRPC.get_upstream_server!(id)
    {:ok, _} = HubRPC.update_upstream_server(server, %{enabled: !server.enabled})

    {:noreply, assign(socket, servers: HubRPC.list_upstream_servers())}
  end

  def handle_event("toggle_global", %{"id" => id}, socket) do
    server = HubRPC.get_upstream_server!(id)
    {:ok, _} = HubRPC.update_upstream_server(server, %{global: !server.global})

    {:noreply, assign(socket, servers: HubRPC.list_upstream_servers())}
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
        {:noreply,
         put_flash(socket, :info, "Restarted #{sup_str} on #{Cluster.node_name(target)}")}

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

  # ── Secrets (OrcaHub-managed, injected into upstream MCP tool calls) ──
  #
  # Strictly write-only: the submitted value is used to call put_secret and
  # then discarded — it is never assigned to socket state, so it can never
  # be rendered back (the in-cluster Playwright browser can reach this UI).

  def handle_event("add_secret", %{"key" => key, "value" => value}, socket) do
    key = String.trim(key)

    if key == "" or value == "" do
      {:noreply, put_flash(socket, :error, "Both a key and a value are required")}
    else
      {:ok, _} = HubRPC.put_secret(key, value)

      {:noreply,
       socket
       |> assign(secret_keys: HubRPC.list_secret_keys())
       |> put_flash(:info, "Secret #{key} saved")}
    end
  end

  def handle_event("delete_secret", %{"key" => key}, socket) do
    {:ok, _} = HubRPC.delete_secret(key)

    {:noreply,
     socket
     |> assign(secret_keys: HubRPC.list_secret_keys())
     |> put_flash(:info, "Secret #{key} deleted")}
  end

  # ── Node login (Claude Code OAuth) ──────────────────────────────────

  def handle_event("login_node", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)

    socket = unsubscribe_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "node_login:#{node_str}")

    socket =
      assign(socket,
        login_node: target,
        login_output: "",
        login_url: nil,
        login_status: :running,
        login_error: nil
      )

    case Cluster.login_node(target) do
      {:ok, _pid} ->
        {:noreply, socket}

      error ->
        {:noreply, assign(socket, login_status: :error, login_error: inspect(error))}
    end
  end

  def handle_event("submit_login_code", %{"code" => code}, socket) do
    if socket.assigns.login_node do
      Cluster.submit_login_code(socket.assigns.login_node, code)
    end

    {:noreply, socket}
  end

  def handle_event("cancel_login", _params, socket) do
    if socket.assigns.login_node do
      Cluster.cancel_login(socket.assigns.login_node)
    end

    {:noreply, close_login(socket)}
  end

  def handle_event("close_login", _params, socket) do
    {:noreply, close_login(socket)}
  end

  def handle_event("logout_node", %{"node" => node_str}, socket) do
    {:ok, _} = HubRPC.delete_node_token(node_str)

    {:noreply,
     socket
     |> assign(logged_in_nodes: HubRPC.list_logged_in_nodes())
     |> put_flash(:info, "Removed stored credential for #{Cluster.node_name(node_str)}")}
  end

  # ── Node login (codex device-auth / API key) ────────────────────────

  def handle_event("codex_login_device", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)

    socket = unsubscribe_codex_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "codex_login:#{node_str}")

    socket =
      assign(socket,
        codex_login_node: target,
        codex_login_mode: :device_auth,
        codex_login_output: "",
        codex_login_url: nil,
        codex_login_code: nil,
        codex_login_status: :running,
        codex_login_error: nil
      )

    case Cluster.login_node_codex_device(target) do
      {:ok, _pid} ->
        {:noreply, socket}

      error ->
        {:noreply, assign(socket, codex_login_status: :error, codex_login_error: inspect(error))}
    end
  end

  def handle_event("codex_login_api_key_open", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)

    socket = unsubscribe_codex_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "codex_login:#{node_str}")

    {:noreply,
     assign(socket,
       codex_login_node: target,
       codex_login_mode: :api_key,
       codex_login_output: "",
       codex_login_url: nil,
       codex_login_code: nil,
       codex_login_status: nil,
       codex_login_error: nil
     )}
  end

  # Strictly write-only, same discipline as add_secret above: `key` is used
  # to start the login flow and then discarded — never assigned to socket
  # state, so it can never be rendered back or leak into a later render.
  def handle_event("submit_codex_api_key", %{"key" => key}, socket) do
    key = String.trim(key)
    node = socket.assigns.codex_login_node

    if node && key != "" do
      case Cluster.login_node_codex_api_key(node, key) do
        {:ok, _pid} ->
          {:noreply, assign(socket, codex_login_status: :running)}

        error ->
          {:noreply,
           assign(socket, codex_login_status: :error, codex_login_error: inspect(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_codex_login", _params, socket) do
    if socket.assigns.codex_login_node do
      Cluster.cancel_codex_login(socket.assigns.codex_login_node)
    end

    {:noreply, close_codex_login(socket)}
  end

  def handle_event("close_codex_login", _params, socket) do
    {:noreply, close_codex_login(socket)}
  end

  # ── pi provider keys ─────────────────────────────────────────────────

  def handle_event("open_pi_keys", %{"node" => node_str}, socket) do
    target = String.to_existing_atom(node_str)
    {:noreply, assign(socket, pi_key_node: target, pi_key_sanity: nil)}
  end

  def handle_event("close_pi_keys", _params, socket) do
    {:noreply, assign(socket, pi_key_node: nil, pi_key_sanity: nil)}
  end

  # Strictly write-only, same discipline as add_secret: `key` is used to
  # call set_pi_key and then discarded — never assigned to socket state.
  def handle_event("save_pi_key", %{"provider" => provider, "key" => key} = params, socket) do
    provider = resolve_pi_provider(provider, params["custom_provider"])
    key = String.trim(key)
    node = socket.assigns.pi_key_node

    cond do
      is_nil(node) ->
        {:noreply, socket}

      provider == "" or key == "" ->
        {:noreply, put_flash(socket, :error, "Both a provider and a key are required")}

      true ->
        case Cluster.set_pi_key(node, provider, key) do
          :ok ->
            {:noreply,
             socket
             |> refresh_pi_providers(node)
             |> assign(pi_key_sanity: pi_sanity_check(node, provider))
             |> put_flash(:info, "Saved #{provider} key for #{Cluster.node_name(node)}")}

          error ->
            {:noreply, put_flash(socket, :error, "Failed to save key: #{inspect(error)}")}
        end
    end
  end

  def handle_event("delete_pi_key", %{"provider" => provider}, socket) do
    node = socket.assigns.pi_key_node

    if node do
      case Cluster.delete_pi_key(node, provider) do
        :ok ->
          {:noreply,
           socket
           |> refresh_pi_providers(node)
           |> put_flash(:info, "Removed #{provider} key")}

        error ->
          {:noreply, put_flash(socket, :error, "Failed to remove key: #{inspect(error)}")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:login_output, text}, socket) do
    {:noreply, assign(socket, login_output: text)}
  end

  def handle_info({:login_url, url}, socket) do
    {:noreply, assign(socket, login_url: url, login_status: :awaiting_code)}
  end

  def handle_info({:login_status, status}, socket) do
    # Don't downgrade a terminal status (success/error) from a late event.
    if socket.assigns.login_status in [:success, :error] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, login_status: status)}
    end
  end

  def handle_info({:login_done, :success}, socket) do
    {:noreply,
     socket
     |> assign(login_status: :success, logged_in_nodes: HubRPC.list_logged_in_nodes())}
  end

  def handle_info({:login_done, {:error, msg}}, socket) do
    {:noreply, assign(socket, login_status: :error, login_error: msg)}
  end

  def handle_info({:codex_login_output, text}, socket) do
    {:noreply, assign(socket, codex_login_output: text)}
  end

  def handle_info({:codex_login_url, url}, socket) do
    {:noreply, assign(socket, codex_login_url: url)}
  end

  def handle_info({:codex_login_code, code}, socket) do
    {:noreply, assign(socket, codex_login_code: code)}
  end

  def handle_info({:codex_login_status, status}, socket) do
    if socket.assigns.codex_login_status in [:success, :error] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, codex_login_status: status)}
    end
  end

  def handle_info({:codex_login_done, :success}, socket) do
    node = socket.assigns.codex_login_node

    {:noreply,
     socket
     |> assign(codex_login_status: :success)
     |> refresh_codex_status(node)}
  end

  def handle_info({:codex_login_done, {:error, msg}}, socket) do
    {:noreply, assign(socket, codex_login_status: :error, codex_login_error: msg)}
  end

  def handle_info(:do_push_all, socket) do
    result = CodeSync.push_all()

    {:noreply,
     assign(socket,
       code_sync_result: result,
       code_sync_loading: false,
       cluster_nodes: Cluster.node_info()
     )}
  end

  def handle_info(:do_push_changed, socket) do
    result = CodeSync.push_changed()

    {:noreply,
     assign(socket,
       code_sync_result: result,
       code_sync_loading: false,
       cluster_nodes: Cluster.node_info()
     )}
  end

  def handle_info({:do_push_to, target}, socket) do
    result = CodeSync.push_to(target)

    {:noreply,
     assign(socket,
       code_sync_result: result,
       code_sync_loading: false,
       cluster_nodes: Cluster.node_info()
     )}
  end

  def handle_info(:upstream_servers_changed, socket) do
    upstream_tools = OrcaHub.MCP.UpstreamClient.list_tools()

    {:noreply,
     socket
     |> assign(
       servers: HubRPC.list_upstream_servers(),
       upstream_tools: upstream_tools,
       secret_keys: HubRPC.list_secret_keys()
     )}
  end

  defp unsubscribe_login(socket) do
    if node = socket.assigns[:login_node] do
      Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "node_login:#{node}")
    end

    socket
  end

  defp close_login(socket) do
    socket
    |> unsubscribe_login()
    |> assign(
      login_node: nil,
      login_output: "",
      login_url: nil,
      login_status: nil,
      login_error: nil,
      logged_in_nodes: HubRPC.list_logged_in_nodes()
    )
  end

  defp unsubscribe_codex_login(socket) do
    if node = socket.assigns[:codex_login_node] do
      Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "codex_login:#{node}")
    end

    socket
  end

  defp close_codex_login(socket) do
    socket
    |> unsubscribe_codex_login()
    |> assign(
      codex_login_node: nil,
      codex_login_mode: nil,
      codex_login_output: "",
      codex_login_url: nil,
      codex_login_code: nil,
      codex_login_status: nil,
      codex_login_error: nil
    )
  end

  defp codex_status_map(cluster_nodes) do
    Map.new(cluster_nodes, fn info ->
      status =
        case Cluster.codex_status(info.node) do
          %{} = s -> s
          _ -> %{status: :not_logged_in, label: "Not logged in"}
        end

      {"#{info.node}", status}
    end)
  end

  defp codex_env_conflict_map(cluster_nodes) do
    Map.new(cluster_nodes, fn info ->
      {"#{info.node}", Cluster.codex_env_conflict?(info.node) == true}
    end)
  end

  defp pi_providers_map(cluster_nodes) do
    Map.new(cluster_nodes, fn info ->
      providers =
        case Cluster.list_pi_providers(info.node) do
          list when is_list(list) -> list
          _ -> []
        end

      {"#{info.node}", providers}
    end)
  end

  defp refresh_codex_status(socket, node) do
    status =
      case Cluster.codex_status(node) do
        %{} = s -> s
        _ -> %{status: :not_logged_in, label: "Not logged in"}
      end

    update(socket, :codex_status_by_node, &Map.put(&1, "#{node}", status))
  end

  defp refresh_pi_providers(socket, node) do
    providers =
      case Cluster.list_pi_providers(node) do
        list when is_list(list) -> list
        _ -> []
      end

    update(socket, :pi_providers_by_node, &Map.put(&1, "#{node}", providers))
  end

  defp resolve_pi_provider("custom", custom) when is_binary(custom) do
    custom |> String.trim() |> String.downcase()
  end

  defp resolve_pi_provider(provider, _custom), do: provider

  # Optional, non-blocking sanity check (docs/codex_pi_auth_research.md §6):
  # `pi --list-models` only enumerates providers that already have working
  # credentials, so if the provider we just saved shows up, the key is at
  # least well-formed enough for pi to use.
  defp pi_sanity_check(node, provider) do
    case Cluster.rpc(node, OrcaHub.Backend.Pi, :models, []) do
      models when is_list(models) ->
        if Enum.any?(models, fn {id, _label} -> String.starts_with?(id, "#{provider}/") end) do
          {:ok, "pi --list-models now sees #{provider}"}
        else
          {:warn, "pi --list-models doesn't show #{provider} yet — double-check the key"}
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
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
