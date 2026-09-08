defmodule OrcaHubWeb.TTSController do
  use OrcaHubWeb, :controller

  # Client-side chunking (app.js's ttsSplitIntoChunks) targets ~80+ char
  # sentence-bucketed chunks, so a legitimate request is nowhere near this —
  # this is purely an upper bound on a single synthesis call, not a realistic
  # chunk size (see tts_rewrite_spec.md §3.5: this route had no length cap at
  # all before, on top of having no auth).
  @max_text_bytes 4_000

  # The local ai_gateway synthesizes at roughly 1x real time, so a long chunk
  # takes about as long as the audio it produces — and the first request after
  # an idle period additionally pays a cold model load. 30s (the old
  # ElevenLabs-turbo bound) is a real risk under that profile.
  @receive_timeout 120_000

  def create(conn, %{"text" => text}) when byte_size(text) > @max_text_bytes do
    conn
    |> put_status(413)
    |> json(%{error: "text too long", max_bytes: @max_text_bytes})
  end

  def create(conn, %{"text" => text}) when byte_size(text) > 0 do
    case provider() do
      "elevenlabs" -> elevenlabs(conn, text)
      _ -> local(conn, text)
    end
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing text parameter"})
  end

  # The homelab ai_gateway speaks the OpenAI /v1/audio/speech dialect but is
  # deliberately strict about the optional fields: `voice` must be absent or
  # "default", `response_format` absent or "wav", `speed` absent or 1 —
  # anything else is a 400. So we send only model/input/language and take the
  # raw audio/wav body it returns (24 kHz mono 16-bit PCM), which an <audio>
  # element plays natively with no transcoding.
  defp local(conn, text) do
    url = String.trim_trailing(tts_url(), "/") <> "/v1/audio/speech"

    opts =
      [
        json: %{
          model: Application.get_env(:orca_hub, :tts_model) || "tts-chatterbox-23lang",
          input: text,
          language: Application.get_env(:orca_hub, :tts_language) || "en"
        },
        receive_timeout: @receive_timeout
      ] ++ req_opts()

    case Req.post(url, opts) do
      {:ok, %{status: 200, body: audio_data}} ->
        conn
        |> put_resp_content_type("audio/wav")
        |> send_resp(200, audio_data)

      {:ok, %{status: status, body: body}} ->
        conn |> put_status(status) |> json(%{error: "TTS error", detail: inspect(body)})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Request failed", detail: inspect(reason)})
    end
  end

  # Preserved verbatim as an opt-in fallback (TTS_PROVIDER=elevenlabs): the
  # local service is materially slower than ElevenLabs turbo, so the hosted
  # path stays one env var away.
  defp elevenlabs(conn, text) do
    api_key = Application.get_env(:orca_hub, :elevenlabs_api_key)
    voice_id = Application.get_env(:orca_hub, :elevenlabs_voice_id)

    if is_nil(api_key) do
      conn |> put_status(500) |> json(%{error: "ElevenLabs API key not configured"})
    else
      opts =
        [
          headers: [{"xi-api-key", api_key}],
          json: %{
            text: text,
            model_id: "eleven_turbo_v2_5",
            voice_settings: %{stability: 0.5, similarity_boost: 0.75}
          },
          receive_timeout: 30_000
        ] ++ req_opts()

      case Req.post("https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}", opts) do
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

  defp provider, do: Application.get_env(:orca_hub, :tts_provider) || "local"

  defp tts_url,
    do: Application.get_env(:orca_hub, :tts_url) || "https://ai.lab.ingbretsenhome.com"

  defp req_opts, do: Application.get_env(:orca_hub, :tts_req_options, [])
end
