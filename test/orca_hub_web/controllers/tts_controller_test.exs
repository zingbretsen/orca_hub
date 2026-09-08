defmodule OrcaHubWeb.TTSControllerTest do
  use OrcaHubWeb.ConnCase, async: true

  @token "test-api-token"
  @stub __MODULE__

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  # Same Req.Test plug-stub convention as OrcaHub.A2ATest / MemoryGitTest: the
  # controller merges :tts_req_options into every Req call precisely so a test
  # can swap the transport out.
  defp stub_tts(test_name, fun) do
    Application.put_env(:orca_hub, :tts_req_options, plug: {Req.Test, {@stub, test_name}})
    on_exit(fn -> Application.delete_env(:orca_hub, :tts_req_options) end)
    Req.Test.stub({@stub, test_name}, fun)
  end

  describe "POST /api/tts auth (moved off the bare :api pipeline — tts_rewrite_spec.md §3.5)" do
    test "503 when the API is disabled (no token configured)", %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "401 with no Authorization header", %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, @token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      conn = post(conn, ~p"/api/tts", %{"text" => "hello"})
      assert json_response(conn, 401)
    end

    test "401 with a mismatched token", %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, @token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> post(~p"/api/tts", %{"text" => "hello"})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/tts text handling" do
    setup do
      Application.put_env(:orca_hub, :api_token, @token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
      :ok
    end

    test "400 when text is missing", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/tts", %{})
      assert json_response(conn, 400)["error"] == "Missing text parameter"
    end

    test "413 when text exceeds the length cap", %{conn: conn} do
      too_long = String.duplicate("a", 4_001)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => too_long})

      body = json_response(conn, 413)
      assert body["error"] == "text too long"
      assert body["max_bytes"] == 4_000
    end

    test "text exactly at the cap is accepted past the length check (reaches the provider, " <>
           "never a 413)",
         %{conn: conn, test: test_name} do
      stub_tts(test_name, fn c -> Plug.Conn.send_resp(c, 200, "RIFF____WAVE") end)
      at_cap = String.duplicate("a", 4_000)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => at_cap})

      assert response(conn, 200) == "RIFF____WAVE"
    end
  end

  describe "POST /api/tts local provider (homelab ai_gateway)" do
    setup do
      Application.put_env(:orca_hub, :api_token, @token)
      Application.put_env(:orca_hub, :tts_provider, "local")

      on_exit(fn ->
        Application.delete_env(:orca_hub, :api_token)
        Application.delete_env(:orca_hub, :tts_provider)
      end)

      :ok
    end

    test "posts the OpenAI-dialect body the gateway accepts and returns audio/wav", %{
      conn: conn,
      test: test_name
    } do
      Application.put_env(:orca_hub, :tts_url, "http://ai-gateway.test")
      on_exit(fn -> Application.delete_env(:orca_hub, :tts_url) end)

      stub_tts(test_name, fn c ->
        assert c.method == "POST"
        assert c.request_path == "/v1/audio/speech"

        {:ok, raw, c} = Plug.Conn.read_body(c)
        body = Jason.decode!(raw)

        assert body == %{
                 "model" => "tts-chatterbox-23lang",
                 "input" => "hello there",
                 "language" => "en"
               }

        # The gateway 400s on a non-"default" voice, a non-"wav"
        # response_format, or a speed other than 1 — so we must not send them
        # at all. Asserted explicitly because a green mocked test is otherwise
        # blind to exactly that failure.
        refute Map.has_key?(body, "voice")
        refute Map.has_key?(body, "response_format")
        refute Map.has_key?(body, "speed")

        Plug.Conn.send_resp(c, 200, "RIFF0000WAVEfmt ")
      end)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello there"})

      assert response(conn, 200) == "RIFF0000WAVEfmt "
      assert response_content_type(conn, :wav) =~ "audio/wav"
    end

    test "honours TTS_MODEL/TTS_LANGUAGE overrides", %{conn: conn, test: test_name} do
      Application.put_env(:orca_hub, :tts_model, "other-model")
      Application.put_env(:orca_hub, :tts_language, "fr")

      on_exit(fn ->
        Application.delete_env(:orca_hub, :tts_model)
        Application.delete_env(:orca_hub, :tts_language)
      end)

      stub_tts(test_name, fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)
        body = Jason.decode!(raw)
        assert body["model"] == "other-model"
        assert body["language"] == "fr"
        Plug.Conn.send_resp(c, 200, "RIFF")
      end)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "bonjour"})
      assert response(conn, 200) == "RIFF"
    end

    test "propagates a non-200 from the gateway with its status and a detail body", %{
      conn: conn,
      test: test_name
    } do
      stub_tts(test_name, fn c ->
        Plug.Conn.send_resp(c, 400, ~s({"detail":"voice must be 'default'"}))
      end)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      body = json_response(conn, 400)
      assert body["error"] == "TTS error"
      assert body["detail"] =~ "voice must be 'default'"
    end

    test "500 when the gateway is unreachable", %{conn: conn, test: test_name} do
      stub_tts(test_name, fn c -> Req.Test.transport_error(c, :econnrefused) end)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      body = json_response(conn, 500)
      assert body["error"] == "Request failed"
      assert body["detail"] =~ "econnrefused"
    end
  end

  describe "POST /api/tts with TTS_PROVIDER=elevenlabs (opt-in fallback)" do
    setup do
      Application.put_env(:orca_hub, :api_token, @token)
      Application.put_env(:orca_hub, :tts_provider, "elevenlabs")

      on_exit(fn ->
        Application.delete_env(:orca_hub, :api_token)
        Application.delete_env(:orca_hub, :tts_provider)
      end)

      :ok
    end

    test "still proxies to ElevenLabs and returns audio/mpeg", %{conn: conn, test: test_name} do
      Application.put_env(:orca_hub, :elevenlabs_api_key, "sk_test")
      on_exit(fn -> Application.delete_env(:orca_hub, :elevenlabs_api_key) end)

      stub_tts(test_name, fn c ->
        assert c.host == "api.elevenlabs.io"
        assert Plug.Conn.get_req_header(c, "xi-api-key") == ["sk_test"]

        {:ok, raw, c} = Plug.Conn.read_body(c)
        assert Jason.decode!(raw)["model_id"] == "eleven_turbo_v2_5"

        Plug.Conn.send_resp(c, 200, "ID3-mp3-bytes")
      end)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      assert response(conn, 200) == "ID3-mp3-bytes"
      assert response_content_type(conn, :mpeg) =~ "audio/mpeg"
    end

    test "500 with a clear error when the ElevenLabs key isn't configured", %{conn: conn} do
      Application.delete_env(:orca_hub, :elevenlabs_api_key)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      assert json_response(conn, 500)["error"] == "ElevenLabs API key not configured"
    end
  end
end
