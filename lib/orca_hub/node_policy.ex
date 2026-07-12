defmodule OrcaHub.NodePolicy do
  @moduledoc """
  Cross-node isolation policy for MCP session tools (`OrcaHub.MCP.Tools.Sessions`
  et al). A node can be flagged `isolated` (via the `nodes` table / `/nodes`
  UI) so that sessions running on it cannot message, inspect, spawn, or
  discover sessions on any OTHER node — e.g. a Discord agent node that
  should stay sandboxed to its own directory.

  Isolation is a property of the CALLER's node, checked at the moment a tool
  call would reach across to a different node. Inbound traffic (another
  node reaching a session on an isolated node) is intentionally unaffected —
  isolation only restricts what an isolated node can initiate.

  Fails OPEN on lookup failure (hub unreachable, no `nodes` row for this
  node yet) — these tools already depend on `HubRPC`/the hub being up for
  the operation itself, so a lookup failure here just means "couldn't
  determine isolation, don't newly block on top of that."
  """

  require Logger

  alias OrcaHub.HubRPC

  @doc "Whether the LOCAL node (`node()`) is currently flagged isolated."
  def local_node_isolated? do
    case HubRPC.get_node_by_name(Atom.to_string(node())) do
      %{isolated: true} ->
        true

      %{} ->
        false

      nil ->
        false

      other ->
        Logger.warning(
          "[NodePolicy] unexpected result looking up isolation for #{node()}: #{inspect(other)} — treating as not isolated"
        )

        false
    end
  rescue
    error ->
      Logger.warning(
        "[NodePolicy] failed to look up isolation for #{node()}: #{Exception.format(:error, error)} — treating as not isolated"
      )

      false
  catch
    kind, reason ->
      Logger.warning(
        "[NodePolicy] failed to look up isolation for #{node()}: #{inspect({kind, reason})} — treating as not isolated"
      )

      false
  end

  @doc """
  Whether the calling (local) node is allowed to reach `target_node`. Always
  true for the local node itself or an unassigned/nil target (nothing
  cross-node is actually happening) — otherwise false only when the LOCAL
  node is isolated.
  """
  def cross_node_allowed?(target_node) when target_node in [nil, node()], do: true
  def cross_node_allowed?(_target_node), do: not local_node_isolated?()

  @doc "Standard denial message for a blocked cross-node tool call."
  def denial_message(target_node) do
    "This node (#{node()}) is isolated: sessions here cannot interact with sessions or " <>
      "projects on other nodes (target: #{inspect(target_node)})."
  end
end
