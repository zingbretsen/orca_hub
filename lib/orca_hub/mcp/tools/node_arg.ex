defmodule OrcaHub.MCP.Tools.NodeArg do
  @moduledoc """
  Resolves a caller-supplied `node` string argument to a live node atom,
  safely.

  A `node` argument arrives as caller-supplied text at the MCP boundary,
  unlike every other place a node atom is derived in this codebase (always
  from a trusted DB column via `Cluster.runner_node_for/1`/
  `project_node_for/1`, which is safe to `String.to_atom/1` because it was
  written by our own code). `resolve/1` never calls `String.to_atom/1` on
  its input — it only matches against `Cluster.nodes/0`, the list of
  ALREADY-existing, currently-connected node atoms, so an arbitrary/garbage
  `node` string can never grow the atom table.

  Originally written inline for `OrcaHub.MCP.Tools.Probes` (ORCAHUB3-28);
  extracted here so `OrcaHub.MCP.Tools.Sessions`'s `start_session` node
  targeting reuses the identical safety property instead of a second,
  easy-to-drift copy.
  """

  alias OrcaHub.Cluster

  @doc """
  Resolves `name` against currently-connected nodes. `nil`/`""` resolves to
  this node. Returns `{:ok, node_atom} | {:error, message}`.
  """
  def resolve(nil), do: {:ok, node()}
  def resolve(""), do: {:ok, node()}

  def resolve(name) when is_binary(name) do
    case Enum.find(Cluster.nodes(), &(Atom.to_string(&1) == name)) do
      nil ->
        connected = Enum.map_join(Cluster.nodes(), ", ", &Atom.to_string/1)
        {:error, "Unknown or disconnected node: #{name}. Connected nodes: #{connected}"}

      n ->
        {:ok, n}
    end
  end
end
