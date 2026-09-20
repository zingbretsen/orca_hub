defmodule OrcaHub.Notify do
  @moduledoc """
  Hub-side Gotify push-notification client.

  Two entry points:

    * `deliver/1` — the generic sender, backing the `send_notification` MCP
      tool (`OrcaHub.MCP.Tools.Notify`).
    * `deliver_session_finished/1` — the OPT-IN turn-end push. Since D6 the
      runner no longer calls this directly: every eligible
      `running -> idle|error` transition goes to
      `OrcaHub.SessionEvents.turn_end/1`, which always broadcasts the
      `session_events` channel event and calls this only when
      `ORCA_NOTIFY_ON_FINISH` opted the runner's node in (off by default).
      Its `extras["orca"]` payload is a strict contract; see
      `.context/push-payload.md`.

  Unlike `OrcaHub.MCP.Tools.Databases`/`PhxAgents` (which call their external
  API directly from the session's own runner node, so every node needs the
  token), this module is only ever invoked on the hub — sessions reach it
  through `OrcaHub.HubRPC.send_notification/1` /
  `OrcaHub.HubRPC.send_session_turn_end/1`, which run locally on
  the hub and `:erpc` there otherwise. Only the hub needs `GOTIFY_TOKEN`
  configured.
  """

  require Logger

  alias OrcaHub.Sessions

  # The Android client (orca-watch) renders the notification ENTIRELY from
  # this payload — it cannot call back to OrcaHub when OrcaHub is the thing
  # that is unreachable (DESIGN.md §1.4 / R12). Namespaced so it can never
  # collide with Gotify's own `client::*` extras.
  @orca_extras_key "orca"
  @idle_priority 4
  @error_priority 8

  @doc """
  Deliver a Gotify notification. `payload` may use string OR atom keys:
  `message` (required), `title`, `priority`, `click_url`, `markdown`,
  `extras`.

  `extras` is a generic passthrough merged into the Gotify `extras` object
  under the caller's own keys; `markdown`/`click_url` still add their
  `client::display`/`client::notification` entries on top of it.
  """
  def deliver(payload) do
    payload = normalize(payload)

    case require_token() do
      {:ok, token} -> do_deliver(payload, token)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The turn-end push for a session that just went idle or errored — opt-in,
  gated on `SessionRunner.finish_notifications_enabled?/0` (off by default).

  Called ON THE HUB by `OrcaHub.SessionEvents.turn_end/1` (reached from the
  runner — possibly on an agent node — via
  `OrcaHub.HubRPC.send_session_turn_end/1`), which has already resolved
  `excerpt` from `Sessions.session_tail/2`, a hub-local DB read, and passes
  it in so this push and the channel event carry the SAME string. Keeping
  that read on the hub is what lets the cross-node hop be three small
  strings and an agent node need neither DB nor Gotify credentials.
  `excerpt` is still filled in here when a caller omits it.

  Returns `{:ok, :skipped}` — silently, with no log line — when Gotify is
  not configured, so an unconfigured hub produces no log spam on every turn
  end.
  """
  def deliver_session_finished(attrs) do
    attrs = stringify_keys(attrs)
    session_id = attrs["session_id"]
    status = to_string(attrs["status"] || "idle")

    case require_token() do
      {:error, _reason} ->
        {:ok, :skipped}

      {:ok, _token} ->
        title = presence(attrs["session_title"]) || "Session #{short_id(session_id)}"
        excerpt = attrs["excerpt"] || session_excerpt(session_id)

        deliver(%{
          title: finish_title(title, status),
          message: presence(excerpt) || default_message(status),
          priority: if(status == "error", do: @error_priority, else: @idle_priority),
          click_url: session_click_url(session_id),
          extras: %{
            @orca_extras_key => %{
              "session_id" => session_id,
              "session_title" => title,
              "status" => status,
              "excerpt" => excerpt || ""
            }
          }
        })
    end
  end

  @doc """
  Truncate `text` for the `excerpt` field: whitespace collapsed, cut to
  `limit` (default 400) characters on a word boundary, ellipsised.

  Delegated to `OrcaHub.Sessions` rather than implemented here, so the
  string a push carries and the one
  `GET /api/v1/sessions/recent?include_tail=true` returns can never drift —
  an Android notification and the in-app list row it opens must not
  disagree about where the text stops.
  """
  defdelegate truncate_excerpt(text), to: Sessions
  defdelegate truncate_excerpt(text, limit), to: Sessions

  @doc "True when this node has Gotify credentials (i.e. it is the hub)."
  def configured?, do: match?({:ok, _}, require_token())

  defp session_excerpt(nil), do: nil

  defp session_excerpt(session_id) do
    session_id
    |> Sessions.session_tail(tool_call_limit: 1)
    |> Map.get(:last_assistant_text)
    |> truncate_excerpt()
  rescue
    e ->
      Logger.warning(
        "[notify] session_tail for #{inspect(session_id)} failed: #{Exception.message(e)}"
      )

      nil
  end

  defp finish_title(title, "error"), do: "⚠ " <> title
  defp finish_title(title, _status), do: title

  defp default_message("error"), do: "Session errored."
  defp default_message(_status), do: "Session finished."

  defp short_id(nil), do: "?"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: inspect(id)

  # The runner may be on an agent node whose PHX_HOST is a LAN address; this
  # runs on the hub, whose endpoint URL is the public (ingress) one.
  defp session_click_url(nil), do: nil

  defp session_click_url(session_id) do
    String.trim_trailing(OrcaHubWeb.Endpoint.url(), "/") <> "/sessions/#{session_id}"
  end

  defp presence(nil), do: nil
  defp presence(str) when is_binary(str), do: if(String.trim(str) == "", do: nil, else: str)
  defp presence(other), do: other

  @known_keys ~w(message title priority click_url markdown extras)a

  defp normalize(payload) do
    Map.new(@known_keys, fn key ->
      {key, Map.get(payload, key) || Map.get(payload, to_string(key))}
    end)
  end

  defp require_token do
    case Application.get_env(:orca_hub, :gotify_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        {:error,
         "GOTIFY_TOKEN is not configured on the hub — notifications are unavailable. " <>
           "Ask a human to check the hub's env/secrets."}
    end
  end

  defp do_deliver(payload, token) do
    url = base_url() <> "/message?token=#{token}"
    body = build_body(payload)

    case Req.post(url, [json: body] ++ req_opts()) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, "Notification sent: #{inspect(resp_body)}"}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Gotify returned HTTP #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, "Failed to reach Gotify: #{inspect(reason)}"}
    end
  end

  defp build_body(payload) do
    %{
      "title" => Map.get(payload, :title) || "OrcaHub",
      "message" => Map.get(payload, :message),
      "priority" => Map.get(payload, :priority) || 5
    }
    |> maybe_add_extras(build_extras(payload))
  end

  defp build_extras(payload) do
    payload
    |> custom_extras()
    |> maybe_put_markdown(payload)
    |> maybe_put_click_url(payload)
  end

  # Generic passthrough: whatever the caller put under `extras`, JSON-keyed.
  # Merged FIRST so the `client::*` entries below always win a key clash.
  defp custom_extras(payload) do
    case Map.get(payload, :extras) do
      extras when is_map(extras) and map_size(extras) > 0 -> stringify_keys(extras)
      _ -> %{}
    end
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp maybe_put_markdown(extras, payload) do
    if Map.get(payload, :markdown) do
      Map.put(extras, "client::display", %{"contentType" => "text/markdown"})
    else
      extras
    end
  end

  defp maybe_put_click_url(extras, payload) do
    case Map.get(payload, :click_url) do
      nil -> extras
      "" -> extras
      click_url -> Map.put(extras, "client::notification", %{"click" => %{"url" => click_url}})
    end
  end

  defp maybe_add_extras(body, extras) when extras == %{}, do: body
  defp maybe_add_extras(body, extras), do: Map.put(body, "extras", extras)

  defp base_url do
    (Application.get_env(:orca_hub, :gotify_url) || "https://gotify.ingbretsenhome.com")
    |> String.trim_trailing("/")
  end

  defp req_opts, do: Application.get_env(:orca_hub, :gotify_req_options, [])
end
