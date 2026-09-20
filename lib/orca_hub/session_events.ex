defmodule OrcaHub.SessionEvents do
  @moduledoc """
  Hub-side fan-out for session turn-end events (orca-watch DESIGN.md §7c /
  D6 / R12).

  ONE entry point, `turn_end/1`, called on the hub by every genuine
  SessionRunner `running -> idle|error` transition that survives
  `SessionRunner.turn_end_push_eligible?/2`. It fans the same four-field
  payload onto TWO wires:

    1. **The `session_events` channel — always.** An
       `OrcaHubWeb.Endpoint.broadcast/3` on `"session_events:all"` and
       `"session_events:<session_id>"`, which is what the Android app
       (`OrcaHubWeb.ApiSocket`) subscribes to. This is the primary delivery
       path since D6 and is NOT gated on `ORCA_NOTIFY_ON_FINISH`.
    2. **Gotify — only when the runner's node opted in.** The caller passes
       `gotify: true/false` (read on the RUNNER's node, since
       `ORCA_NOTIFY_ON_FINISH` is per-node); when true this hands off to
       `OrcaHub.Notify.deliver_session_finished/1` with the excerpt already
       resolved, so the two wires carry byte-identical text and the DB is
       read once.

  Runs on the HUB — the runner may be on an agent node with no DB and no
  Gotify credentials, so it sends only `session_id`/`session_title`/`status`
  through `OrcaHub.HubRPC.send_session_turn_end/1` and the excerpt (a
  `Sessions.session_tail/2` read) is filled in here. PubSub auto-distributes
  via `:pg`, so a socket held on any node still receives the broadcast.

  Nothing here may raise back into the caller: the runner's transition is
  already fire-and-forget on a `Task.Supervisor`, and a failed notification
  must never become a failed turn end.
  """

  require Logger

  alias OrcaHub.{Notify, Sessions}

  @all_topic "session_events:all"
  @event "turn_end"

  @doc """
  Fan out one turn end. `attrs` (string or atom keys):

    * `session_id` — required in practice; the reply target.
    * `session_title` — may be nil/blank; falls back to `"Session <id8>"`.
    * `status` — `"idle"` or `"error"`.
    * `excerpt` — optional; read from the session's tail when absent.
    * `gotify` — truthy to ALSO send the opt-in Gotify push.

  Returns `{:ok, payload}` — the payload as broadcast — or `{:error, reason}`
  only for a caller-shaped problem. Gotify's own outcome is logged, never
  returned, so the channel wire cannot be affected by the Gotify one.
  """
  def turn_end(attrs) do
    attrs = stringify_keys(attrs)
    session_id = attrs["session_id"]
    status = to_string(attrs["status"] || "idle")
    title = presence(attrs["session_title"]) || "Session #{short_id(session_id)}"
    excerpt = attrs["excerpt"] || session_excerpt(session_id)

    payload = %{
      session_id: session_id,
      session_title: title,
      status: status,
      excerpt: excerpt || "",
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    broadcast(session_id, payload)

    if attrs["gotify"] do
      maybe_gotify(session_id, title, status, payload.excerpt)
    end

    {:ok, payload}
  end

  @doc "The channel topic every authorized socket may join."
  def all_topic, do: @all_topic

  @doc "The per-session channel topic (what a session-pinned token may join)."
  def session_topic(session_id), do: "session_events:#{session_id}"

  @doc false
  def event_name, do: @event

  # A broadcast is PubSub fan-out, not I/O, but it is still not allowed to
  # take the caller down: an Endpoint that isn't running (or a node whose
  # PubSub is mid-restart) would otherwise turn a turn end into a crash.
  defp broadcast(nil, payload) do
    safe_broadcast(@all_topic, payload)
  end

  defp broadcast(session_id, payload) do
    safe_broadcast(@all_topic, payload)
    safe_broadcast(session_topic(session_id), payload)
  end

  defp safe_broadcast(topic, payload) do
    OrcaHubWeb.Endpoint.broadcast(topic, @event, payload)
    :ok
  rescue
    e ->
      Logger.warning("[session events] broadcast on #{topic} failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[session events] broadcast on #{topic} exited: #{inspect(reason)}")
      :ok
  end

  # The excerpt is resolved once, above, and handed to Notify so the Gotify
  # body and the channel payload can never disagree about where the text
  # stops (`Sessions.truncate_excerpt/2` is the single rule behind both).
  defp maybe_gotify(session_id, title, status, excerpt) do
    Notify.deliver_session_finished(%{
      "session_id" => session_id,
      "session_title" => title,
      "status" => status,
      "excerpt" => excerpt
    })
  rescue
    e ->
      Logger.warning(
        "[session events] gotify for #{inspect(session_id)}: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[session events] gotify for #{inspect(session_id)} exited: #{inspect(reason)}"
      )

      :ok
  end

  defp session_excerpt(nil), do: nil

  defp session_excerpt(session_id) do
    session_id
    |> Sessions.session_tail(tool_call_limit: 1)
    |> Map.get(:last_assistant_text)
    |> Sessions.truncate_excerpt()
  rescue
    e ->
      Logger.warning(
        "[session events] session_tail for #{inspect(session_id)} failed: #{Exception.message(e)}"
      )

      nil
  end

  defp short_id(nil), do: "?"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: inspect(id)

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp presence(value), do: value

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify_keys(other), do: other
end
