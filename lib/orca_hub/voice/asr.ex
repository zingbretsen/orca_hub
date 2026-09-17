defmodule OrcaHub.Voice.ASR do
  @moduledoc """
  Server-side HTTP client for the GB10 transcription SYNC LANE — the ASR half
  of voice mode. See `voice_mode_spec.md` section 6 (and 6.1 for the latency
  budget) for how this was measured; the contract below is MEASURED, not
  assumed, so do not re-derive it from an OpenAI client.

  ## The contract

  - `POST <config.url><config.path>` — default
    `http://192.168.1.77:8000/v1/transcribe/sync`. This lane is **not**
    OpenAI-compatible; `/v1/audio/transcriptions` 404s on that box, and the
    `ai.lab.ingbretsenhome.com` gateway fronts only TTS.
  - `multipart/form-data` ONLY — anything else is a 415. Fields: `file` (the
    WAV) plus `language`. The lane accepts at most FOUR form fields.
  - A 200 body is EXACTLY five fields: `text`, `language`, `duration`,
    `model`, `elapsed_seconds`. There are no segments, no word timestamps and
    **no confidence fields** — do not model any.
  - `200` with `text: ""` is the NORMAL non-speech result, not an error, and
    `elapsed_seconds` under ~0.05 means the server's own VAD gate found
    nothing. `silence?/1` covers both.
  - Errors are `{"detail": "<string>"}` with no machine-readable code —
    switch on HTTP STATUS. 413 = clip over 20 s or upload over 25 MiB,
    415 = wrong content type, 504 = the server's own 30 s timeout.
  - Warm p50: 569 ms for a bare command, 772 ms at 4-5 s, 1323 ms at
    10-12 s. A COLD start costs up to 35 s, which is what `warmup/1` exists
    to absorb at voice-mode arm.

  ## Belt-and-braces guards (spec section 3.2)

  Sub-0.8 s fragments are the real hallucination mode on this endpoint (a
  0.3 s cut of "Orca" came back `"archives."`). The client-side dispatcher
  merges or pads them, but this module enforces the floor a SECOND time and
  simply refuses: `{:error, :too_short}` under 12,800 samples. The 20 s cap
  is likewise refused locally (`{:error, :too_long}`) rather than spending a
  round trip to earn a 413.

  ## Failure discipline

  Nothing here raises on a network or HTTP problem — the voice channel has to
  surface every failure as a visible error state, so every path returns
  `{:ok, _}` or `{:error, reason}`.

  `config` is the map `OrcaHub.ASRConfig.resolve/0` returns:
  `%{url:, path:, language:, timeout_ms:, warmup_timeout_ms:, threshold:}`.
  It is taken as an ARGUMENT rather than resolved here, so this module stays
  testable without the config table.
  """

  # 16 kHz mono int16 little-endian: what the browser worklet ships and what
  # the lane's WhisperX pipeline wants.
  @sample_rate 16_000
  @bits_per_sample 16
  @channels 1
  @bytes_per_sample 2

  # Spec section 3.2: the hard ~0.8 s pre-dispatch floor, in SAMPLES.
  @min_samples 12_800

  # Spec section 6: the lane 413s over 20 s of audio.
  @max_samples 320_000

  # Spec section 3.2: non-speech returns in ~14 ms against ~500 ms for real
  # speech, so a sub-50 ms server time means the VAD gate found nothing.
  @silence_elapsed_seconds 0.05

  @warmup_filename "warmup.wav"
  @default_filename "segment.wav"

  @type result :: %{
          text: String.t(),
          language: String.t(),
          duration: float(),
          model: String.t(),
          elapsed_seconds: float()
        }

  @type reason ::
          :too_short
          | :too_long
          | :timeout
          | {:http, non_neg_integer(), String.t()}
          | {:transport, term()}
          | {:bad_response, term()}

  @doc """
  Transcribes one VAD segment of RAW 16 kHz mono int16 little-endian PCM.

  The PCM is wrapped in a 44-byte WAV header here (the channel receives raw
  samples, not a container) and posted as multipart.

  Options:

    * `:timeout_ms` — overrides `config.timeout_ms`
    * `:language` — overrides `config.language`
    * `:filename` — the multipart filename, default `"segment.wav"`
    * `:sample_rate` — WAV header rate, default 16000

  Returns `{:ok, result}` or `{:error, reason}`. Both length guards refuse
  BEFORE any network call.
  """
  @spec transcribe(binary(), map(), keyword()) :: {:ok, result()} | {:error, reason()}
  def transcribe(pcm, config, opts \\ []) when is_binary(pcm) do
    samples = div(byte_size(pcm), @bytes_per_sample)

    cond do
      samples < @min_samples ->
        {:error, :too_short}

      samples > @max_samples ->
        {:error, :too_long}

      true ->
        wav = wav_from_pcm16(pcm, Keyword.get(opts, :sample_rate, @sample_rate))
        timeout = Keyword.get(opts, :timeout_ms) || config.timeout_ms
        filename = Keyword.get(opts, :filename, @default_filename)
        language = Keyword.get(opts, :language) || config.language

        case post_wav(wav, config, language, filename, timeout) do
          {:ok, %{body: body}} -> decode_ok(body)
          other -> other
        end
    end
  end

  @doc """
  The warm-up ping fired the moment voice mode is ARMED.

  A cold lane costs up to 35 s on its first call (spec section 6.1), so this
  pays that cost once, up front, behind an explicit "warming up" UI state and
  the much looser `config.warmup_timeout_ms`.

  Posts 1.0 s of digital silence — a VALID clip comfortably over the 0.8 s
  floor, so it is one the lane accepts; the expected reply is
  `text: ""` (SPIKE 2 measured 0 non-empty results across 173 silence/noise
  requests). ANY 200 counts as warm.

  Returns `{:ok, %{elapsed_ms: n}}` — wall clock, so the UI can say
  "warmed in 12.5 s" — or `{:error, reason}`.
  """
  @spec warmup(map()) :: {:ok, %{elapsed_ms: non_neg_integer()}} | {:error, reason()}
  def warmup(config) do
    wav = wav_from_pcm16(:binary.copy(<<0, 0>>, @sample_rate))
    started = System.monotonic_time(:millisecond)

    case post_wav(wav, config, config.language, @warmup_filename, config.warmup_timeout_ms) do
      {:ok, %{status: 200}} ->
        {:ok, %{elapsed_ms: System.monotonic_time(:millisecond) - started}}

      other ->
        other
    end
  end

  @doc """
  Whether a successful transcription is really silence.

  Two independent signals, either of which is enough: a blank `text` (the
  normal non-speech 200), or an `elapsed_seconds` under 50 ms, which means
  the server's VAD gate rejected the clip before the decoder ever ran.
  """
  @spec silence?(result()) :: boolean()
  def silence?(%{text: text, elapsed_seconds: elapsed}) do
    String.trim(text) == "" or elapsed < @silence_elapsed_seconds
  end

  @doc """
  A short, human-readable rendering of an error reason for the voice UI.

  Pass the config to get the timeout figure and the lane's `host:port` into
  the message — without it the wording stays generic rather than lying.
  """
  @spec describe_error(reason(), map() | nil) :: String.t()
  def describe_error(reason, config \\ nil)

  def describe_error(:too_short, _config),
    do: "Clip too short for transcription (under 0.8 s)"

  def describe_error(:too_long, _config),
    do: "Clip too long for transcription (over 20 s)"

  def describe_error(:timeout, config) do
    case config && config[:timeout_ms] do
      nil -> "ASR timed out"
      ms -> "ASR timed out after #{ms} ms"
    end
  end

  def describe_error({:http, status, detail}, _config) do
    base = "ASR returned #{status}: #{http_hint(status)}"
    if is_binary(detail) and String.trim(detail) != "", do: "#{base} (#{detail})", else: base
  end

  def describe_error({:transport, reason}, config),
    do: "ASR unreachable: #{transport_hint(reason)}#{endpoint_suffix(config)}"

  def describe_error({:bad_response, _term}, _config),
    do: "ASR returned an unrecognized response"

  def describe_error(other, _config), do: "ASR error: #{inspect(other)}"

  @doc """
  Wraps raw int16 little-endian mono PCM in a 44-byte canonical WAV header.

  The lane wants a real container; the browser worklet hands us bare samples.
  Public because its byte layout is worth unit-testing directly.
  """
  @spec wav_from_pcm16(binary(), pos_integer()) :: binary()
  def wav_from_pcm16(pcm, sample_rate \\ @sample_rate) when is_binary(pcm) do
    data_size = byte_size(pcm)
    byte_rate = sample_rate * @channels * @bytes_per_sample
    block_align = @channels * @bytes_per_sample

    <<
      "RIFF",
      36 + data_size::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      # audio format: 1 = PCM
      1::little-16,
      @channels::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      block_align::little-16,
      @bits_per_sample::little-16,
      "data",
      data_size::little-32,
      pcm::binary
    >>
  end

  defp post_wav(wav, config, language, filename, timeout) do
    url = String.trim_trailing(config.url, "/") <> config.path

    opts =
      [
        form_multipart: [
          file: {wav, filename: filename, content_type: "audio/wav"},
          language: language
        ],
        receive_timeout: timeout,
        # The lane is a single GPU thread on a FIFO (spec 6.1) — re-firing a
        # slow request against a saturated box is how you double the tail.
        retry: false
      ] ++ req_opts()

    url |> Req.post(opts) |> normalize()
  end

  defp normalize({:ok, %{status: 200} = resp}), do: {:ok, resp}

  defp normalize({:ok, %{status: status, body: body}}),
    do: {:error, {:http, status, detail(body)}}

  defp normalize({:error, %{reason: :timeout}}), do: {:error, :timeout}
  defp normalize({:error, %{reason: reason}}), do: {:error, {:transport, reason}}
  defp normalize({:error, reason}), do: {:error, {:transport, reason}}

  # Errors are `{"detail": "<string>"}` with no machine-readable code; take
  # the string when it's there, and never let a surprise body shape crash a
  # path whose whole job is reporting a failure.
  defp detail(%{"detail" => detail}) when is_binary(detail), do: detail
  defp detail(%{"detail" => detail}), do: inspect(detail)
  defp detail(body) when is_binary(body), do: body
  defp detail(body), do: inspect(body)

  defp decode_ok(%{
         "text" => text,
         "language" => language,
         "duration" => duration,
         "model" => model,
         "elapsed_seconds" => elapsed
       })
       when is_binary(text) and is_binary(language) and is_binary(model) and is_number(duration) and
              is_number(elapsed) do
    {:ok,
     %{
       text: text,
       language: language,
       duration: duration / 1,
       model: model,
       elapsed_seconds: elapsed / 1
     }}
  end

  defp decode_ok(body), do: {:error, {:bad_response, body}}

  defp http_hint(413), do: "clip too long"
  defp http_hint(415), do: "wrong content type"
  defp http_hint(504), do: "transcription server timed out"
  defp http_hint(_), do: "transcription failed"

  defp transport_hint(:econnrefused), do: "connection refused"
  defp transport_hint(:nxdomain), do: "host not found"
  defp transport_hint(:ehostunreach), do: "host unreachable"
  defp transport_hint(:timeout), do: "connection timed out"
  defp transport_hint(reason), do: inspect(reason)

  defp endpoint_suffix(nil), do: ""

  defp endpoint_suffix(config) do
    case URI.parse(config[:url] || "") do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        " (#{host}:#{port})"

      %URI{host: host} when is_binary(host) ->
        " (#{host})"

      _ ->
        ""
    end
  end

  defp req_opts, do: Application.get_env(:orca_hub, :asr_req_options, [])
end
