defmodule OrcaHub.Voice.ASRTest do
  @moduledoc """
  Every request path here is stubbed via `Req.Test`; nothing touches the real
  GB10 sync lane. The measured contract these assertions pin down lives in
  `voice_mode_spec.md` section 6.
  """

  # async: false — sets the global :asr_req_options app env.
  use ExUnit.Case, async: false

  alias OrcaHub.Voice.ASR

  @stub OrcaHub.Voice.ASRStub

  @config %{
    url: "http://192.168.1.77:8000",
    path: "/v1/transcribe/sync",
    language: "en",
    timeout_ms: 10_000,
    warmup_timeout_ms: 35_000,
    threshold: 0.85
  }

  setup do
    Application.put_env(:orca_hub, :asr_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:orca_hub, :asr_req_options) end)
    :ok
  end

  # 1 s of 16 kHz mono int16 — comfortably over the 0.8 s floor.
  defp pcm(samples), do: :binary.copy(<<0, 0>>, samples)
  defp pcm, do: pcm(16_000)

  defp ok_body(overrides \\ %{}) do
    Map.merge(
      %{
        "text" => "orca send",
        "language" => "en",
        "duration" => 1.0,
        "model" => "large-v3-turbo",
        "elapsed_seconds" => 0.569
      },
      overrides
    )
  end

  # A TCP socket that accepts a connection and then never answers, so a real
  # Finch request against it can only end in receive_timeout. Timeout
  # selection is invisible to a Req.Test plug (the plug never sees the
  # request options), so the only honest way to prove which budget was used
  # is to let the real one expire.
  defp blackhole_config do
    Application.delete_env(:orca_hub, :asr_req_options)

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    acceptor =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        Process.sleep(:infinity)
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{@config | url: "http://127.0.0.1:#{port}"}
  end

  # Decodes a stubbed multipart request body back into %{"file" => %Plug.Upload{},
  # "language" => "en"} so the parts can be asserted on individually.
  defp parse_multipart(conn) do
    opts = Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"], length: 50_000_000)
    Plug.Parsers.call(conn, opts)
  end

  describe "wav_from_pcm16/1,2" do
    test "emits a canonical 44-byte PCM WAV header" do
      data = :binary.copy(<<1, 0>>, 100)
      wav = ASR.wav_from_pcm16(data)

      assert byte_size(wav) == 44 + 200

      <<"RIFF", riff_size::little-32, "WAVE", "fmt ", fmt_size::little-32, format::little-16,
        channels::little-16, rate::little-32, byte_rate::little-32, block_align::little-16,
        bits::little-16, "data", data_size::little-32, payload::binary>> = wav

      assert riff_size == 36 + 200
      assert fmt_size == 16
      # 1 = PCM (uncompressed)
      assert format == 1
      assert channels == 1
      assert rate == 16_000
      assert byte_rate == 32_000
      assert block_align == 2
      assert bits == 16
      assert data_size == 200
      assert payload == data
    end

    test "an explicit sample rate flows into rate and byte rate" do
      <<_::binary-24, rate::little-32, byte_rate::little-32, _::binary>> =
        ASR.wav_from_pcm16(<<0, 0>>, 8_000)

      assert rate == 8_000
      assert byte_rate == 16_000
    end

    test "an empty payload still produces a well-formed 44-byte header" do
      wav = ASR.wav_from_pcm16(<<>>)
      assert byte_size(wav) == 44
      assert <<"RIFF", 36::little-32, "WAVE", _::binary>> = wav
    end
  end

  describe "transcribe/3 request shape" do
    test "POSTs multipart/form-data with exactly the file and language parts" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/transcribe/sync"
        assert conn.host == "192.168.1.77"
        assert conn.port == 8000

        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type =~ "multipart/form-data"

        conn = parse_multipart(conn)
        assert Map.keys(conn.params) |> Enum.sort() == ["file", "language"]
        assert conn.params["language"] == "en"

        upload = conn.params["file"]
        assert %Plug.Upload{filename: "segment.wav", content_type: "audio/wav"} = upload

        # The WAV the lane receives is the PCM we handed in, headered.
        body = File.read!(upload.path)
        assert <<"RIFF", _::little-32, "WAVE", _::binary>> = body
        assert byte_size(body) == 44 + 32_000

        Req.Test.json(conn, ok_body())
      end)

      assert {:ok, %{text: "orca send"}} = ASR.transcribe(pcm(), @config)
    end

    test "opts override the language and the multipart filename" do
      Req.Test.stub(@stub, fn conn ->
        conn = parse_multipart(conn)
        assert conn.params["language"] == "fr"
        assert %Plug.Upload{filename: "utterance.wav"} = conn.params["file"]
        Req.Test.json(conn, ok_body(%{"language" => "fr"}))
      end)

      assert {:ok, %{language: "fr"}} =
               ASR.transcribe(pcm(), @config, language: "fr", filename: "utterance.wav")
    end

    test "a trailing slash on the configured url does not double up the path" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/transcribe/sync"
        Req.Test.json(conn, ok_body())
      end)

      assert {:ok, _} = ASR.transcribe(pcm(), %{@config | url: "http://192.168.1.77:8000/"})
    end
  end

  describe "transcribe/3 success decoding" do
    test "decodes exactly the five fields the lane returns" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(
          conn,
          ok_body(%{"text" => "hello there", "duration" => 8.32, "elapsed_seconds" => 0.967})
        )
      end)

      assert {:ok, result} = ASR.transcribe(pcm(), @config)

      assert result == %{
               text: "hello there",
               language: "en",
               duration: 8.32,
               model: "large-v3-turbo",
               elapsed_seconds: 0.967
             }

      refute ASR.silence?(result)
    end

    test "integer duration/elapsed_seconds are coerced to floats" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, ok_body(%{"duration" => 1, "elapsed_seconds" => 2}))
      end)

      assert {:ok, %{duration: 1.0, elapsed_seconds: 2.0}} = ASR.transcribe(pcm(), @config)
    end

    test "text: \"\" is a normal 200 result, and silence?/1 says so" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, ok_body(%{"text" => "", "elapsed_seconds" => 0.5}))
      end)

      assert {:ok, result} = ASR.transcribe(pcm(), @config)
      assert result.text == ""
      assert ASR.silence?(result)
    end

    test "a sub-50ms elapsed_seconds means the server VAD found nothing" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, ok_body(%{"text" => "archives.", "elapsed_seconds" => 0.014}))
      end)

      assert {:ok, result} = ASR.transcribe(pcm(), @config)
      assert result.elapsed_seconds == 0.014
      assert ASR.silence?(result)
    end

    test "a 200 missing the five fields is {:bad_response, _}, not a crash" do
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"text" => "hi"}) end)

      assert {:error, {:bad_response, %{"text" => "hi"}}} = ASR.transcribe(pcm(), @config)
    end
  end

  describe "silence?/1" do
    test "whitespace-only text counts as silence" do
      assert ASR.silence?(%{text: "  \n ", elapsed_seconds: 0.5})
    end

    test "real text at a real elapsed time is not silence" do
      refute ASR.silence?(%{text: "orca send", elapsed_seconds: 0.5})
    end
  end

  describe "transcribe/3 error mapping" do
    for {status, detail} <- [
          {413, "Audio duration 22.10s exceeds maximum of 20s"},
          {415, "Unsupported Media Type"},
          {504, "Transcription timed out after 30s"},
          {500, "Internal Server Error"}
        ] do
      test "HTTP #{status} becomes {:http, #{status}, detail}" do
        status = unquote(status)
        detail = unquote(detail)

        Req.Test.stub(@stub, fn conn ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"detail" => detail})
        end)

        assert {:error, {:http, ^status, ^detail}} = ASR.transcribe(pcm(), @config)
      end
    end

    test "a timeout becomes {:error, :timeout}" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :timeout} = ASR.transcribe(pcm(), @config)
    end

    test "a refused connection becomes {:error, {:transport, _}}" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, :econnrefused}} = ASR.transcribe(pcm(), @config)
    end

    test "a non-JSON error body still yields a string detail" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(502, "bad gateway")
      end)

      assert {:error, {:http, 502, "bad gateway"}} = ASR.transcribe(pcm(), @config)
    end
  end

  describe "transcribe/3 length guards" do
    test "under 12800 samples is refused with NO request made" do
      Req.Test.stub(@stub, fn _conn -> flunk("should not have called the endpoint") end)

      # 0.79 s at 16 kHz.
      assert {:error, :too_short} = ASR.transcribe(pcm(12_799), @config)
      assert {:error, :too_short} = ASR.transcribe(<<>>, @config)
    end

    test "exactly 12800 samples is accepted (the floor is inclusive)" do
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, ok_body()) end)

      assert {:ok, _} = ASR.transcribe(pcm(12_800), @config)
    end

    test "over 320000 samples is refused with NO request made" do
      Req.Test.stub(@stub, fn _conn -> flunk("should not have called the endpoint") end)

      assert {:error, :too_long} = ASR.transcribe(pcm(320_001), @config)
    end

    test "exactly 320000 samples (20 s) is accepted" do
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, ok_body()) end)

      assert {:ok, _} = ASR.transcribe(pcm(320_000), @config)
    end
  end

  describe "warmup/1" do
    test "posts 1.0 s of valid silence and returns the wall time on any 200" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/transcribe/sync"

        conn = parse_multipart(conn)
        assert conn.params["language"] == "en"
        assert %Plug.Upload{filename: "warmup.wav"} = conn.params["file"]

        # 16000 zero samples + a 44-byte header: over the 0.8 s floor, so the
        # lane accepts it rather than 413ing or hallucinating on a fragment.
        body = File.read!(conn.params["file"].path)
        assert byte_size(body) == 44 + 32_000
        assert <<"RIFF", _::little-32, "WAVE", _::binary>> = body
        assert binary_part(body, 44, 32_000) == :binary.copy(<<0, 0>>, 16_000)

        Req.Test.json(conn, ok_body(%{"text" => "", "elapsed_seconds" => 0.014}))
      end)

      assert {:ok, %{elapsed_ms: elapsed_ms}} = ASR.warmup(@config)
      assert is_integer(elapsed_ms) and elapsed_ms >= 0
    end

    test "uses warmup_timeout_ms, not timeout_ms, as the receive timeout" do
      # Against a socket that accepts and never answers: a config whose
      # warmup_timeout_ms is tiny while timeout_ms is huge can only time out
      # fast if warmup/1 picked the warm-up budget.
      config = %{blackhole_config() | timeout_ms: 30_000, warmup_timeout_ms: 150}

      {elapsed_us, result} = :timer.tc(fn -> ASR.warmup(config) end)

      assert {:error, :timeout} = result
      assert elapsed_us < 5_000_000
    end

    test "warmup surfaces errors rather than raising" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:transport, :econnrefused}} = ASR.warmup(@config)
    end
  end

  describe "transcribe/3 timeout selection" do
    test "defaults to config.timeout_ms" do
      config = %{blackhole_config() | timeout_ms: 150}

      {elapsed_us, result} = :timer.tc(fn -> ASR.transcribe(pcm(), config) end)

      assert {:error, :timeout} = result
      assert elapsed_us < 5_000_000
    end

    test "opts[:timeout_ms] overrides config.timeout_ms" do
      config = %{blackhole_config() | timeout_ms: 30_000}

      {elapsed_us, result} =
        :timer.tc(fn -> ASR.transcribe(pcm(), config, timeout_ms: 150) end)

      assert {:error, :timeout} = result
      assert elapsed_us < 5_000_000
    end
  end

  describe "describe_error/1,2" do
    test "renders each reason for the UI" do
      assert ASR.describe_error(:timeout, @config) == "ASR timed out after 10000 ms"
      assert ASR.describe_error(:timeout) == "ASR timed out"

      assert ASR.describe_error({:http, 413, "clip too long"}) ==
               "ASR returned 413: clip too long (clip too long)"

      assert ASR.describe_error({:http, 415, ""}) == "ASR returned 415: wrong content type"

      assert ASR.describe_error({:http, 504, "timed out"}) ==
               "ASR returned 504: transcription server timed out (timed out)"

      assert ASR.describe_error({:http, 500, "boom"}) ==
               "ASR returned 500: transcription failed (boom)"

      assert ASR.describe_error({:transport, :econnrefused}, @config) ==
               "ASR unreachable: connection refused (192.168.1.77:8000)"

      assert ASR.describe_error({:transport, :econnrefused}) ==
               "ASR unreachable: connection refused"

      assert ASR.describe_error({:transport, :nxdomain}) == "ASR unreachable: host not found"

      assert ASR.describe_error(:too_short) == "Clip too short for transcription (under 0.8 s)"
      assert ASR.describe_error(:too_long) == "Clip too long for transcription (over 20 s)"

      assert ASR.describe_error({:bad_response, %{}}) == "ASR returned an unrecognized response"
      assert ASR.describe_error(:wat) == "ASR error: :wat"
    end
  end
end
