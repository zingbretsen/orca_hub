defmodule OrcaHub.MCP.Tools do
  @moduledoc """
  MCP tool registry and dispatcher.

  Tool definitions and their `call/3` implementations live in per-category
  modules under `OrcaHub.MCP.Tools.*`. This module is a thin facade that
  concatenates their definitions for `list/1` and routes `call/3` to the
  owning category module by tool name.

  ## Permissions

  Most tools are restricted to **orchestrator** sessions, which coordinate
  work across other sessions. Regular (non-orchestrator) sessions can only
  use the tools in `@regular_session_tools` — messaging another session and
  opening files. Both `list/1` and `call/3` enforce this based on whether
  the calling MCP connection is linked to an orchestrator session.
  """

  alias OrcaHub.HubRPC
  alias OrcaHub.MCP.Tools.{Files, Heartbeat, Result, Sessions, Triggers}

  @categories [Sessions, Triggers, Files, Heartbeat]

  # Tools available to regular (non-orchestrator) sessions. All other tools
  # require an orchestrator session.
  @regular_session_tools ~w(send_message_to_session open_file)

  @doc "Return every MCP tool definition map across every category."
  def list do
    Enum.flat_map(@categories, & &1.list())
  end

  @doc """
  Return the MCP tool definitions visible to the given MCP server `state`.
  Orchestrator sessions see every tool; regular sessions see only the
  tools in `@regular_session_tools`.
  """
  def list(state) do
    if orchestrator?(state) do
      list()
    else
      Enum.filter(list(), &(&1["name"] in @regular_session_tools))
    end
  end

  @doc """
  Dispatch a tool call by name to its category module. Unknown tool names
  return an error result, as do tools the calling session is not permitted
  to use.
  """
  def call(name, args, state) do
    cond do
      category_for(name) == nil ->
        Result.error("Unknown tool: #{name}")

      not tool_allowed?(name, state) ->
        Result.error(
          "Tool \"#{name}\" is only available to orchestrator sessions. " <>
            "Regular sessions can only use: #{Enum.join(@regular_session_tools, ", ")}."
        )

      true ->
        category_for(name).call(name, args, state)
    end
  end

  defp category_for(name) do
    Enum.find(@categories, fn module ->
      Enum.any?(module.list(), &(&1["name"] == name))
    end)
  end

  defp tool_allowed?(name, state) do
    name in @regular_session_tools or orchestrator?(state)
  end

  # Whether the MCP connection is linked to an orchestrator OrcaHub session.
  # Connections with no linked session are treated as regular sessions.
  defp orchestrator?(%{orca_session_id: session_id}) when is_binary(session_id) do
    case HubRPC.get_session(session_id) do
      nil -> false
      session -> session.orchestrator == true
    end
  end

  defp orchestrator?(_state), do: false
end
