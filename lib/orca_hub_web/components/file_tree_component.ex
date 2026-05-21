defmodule OrcaHubWeb.FileTreeComponent do
  use OrcaHubWeb, :live_component

  alias OrcaHub.{Cluster, Projects}

  @impl true
  def update(%{reload: true}, socket) do
    tree =
      load_root_tree(socket.assigns.target_node, socket.assigns.project,
        show_hidden: socket.assigns.show_hidden_files
      )

    filtered =
      filtered_tree(
        socket.assigns.target_node,
        socket.assigns.project,
        tree,
        socket.assigns.file_tree_filter,
        socket.assigns.show_hidden_files
      )

    {:ok, assign(socket, file_tree: tree, filtered_file_tree: filtered)}
  end

  def update(assigns, socket) do
    initial = not Map.has_key?(socket.assigns, :file_tree)

    socket =
      socket
      |> assign(
        Map.take(assigns, [
          :id,
          :target_node,
          :project,
          :selected_path,
          :tree_id,
          :on_select,
          :show_hidden_toggle,
          :search_input_id
        ])
      )
      |> assign_new(:show_hidden_toggle, fn -> true end)
      |> assign_new(:tree_id, fn -> "file-tree-#{assigns.id}" end)
      |> assign_new(:on_select, fn -> :file_selected end)
      |> assign_new(:search_input_id, fn -> nil end)

    socket =
      if initial do
        tree =
          load_root_tree(socket.assigns.target_node, socket.assigns.project, show_hidden: false)

        assign(socket,
          file_tree: tree,
          filtered_file_tree: tree,
          file_tree_filter: "",
          show_hidden_files: false
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    send(self(), {socket.assigns.on_select, path})
    {:noreply, socket}
  end

  def handle_event("expand_dir", %{"path" => path}, socket) do
    if dir_loaded?(socket.assigns.file_tree, path) do
      {:noreply, socket}
    else
      case load_dir_children(
             socket.assigns.target_node,
             socket.assigns.project,
             path,
             show_hidden: socket.assigns.show_hidden_files
           ) do
        {:ok, children} ->
          file_tree = Projects.merge_loaded_children(socket.assigns.file_tree, path, children)

          filtered =
            filtered_tree(
              socket.assigns.target_node,
              socket.assigns.project,
              file_tree,
              socket.assigns.file_tree_filter,
              socket.assigns.show_hidden_files
            )

          {:noreply, assign(socket, file_tree: file_tree, filtered_file_tree: filtered)}

        :unsupported ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("filter_file_tree", %{"value" => query}, socket) do
    filtered =
      filtered_tree(
        socket.assigns.target_node,
        socket.assigns.project,
        socket.assigns.file_tree,
        query,
        socket.assigns.show_hidden_files
      )

    {:noreply, assign(socket, file_tree_filter: query, filtered_file_tree: filtered)}
  end

  def handle_event("toggle_hidden_files", _params, socket) do
    show_hidden = !socket.assigns.show_hidden_files

    tree =
      load_root_tree(socket.assigns.target_node, socket.assigns.project, show_hidden: show_hidden)

    filtered =
      filtered_tree(
        socket.assigns.target_node,
        socket.assigns.project,
        tree,
        socket.assigns.file_tree_filter,
        show_hidden
      )

    {:noreply,
     assign(socket,
       show_hidden_files: show_hidden,
       file_tree: tree,
       filtered_file_tree: filtered
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col min-h-0 h-full">
      <div class="flex items-center gap-1 mb-1 shrink-0">
        <input
          id={@search_input_id}
          type="text"
          placeholder="Search files..."
          value={@file_tree_filter}
          phx-keyup="filter_file_tree"
          phx-target={@myself}
          phx-debounce="150"
          class="input input-xs input-bordered flex-1 min-w-0"
        />
        <button
          :if={@show_hidden_toggle}
          phx-click="toggle_hidden_files"
          phx-target={@myself}
          class={["btn btn-xs", if(@show_hidden_files, do: "btn-primary", else: "btn-ghost")]}
          title={if @show_hidden_files, do: "Hide hidden files", else: "Show hidden files"}
        >
          <.icon name="hero-eye-micro" class="size-3" />
        </button>
        <button
          phx-click={JS.dispatch("phx:expand-all", to: "##{@tree_id}")}
          class="btn btn-ghost btn-xs"
          title="Expand all"
        >
          <.icon name="hero-chevron-down-micro" class="size-3" />
        </button>
        <button
          phx-click={JS.dispatch("phx:collapse-all", to: "##{@tree_id}")}
          class="btn btn-ghost btn-xs"
          title="Collapse all"
        >
          <.icon name="hero-chevron-up-micro" class="size-3" />
        </button>
      </div>
      <div class="flex-1 overflow-y-auto overflow-x-hidden min-h-0">
        <ul
          id={@tree_id}
          class="menu menu-xs bg-base-200 rounded-lg w-full"
          phx-hook="FileTree"
          data-filter={@file_tree_filter}
        >
          <.file_tree_node
            :for={node <- @filtered_file_tree}
            node={node}
            selected_path={@selected_path}
            target={@myself}
          />
        </ul>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :selected_path, :string, default: nil
  attr :target, :any, required: true

  defp file_tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <li>
      <button
        phx-click="select_file"
        phx-value-path={@node.path}
        phx-target={@target}
        class={[@selected_path == @node.path && "active"]}
      >
        <span class="font-mono text-xs truncate">{@node.name}</span>
      </button>
    </li>
    """
  end

  defp file_tree_node(%{node: %{type: :dir}} = assigns) do
    ~H"""
    <li>
      <details>
        <summary
          class="font-mono text-xs"
          phx-click={
            @node.children == nil &&
              JS.push("expand_dir", target: @target, value: %{path: @node.path})
          }
        >
          <.icon name="hero-folder-micro" class="size-3 opacity-50" />
          {@node.name}
        </summary>
        <ul :if={@node.children == nil}>
          <li class="text-base-content/50 text-xs px-2 py-1">Loading…</li>
        </ul>
        <ul :if={is_list(@node.children)}>
          <.file_tree_node
            :for={child <- @node.children}
            node={child}
            selected_path={@selected_path}
            target={@target}
          />
        </ul>
      </details>
    </li>
    """
  end

  defp load_root_tree(target_node, project, opts) do
    show_hidden = Keyword.get(opts, :show_hidden, false)

    try do
      Cluster.rpc(target_node, Projects, :list_dir_entries, [
        project,
        "",
        [show_hidden: show_hidden, prefetch: true]
      ])
    rescue
      e in ErlangError ->
        if undef_error?(e) do
          eager_tree(target_node, project, show_hidden)
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp load_dir_children(target_node, project, path, opts) do
    show_hidden = Keyword.get(opts, :show_hidden, false)

    try do
      children =
        Cluster.rpc(target_node, Projects, :list_dir_entries, [
          project,
          path,
          [show_hidden: show_hidden, prefetch: true]
        ])

      {:ok, children}
    rescue
      e in ErlangError ->
        if undef_error?(e), do: :unsupported, else: reraise(e, __STACKTRACE__)
    end
  end

  defp eager_tree(target_node, project, show_hidden) do
    files =
      Cluster.rpc(target_node, Projects, :list_editable_files, [
        project,
        [show_hidden: show_hidden]
      ])

    Projects.build_file_tree(files)
  end

  defp undef_error?(%ErlangError{original: {:exception, :undef, _}}), do: true
  defp undef_error?(_), do: false

  defp filtered_tree(_node, _project, file_tree, "", _show_hidden), do: file_tree
  defp filtered_tree(_node, _project, file_tree, nil, _show_hidden), do: file_tree

  defp filtered_tree(target_node, project, _file_tree, query, show_hidden) do
    files =
      Cluster.rpc(target_node, Projects, :list_editable_files, [
        project,
        [show_hidden: show_hidden]
      ])

    files
    |> Projects.build_file_tree()
    |> Projects.filter_file_tree(query)
  end

  defp dir_loaded?(tree, path) do
    Enum.any?(tree, fn
      %{type: :dir, path: ^path, children: kids} -> is_list(kids)
      %{type: :dir, children: kids} when is_list(kids) -> dir_loaded?(kids, path)
      _ -> false
    end)
  end
end
