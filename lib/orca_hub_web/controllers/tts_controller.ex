defmodule OrcaHubWeb.TTSController do
  use OrcaHubWeb, :controller

  # Client-side chunking (app.js's ttsSplitIntoChunks) targets ~80+ char
  # sentence-bucketed chunks, so a legitimate request is nowhere near this —
  # this is purely an upper bound on a single metered ElevenLabs call, not a
  # realistic chunk size (see tts_rewrite_spec.md §3.5: this route had no
  # length cap at all before, on top of having no auth).
  @max_text_bytes 4_000

  def create(conn, %{"text" => text}) when byte_size(text) > @max_text_bytes do
    conn
    |> put_status(413)
    |> json(%{error: "text too long", max_bytes: @max_text_bytes})
  end

  def create(conn, %{"text" => text}) when byte_size(text) > 0 do
    api_key = Application.get_env(:orca_hub, :elevenlabs_api_key)
    voice_id = Application.get_env(:orca_hub, :elevenlabs_voice_id)

    if is_nil(api_key) do
      conn |> put_status(500) |> json(%{error: "ElevenLabs API key not configured"})
    else
      case Req.post("https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}",
             headers: [{"xi-api-key", api_key}],
             json: %{
               text: text,
               model_id: "eleven_turbo_v2_5",
               voice_settings: %{stability: 0.5, similarity_boost: 0.75}
             },
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: audio_data}} ->
          conn
          |> put_resp_content_type("audio/mpeg")
          |> send_resp(200, audio_data)

        {:ok, %{status: status, body: body}} ->
          conn |> put_status(status) |> json(%{error: "ElevenLabs error", detail: body})

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "Request failed", detail: inspect(reason)})
      end
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing text parameter"})
  end
end
