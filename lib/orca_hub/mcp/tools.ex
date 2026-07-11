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
  files), plus `send_discord_message` when (and only when) the connection's
  session is actually Discord-bridged. That one exception needs a hub lookup,
  so it is done lazily in `list/1` itself, gated behind `Discord.enabled?()`
  first (a cheap local check) so every non-Discord node's `tools/list` stays
  free of hub work. `initialize` itself never does a hub lookup.

  `call/3` does **not** gate by role: any known tool may be called. Only
  genuinely-unknown tool names are rejected.
  """

  require Logger

  alias OrcaHub.MCP.Tools.{Discord, FeatureRequests, Files, Heartbeat, Result, Sessions, Triggers}

  @categories [Sessions, Triggers, Files, Heartbeat, Discord, FeatureRequests]

  # Tools visible to regular (non-orchestrator) connections. Orchestrator
  # connections see every tool. `send_discord_message` is deliberately absent
  # here — its visibility is conditional (see moduledoc), not static.
  @regular_session_tools ~w(send_message_to_session open_file report_progress file_feature_request
                             list_feature_requests get_feature_request append_feature_request_note)

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
    tools =
      if orchestrator?(state) do
        list()
      else
        list()
        |> Enum.filter(&(&1["name"] in @regular_session_tools))
        |> maybe_add_discord_tool(state)
      end

    Logger.info(
      "[MCP] Tools.list: role=#{if orchestrator?(state), do: "orchestrator (full set)", else: "regular (filtered)"} " <>
        "tool_count=#{length(tools)}"
    )

    tools
  end

  @doc """
  Dispatch a tool call by name to its owning category module. Unknown tool
  names return an error result. Known tools are dispatched regardless of the
  connection role.
  """
  def call(name, args, state) do
    case category_for(name) do
      nil ->
        Logger.warning("[MCP] Tools.call: unknown tool name=#{inspect(name)}")
        Result.error("Unknown tool: #{name}")

      module ->
        module.call(name, args, state)
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

  # Adds `send_discord_message` when this connection's session is actually
  # Discord-bridged. `Discord.enabled?()` is checked first (no hub work) so
  # every non-Discord node's tools/list short-circuits before ever calling
  # HubRPC. `discord_bridged?/1` is defensive on top of that: any lookup
  # failure just omits the tool rather than raising out of `list/1`.
  defp maybe_add_discord_tool(tools, %{orca_session_id: session_id}) when is_binary(session_id) do
    if OrcaHub.Discord.enabled?() and discord_bridged?(session_id) do
      tools ++ Enum.filter(list(), &(&1["name"] == "send_discord_message"))
    else
      tools
    end
  end

  defp maybe_add_discord_tool(tools, _state), do: tools

  defp discord_bridged?(session_id) do
    not is_nil(OrcaHub.HubRPC.get_discord_channel_by_session_id(session_id))
  rescue
    _ -> false
  end
end
