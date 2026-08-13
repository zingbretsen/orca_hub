defmodule OrcaHub.MCP.Tools.ForkQueue do
  @moduledoc """
  The orchestrator-facing half of `OrcaHub.ForkGate` (pi_fork_spec.md §6.1):
  inspect, resume, or abort the serialized first-turn queue for the fork
  children you spawned.

  Only reachable in one situation that matters — the gate detected that a
  forked child's first turn was a prompt-cache MISS and PAUSED the rest of
  the fan-out rather than serially paying a full cold prefill for every
  remaining sibling. The `[Session lifecycle]` message it sends names this
  tool; without it that notification would be unactionable.

  The gate is a per-node process and a fork child always runs on its parent's
  node (§3's same-node restriction), which is also the node serving this MCP
  connection — so this dispatches locally, no cross-node routing.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.ForkGate

  def list do
    [
      %{
        "name" => "fork_queue",
        "description" =>
          "Inspect, resume, or abort the first-turn queue for pi fork children you spawned " <>
            "with start_session(fork_from_parent: true). Forked children's first turns are " <>
            "serialized (one at a time) so each one's inherited context is served from the " <>
            "provider's prompt cache instead of cold-prefilled. If a child's first turn missed " <>
            "the cache, the remaining fan-out is PAUSED and you are notified — use action " <>
            "\"resume\" to send the rest anyway (each may pay a full cold prefill, which is " <>
            "slow and degrades every other tenant of the serving box) or \"abort\" to drop the " <>
            "queue. Aborted children are NOT deleted: they stay created and un-prompted, so " <>
            "you can message or archive them yourself.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["status", "resume", "abort"],
              "description" =>
                "\"status\" (default) reports the queue; \"resume\" releases the next pending " <>
                  "child's first prompt and un-pauses; \"abort\" drops every pending first " <>
                  "prompt without touching the child sessions."
            },
            "parent_session_id" => %{
              "type" => "string",
              "description" =>
                "The session whose fork children are queued. Defaults to your own session — " <>
                  "the queue is keyed by the PARENT, so this is only needed if you are asking " <>
                  "on behalf of another session."
            }
          }
        }
      }
    ]
  end

  def call("fork_queue", args, state) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      caller_id ->
        parent_id = args["parent_session_id"] || caller_id
        dispatch(args["action"] || "status", parent_id)
    end
  end

  defp dispatch("status", parent_id) do
    case ForkGate.status(parent_id) do
      nil ->
        text(
          "No fork queue for session #{parent_id} — nothing is pending, and no forked child's " <>
            "first turn is in flight on this node."
        )

      snapshot ->
        text(Jason.encode!(describe(parent_id, snapshot)))
    end
  end

  defp dispatch("resume", parent_id) do
    case ForkGate.resume(parent_id) do
      {:error, :not_found} ->
        error(
          "No fork queue for session #{parent_id} — nothing to resume. (Gate state is per-node " <>
            "and in-memory: a node restart drops queues, and the affected children send " <>
            "unserialized.)"
        )

      {:ok, snapshot} ->
        text(
          Jason.encode!(
            Map.put(
              describe(parent_id, snapshot),
              :resumed,
              "Released the next forked child's first prompt; the rest follow one turn at a time."
            )
          )
        )
    end
  end

  defp dispatch("abort", parent_id) do
    {:ok, dropped} = ForkGate.abort(parent_id)

    text(
      Jason.encode!(%{
        parent_session_id: parent_id,
        aborted: length(dropped),
        dropped_child_session_ids: dropped,
        note:
          "These child sessions still exist and are un-prompted — send_message_to_session to " <>
            "prompt one yourself (cold prefill), or archive_session to clean it up."
      })
    )
  end

  defp dispatch(action, _parent_id) do
    error("Unknown action #{inspect(action)}. Use \"status\", \"resume\", or \"abort\".")
  end

  defp describe(parent_id, snapshot) do
    %{
      parent_session_id: parent_id,
      active_child_session_id: snapshot.active_child,
      pending_child_session_ids: snapshot.pending,
      paused: snapshot.paused != nil,
      paused_reason: snapshot.paused && snapshot.paused[:reason]
    }
  end
end
