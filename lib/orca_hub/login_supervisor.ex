defmodule OrcaHub.LoginSupervisor do
  @moduledoc """
  DynamicSupervisor for the singleton `OrcaHub.LoginRunner` on each node.

  Runs on every node (hub and agent) so a node can be logged into Claude
  Code from the web UI via `Cluster.rpc/5`.
  """

  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
