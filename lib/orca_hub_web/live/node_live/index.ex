defmodule OrcaHubWeb.NodeLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Nodes") |> assign(nodes: load_nodes())}
  end

  def last_connected_label(true, _last_connected_at), do: "Connected now"
  def last_connected_label(false, nil), do: "Never"

  def last_connected_label(false, last_connected_at),
    do: OrcaHubWeb.DashboardLive.time_ago(last_connected_at)

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
end
