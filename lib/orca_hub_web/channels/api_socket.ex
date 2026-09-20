defmodule OrcaHubWeb.ApiSocket do
  @moduledoc """
  The API WebSocket, mounted at `/api/v1/socket` — the push half of the
  Agent Runs API, authenticated by exactly the same scoped `ApiToken` the
  bearer plug (`OrcaHubWeb.Plugs.ApiAuth`) takes on `/api/v1/*`.

  Its one channel today is `OrcaHubWeb.SessionEventsChannel`
  (`session_events:*`), which pushes session turn-end events to the unified
  Android app — orca-watch DESIGN.md D6/§7c: the app takes finish events
  from this socket rather than from Gotify.

  ## Auth (connect, not join)

  `connect/3` reads `params["token"]` — an `orca_…` secret, the SAME value
  the HTTP client sends as `Authorization: Bearer` — and runs it through
  `OrcaHub.ApiTokens.authenticate/1`: SHA-256 hash lookup, revoked and
  expired rejected, `last_used_at` touched best-effort. It then requires the
  **`sessions:read`** scope, because the channel is a push-shaped read of
  exactly the data `GET /api/v1/sessions*` already gates on that scope.

  A bad, revoked, expired or wrongly-scoped token is rejected at CONNECT
  with `:error` (HTTP 403 on the handshake) — never accepted-then-refused at
  join. The legacy static `ORCA_API_TOKEN` is deliberately NOT accepted
  here: it is unscoped and unrevocable, and this is a new surface with no
  back-compat to preserve.

  A session-PINNED token (`api_token.session_id`) connects fine but is
  confined to its own session's topic — enforced in the channel's `join/3`,
  which is the first place the target topic is known.

  ## Revocation kicks live sockets

  `id/1` returns `"api_token:<id>"`, so `OrcaHub.ApiTokens.revoke_token/1`
  broadcasts `"disconnect"` on that topic and Phoenix closes every socket
  the token holds. Without this a revoked token would keep receiving pushes
  for as long as it stayed connected — its HTTP twin dies on the next
  request, but a socket makes no further requests.

  ## Agent nodes

  Phoenix's `:socket_dispatch` runs ahead of the endpoint's
  `agent_mode_gate` plug (see the caveat in `OrcaHubWeb.Endpoint`), so agent
  mode is refused HERE instead: an agent node has no `Repo`, so the token
  lookup could not run anyway. The phone talks to the hub's ingress.
  """

  use Phoenix.Socket

  require Logger

  alias OrcaHub.ApiTokens
  alias OrcaHubWeb.Plugs.ApiAuth

  @required_scope "sessions:read"

  channel "session_events:*", OrcaHubWeb.SessionEventsChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with false <- OrcaHub.Mode.agent?(),
         secret when is_binary(secret) <- params["token"],
         {:ok, token} <- ApiTokens.authenticate(secret),
         true <- @required_scope in token.scopes do
      ApiAuth.touch_last_used_best_effort(token)

      {:ok,
       assign(socket,
         api_token_id: token.id,
         api_token_scopes: token.scopes,
         pinned_session_id: token.session_id
       )}
    else
      _ -> :error
    end
  rescue
    # The Repo can be unreachable (or absent) under a socket handshake in a
    # way it never is under the HTTP plug; refuse the connection rather than
    # 500 the upgrade.
    e ->
      Logger.warning("[api socket] connect failed: #{Exception.message(e)}")
      :error
  end

  @impl true
  def id(socket), do: "api_token:" <> socket.assigns.api_token_id
end
