defmodule OrcaHubWeb.TTSControllerTest do
  use OrcaHubWeb.ConnCase, async: true

  @token "test-api-token"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

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

    test "text exactly at the cap is accepted past the length check (falls through to the " <>
           "ElevenLabs-key check, never a 413)",
         %{conn: conn} do
      Application.delete_env(:orca_hub, :elevenlabs_api_key)
      at_cap = String.duplicate("a", 4_000)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => at_cap})

      assert json_response(conn, 500)["error"] == "ElevenLabs API key not configured"
    end

    test "500 with a clear error when ElevenLabs isn't configured (auth + length both pass)", %{
      conn: conn
    } do
      Application.delete_env(:orca_hub, :elevenlabs_api_key)

      conn = conn |> authed() |> post(~p"/api/tts", %{"text" => "hello"})

      assert json_response(conn, 500)["error"] == "ElevenLabs API key not configured"
    end
  end
end
