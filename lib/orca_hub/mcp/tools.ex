defmodule OrcaHub.MCP.Tools do
  @moduledoc """
  MCP tool registry and dispatcher.

  Tool definitions and their `call/3` implementations live in per-category
  modules under `OrcaHub.MCP.Tools.*`. This module is a thin facade that
  concatenates their definitions for `list/0` and routes `call/3` to the
  owning category module by tool name.
  """

  alias OrcaHub.MCP.Tools.{Files, Heartbeat, Result, Sessions, Triggers}

  @categories [Sessions, Triggers, Files, Heartbeat]

  @doc "Return all MCP tool definition maps across every category."
  def list do
    Enum.flat_map(@categories, & &1.list())
  end

  @doc """
  Dispatch a tool call by name to its category module. Unknown tool names
  return an error result.
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
end
