defmodule OrcaHub.Notify do
  @moduledoc """
  Hub-side Gotify push-notification client, backing the `send_notification`
  MCP tool (`OrcaHub.MCP.Tools.Notify`).

  Unlike `OrcaHub.MCP.Tools.Databases`/`PhxAgents` (which call their external
  API directly from the session's own runner node, so every node needs the
  token), this module is only ever invoked on the hub — sessions reach it
  through `OrcaHub.HubRPC.send_notification/1`, which runs locally on the hub
  and `:erpc`s there otherwise. Only the hub needs `GOTIFY_TOKEN` configured.
  """

  require Logger

  @doc """
  Deliver a Gotify notification. `payload` may use string OR atom keys:
  `message` (required), `title`, `priority`, `click_url`, `markdown`.
  """
  def deliver(payload) do
    payload = normalize(payload)

    case require_token() do
      {:ok, token} -> do_deliver(payload, token)
      {:error, reason} -> {:error, reason}
    end
  end

  @known_keys ~w(message title priority click_url markdown)a

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
    %{}
    |> maybe_put_markdown(payload)
    |> maybe_put_click_url(payload)
  end

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
