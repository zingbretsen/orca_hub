defmodule OrcaHubWeb.NodeLive.Index do
  @moduledoc """
  Nodes index — also hosts the "Update all backends" sweep: a one-click
  fan-out that calls `OrcaHub.BackendInstaller.run/2` for every `:update`
  action across every CONNECTED node, and renders a node × backend progress
  grid driven by `OrcaHub.BackendInstaller`'s PubSub events.

  Update-only by design: `:install` rows are listed as skipped (mass-installing
  software from a single click is a bigger decision than this button makes),
  `:unavailable` rows show their reason, and offline nodes are always skipped
  — never proxied or reassigned to another node.

  Status is fetched per-node via `start_async/3` so one slow/hung node can't
  serialize the sweep — each node's status arrives (and its updates dispatch)
  independently in `handle_async/3`. Progress then streams in via
  `{:installer_output, node, backend, chunk}` / `{:installer_done, node,
  backend, result}` — the `node` field (added in Stage B) is what lets this
  page disambiguate which of the several node topics it's subscribed to a
  given message came from; the raw PubSub message itself carries no topic.

  Sweep state lives in `sweep_cells` (`%{{node_name, backend} => cell}`,
  `node_name` being the node's DB `name` string — the same key already used
  to look up rows in `@nodes`) plus `sweep_node_names` (a `MapSet` of node
  names currently part of the sweep, so the grid only renders rows that are
  actually in it). A best-effort restore on a fresh (connected) mount checks
  `running_backends/0` on every connected node so the grid can show spinners
  again after a page reload — it only recovers cells that are still running,
  not a full picture of a sweep that was already in progress before reload.
  """

  use OrcaHubWeb, :live_view

  alias OrcaHub.{BackendInstaller, Cluster, HubRPC, NodeConfig}
  alias OrcaHub.ClusterNodes.ClusterNode

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Nodes")
      |> assign(nodes: load_nodes())
      |> assign(sweep_active?: false, sweep_summary: nil)
      |> assign(sweep_cells: %{}, sweep_node_names: MapSet.new())
      |> assign(adding_node?: false, add_node_form: nil)

    socket = if connected?(socket), do: restore_running_sweep(socket), else: socket

    {:ok, socket}
  end

  def last_connected_label(true, _last_connected_at), do: "Connected now"
  def last_connected_label(false, nil), do: "Never"

  def last_connected_label(false, last_connected_at),
    do: OrcaHubWeb.DashboardLive.time_ago(last_connected_at)

  @doc "The fixed backend list the sweep grid's columns are built from."
  def backends, do: NodeConfig.backends()

  # -------------------------------------------------------------------
  # Add node: a `nodes` row can only ever be auto-created by
  # OrcaHub.ClusterNodeTracker when a node first connects — but a LAN node
  # the hub can't dial *into* can never connect until the hub dials *out*
  # to it, which requires a row with `dial: true` to already exist. This
  # form is the only way to bootstrap that first row.
  # -------------------------------------------------------------------

  @impl true
  def handle_event("show_add_node_form", _params, socket) do
    changeset = ClusterNode.changeset(%ClusterNode{}, %{dial: true})
    {:noreply, assign(socket, adding_node?: true, add_node_form: to_form(changeset))}
  end

  def handle_event("cancel_add_node_form", _params, socket) do
    {:noreply, assign(socket, adding_node?: false, add_node_form: nil)}
  end

  def handle_event("validate_add_node", %{"cluster_node" => params}, socket) do
    changeset =
      %ClusterNode{}
      |> ClusterNode.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, add_node_form: to_form(changeset))}
  end

  def handle_event("save_add_node", %{"cluster_node" => params}, socket) do
    case HubRPC.create_node(params) do
      {:ok, _node} ->
        {:noreply,
         socket
         |> assign(nodes: load_nodes(), adding_node?: false, add_node_form: nil)
         |> put_flash(:info, "Node added")}

      {:error, changeset} ->
        {:noreply, assign(socket, add_node_form: to_form(changeset))}
    end
  end

  # -------------------------------------------------------------------
  # Sweep: kick-off
  # -------------------------------------------------------------------

  @impl true
  def handle_event("sweep_update_all", _params, socket) do
    targets = connected_targets(socket.assigns.nodes)
    offline_rows = Enum.reject(socket.assigns.nodes, & &1.connected)

    socket =
      socket
      |> assign(sweep_active?: true, sweep_summary: nil)
      |> init_offline_cells(offline_rows)
      |> init_pending_cells(targets)

    socket =
      Enum.reduce(targets, socket, fn {name, atom}, acc ->
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, BackendInstaller.topic(atom))
        start_async(acc, {:sweep_status, name}, fn -> fetch_status(atom) end)
      end)

    {:noreply, maybe_finalize_sweep(socket)}
  end

  # -------------------------------------------------------------------
  # Sweep: per-node status arrives (async, one node can't block another)
  # -------------------------------------------------------------------

  @impl true
  def handle_async({:sweep_status, name}, result, socket) do
    socket =
      case result do
        {:ok, {:ok, rows}} -> apply_status_rows(socket, name, rows)
        {:ok, {:error, _reason}} -> mark_status_unreachable(socket, name)
        {:exit, _reason} -> mark_status_unreachable(socket, name)
      end

    {:noreply, maybe_finalize_sweep(socket)}
  end

  # -------------------------------------------------------------------
  # Sweep: job progress (OrcaHub.BackendInstaller.Job PubSub events)
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:installer_output, node, backend, chunk}, socket) do
    {:noreply, update_output_tail(socket, to_string(node), backend, chunk)}
  end

  def handle_info({:installer_done, node, backend, result}, socket) do
    name = to_string(node)

    new_cell =
      case result do
        {:ok, version} -> cell(:done, :update, nil, version)
        {:error, reason} -> cell(:failed, :update, format_done_reason(reason), nil)
      end

    {:noreply,
     socket
     |> put_cell(name, backend, new_cell)
     |> maybe_finalize_sweep()}
  end

  # -------------------------------------------------------------------
  # Private helpers — node loading (unchanged from before Stage B)
  # -------------------------------------------------------------------

  defp load_nodes do
    connected_names = Cluster.nodes() |> MapSet.new(&Atom.to_string/1)

    rows =
      HubRPC.list_nodes()
      |> Enum.map(fn n ->
        %{
          node: n,
          connected: MapSet.member?(connected_names, n.name),
          session_count: HubRPC.count_sessions_for_node(n.name),
          project_count: HubRPC.count_projects_for_node(n.name)
        }
      end)

    {connected, offline} = Enum.split_with(rows, & &1.connected)

    Enum.sort_by(connected, & &1.node.display_name) ++
      Enum.sort_by(
        offline,
        &(&1.node.last_connected_at || ~U[1970-01-01 00:00:00Z]),
        {:desc, DateTime}
      )
  end

  # -------------------------------------------------------------------
  # Private helpers — sweep
  # -------------------------------------------------------------------

  # A node string in the `nodes` table is only ever meaningful as a live
  # Erlang node atom if that atom already exists in this VM (i.e. we've
  # actually connected to it before) — mirrors NodeLive.Show's
  # resolve_target_node/1.
  defp resolve_atom(name) do
    atom = String.to_existing_atom(name)
    if atom in Cluster.nodes(), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp connected_targets(nodes) do
    nodes
    |> Enum.filter(& &1.connected)
    |> Enum.flat_map(fn %{node: n} ->
      case resolve_atom(n.name) do
        nil -> []
        atom -> [{n.name, atom}]
      end
    end)
  end

  defp fetch_status(atom) do
    case Cluster.rpc(atom, BackendInstaller, :status, [], 12_000) do
      list when is_list(list) -> {:ok, list}
      other -> {:error, other}
    end
  end

  defp dispatch_run(name, backend) do
    case resolve_atom(name) do
      nil -> {:error, :node_unavailable}
      atom -> Cluster.rpc(atom, BackendInstaller, :run, [backend, :update])
    end
  end

  defp safe_running_backends(atom) do
    case Cluster.rpc(atom, BackendInstaller, :running_backends, [], 6_000) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp restore_running_sweep(socket) do
    targets = connected_targets(socket.assigns.nodes)

    running_by_node =
      targets
      |> Task.async_stream(fn {name, atom} -> {name, atom, safe_running_backends(atom)} end,
        timeout: 6_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {name, atom, backends}} when backends != [] -> [{name, atom, backends}]
        _ -> []
      end)

    if running_by_node == [] do
      socket
    else
      socket = assign(socket, sweep_active?: true)

      Enum.reduce(running_by_node, socket, fn {name, atom, backends}, acc ->
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, BackendInstaller.topic(atom))

        Enum.reduce(backends, acc, fn backend, acc2 ->
          put_cell(acc2, name, backend, cell(:running, :update, nil, nil))
        end)
      end)
    end
  end

  defp init_offline_cells(socket, offline_rows) do
    Enum.reduce(offline_rows, socket, fn %{node: n}, acc ->
      Enum.reduce(backends(), acc, fn backend, acc2 ->
        put_cell(acc2, n.name, backend, cell(:skipped, nil, "node unavailable", nil))
      end)
    end)
  end

  defp init_pending_cells(socket, targets) do
    Enum.reduce(targets, socket, fn {name, _atom}, acc ->
      Enum.reduce(backends(), acc, fn backend, acc2 ->
        put_cell(acc2, name, backend, cell(:pending, nil, nil, nil))
      end)
    end)
  end

  defp apply_status_rows(socket, name, rows) do
    Enum.reduce(rows, socket, fn row, acc ->
      case row.action do
        :update ->
          apply_update_action(acc, name, row.backend)

        :install ->
          put_cell(acc, name, row.backend, cell(:skipped, :install, "not installed", nil))

        :unavailable ->
          put_cell(
            acc,
            name,
            row.backend,
            cell(:skipped, :unavailable, row.unavailable_reason, nil)
          )
      end
    end)
  end

  defp apply_update_action(socket, name, backend) do
    case dispatch_run(name, backend) do
      :ok ->
        put_cell(socket, name, backend, cell(:running, :update, nil, nil))

      {:error, :already_running} ->
        put_cell(socket, name, backend, cell(:running, :update, "already running", nil))

      {:error, reason} ->
        put_cell(socket, name, backend, cell(:failed, :update, inspect(reason), nil))
    end
  end

  defp mark_status_unreachable(socket, name) do
    Enum.reduce(backends(), socket, fn backend, acc ->
      put_cell(acc, name, backend, cell(:skipped, nil, "could not fetch backend status", nil))
    end)
  end

  defp cell(status, action, reason, version) do
    %{status: status, action: action, reason: reason, version: version, output_tail: ""}
  end

  defp put_cell(socket, name, backend, cell) do
    socket
    |> update(:sweep_cells, &Map.put(&1, {name, backend}, cell))
    |> update(:sweep_node_names, &MapSet.put(&1, name))
  end

  defp update_output_tail(socket, name, backend, chunk) do
    update(socket, :sweep_cells, fn cells ->
      Map.update(
        cells,
        {name, backend},
        cell(:running, :update, nil, nil) |> Map.put(:output_tail, last_line(chunk, "")),
        fn c -> %{c | output_tail: last_line(chunk, c.output_tail)} end
      )
    end)
  end

  defp last_line(chunk, prev) do
    case chunk |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.last() do
      nil -> prev
      line -> String.slice(line, 0, 160)
    end
  end

  defp format_done_reason(:timeout), do: "timed out"
  defp format_done_reason(:not_found), do: "command not found"
  defp format_done_reason(:invalid_action), do: "invalid action"
  defp format_done_reason(code) when is_integer(code), do: "exit code #{code}"
  defp format_done_reason(other), do: inspect(other)

  defp maybe_finalize_sweep(socket) do
    cells = socket.assigns.sweep_cells

    if socket.assigns.sweep_active? and
         Enum.all?(cells, fn {_key, c} -> c.status in [:done, :failed, :skipped] end) do
      assign(socket, sweep_active?: false, sweep_summary: summarize(cells))
    else
      socket
    end
  end

  defp summarize(cells) do
    counts = cells |> Map.values() |> Enum.frequencies_by(& &1.status)

    "#{counts[:done] || 0} updated, #{counts[:failed] || 0} failed, #{counts[:skipped] || 0} skipped"
  end
end
