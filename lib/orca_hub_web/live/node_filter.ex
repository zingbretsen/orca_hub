defmodule OrcaHubWeb.NodeFilter do
  @moduledoc """
  LiveView on_mount hook that provides global node filtering.

  Attaches `node_filter` assigns and handles toggle events so that
  every page can filter cluster data by selected nodes. The selected
  nodes are persisted in the browser's localStorage via a JS hook.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias OrcaHub.Cluster

  def on_mount(:default, _params, _session, socket) do
    cluster_nodes = Cluster.node_info()
    clustered = length(cluster_nodes) > 1

    socket =
      socket
      |> assign(:node_filter, :all)
      |> assign(:node_filter_nodes, cluster_nodes)
      |> assign(:node_filter_visible, clustered)
      |> attach_hook(:node_filter_events, :handle_event, &handle_event/3)
      |> attach_hook(:node_filter_info, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  # Default handler for :node_filter_changed — halts so LiveViews without
  # their own handler don't crash. Index pages that need to reload data
  # should define their own handle_info(:node_filter_changed, socket) clause;
  # they must detach this hook in mount or use the workaround below.
  #
  # Because attach_hook runs BEFORE the LiveView's handle_info, we can't
  # simply :cont here (the LV would still need a clause). Instead, we
  # halt and noop. Index pages that care override this by detaching and
  # reattaching, OR we just do the reload from here via a callback.
  #
  # Strategy: always halt. If the LiveView module exports
  # __node_filter_reload__/1, call it. Otherwise noop.
  defp handle_info(:node_filter_changed, socket) do
    view = socket.view

    if function_exported?(view, :reload_for_node_filter, 1) do
      {:noreply, updated_socket} = view.reload_for_node_filter(socket)
      {:halt, updated_socket}
    else
      {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp handle_event("node_filter_init", %{"nodes" => nodes}, socket) do
    all_node_names = Enum.map(socket.assigns.node_filter_nodes, & &1.name)

    filter =
      case nodes do
        [] ->
          :all

        names when is_list(names) ->
          valid = Enum.filter(names, &(&1 in all_node_names))
          if valid == [] or length(valid) == length(all_node_names), do: :all, else: MapSet.new(valid)
      end

    socket = assign(socket, :node_filter, filter)
    # Only notify if filter isn't :all (i.e. user had a saved filter)
    if filter != :all, do: send(self(), :node_filter_changed)
    {:halt, socket}
  end

  defp handle_event("toggle_node_filter", %{"node" => node_name}, socket) do
    all_node_names = Enum.map(socket.assigns.node_filter_nodes, & &1.name)
    current = socket.assigns.node_filter

    new_filter =
      case current do
        :all ->
          others = MapSet.new(all_node_names -- [node_name])
          if MapSet.size(others) == 0, do: :all, else: others

        set ->
          if MapSet.member?(set, node_name) do
            result = MapSet.delete(set, node_name)
            if MapSet.size(result) == 0, do: :all, else: result
          else
            result = MapSet.put(set, node_name)
            if MapSet.size(result) == length(all_node_names), do: :all, else: result
          end
      end

    socket =
      socket
      |> assign(:node_filter, new_filter)
      |> push_event("node_filter_updated", %{nodes: selected_node_names(new_filter)})

    send(self(), :node_filter_changed)
    {:halt, socket}
  end

  defp handle_event("solo_node_filter", %{"node" => node_name}, socket) do
    all_node_names = Enum.map(socket.assigns.node_filter_nodes, & &1.name)

    new_filter =
      if length(all_node_names) <= 1 do
        :all
      else
        MapSet.new([node_name])
      end

    socket =
      socket
      |> assign(:node_filter, new_filter)
      |> push_event("node_filter_updated", %{nodes: selected_node_names(new_filter)})

    send(self(), :node_filter_changed)
    {:halt, socket}
  end

  defp handle_event("node_filter_select_all", _params, socket) do
    socket =
      socket
      |> assign(:node_filter, :all)
      |> push_event("node_filter_updated", %{nodes: []})

    send(self(), :node_filter_changed)
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  Filter tagged results `[{node, item}, ...]` by the current node filter.
  Returns the filtered list of tagged tuples.
  """
  def filter_tagged(tagged_results, :all), do: tagged_results

  def filter_tagged(tagged_results, %MapSet{} = selected_names) do
    Enum.filter(tagged_results, fn {node, item} ->
      # Use the item's runner_node field if available (preserves disconnected node identity)
      # Otherwise fall back to the tuple's node atom
      node_name =
        case item do
          %{runner_node: rn} when is_binary(rn) and rn != "" -> Cluster.node_name(rn)
          _ -> Cluster.node_name(node)
        end

      node_name in selected_names
    end)
  end

  @doc """
  Returns the list of selected node names for the JS hook to persist.
  """
  def selected_node_names(:all), do: []
  def selected_node_names(%MapSet{} = set), do: MapSet.to_list(set)

  @doc """
  Check if a specific node name is selected in the current filter.
  """
  def node_selected?(:all, _node_name), do: true
  def node_selected?(%MapSet{} = set, node_name), do: MapSet.member?(set, node_name)
end
