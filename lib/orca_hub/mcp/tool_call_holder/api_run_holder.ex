defmodule OrcaHub.MCP.ToolCallHolder.ApiRunHolder do
  @moduledoc """
  `OrcaHub.MCP.ToolCallHolder` adapter over the Agent Runs API's `api_runs`
  table (docs/api.md) — the original client-tool-call parking holder, thin
  wrapper around the existing `OrcaHub.HubRPC` calls.
  """

  @behaviour OrcaHub.MCP.ToolCallHolder

  alias OrcaHub.HubRPC

  @impl true
  def get_by_session_id(session_id), do: HubRPC.get_run_by_session_id(session_id)

  @impl true
  def get(id), do: HubRPC.get_api_run(id)

  @impl true
  def update(run, attrs), do: HubRPC.update_api_run(run, attrs)

  @impl true
  def topic(id), do: "api_run:#{id}"

  @impl true
  def parked_status, do: "awaiting_tool_result"

  @impl true
  def resumed_status, do: "running"
end
