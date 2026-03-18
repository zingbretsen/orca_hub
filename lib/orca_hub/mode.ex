defmodule OrcaHub.Mode do
  @moduledoc """
  Detects whether this node is running as a hub or agent.

  - **hub** (default): Full stack — database, web UI, scheduler, MCP, everything.
  - **agent**: Lightweight — runs SessionRunner processes and connects to the hub
    for all database operations via Erlang distribution.

  Set the `ORCA_MODE` environment variable to `agent` to run in agent mode.
  """

  @doc "Returns :hub or :agent"
  def mode do
    Application.get_env(:orca_hub, :mode, :hub)
  end

  @doc "True if this node is the hub (has its own database)."
  def hub?, do: mode() == :hub

  @doc "True if this node is an agent (no local database)."
  def agent?, do: mode() == :agent

  @doc """
  Returns the hub node. In hub mode, returns self.
  In agent mode, discovers the hub from connected nodes.
  """
  def hub_node do
    if hub?() do
      node()
    else
      find_hub_node()
    end
  end

  defp find_hub_node do
    # Check connected nodes for one running in hub mode
    Enum.find(Node.list(), fn n ->
      try do
        :erpc.call(n, __MODULE__, :hub?, [], 5_000)
      catch
        _, _ -> false
      end
    end) || raise "No hub node found in cluster. Ensure the hub is running and connected."
  end
end
