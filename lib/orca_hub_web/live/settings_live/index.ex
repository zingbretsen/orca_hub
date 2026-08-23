defmodule OrcaHubWeb.SettingsLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.ApiTokens.ApiToken
  alias OrcaHub.Cluster
  alias OrcaHub.Cluster.CodeSync
  alias OrcaHub.EmailInboxes.EmailInbox
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
       node_records: node_records_map(cluster_nodes),
       code_sync_result: nil,
       code_sync_loading: false,
       drift_results: nil,
       secret_keys: HubRPC.list_secret_keys(),
       email_inboxes: HubRPC.list_email_inboxes(),
       show_inbox_form: false,
       editing_inbox: nil,
       inbox_form: to_form(HubRPC.change_email_inbox(%EmailInbox{})),
       api_tokens: HubRPC.list_api_tokens(),
       show_token_form: false,
       token_form: to_form(HubRPC.change_api_token(%ApiToken{}, %{"scopes" => []})),
       revealed_secret: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Any patch navigation (saving/cancelling an unrelated form on this same
    # page) counts as "any further action" per the API-token secret-reveal
    # contract — clear it here rather than at each individual call site.
    socket = assign(socket, revealed_secret: nil)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      show_form: false,
      editing_server: nil,
      show_inbox_form: false,
      editing_inbox: nil
    )
  end

  defp apply_action(socket, :new, _params) do
    changeset = HubRPC.change_upstream_server(%UpstreamServer{})

    socket
    |> assign(
      show_form: true,
      editing_server: nil,
      form: to_form(changeset),
      header_pairs: [%{key: "", value: ""}],
      show_inbox_form: false,
      editing_inbox: nil
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
      header_pairs: header_pairs,
      show_inbox_form: false,
      editing_inbox: nil
    )
  end

  defp apply_action(socket, :new_inbox, _params) do
    changeset = HubRPC.change_email_inbox(%EmailInbox{})

    socket
    |> assign(show_form: false, editing_server: nil)
    |> assign(show_inbox_form: true, editing_inbox: nil, inbox_form: to_form(changeset))
  end

  defp apply_action(socket, :edit_inbox, %{"id" => id}) do
    inbox = HubRPC.get_email_inbox!(id)
    changeset = HubRPC.change_email_inbox(inbox)

    socket
    |> assign(show_form: false, editing_server: nil)
    |> assign(show_inbox_form: true, editing_inbox: inbox, inbox_form: to_form(changeset))
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

  # ── Email Inboxes (IMAP mailboxes polled for inbound email triggers) ──
  #
  # The password field is strictly write-only, same posture as Secrets
  # above: `EmailInbox.changeset/2`'s virtual `:password` is cast straight
  # into `:password_encrypted` and dropped, so it is never assigned back
  # into `inbox_form` here.
  #
  # A blank submit on the EDIT form means "unchanged" — but the schema casts
  # `:password` with `empty_values: []` deliberately (an explicit blank is a
  # real "can't be blank" error on CREATE, not a silent no-op), so an empty
  # string here would be read as "the user is explicitly clearing it" rather
  # than "left untouched". `drop_blank_password_on_edit/2` is what actually
  # implements "unchanged" for an edit: it removes the key entirely so the
  # changeset never sees a change to cast in the first place.

  def handle_event("validate_inbox", %{"email_inbox" => params}, socket) do
    inbox = socket.assigns.editing_inbox || %EmailInbox{}
    params = drop_blank_password_on_edit(params, socket.assigns.editing_inbox)
    changeset = HubRPC.change_email_inbox(inbox, params)
    {:noreply, assign(socket, inbox_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_inbox", %{"email_inbox" => params}, socket) do
    params = drop_blank_password_on_edit(params, socket.assigns.editing_inbox)

    result =
      case socket.assigns.editing_inbox do
        nil -> HubRPC.create_email_inbox(params)
        inbox -> HubRPC.update_email_inbox(inbox, params)
      end

    case result do
      {:ok, inbox} ->
        # Starts a poller immediately for a newly-created (or just
        # re-enabled) inbox; a no-op otherwise — see EmailInboxLoader.sync/0.
        if inbox.enabled, do: HubRPC.sync_email_inbox_pollers()

        {:noreply,
         socket
         |> assign(
           email_inboxes: HubRPC.list_email_inboxes(),
           show_inbox_form: false,
           editing_inbox: nil
         )
         |> put_flash(:info, "Email inbox saved")
         |> push_patch(to: ~p"/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, inbox_form: to_form(changeset))}
    end
  end

  def handle_event("delete_inbox", %{"id" => id}, socket) do
    inbox = HubRPC.get_email_inbox!(id)
    {:ok, _} = HubRPC.delete_email_inbox(inbox)

    {:noreply,
     socket
     |> assign(email_inboxes: HubRPC.list_email_inboxes())
     |> put_flash(:info, "Email inbox deleted")}
  end

  def handle_event("toggle_inbox", %{"id" => id}, socket) do
    inbox = HubRPC.get_email_inbox!(id)
    {:ok, inbox} = HubRPC.update_email_inbox(inbox, %{enabled: !inbox.enabled})

    if inbox.enabled, do: HubRPC.sync_email_inbox_pollers()

    {:noreply, assign(socket, email_inboxes: HubRPC.list_email_inboxes())}
  end

  def handle_event("cancel_inbox", _params, socket) do
    {:noreply,
     socket
     |> assign(show_inbox_form: false, editing_inbox: nil)
     |> push_patch(to: ~p"/settings")}
  end

  # Reads the CURRENT (possibly-unsaved) form state out of `inbox_form`
  # rather than requiring its own params — `inbox_form` is already kept live
  # by "validate_inbox" on every keystroke, so this works identically for a
  # brand-new inbox and an edit-in-progress. Connects, authenticates, and
  # SELECTs the folder on the HUB (EmailInboxes.test_connection/1 ->
  # ImapClient.test_connection/1); never fetches or mutates messages.
  def handle_event("test_inbox_connection", _params, socket) do
    form = socket.assigns.inbox_form

    attrs = %{
      host: Phoenix.HTML.Form.input_value(form, :host) |> blank_to_nil(),
      port: Phoenix.HTML.Form.input_value(form, :port) || 993,
      tls: tls_value(form),
      username: Phoenix.HTML.Form.input_value(form, :username) |> blank_to_nil(),
      folder: Phoenix.HTML.Form.input_value(form, :folder) |> blank_to_nil() || "INBOX",
      password: Phoenix.HTML.Form.input_value(form, :password) |> blank_to_nil()
    }

    attrs =
      case socket.assigns.editing_inbox do
        nil -> attrs
        inbox -> Map.put(attrs, :inbox_id, inbox.id)
      end

    socket =
      case validate_test_attrs(attrs) do
        :ok ->
          case safe_test_connection(attrs) do
            :ok ->
              put_flash(
                socket,
                :info,
                ~s(Connected to #{attrs.host}:#{attrs.port} and selected "#{attrs.folder}" successfully.)
              )

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                "Connection test failed: #{format_connection_error(reason)}"
              )
          end

        {:error, message} ->
          put_flash(socket, :error, message)
      end

    {:noreply, socket}
  end

  # ── API Tokens (scoped, revocable — see OrcaHub.ApiTokens) ──────────────
  #
  # `revealed_secret` is the ONLY place the plaintext secret ever touches
  # this LiveView's state, and only from the moment `create_api_token`
  # returns it until an explicit dismiss — or ANY other patch navigation on
  # this page, which clears it in `handle_params` above. It must never be
  # put into flash, a URL/query param, a log, an HTML attribute, or a
  # `phx-value-*` — see `OrcaHub.ApiTokens` moduledoc. There is deliberately
  # no function anywhere that can retrieve a secret after creation.

  def handle_event("toggle_token_form", _params, socket) do
    socket =
      if socket.assigns.show_token_form do
        assign(socket, show_token_form: false)
      else
        assign(socket,
          show_token_form: true,
          token_form: to_form(HubRPC.change_api_token(%ApiToken{}, %{"scopes" => []}))
        )
      end

    {:noreply, socket}
  end

  def handle_event("validate_token", %{"api_token" => params}, socket) do
    changeset = HubRPC.change_api_token(%ApiToken{}, normalize_token_params(params))
    {:noreply, assign(socket, token_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_token", %{"api_token" => params}, socket) do
    case HubRPC.create_api_token(normalize_token_params(params)) do
      {:ok, %{token: token, secret: secret}} ->
        {:noreply,
         assign(socket,
           api_tokens: HubRPC.list_api_tokens(),
           show_token_form: false,
           token_form: to_form(HubRPC.change_api_token(%ApiToken{}, %{"scopes" => []})),
           revealed_secret: %{name: token.name, secret: secret}
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, token_form: to_form(changeset, action: :validate))}
    end
  end

  def handle_event("cancel_token_form", _params, socket) do
    {:noreply,
     assign(socket,
       show_token_form: false,
       token_form: to_form(HubRPC.change_api_token(%ApiToken{}, %{"scopes" => []}))
     )}
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, _} = HubRPC.revoke_api_token(id)

    {:noreply,
     socket
     |> assign(api_tokens: HubRPC.list_api_tokens())
     |> put_flash(:info, "Token revoked")}
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, revealed_secret: nil)}
  end

  @impl true
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

  def token_scopes, do: ApiToken.scopes()

  # Maps each connected node's atom to its `nodes`-table row (or nil if it
  # has none yet), so the Connected Nodes list can link through to
  # NodeLive.Show without a per-row DB round-trip during render.
  defp node_records_map(cluster_nodes) do
    Map.new(cluster_nodes, fn info -> {info.node, HubRPC.get_node_by_name("#{info.node}")} end)
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

  defp drop_blank_password_on_edit(params, nil), do: params

  defp drop_blank_password_on_edit(params, %EmailInbox{}) do
    if params["password"] == "", do: Map.delete(params, "password"), else: params
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # The scopes checkbox group pairs each checkbox with a leading hidden
  # `api_token[scopes][]` of value "" (same idiom as SkillLive's `backends`)
  # so an all-unchecked submit still sends the key at all; strip that
  # placeholder back out before it reaches the changeset. Blank optional
  # text inputs (session pin, expiry) are nil'd rather than cast as "" — an
  # empty string is not a valid session_id/utc_datetime.
  defp normalize_token_params(params) do
    params
    |> strip_blank_scope_placeholder()
    |> Map.new(fn
      {"session_id", v} -> {"session_id", blank_to_nil(v)}
      {"expires_at", v} -> {"expires_at", blank_to_nil(v)}
      pair -> pair
    end)
  end

  defp strip_blank_scope_placeholder(%{"scopes" => list} = params) when is_list(list) do
    Map.put(params, "scopes", Enum.reject(list, &(&1 == "")))
  end

  defp strip_blank_scope_placeholder(params), do: params

  # The `.input` checkbox component always submits a real "true"/"false"
  # value (a hidden hedge input pairs with the checkbox — see
  # CoreComponents.input/1), so a live changeset's :tls is already the
  # correctly-typed boolean; this only covers the untouched-form case, where
  # the schema's own `field :tls, :boolean, default: true` applies.
  defp tls_value(form) do
    case Phoenix.HTML.Form.input_value(form, :tls) do
      nil -> true
      value -> value
    end
  end

  defp validate_test_attrs(attrs) do
    cond do
      blank_to_nil(attrs.host) == nil ->
        {:error, "Host is required to test the connection."}

      blank_to_nil(attrs.username) == nil ->
        {:error, "Username is required to test the connection."}

      true ->
        :ok
    end
  end

  # Isolates the HubRPC round-trip so a genuinely unreachable hub (see
  # OrcaHub.HubRPC moduledoc) surfaces as a flash message instead of
  # crashing this LiveView.
  defp safe_test_connection(attrs) do
    HubRPC.test_email_inbox_connection(attrs)
  rescue
    e -> {:error, {:hub_unreachable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:hub_unreachable, inspect(reason)}}
  end

  defp format_connection_error({:connect_failed, reason}),
    do: "Could not connect: #{inspect(reason)}"

  defp format_connection_error({:greeting_failed, line}),
    do: "Unexpected server greeting: #{line}"

  defp format_connection_error(:login_failed),
    do: "Login failed — check the username and password."

  defp format_connection_error({:command_failed, line}),
    do: "IMAP command failed: #{line}"

  defp format_connection_error({:send_failed, reason}),
    do: "Connection error while sending: #{inspect(reason)}"

  defp format_connection_error({:recv_failed, reason}),
    do: "Connection error while reading: #{inspect(reason)}"

  defp format_connection_error(:timeout),
    do: "Timed out waiting for the server to respond."

  defp format_connection_error({:crashed, reason}),
    do: "Unexpected error: #{inspect(reason)}"

  defp format_connection_error(:inbox_not_found),
    do: "This inbox no longer exists."

  defp format_connection_error(:password_required),
    do: "Enter a password to test the connection."

  defp format_connection_error({:hub_unreachable, message}),
    do: "Could not reach the hub node to test this connection: #{message}"

  defp format_connection_error(other), do: inspect(other)
end
