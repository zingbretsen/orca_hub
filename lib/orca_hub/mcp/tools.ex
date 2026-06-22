defmodule OrcaHub.MCP.Tools do
  @moduledoc """
  MCP tool registry and dispatcher.

  Tool definitions and their `call/3` implementations live in per-category
  modules under `OrcaHub.MCP.Tools.*`. This module is a thin facade that
  concatenates their definitions for `list/0,1` and routes `call/3` to the
  owning category module by tool name.

  ## Tool visibility

  `tools/list` is filtered by the connection's role, which is carried on the
  MCP server `state` (`:orchestrator`) and sourced from the MCP connection
  itself (a query param set by `SessionRunner`) — never from a hub/DB lookup.
  Orchestrator connections see every tool; regular connections see only the
  tools in `@regular_session_tools` (messaging another session and opening
  files). This keeps `initialize` free of any hub work.

  `call/3` does **not** gate by role: any known tool may be called. Only
  genuinely-unknown tool names are rejected.
  """

  alias OrcaHub.MCP.Tools.{Files, Heartbeat, Result, Sessions, Triggers}

  @categories [Sessions, Triggers, Files, Heartbeat]

  # Tools visible to regular (non-orchestrator) connections. Orchestrator
  # connections see every tool.
  @regular_session_tools ~w(send_message_to_session open_file)

  @doc "Return every MCP tool definition map across every category."
  def list do
    Enum.flat_map(@categories, & &1.list())
  end

  @doc """
  Return the MCP tool definitions visible to the given MCP server `state`.
  Orchestrator connections see every tool; regular connections see only the
  tools in `@regular_session_tools`. The role is read from `state`, not a
  hub lookup.
  """
  def list(state) do
    if orchestrator?(state) do
      list()
    else
      Enum.filter(list(), &(&1["name"] in @regular_session_tools))
    end
  end

  @doc """
  Dispatch a tool call by name to its owning category module. Unknown tool
  names return an error result. Known tools are dispatched regardless of the
  connection role.
  """
  def call(name, args, state) do
    case category_for(name) do
      nil -> Result.error("Unknown tool: #{name}")
      module -> module.call(name, args, state)
    end
  end

  defp category_for(name) do
    Enum.find(@categories, fn module ->
      Enum.any?(module.list(), &(&1["name"] == name))
    end)
  end

  # The connection role is resolved once (from the MCP connection's query
  # param) and cached in state at MCP.Server init. Absent/unknown defaults to
  # a regular (non-orchestrator) connection.
  defp orchestrator?(%{orchestrator: true}), do: true
  defp orchestrator?(_state), do: false
end
