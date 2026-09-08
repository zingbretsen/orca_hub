defmodule OrcaHub.TTS do
  @moduledoc """
  One synthesis call against a resolved TTS config.

  Extracted out of `OrcaHubWeb.TTSController` so the Settings page's
  "Speak sample" button exercises the IDENTICAL request path playback uses —
  same dialect, same strictness, same timeout — rather than a second
  hand-rolled client that could agree with the gateway while the real one
  doesn't. The controller keeps its own HTTP-response mapping; everything
  above the wire lives here.

  `config` is the map `OrcaHub.TTSConfig.resolve/0` returns:
  `%{provider:, url:, model:, language:}`.
  """

  # The local ai_gateway synthesizes at roughly 1x real time, so a long chunk
  # takes about as long as the audio it produces — and the first request
  # after an idle period additionally pays a cold model load. 30s (the old
  # ElevenLabs-turbo bound) is a real risk under that profile.
  @receive_timeout 120_000

  @elevenlabs_receive_timeout 30_000

  @type result ::
          {:ok, %{body: binary(), content_type: String.t()}}
          | {:error, {:http, :local | :elevenlabs, non_neg_integer(), term()}}
          | {:error, {:transport, term()}}
          | {:error, :missing_elevenlabs_key}

  @spec synthesize(String.t(), map()) :: result()
  def synthesize(text, %{provider: "elevenlabs"} = config), do: elevenlabs(text, config)
  def synthesize(text, config), do: local(text, config)

  # The homelab ai_gateway speaks the OpenAI /v1/audio/speech dialect but is
  # deliberately strict about the optional fields: `voice` must be absent or
  # "default", `response_format` absent or "wav", `speed` absent or 1 —
  # anything else is a 400. So we send only model/input/language and take the
  # raw audio/wav body it returns (24 kHz mono 16-bit PCM), which an <audio>
  # element plays natively with no transcoding.
  defp local(text, config) do
    url = String.trim_trailing(config.url, "/") <> "/v1/audio/speech"

    opts =
      [
        json: %{model: config.model, input: text, language: config.language},
        receive_timeout: @receive_timeout
      ] ++ req_opts()

    url |> Req.post(opts) |> normalize(:local, "audio/wav")
  end

  # Preserved verbatim as an opt-in fallback: the local service is materially
  # slower than ElevenLabs turbo, so the hosted path stays one setting away.
  defp elevenlabs(text, _config) do
    api_key = Application.get_env(:orca_hub, :elevenlabs_api_key)
    voice_id = Application.get_env(:orca_hub, :elevenlabs_voice_id)

    if is_nil(api_key) do
      {:error, :missing_elevenlabs_key}
    else
      opts =
        [
          headers: [{"xi-api-key", api_key}],
          json: %{
            text: text,
            model_id: "eleven_turbo_v2_5",
            voice_settings: %{stability: 0.5, similarity_boost: 0.75}
          },
          receive_timeout: @elevenlabs_receive_timeout
        ] ++ req_opts()

      "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"
      |> Req.post(opts)
      |> normalize(:elevenlabs, "audio/mpeg")
    end
  end

  defp normalize({:ok, %{status: 200, body: audio}}, _provider, content_type),
    do: {:ok, %{body: audio, content_type: content_type}}

  defp normalize({:ok, %{status: status, body: body}}, provider, _content_type),
    do: {:error, {:http, provider, status, body}}

  defp normalize({:error, reason}, _provider, _content_type), do: {:error, {:transport, reason}}

  defp req_opts, do: Application.get_env(:orca_hub, :tts_req_options, [])
end
