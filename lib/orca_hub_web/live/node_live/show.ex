defmodule OrcaHubWeb.NodeLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{BackendInstaller, Cluster, ConfigFile, HubRPC, NodeConfig}
  alias OrcaHubWeb.Markdown

  import OrcaHubWeb.NodeLive.ConfigComponents, only: [config_file_row: 1, config_dir_row: 1]

  import OrcaHubWeb.NodeLive.ConfigHelpers, only: [entry_key: 2, split_config_blocks: 2]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    node = HubRPC.get_node!(id)
    connected? = Cluster.nodes() |> Enum.map(&Atom.to_string/1) |> Enum.member?(node.name)
    config_node = if connected?, do: resolve_target_node(node.name), else: nil

    node_config = if config_node, do: load_all_node_config(config_node), else: nil

    if config_node && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, BackendInstaller.topic(config_node))
    end

    socket =
      socket
      |> assign(
        page_title: node.display_name,
        node: node,
        connected: connected?,
        config_node: config_node,
        node_config: node_config,
        backend_installer_status: if(config_node, do: load_backend_installer_status(config_node)),
        backend_installer_running:
          if(config_node,
            do: load_backend_installer_running(config_node),
            else: MapSet.new()
          ),
        backend_installer_output: %{},
        backend_installer_result: %{},
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
        structured_edit_value: ""
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
  # Backend install/update (PubSub events from OrcaHub.BackendInstaller.Job)
  # -------------------------------------------------------------------

  @impl true
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
