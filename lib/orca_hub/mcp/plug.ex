defmodule OrcaHub.MCP.Plug do
  @moduledoc """
  Plug implementing MCP Streamable HTTP transport.

  POST /mcp - JSON-RPC requests from the client
  GET  /mcp - Server-initiated SSE (returns 405 for now)
  DELETE /mcp - Terminate session
  """
  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    message = conn.body_params

    case message do
      %{"method" => "initialize", "id" => _id} ->
        # Start a new MCP session, linking it to the OrcaHub session if provided.
        # The connection role (orchestrator?) is carried as a query param by
        # SessionRunner — no hub lookup here.
        conn = fetch_query_params(conn)
        orca_session_id = conn.query_params["orca_session_id"]
        orchestrator = conn.query_params["orchestrator"] == "true"

        {:ok, session_id} =
          OrcaHub.MCP.Server.start_session(
            orca_session_id: orca_session_id,
            orchestrator: orchestrator
          )

        Logger.info(
          "[MCP] initialize: mcp_session_id=#{session_id} orca_session_id=#{inspect(orca_session_id)} " <>
            "orchestrator=#{orchestrator} query=#{inspect(conn.query_string)}"
        )

        response = OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)

        conn
        |> put_resp_header("mcp-session-id", session_id)
        |> json_response(200, response)

      %{"method" => "notifications/" <> _ = method} ->
        # Notifications — need a session
        with {:ok, session_id} <- get_session_id(conn),
             true <- OrcaHub.MCP.Server.session_exists?(session_id) do
          Logger.info("[MCP] #{method}: mcp_session_id=#{session_id}")
          OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)

          conn
          |> send_resp(202, "")
        else
          other ->
            log_invalid_session(conn, method, other)
            send_resp(conn, 400, Jason.encode!(%{"error" => "Invalid or missing session"}))
        end

      %{"id" => _id} = request ->
        # Request — needs a session, returns JSON
        method = request["method"] || "unknown"

        with {:ok, session_id} <- get_session_id(conn),
             true <- OrcaHub.MCP.Server.session_exists?(session_id) do
          Logger.info("[MCP] #{method}: mcp_session_id=#{session_id}")
          response = OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)
          json_response(conn, 200, response)
        else
          other ->
            log_invalid_session(conn, method, other)
            send_resp(conn, 400, Jason.encode!(%{"error" => "Invalid or missing session"}))
        end
    end
  end

  def call(%{method: "GET"} = conn, _opts) do
    send_resp(conn, 405, "")
  end

  def call(%{method: "DELETE"} = conn, _opts) do
    case get_session_id(conn) do
      {:ok, session_id} ->
        OrcaHub.MCP.Server.stop_session(session_id)
        send_resp(conn, 200, "")

      :error ->
        send_resp(conn, 400, "")
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 405, "")
  end

  # Logs the smoking-gun "Invalid or missing session" path, distinguishing a
  # missing mcp-session-id header from a header present but no live MCP server.
  defp log_invalid_session(conn, method, with_result) do
    case with_result do
      :error ->
        Logger.warning(
          "[MCP] invalid/missing session for method=#{method}: no mcp-session-id header"
        )

      false ->
        session_id =
          case get_session_id(conn) do
            {:ok, id} -> id
            :error -> nil
          end

        Logger.warning(
          "[MCP] invalid/missing session for method=#{method}: " <>
            "mcp_session_id=#{inspect(session_id)} present but no live MCP server"
        )

      other ->
        Logger.warning("[MCP] invalid/missing session for method=#{method}: #{inspect(other)}")
    end
  end

  defp get_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [session_id] -> {:ok, session_id}
      _ -> :error
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
