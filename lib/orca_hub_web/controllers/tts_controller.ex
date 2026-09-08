defmodule OrcaHubWeb.TTSController do
  use OrcaHubWeb, :controller

  alias OrcaHub.HubRPC

  # Client-side chunking (app.js's ttsSplitIntoChunks) targets ~80+ char
  # sentence-bucketed chunks, so a legitimate request is nowhere near this —
  # this is purely an upper bound on a single synthesis call, not a realistic
  # chunk size (see tts_rewrite_spec.md §3.5: this route had no length cap at
  # all before, on top of having no auth).
  @max_text_bytes 4_000

  def create(conn, %{"text" => text}) when byte_size(text) > @max_text_bytes do
    conn
    |> put_status(413)
    |> json(%{error: "text too long", max_bytes: @max_text_bytes})
  end

  def create(conn, %{"text" => text}) when byte_size(text) > 0 do
    # Resolved fresh on every request, with no cache anywhere behind it, so a
    # provider/model change made in Settings takes effect on the very next
    # request with no restart and no redeploy — see OrcaHub.TTSConfig.
    text
    |> OrcaHub.TTS.synthesize(HubRPC.resolve_tts_config())
    |> respond(conn)
  end

  def create(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing text parameter"})
  end

  defp respond({:ok, %{body: audio, content_type: content_type}}, conn) do
    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, audio)
  end

  defp respond({:error, {:http, :local, status, body}}, conn),
    do: conn |> put_status(status) |> json(%{error: "TTS error", detail: inspect(body)})

  defp respond({:error, {:http, :elevenlabs, status, body}}, conn),
    do: conn |> put_status(status) |> json(%{error: "ElevenLabs error", detail: body})

  defp respond({:error, {:transport, reason}}, conn),
    do: conn |> put_status(500) |> json(%{error: "Request failed", detail: inspect(reason)})

  defp respond({:error, :missing_elevenlabs_key}, conn),
    do: conn |> put_status(500) |> json(%{error: "ElevenLabs API key not configured"})
end
