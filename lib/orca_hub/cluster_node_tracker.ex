defmodule OrcaHub.ClusterNodeTracker do
  @moduledoc """
  Hub-only GenServer that records which Erlang nodes have connected to the
  cluster (currently or previously), for the /nodes UI
  (`OrcaHub.ClusterNodes`). Started only from `Application.hub_children/1` —
  agents never track cluster membership themselves, they only ever appear
  as a row the hub creates when it sees them.
  """

  use GenServer
  require Logger

  alias OrcaHub.Cluster
  alias OrcaHub.ClusterNodes

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)

    Enum.each(Cluster.nodes(), &record_seen/1)
    backfill_from_data()

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, n}, state) do
    record_seen(n)
    {:noreply, state}
  end

  def handle_info({:nodedown, n}, state) do
    ClusterNodes.touch_last_connected(Atom.to_string(n))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp record_seen(n) do
    ClusterNodes.upsert_seen(Atom.to_string(n), Cluster.node_name(n))
  end

  defp backfill_from_data do
    known = ClusterNodes.list_nodes() |> MapSet.new(& &1.name)

    ClusterNodes.distinct_session_and_project_node_names()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.each(fn name -> ClusterNodes.backfill_node(name, Cluster.node_name(name)) end)
  rescue
    e -> Logger.warning("ClusterNodeTracker backfill failed: #{Exception.message(e)}")
  end
end
