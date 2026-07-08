defmodule OrcaHub.Backend.McpUrl do
  @moduledoc """
  Shared orca MCP server URL construction.

  Both `Backend.Claude` (inline `--mcp-config` JSON) and `Backend.Codex`
  (per-session `CODEX_HOME/config.toml`) point their agent CLI at the same
  local `/mcp` endpoint. This is the ONE place the query params
  (`orca_session_id`, `orchestrator`, `code_exec`, `api_run`) are built, so
  the two backends can never drift out of sync.
  """

  @doc "Builds the local orca MCP server URL for a session ctx."
  @spec orca_url(map) :: String.t()
  def orca_url(ctx) do
    port =
      case OrcaHubWeb.Endpoint.config(:http) do
        config when is_list(config) -> Keyword.get(config, :port, 4000)
        _ -> 4000
      end

    # Honor the env kill switch at bake time so a disabled node never advertises
    # code-exec mode (and a stale URL can't re-enable it).
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))
    # Agent Runs API (docs/api.md): whether this session backs a run with a
    # result_schema — tells MCP.Server to collapse tools/list down to just
    # `submit_result` for this connection.
    api_run = Map.get(ctx, :api_run_schema?) == true

    "http://localhost:#{port}/mcp?orca_session_id=#{ctx.session_id}" <>
      "&orchestrator=#{ctx.orchestrator == true}" <>
      "&code_exec=#{code_exec}" <>
      "&api_run=#{api_run}"
  end
end
