defmodule OrcaHubWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the Agent Runs API (docs/api.md).

  Two credential kinds are accepted, tried in this order:

  1. A scoped, revocable `OrcaHub.ApiTokens.ApiToken` — hashed at rest,
     checked against the route's required scope and (if the token is pinned)
     its one allowed session via `ApiTokens.authorize/2`. On success the
     token's id/name/scopes (never its secret) are assigned to
     `conn.assigns.api_token`.
  2. The legacy statically configured `:api_token` (from `ORCA_API_TOKEN`,
     see config/runtime.exs) — a single value with full access to every
     route. Preserved BYTE-IDENTICALLY as the fallback: this is live in prod
     for other consumers and must not be weakened or bypassed.

  Responds 503 when the API is disabled (no legacy token configured AND the
  bearer value isn't a valid scoped token) and 401 on a missing/mismatched
  token — never reveals which case it is beyond that. A scope/pin violation
  on an otherwise-valid scoped token is a 403, deliberately distinct from
  401, and never echoes the scope or session id it denied.
  """

  import Plug.Conn

  alias OrcaHub.ApiTokens

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] -> authenticate(conn, provided)
      _ -> legacy_authenticate(conn)
    end
  end

  defp authenticate(conn, provided) do
    case ApiTokens.authenticate(provided) do
      {:ok, token} -> authorize(conn, token)
      :error -> legacy_authenticate(conn, provided)
    end
  end

  defp authorize(conn, token) do
    case ApiTokens.authorize(token, conn) do
      :ok ->
        touch_last_used_best_effort(token)
        assign(conn, :api_token, %{id: token.id, name: token.name, scopes: token.scopes})

      {:error, :forbidden} ->
        halt_json(conn, 403, "forbidden")
    end
  end

  # A `last_used_at` write is best-effort — it must never turn an already
  # -authenticated, correctly-scoped request into a 500. Covers both an
  # {:error, changeset} return AND a raise: the pinned session's on_delete:
  # :delete_all means the token row itself can vanish between authenticate/1
  # reading it and this update landing (a real, if narrow, race), which
  # surfaces as Ecto.StaleEntryError, not an error tuple. We proceed either
  # way — the token was valid when checked, and a vanished row shouldn't
  # produce a confusing 500 for a request that's otherwise legitimate.
  @doc false
  def touch_last_used_best_effort(token) do
    ApiTokens.touch_last_used(token)
    :ok
  rescue
    _ -> :ok
  end

  # Falls back to the legacy static-token check even without a header, since
  # its own "no header" case is folded into `secure_compare`'s mismatch path
  # below exactly as it always has been.
  defp legacy_authenticate(conn, provided \\ nil) do
    case Application.get_env(:orca_hub, :api_token) do
      nil -> halt_json(conn, 503, "API disabled")
      "" -> halt_json(conn, 503, "API disabled")
      token -> legacy_compare(conn, provided, token)
    end
  end

  defp legacy_compare(conn, provided, token) do
    if is_binary(provided) and Plug.Crypto.secure_compare(provided, token) do
      conn
    else
      halt_json(conn, 401, "unauthorized")
    end
  end

  defp halt_json(conn, status, error) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: error})
    |> halt()
  end
end
