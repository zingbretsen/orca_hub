defmodule OrcaHubWeb.NodeLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    node = HubRPC.get_node!(id)
    connected? = Cluster.nodes() |> Enum.map(&Atom.to_string/1) |> Enum.member?(node.name)

    {:ok,
     socket
     |> assign(
       page_title: node.display_name,
       node: node,
       connected: connected?,
       session_count: HubRPC.count_sessions_for_node(node.name),
       project_count: HubRPC.count_projects_for_node(node.name)
     )}
  end

  def last_connected_label(true, _last_connected_at), do: "Connected now"
  def last_connected_label(false, nil), do: "Never"

  def last_connected_label(false, last_connected_at),
    do: OrcaHubWeb.DashboardLive.time_ago(last_connected_at)

  def first_connected_label(nil), do: "Unknown"
  def first_connected_label(dt), do: OrcaHubWeb.DashboardLive.time_ago(dt)
end
