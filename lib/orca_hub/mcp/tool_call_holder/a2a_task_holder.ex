defmodule OrcaHub.MCP.ToolCallHolder.A2ATaskHolder do
  @moduledoc """
  `OrcaHub.MCP.ToolCallHolder` adapter over the inbound A2A server's
  `a2a_tasks` table (docs/a2a.md v2 — client tools + structured results).

  `parked_status`/`resumed_status` are the A2A wire states directly
  (`"input-required"`/`"working"`) — unlike `ApiRunHolder`'s internal-only
  `awaiting_tool_result`, these ARE the values `A2AController` renders to
  callers, since A2A's task states are the wire protocol.
  """

  @behaviour OrcaHub.MCP.ToolCallHolder

  alias OrcaHub.HubRPC

  @impl true
  def get_by_session_id(session_id), do: HubRPC.get_a2a_task_by_session_id(session_id)

  @impl true
  def get(id), do: HubRPC.get_a2a_task(id)

  # The shared parking code in MCP.Server is holder-agnostic — it has no idea
  # `a2a_tasks` also needs to remember every distinct tool_call_id it has
  # ever parked (for the idempotent-ack precedence rule, docs/a2a.md). Every
  # `update/2` call that sets a NEW `pending_tool_call` (park or re-park —
  # see `persist_and_park/6`/`repark_existing/5`) goes through here, so this
  # is the one place to fold that id into `issued_tool_call_ids` transparently,
  # without teaching the shared code anything A2A-specific. A `clear` update
  # (`pending_tool_call: nil`) doesn't match this clause and falls through
  # unchanged — history is only ever appended to, never touched on clear.
  @impl true
  def update(task, %{pending_tool_call: %{"id" => id}} = attrs) when is_binary(id) do
    issued = Enum.uniq([id | task.issued_tool_call_ids || []])
    HubRPC.update_a2a_task(task, Map.put(attrs, :issued_tool_call_ids, issued))
  end

  def update(task, attrs), do: HubRPC.update_a2a_task(task, attrs)

  @impl true
  def topic(id), do: "a2a_task:#{id}"

  @impl true
  def parked_status, do: "input-required"

  @impl true
  def resumed_status, do: "working"
end
