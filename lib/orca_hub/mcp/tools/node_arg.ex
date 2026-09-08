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

  alias OrcaHub.{Cluster, Mode}

  @hub_lookup_timeout 5_000

  @doc """
  Resolves `name` against currently-connected nodes. `nil`/`""` resolves to
  this node. Returns `{:ok, node_atom} | {:error, message}`.

  Checks the LOCAL view first (`Cluster.nodes/0`). On a miss, an agent node
  additionally asks the hub for ITS node list and matches there — agent
  nodes are deliberately unmeshed with each other (only with the hub), so
  the local view alone can never see a sibling agent (ORCAHUB3-73). Either
  way, only atoms already returned by a connected node are ever matched
  against — `String.to_atom/1` is never called on caller-supplied `name`.
  """
  def resolve(nil), do: {:ok, node()}
  def resolve(""), do: {:ok, node()}

  def resolve(name) when is_binary(name) do
    case find_among(Cluster.nodes(), name) do
      {:ok, n} -> {:ok, n}
      :error -> resolve_via_hub(name)
    end
  end

  defp resolve_via_hub(name) do
    if Mode.agent?() do
      case hub_nodes() do
        {:ok, nodes} ->
          case find_among(nodes, name) do
            {:ok, n} -> {:ok, n}
            :error -> {:error, not_connected_anywhere_message(name, nodes)}
          end

        :error ->
          {:error, not_connected_here_message(name)}
      end
    else
      {:error, not_connected_here_message(name)}
    end
  end

  defp find_among(nodes, name) do
    case Enum.find(nodes, &(Atom.to_string(&1) == name)) do
      nil -> :error
      n -> {:ok, n}
    end
  end

  # Overridable via the :node_arg_hub_nodes_fetcher app env (a 0-arity fun
  # returning {:ok, [node_atom]} | :error) so tests can exercise the
  # hub-relay branch without a real second connected node.
  defp hub_nodes do
    Application.get_env(:orca_hub, :node_arg_hub_nodes_fetcher, &default_hub_nodes/0).()
  end

  defp default_hub_nodes do
    case Cluster.rpc(Mode.hub_node(), Cluster, :nodes, [], @hub_lookup_timeout) do
      nodes when is_list(nodes) -> {:ok, nodes}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp not_connected_anywhere_message(name, connected) do
    list = Enum.map_join(connected, ", ", &Atom.to_string/1)

    "Unknown or disconnected node: #{name}. Not connected anywhere in the cluster. " <>
      "Connected nodes: #{list}"
  end

  defp not_connected_here_message(name) do
    connected = Enum.map_join(Cluster.nodes(), ", ", &Atom.to_string/1)

    "Unknown or disconnected node: #{name}. Not connected from this node. " <>
      "Connected nodes: #{connected}"
  end
end
