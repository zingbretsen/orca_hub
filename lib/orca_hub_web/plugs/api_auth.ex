defmodule OrcaHubWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the Agent Runs API (docs/api.md).

  Requires `Authorization: Bearer <token>` matching the statically
  configured `:api_token` (from `ORCA_API_TOKEN`, see config/runtime.exs).
  Responds 503 when the API is disabled (no token configured) and 401 on a
  missing/mismatched token — never reveals which case it is beyond that.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:orca_hub, :api_token) do
      nil -> halt_json(conn, 503, "API disabled")
      "" -> halt_json(conn, 503, "API disabled")
      token -> authenticate(conn, token)
    end
  end

  defp authenticate(conn, token) do
    with ["Bearer " <> provided] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(provided, token) do
      conn
    else
      _ -> halt_json(conn, 401, "unauthorized")
    end
  end

  defp halt_json(conn, status, error) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: error})
    |> halt()
  end
end
