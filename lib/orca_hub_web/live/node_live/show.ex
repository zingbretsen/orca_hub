defmodule OrcaHubWeb.NodeLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{
    BackendAuth,
    BackendInstaller,
    Cluster,
    ConfigFile,
    GlobalGitignore,
    HubRPC,
    NodeConfig,
    SkillSync
  }

  alias OrcaHubWeb.Markdown

  import OrcaHubWeb.NodeLive.ConfigComponents, only: [config_file_row: 1, config_dir_row: 1]

  import OrcaHubWeb.NodeLive.ConfigHelpers, only: [entry_key: 2, split_config_blocks: 2]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    node = HubRPC.get_node!(id)
    connected? = Cluster.nodes() |> Enum.map(&Atom.to_string/1) |> Enum.member?(node.name)
    config_node = if connected?, do: resolve_target_node(node.name), else: nil

    node_config = if config_node, do: load_all_node_config(config_node), else: nil
    managed_skills = if config_node, do: load_managed_skills(config_node), else: %{}

    if config_node && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, BackendInstaller.topic(config_node))
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "skills")
    end

    socket =
      socket
      |> assign(
        page_title: node.display_name,
        node: node,
        connected: connected?,
        config_node: config_node,
        node_config: node_config,
        managed_skills: managed_skills,
        backend_installer_status: if(config_node, do: load_backend_installer_status(config_node)),
        backend_installer_running:
          if(config_node,
            do: load_backend_installer_running(config_node),
            else: MapSet.new()
          ),
        backend_installer_output: %{},
        backend_installer_result: %{},
        global_gitignore: if(config_node, do: load_global_gitignore(config_node)),
        session_count: HubRPC.count_sessions_for_node(node.name),
        project_count: HubRPC.count_projects_for_node(node.name),
        config_sections_expanded: MapSet.new(),
        config_dirs_expanded: MapSet.new(),
        config_expanded: MapSet.new(),
        config_content: %{},
        config_editing: nil,
        config_edit_content: "",
        config_new_entry: nil,
        config_new_entry_name: "",
        config_new_entry_content: "",
        editing_block: nil,
        block_edit_content: nil,
        config_view_mode: %{},
        structured_editing: nil,
        structured_edit_value: "",
        claude_logged_in?: node.name in HubRPC.list_logged_in_nodes(),
        login_node: nil,
        login_output: "",
        login_url: nil,
        login_status: nil,
        login_error: nil,
        codex_status: codex_status_for(config_node),
        codex_env_conflict?: codex_env_conflict_for(config_node),
        pi_providers: pi_providers_for(config_node),
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
      )

    socket =
      if node_config && node_config_errors(node_config) != [] do
        put_flash(
          socket,
          :error,
          "Some backend configuration failed to load — the node may have disconnected."
        )
      else
        socket
      end

    {:ok, socket}
  end

  def last_connected_label(true, _last_connected_at), do: "Connected now"
  def last_connected_label(false, nil), do: "Never"

  def last_connected_label(false, last_connected_at),
    do: OrcaHubWeb.DashboardLive.time_ago(last_connected_at)

  def first_connected_label(nil), do: "Unknown"
  def first_connected_label(dt), do: OrcaHubWeb.DashboardLive.time_ago(dt)

  # -------------------------------------------------------------------
  # Backend install/update
  # -------------------------------------------------------------------

  def handle_event("toggle_isolated", _params, socket) do
    node = socket.assigns.node
    new_value = !node.isolated

    case HubRPC.update_node(node, %{isolated: new_value}) do
      {:ok, updated_node} ->
        flash_msg =
          if new_value,
            do: "Node isolated — sessions here can no longer reach other nodes",
            else: "Node isolation disabled"

        {:noreply, socket |> assign(:node, updated_node) |> put_flash(:info, flash_msg)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update isolation setting")}
    end
  end

  def handle_event("toggle_dial", _params, socket) do
    node = socket.assigns.node
    new_value = !node.dial

    case HubRPC.update_node(node, %{dial: new_value}) do
      {:ok, updated_node} ->
        flash_msg =
          if new_value,
            do: "Hub will now dial this node every 5s (OrcaHub.NodeDialer)",
            else: "Hub dial-out disabled for this node"

        {:noreply, socket |> assign(:node, updated_node) |> put_flash(:info, flash_msg)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update dial setting")}
    end
  end

  def handle_event("toggle_scrub_session_env", _params, socket) do
    node = socket.assigns.node
    new_value = !node.scrub_session_env

    case HubRPC.update_node(node, %{scrub_session_env: new_value}) do
      {:ok, updated_node} ->
        flash_msg =
          if new_value,
            do:
              "Session env scrubbing enabled — new sessions/terminals on this node get a minimal allow-list environment",
            else: "Session env scrubbing disabled"

        {:noreply, socket |> assign(:node, updated_node) |> put_flash(:info, flash_msg)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update session env scrubbing setting")}
    end
  end

  def handle_event("update_env_allowlist", %{"env_allowlist" => value}, socket) do
    node = socket.assigns.node
    entries = OrcaHubWeb.EnvAllowlistInput.parse(value)

    case HubRPC.update_node(node, %{env_allowlist: entries}) do
      {:ok, updated_node} ->
        {:noreply,
         socket |> assign(:node, updated_node) |> put_flash(:info, "Env allow-list updated")}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to update env allow-list: #{OrcaHubWeb.EnvAllowlistInput.error_summary(changeset)}"
         )}
    end
  end

  def handle_event("update_default_backend", %{"default_backend" => value}, socket) do
    update_node_default(socket, :default_backend, blank_to_nil(value))
  end

  def handle_event("update_default_model", %{"default_model" => value}, socket) do
    update_node_default(socket, :default_model, blank_to_nil(value))
  end

  def handle_event("ensure_global_gitignore", _params, socket) do
    config_node = socket.assigns.config_node

    case rpc(config_node, GlobalGitignore, :ensure, []) do
      :ok ->
        {:noreply,
         socket
         |> assign(global_gitignore: load_global_gitignore(config_node))
         |> put_flash(
           :info,
           "Global gitignore on #{Cluster.node_name(config_node)} now covers OrcaHub's working-directory artifacts"
         )}

      error ->
        {:noreply,
         socket
         |> assign(global_gitignore: load_global_gitignore(config_node))
         |> put_flash(:error, "Failed to update global gitignore: #{inspect(error)}")}
    end
  end

  def handle_event("run_backend_job", %{"backend" => b, "action" => a}, socket) do
    with backend when not is_nil(backend) <- backend_atom(b),
         action when not is_nil(action) <- installer_action_atom(a) do
      case rpc(socket.assigns.config_node, BackendInstaller, :run, [backend, action]) do
        :ok ->
          {:noreply,
           socket
           |> update(:backend_installer_running, &MapSet.put(&1, backend))
           |> update(:backend_installer_output, &Map.put(&1, backend, ""))
           |> update(:backend_installer_result, &Map.delete(&1, backend))}

        {:error, :already_running} ->
          {:noreply, put_flash(socket, :error, "#{b} install/update is already running")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start #{b}: #{inspect(reason)}")}
      end
    else
      nil -> {:noreply, socket}
    end
  end

  # -------------------------------------------------------------------
  # Node login (Claude Code OAuth)
  # -------------------------------------------------------------------

  def handle_event("login_node", _params, socket) do
    target = socket.assigns.config_node

    socket = unsubscribe_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "node_login:#{target}")

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

  def handle_event("logout_node", _params, socket) do
    node = socket.assigns.node
    {:ok, _} = HubRPC.delete_node_token(node.name)

    {:noreply,
     socket
     |> assign(claude_logged_in?: false)
     |> put_flash(:info, "Removed stored credential for #{node.display_name}")}
  end

  # -------------------------------------------------------------------
  # Node login (codex device-auth / API key)
  # -------------------------------------------------------------------

  def handle_event("codex_login_device", _params, socket) do
    target = socket.assigns.config_node

    socket = unsubscribe_codex_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "codex_login:#{target}")

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

  def handle_event("codex_login_api_key_open", _params, socket) do
    target = socket.assigns.config_node

    socket = unsubscribe_codex_login(socket)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "codex_login:#{target}")

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

  # Strictly write-only, same discipline as add_secret in the old Settings
  # location: `key` is used to start the login flow and then discarded —
  # never assigned to socket state, so it can never be rendered back or leak
  # into a later render.
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

  # -------------------------------------------------------------------
  # pi provider keys
  # -------------------------------------------------------------------

  def handle_event("open_pi_keys", _params, socket) do
    {:noreply, assign(socket, pi_key_node: socket.assigns.config_node, pi_key_sanity: nil)}
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
             |> refresh_pi_providers()
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
           |> refresh_pi_providers()
           |> put_flash(:info, "Removed #{provider} key")}

        error ->
          {:noreply, put_flash(socket, :error, "Failed to remove key: #{inspect(error)}")}
      end
    else
      {:noreply, socket}
    end
  end

  # -------------------------------------------------------------------
  # Section / entry expand-collapse
  # -------------------------------------------------------------------

  @impl true
  def handle_event("toggle_config_section", %{"backend" => b}, socket) do
    case backend_atom(b) do
      nil ->
        {:noreply, socket}

      backend ->
        {:noreply,
         assign(socket,
           config_sections_expanded: toggle_set(socket.assigns.config_sections_expanded, backend)
         )}
    end
  end

  def handle_event("toggle_config_dir", %{"backend" => b, "path" => path}, socket) do
    case backend_atom(b) do
      nil ->
        {:noreply, socket}

      backend ->
        key = {backend, path}

        {:noreply,
         assign(socket,
           config_dirs_expanded: toggle_set(socket.assigns.config_dirs_expanded, key)
         )}
    end
  end

  def handle_event("toggle_config_entry", %{"key" => key}, socket) do
    expanded = socket.assigns.config_expanded

    if MapSet.member?(expanded, key) do
      {:noreply, assign(socket, config_expanded: MapSet.delete(expanded, key))}
    else
      {backend, path} = split_key(key)

      case rpc(socket.assigns.config_node, NodeConfig, :read_entry, [backend, path]) do
        {:ok, content} ->
          {:noreply,
           socket
           |> update(:config_content, &Map.put(&1, key, content))
           |> assign(config_expanded: MapSet.put(expanded, key))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to load #{path}: #{inspect(reason)}")}
      end
    end
  end

  # -------------------------------------------------------------------
  # Raw edit (create or edit an existing catalog file / dir child)
  # -------------------------------------------------------------------

  def handle_event("edit_config_entry", %{"key" => key}, socket) do
    {backend, path} = split_key(key)

    content =
      case Map.get(socket.assigns.config_content, key) do
        nil ->
          case rpc(socket.assigns.config_node, NodeConfig, :read_entry, [backend, path]) do
            {:ok, content} -> content
            {:error, _} -> template_for(socket, backend, path) || ""
          end

        cached ->
          cached
      end

    {:noreply, assign(socket, config_editing: key, config_edit_content: content)}
  end

  def handle_event("cancel_edit_config_entry", _params, socket) do
    {:noreply, assign(socket, config_editing: nil, config_edit_content: "")}
  end

  def handle_event("save_config_entry", %{"key" => key, "content" => content}, socket) do
    {backend, path} = split_key(key)

    case rpc(socket.assigns.config_node, NodeConfig, :write_entry, [backend, path, content]) do
      :ok ->
        {:noreply,
         socket
         |> update(:config_content, &Map.put(&1, key, content))
         |> refresh_backend_config(backend)
         |> assign(
           config_editing: nil,
           config_edit_content: "",
           config_expanded: MapSet.put(socket.assigns.config_expanded, key)
         )
         |> put_flash(:info, "Saved #{path}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save #{path}: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_config_entry", %{"key" => key}, socket) do
    {backend, path} = split_key(key)

    case rpc(socket.assigns.config_node, NodeConfig, :delete_entry, [backend, path]) do
      :ok ->
        {:noreply,
         socket
         |> update(:config_content, &Map.delete(&1, key))
         |> update(:config_expanded, &MapSet.delete(&1, key))
         |> refresh_backend_config(backend)
         |> put_flash(:info, "Deleted #{path}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{path}: #{inspect(reason)}")}
    end
  end

  def handle_event("create_config_dir", %{"backend" => b, "path" => path}, socket) do
    case backend_atom(b) do
      nil ->
        {:noreply, socket}

      backend ->
        case rpc(socket.assigns.config_node, NodeConfig, :create_directory, [backend, path]) do
          :ok ->
            {:noreply,
             socket
             |> refresh_backend_config(backend)
             |> put_flash(:info, "Created #{path}/")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create #{path}/: #{inspect(reason)}")}
        end
    end
  end

  # -------------------------------------------------------------------
  # New file within a dir (flat dir child, or a brand-new skill)
  # -------------------------------------------------------------------

  def handle_event("new_config_entry", %{"backend" => b, "dir_path" => dir_path}, socket) do
    case backend_atom(b) do
      nil ->
        {:noreply, socket}

      backend ->
        entry = find_dir_entry(socket, backend, dir_path)

        {:noreply,
         assign(socket,
           config_new_entry: %{
             backend: backend,
             dir_path: dir_path,
             dir_kind: entry && entry.dir_kind,
             skill_filename: entry && Map.get(entry, :skill_filename)
           },
           config_new_entry_name: "",
           config_new_entry_content: (entry && entry.create_template) || ""
         )}
    end
  end

  def handle_event("cancel_new_config_entry", _params, socket) do
    {:noreply,
     assign(socket,
       config_new_entry: nil,
       config_new_entry_name: "",
       config_new_entry_content: ""
     )}
  end

  def handle_event("save_new_config_entry", params, socket) do
    %{backend: backend, dir_path: dir_path, dir_kind: dir_kind, skill_filename: skill_filename} =
      socket.assigns.config_new_entry

    name = String.trim(params["name"] || "")
    content = params["content"] || ""

    path =
      case dir_kind do
        :skill_dirs -> Path.join([dir_path, name, skill_filename])
        _ -> Path.join(dir_path, name)
      end

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Please enter a name")}

      true ->
        case rpc(socket.assigns.config_node, NodeConfig, :write_entry, [backend, path, content]) do
          :ok ->
            key = entry_key(backend, path)

            {:noreply,
             socket
             |> update(:config_content, &Map.put(&1, key, content))
             |> refresh_backend_config(backend)
             |> assign(
               config_new_entry: nil,
               config_new_entry_name: "",
               config_new_entry_content: "",
               config_expanded: MapSet.put(socket.assigns.config_expanded, key)
             )
             |> put_flash(:info, "Created #{path}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create #{path}: #{inspect(reason)}")}
        end
    end
  end

  # -------------------------------------------------------------------
  # Markdown block editing (shared by every markdown-format entry)
  # -------------------------------------------------------------------

  def handle_event(
        "edit_block",
        %{"scope" => "node_config", "key" => key, "index" => index_str},
        socket
      ) do
    index = String.to_integer(index_str)
    {_frontmatter, blocks} = split_config_blocks(socket.assigns.config_content, key)

    case Enum.find(blocks, fn {i, _} -> i == index end) do
      {_, text} ->
        {:noreply,
         assign(socket,
           editing_block: %{scope: "node_config", key: key, index: index},
           block_edit_content: text
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_block_edit", _params, socket) do
    {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}
  end

  def handle_event(
        "delete_block",
        %{"scope" => "node_config", "key" => key, "index" => index_str},
        socket
      ) do
    index = String.to_integer(index_str)
    {frontmatter, blocks} = split_config_blocks(socket.assigns.config_content, key)

    new_blocks =
      blocks
      |> Enum.reject(fn {i, _} -> i == index end)
      |> Enum.with_index()
      |> Enum.map(fn {{_, text}, new_idx} -> {new_idx, text} end)

    apply_config_block_change(socket, key, frontmatter, new_blocks)
  end

  def handle_event("save_block", %{"content" => content}, socket) do
    %{key: key, index: index} = socket.assigns.editing_block
    {frontmatter, blocks} = split_config_blocks(socket.assigns.config_content, key)

    new_blocks =
      Enum.map(blocks, fn
        {^index, _} -> {index, String.trim(content)}
        other -> other
      end)

    apply_config_block_change(socket, key, frontmatter, new_blocks)
  end

  # -------------------------------------------------------------------
  # Structured editing (shared by every entry whose format has an
  # `OrcaHub.ConfigFile` adapter) — mirrors the markdown block editing
  # above: a single global editing session, addressed by scope/key/path,
  # applying an op via the format layer and persisting through the same
  # `NodeConfig.write_entry` path `save_config_entry` uses.
  # -------------------------------------------------------------------

  def handle_event(
        "toggle_view_mode",
        %{"scope" => "node_config", "key" => key, "mode" => mode},
        socket
      ) do
    mode_atom = if mode == "raw", do: :raw, else: :structured
    {:noreply, update(socket, :config_view_mode, &Map.put(&1, key, mode_atom))}
  end

  def handle_event(
        "edit_value",
        %{"scope" => "node_config", "key" => key, "path" => encoded_path},
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = entry_format(socket, key)
    content = Map.get(socket.assigns.config_content, key, "")

    with {:ok, tree} <- ConfigFile.parse(format, content),
         %{} = node <- ConfigFile.get_node(tree, path) do
      {:noreply,
       assign(socket,
         structured_editing: %{scope: "node_config", key: key, path: path},
         structured_edit_value: leaf_edit_value(node)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "save_value",
        %{
          "scope" => "node_config",
          "key" => key,
          "path" => encoded_path,
          "value_type" => value_type,
          "value" => raw_value
        },
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = entry_format(socket, key)
    content = Map.get(socket.assigns.config_content, key, "")

    with {:ok, value} <- ConfigFile.coerce(String.to_existing_atom(value_type), raw_value),
         {:ok, new_content} <- ConfigFile.apply_op(format, content, {:set, path, value}) do
      apply_structured_change(socket, key, new_content)
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "delete_key",
        %{"scope" => "node_config", "key" => key, "path" => encoded_path},
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = entry_format(socket, key)
    content = Map.get(socket.assigns.config_content, key, "")

    case ConfigFile.apply_op(format, content, {:delete, path}) do
      {:ok, new_content} ->
        apply_structured_change(socket, key, new_content)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "add_key",
        %{
          "scope" => "node_config",
          "key" => key,
          "path" => encoded_path,
          "value_type" => value_type
        } =
          params,
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = entry_format(socket, key)
    content = Map.get(socket.assigns.config_content, key, "")
    add_key = blank_to_nil(params["name"])

    with {:ok, value} <-
           ConfigFile.coerce(ConfigFile.parse_value_type(value_type), params["value"] || ""),
         {:ok, new_content} <- ConfigFile.apply_op(format, content, {:add, path, add_key, value}) do
      apply_structured_change(socket, key, new_content)
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", %{"scope" => _scope, "key" => _key}, socket) do
    {:noreply, assign(socket, structured_editing: nil, structured_edit_value: "")}
  end

  # -------------------------------------------------------------------
  # Node login (PubSub events from OrcaHub.LoginRunner / CodexLoginRunner)
  # -------------------------------------------------------------------

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
    {:noreply, assign(socket, login_status: :success, claude_logged_in?: true)}
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
    {:noreply,
     socket
     |> assign(codex_login_status: :success)
     |> refresh_codex_status()}
  end

  def handle_info({:codex_login_done, {:error, msg}}, socket) do
    {:noreply, assign(socket, codex_login_status: :error, codex_login_error: msg)}
  end

  # -------------------------------------------------------------------
  # Backend install/update (PubSub events from OrcaHub.BackendInstaller.Job)
  # -------------------------------------------------------------------

  def handle_info({:installer_output, _node, backend, chunk}, socket) do
    {:noreply,
     update(socket, :backend_installer_output, fn output ->
       Map.update(output, backend, chunk, &(&1 <> chunk))
     end)}
  end

  def handle_info({:installer_done, _node, backend, result}, socket) do
    {:noreply,
     socket
     |> update(:backend_installer_running, &MapSet.delete(&1, backend))
     |> update(:backend_installer_result, &Map.put(&1, backend, result))
     |> refresh_backend_installer_status()}
  end

  # -------------------------------------------------------------------
  # Skills (OrcaHub.SkillSync mirrors this node's disk shortly after every
  # {:skills_updated} broadcast — delay the refresh past SkillSync's own
  # debounce so the managed-names/badges we reload actually reflect the
  # post-sync state instead of racing it).
  # -------------------------------------------------------------------

  def handle_info({:skills_updated}, socket) do
    if socket.assigns.config_node do
      Process.send_after(self(), :refresh_managed_skills, 1_500)
    end

    {:noreply, socket}
  end

  def handle_info(:refresh_managed_skills, socket) do
    config_node = socket.assigns.config_node

    {:noreply,
     assign(socket,
       managed_skills: load_managed_skills(config_node),
       node_config: load_all_node_config(config_node)
     )}
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp rpc(target, mod, fun, args), do: Cluster.rpc(target, mod, fun, args)
  defp rpc(target, mod, fun, args, timeout), do: Cluster.rpc(target, mod, fun, args, timeout)

  # A node string in the `nodes` table is only ever meaningful as a live
  # Erlang node atom if that atom already exists in this VM (i.e. we've
  # actually connected to it before) — to_existing_atom/1 raises otherwise,
  # which we treat as "can't route to it", not a crash.
  defp resolve_target_node(name) do
    atom = String.to_existing_atom(name)
    if atom in Cluster.nodes(), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp backend_atom("claude"), do: :claude
  defp backend_atom("codex"), do: :codex
  defp backend_atom("pi"), do: :pi
  defp backend_atom(_), do: nil

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
      claude_logged_in?: socket.assigns.node.name in HubRPC.list_logged_in_nodes()
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

  defp codex_status_for(nil), do: %{status: :not_logged_in, label: "Not logged in"}

  defp codex_status_for(config_node) do
    case Cluster.codex_status(config_node) do
      %{} = s -> s
      _ -> %{status: :not_logged_in, label: "Not logged in"}
    end
  end

  defp codex_env_conflict_for(nil), do: false
  defp codex_env_conflict_for(config_node), do: Cluster.codex_env_conflict?(config_node) == true

  defp pi_providers_for(nil), do: []

  defp pi_providers_for(config_node) do
    case Cluster.list_pi_providers(config_node) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp refresh_codex_status(socket) do
    assign(socket, codex_status: codex_status_for(socket.assigns.config_node))
  end

  defp refresh_pi_providers(socket) do
    assign(socket, pi_providers: pi_providers_for(socket.assigns.config_node))
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

  defp update_node_default(socket, field, value) do
    case HubRPC.update_node(socket.assigns.node, %{field => value}) do
      {:ok, updated_node} ->
        {:noreply, assign(socket, :node, updated_node)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update default #{field}")}
    end
  end

  @doc """
  Backend options for the "Default backend" select: scoped to what's
  actually installed when the node is reachable (mirrors the new-session
  picker), or the full known backend catalog when it isn't — an operator
  should be able to pre-configure a default before a node ever connects.
  """
  def default_backend_options(true, config_node), do: OrcaHub.Backend.available_on(config_node)
  def default_backend_options(false, _config_node), do: OrcaHub.Backend.available()

  @doc """
  Model options for the "Default model" control. Only Claude's model list is
  enumerable (and only when the node is reachable, since an unreached
  `config_node` of `nil` would otherwise resolve to *this* node's models —
  see `Backend.available_on/1`'s node-normalization). `[]` here means the
  template falls back to a free-text input — also the right answer for
  Codex/pi, whose model ids aren't enumerable.
  """
  def default_model_options(_node, false, _config_node), do: []

  def default_model_options(node, true, config_node) do
    if configured_backend(node) == "claude" do
      OrcaHub.Backend.models_for("claude", config_node)
    else
      []
    end
  end

  defp configured_backend(node), do: node.default_backend || "claude"

  defp installer_action_atom("install"), do: :install
  defp installer_action_atom("update"), do: :update
  defp installer_action_atom(_), do: nil

  # BackendInstaller.status/0 runs 3 backends' checks concurrently but each
  # may shell out to npm (see BackendInstaller's internal timeouts) — pad
  # well above Cluster.rpc's default 10s so a slow-but-not-hung node doesn't
  # spuriously read as unavailable.
  defp load_backend_installer_status(config_node) do
    case rpc(config_node, BackendInstaller, :status, [], 12_000) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp load_backend_installer_running(config_node) do
    case rpc(config_node, BackendInstaller, :running_backends, []) do
      list when is_list(list) -> MapSet.new(list)
      _ -> MapSet.new()
    end
  end

  defp refresh_backend_installer_status(socket) do
    assign(socket,
      backend_installer_status: load_backend_installer_status(socket.assigns.config_node)
    )
  end

  defp split_key(key) do
    [backend_str, path] = String.split(key, "|", parts: 2)
    {backend_atom(backend_str), path}
  end

  defp toggle_set(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  defp load_all_node_config(config_node) do
    Map.new(NodeConfig.backends(), fn backend ->
      {backend, load_backend_config(config_node, backend)}
    end)
  end

  defp load_backend_config(config_node, backend) do
    case Cluster.rpc(config_node, NodeConfig, :list_config, [backend]) do
      %{} = result -> result
      {:error, _} = error -> error
    end
  end

  defp node_config_errors(node_config) do
    node_config
    |> Map.values()
    |> Enum.filter(&match?({:error, _}, &1))
  end

  # Stateless live read of the target node's on-disk git config — no DB
  # column backs this; it's re-checked on every mount and after every apply.
  defp load_global_gitignore(config_node) do
    case rpc(config_node, GlobalGitignore, :status, []) do
      %{} = status -> status
      _ -> nil
    end
  end

  defp load_managed_skills(config_node) do
    Map.new(NodeConfig.backends(), fn backend ->
      names =
        case rpc(config_node, SkillSync, :managed_skill_names, [backend]) do
          %MapSet{} = set -> set
          _ -> MapSet.new()
        end

      {backend, names}
    end)
  end

  defp refresh_backend_config(socket, backend) do
    result = load_backend_config(socket.assigns.config_node, backend)
    update(socket, :node_config, &Map.put(&1, backend, result))
  end

  # Resolves the create template for `path` under `backend` — either an
  # exact top-level catalog file, or any path nested under a catalog dir
  # (a flat dir child, or a skill's SKILL.md), whose dir entry carries the
  # template to use for a brand-new child.
  defp template_for(socket, backend, path) do
    case socket.assigns.node_config[backend] do
      %{entries: entries} -> Enum.find_value(entries, &entry_template_match(&1, path))
      _ -> nil
    end
  end

  defp entry_template_match(%{path: path, create_template: template}, path), do: template

  defp entry_template_match(%{kind: :dir, path: dir_path, create_template: template}, path) do
    if String.starts_with?(path, dir_path <> "/"), do: template
  end

  defp entry_template_match(_entry, _path), do: nil

  # Resolves the catalog `format:` for `key` (e.g. `:json`) the same way
  # `template_for/3` resolves a create template — exact top-level match, or
  # inherited from the parent dir entry for a dir child.
  defp entry_format(socket, key) do
    {backend, path} = split_key(key)

    case socket.assigns.node_config[backend] do
      %{entries: entries} -> Enum.find_value(entries, &entry_format_match(&1, path))
      _ -> nil
    end
  end

  defp entry_format_match(%{path: path, format: format}, path), do: format

  defp entry_format_match(%{kind: :dir, path: dir_path, format: format}, path) do
    if String.starts_with?(path, dir_path <> "/"), do: format
  end

  defp entry_format_match(_entry, _path), do: nil

  defp find_dir_entry(socket, backend, dir_path) do
    case socket.assigns.node_config[backend] do
      %{entries: entries} -> Enum.find(entries, &(&1.kind == :dir and &1.path == dir_path))
      _ -> nil
    end
  end

  defp apply_config_block_change(socket, key, frontmatter, blocks) do
    full_content = Markdown.join_frontmatter(frontmatter, Markdown.join_blocks(blocks))
    {backend, path} = split_key(key)

    case rpc(socket.assigns.config_node, NodeConfig, :write_entry, [backend, path, full_content]) do
      :ok ->
        {:noreply,
         socket
         |> update(:config_content, &Map.put(&1, key, full_content))
         |> refresh_backend_config(backend)
         |> assign(editing_block: nil, block_edit_content: nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  defp apply_structured_change(socket, key, new_content) do
    {backend, path} = split_key(key)

    case rpc(socket.assigns.config_node, NodeConfig, :write_entry, [backend, path, new_content]) do
      :ok ->
        {:noreply,
         socket
         |> update(:config_content, &Map.put(&1, key, new_content))
         |> refresh_backend_config(backend)
         |> assign(structured_editing: nil, structured_edit_value: "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  defp leaf_edit_value(%{value_type: :null}), do: ""
  defp leaf_edit_value(%{value: value}), do: to_string(value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(str) do
    case String.trim(str) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
