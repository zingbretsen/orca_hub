defmodule OrcaHubWeb.SessionEventsChannel do
  @moduledoc """
  Session turn-end push, over `OrcaHubWeb.ApiSocket` (`/api/v1/socket`).
  The transport half of orca-watch DESIGN.md D6: the unified Android app
  renders its `MessagingStyle` notification ENTIRELY from what this channel
  pushes, so the payload is a contract (R12), not a convenience.

  ## Topics

    * `"session_events:all"` — every eligible session's turn end. Requires
      an UNPINNED token.
    * `"session_events:<session_id>"` — just that session's. Any token with
      `sessions:read` may join it; a session-PINNED token may join ONLY its
      own (and is refused `:all`), mirroring `ApiTokens.authorize/2`'s pin
      check on `GET /api/v1/sessions/:id`.

  ## Events

  Server -> client, `"turn_end"`, the five-field payload built by
  `OrcaHub.SessionEvents.turn_end/1`:

      {"session_id": "…", "session_title": "the worker", "status": "idle",
       "excerpt": "All three migrations applied cleanly.",
       "occurred_at": "2026-09-19T18:04:12.123456Z"}

  Client -> server, `"ping"` -> replies `{:ok, %{"pong" => true}}`, a
  liveness check that costs no DB read.

  ## No backlog on join

  Joining replays NOTHING. A client that was disconnected reconciles with
  `GET /api/v1/sessions/recent?since=<high-water>` — the same high-water
  mark that makes its fallback poller idempotent — so this channel never has
  to decide what "missed" means or hold a per-token cursor. See
  `docs/api.md` ("Session events socket").
  """

  use Phoenix.Channel

  @impl true
  def join("session_events:all", _params, socket) do
    case socket.assigns.pinned_session_id do
      nil -> {:ok, socket}
      _pinned -> {:error, %{reason: "forbidden"}}
    end
  end

  def join("session_events:" <> session_id, _params, socket) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         true <- authorized?(socket.assigns.pinned_session_id, session_id) do
      {:ok, socket}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown topic"}}

  @impl true
  def handle_in("ping", _payload, socket), do: {:reply, {:ok, %{"pong" => true}}, socket}

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unknown event"}}, socket}

  defp authorized?(nil, _session_id), do: true
  defp authorized?(pinned, session_id), do: pinned == session_id
end
