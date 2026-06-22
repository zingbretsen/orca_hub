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

  require Logger

  alias OrcaHub.HubRPC
  alias OrcaHub.MCP.Tools.{Files, Heartbeat, Result, Sessions, Triggers}

  @categories [Sessions, Triggers, Files, Heartbeat]

  # Tools available to regular (non-orchestrator) sessions. All other tools
  # require an orchestrator session.
  @regular_session_tools ~w(send_message_to_session open_file)

  # Orchestrator status is resolved once (at MCP.Server init) with a few
  # retries to ride out transient hub/DB failures, rather than queried on
  # every tools/list and tools/call. A transient failure on the per-request
  # path used to silently drop the orchestrator tool set for the whole CLI
  # invocation (cached by the Claude CLI), surfacing as intermittent
  # "No such tool available" errors.
  @orchestrator_lookup_attempts 3
  @orchestrator_lookup_backoff_ms 200

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
  # Prefer the value resolved once at MCP.Server init and cached in state.
  # Fall back to a live lookup only if state predates caching (older callers
  # or tests). Connections with no linked session are regular sessions.
  defp orchestrator?(%{orchestrator: orchestrator}) when is_boolean(orchestrator),
    do: orchestrator

  defp orchestrator?(%{orca_session_id: session_id}) when is_binary(session_id),
    do: resolve_orchestrator(session_id)

  defp orchestrator?(_state), do: false

  @doc """
  Resolve whether `orca_session_id` belongs to an orchestrator session.

  Resilient to transient hub/DB failures: the underlying lookup goes through
  `HubRPC` (an `:erpc` call to the hub in agent mode), which can time out or
  lose its connection. We retry a few times with a short backoff before
  giving up, logging the resolved status and any ultimate failure so the
  orchestrator-detection path is diagnosable. Returns a boolean.
  """
  def resolve_orchestrator(orca_session_id, attempts \\ @orchestrator_lookup_attempts)

  def resolve_orchestrator(session_id, attempts)
      when is_binary(session_id) and attempts > 0 do
    case lookup_session(session_id) do
      {:ok, nil} ->
        Logger.info("MCP: session #{session_id} not found; treating as regular session")
        false

      {:ok, session} ->
        orchestrator = session.orchestrator == true
        Logger.info("MCP: resolved orchestrator=#{orchestrator} for session #{session_id}")
        orchestrator

      {:error, reason} when attempts > 1 ->
        Logger.warning(
          "MCP: orchestrator lookup failed for session #{session_id} (#{reason}); retrying"
        )

        Process.sleep(@orchestrator_lookup_backoff_ms)
        resolve_orchestrator(session_id, attempts - 1)

      {:error, reason} ->
        Logger.warning(
          "MCP: orchestrator lookup failed for session #{session_id} (#{reason}) " <>
            "after retries; defaulting to regular session"
        )

        false
    end
  end

  def resolve_orchestrator(_session_id, _attempts), do: false

  defp lookup_session(session_id) do
    {:ok, HubRPC.get_session(session_id)}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end
