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
        # Start a new MCP session
        {:ok, session_id} = OrcaHub.MCP.Server.start_session()
        response = OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)

        conn
        |> put_resp_header("mcp-session-id", session_id)
        |> json_response(200, response)

      %{"method" => "notifications/" <> _} ->
        # Notifications — need a session
        with {:ok, session_id} <- get_session_id(conn),
             true <- OrcaHub.MCP.Server.session_exists?(session_id) do
          OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)

          conn
          |> send_resp(202, "")
        else
          _ -> send_resp(conn, 400, Jason.encode!(%{"error" => "Invalid or missing session"}))
        end

      %{"id" => _id} ->
        # Request — needs a session, returns JSON
        with {:ok, session_id} <- get_session_id(conn),
             true <- OrcaHub.MCP.Server.session_exists?(session_id) do
          response = OrcaHub.MCP.Server.handle_jsonrpc(session_id, message)
          json_response(conn, 200, response)
        else
          _ -> send_resp(conn, 400, Jason.encode!(%{"error" => "Invalid or missing session"}))
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
