defmodule OrcaHub.NodePolicy do
  @moduledoc """
  Per-node security policy, looked up from the `nodes` table / `/nodes` UI.

  ## Isolation

  A node can be flagged `isolated` so that sessions running on it cannot
  message, inspect, spawn, or discover sessions on any OTHER node — e.g. a
  Discord agent node that should stay sandboxed to its own directory.

  Isolation is a property of the CALLER's node, checked at the moment a tool
  call would reach across to a different node. Inbound traffic (another
  node reaching a session on an isolated node) is intentionally unaffected —
  isolation only restricts what an isolated node can initiate.

  ## Session env scrubbing

  A node can also be flagged `scrub_session_env` so that agent-CLI sessions
  and terminal PTYs spawned on it use `OrcaHub.Env.strict_env/1` (allow-list
  only) instead of `OrcaHub.Env.sanitized_env/1` (inherits the full BEAM
  environment minus release cruft) — e.g. that same Discord node, whose
  sessions are triggered by untrusted Discord users and shouldn't be able to
  read `DISCORD_TOKEN`/`SECRET_KEY_BASE`/etc. via the Bash tool.

  ## Fail-open posture

  Both flags fail OPEN on lookup failure (hub unreachable, no `nodes` row
  for this node yet) — these callers already depend on `HubRPC`/the hub
  being up for the operation itself (session spawn, MCP tool call), so a
  lookup failure here just means "couldn't determine the policy, don't
  newly block/scrub on top of that." This is a real tradeoff for
  `scrub_session_env?/0` specifically (failing open on a security control),
  accepted for consistency with `isolated`'s established posture — a hub
  outage already blocks session spawns needing other HubRPC calls (e.g.
  Claude's `node_oauth_env/0`).
  """

  require Logger

  alias OrcaHub.HubRPC

  @doc "Whether the LOCAL node (`node()`) is currently flagged isolated."
  def local_node_isolated?, do: local_node_flag?(:isolated)

  @doc """
  Whether the LOCAL node is currently flagged to scrub session env — see the
  moduledoc's "Session env scrubbing" section.
  """
  def scrub_session_env?, do: local_node_flag?(:scrub_session_env)

  defp local_node_flag?(field) do
    case HubRPC.get_node_by_name(Atom.to_string(node())) do
      %{^field => true} ->
        true

      %{} ->
        false

      nil ->
        false

      other ->
        Logger.warning(
          "[NodePolicy] unexpected result looking up #{field} for #{node()}: #{inspect(other)} — treating as false"
        )

        false
    end
  rescue
    error ->
      Logger.warning(
        "[NodePolicy] failed to look up #{field} for #{node()}: #{Exception.format(:error, error)} — treating as false"
      )

      false
  catch
    kind, reason ->
      Logger.warning(
        "[NodePolicy] failed to look up #{field} for #{node()}: #{inspect({kind, reason})} — treating as false"
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
