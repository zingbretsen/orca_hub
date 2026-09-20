defmodule OrcaHubWeb.SettingsLive.ASRTest do
  @moduledoc """
  LiveView coverage for the Speech recognition section on the Settings page
  (`OrcaHub.ASRConfig`-backed).

  `async: false` for the same reason as `OrcaHub.ASRConfigTest`: these tests
  mutate the global `:asr_*` application env.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ASRConfig

  @env_keys [
    :asr_url,
    :asr_path,
    :asr_language,
    :asr_timeout_ms,
    :asr_warmup_timeout_ms,
    :asr_intent_threshold,
    :asr_echo_cancellation,
    :asr_noise_suppression,
    :asr_auto_gain_control,
    :asr_release_mic_during_playback
  ]

  setup do
    saved = Map.new(@env_keys, fn key -> {key, Application.fetch_env(:orca_hub, key)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:orca_hub, key, value)
        {key, :error} -> Application.delete_env(:orca_hub, key)
      end)
    end)

    Application.put_env(:orca_hub, :asr_url, "http://env-asr.test:8000")
    Application.put_env(:orca_hub, :asr_path, "/env/transcribe")
    Application.put_env(:orca_hub, :asr_language, "en")
    Application.put_env(:orca_hub, :asr_timeout_ms, "1111")
    Application.put_env(:orca_hub, :asr_warmup_timeout_ms, "2222")
    Application.put_env(:orca_hub, :asr_intent_threshold, "0.5")
    Application.put_env(:orca_hub, :asr_echo_cancellation, "true")
    Application.put_env(:orca_hub, :asr_noise_suppression, "true")
    Application.put_env(:orca_hub, :asr_auto_gain_control, "true")
    Application.put_env(:orca_hub, :asr_release_mic_during_playback, "false")

    :ok
  end

  defp submit(view, params) do
    defaults = %{
      "url" => "",
      "path" => "",
      "language" => "",
      "timeout_ms" => "",
      "warmup_timeout_ms" => "",
      "threshold" => "",
      "echo_cancellation" => "",
      "noise_suppression" => "",
      "auto_gain_control" => "",
      "release_mic_during_playback" => "",
      "enabled" => "true"
    }

    view
    |> form("#asr-provider-form", %{"asr" => Map.merge(defaults, params)})
    |> render_submit()
  end

  describe "rendering" do
    test "renders each env value as the placeholder for its blank override", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Speech recognition (ASR)"
      assert html =~ "http://env-asr.test:8000"
      assert html =~ "/env/transcribe"
      assert html =~ "1111"
      assert html =~ "2222"
      assert html =~ "0.5"
    end

    test "renders the three capture constraints and says when they take effect", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Microphone capture constraints"
      assert html =~ "Echo cancellation (AEC)"
      assert html =~ "Noise suppression (NS)"
      assert html =~ "Auto gain control (AGC)"
      assert html =~ "ASR_ECHO_CANCELLATION"
      assert html =~ "next ARM"
    end

    test "renders the release-during-playback knob and says when IT takes effect",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Microphone during TTS playback"
      assert html =~ "Release the microphone while the assistant speaks"
      assert html =~ "ASR_RELEASE_MIC_DURING_PLAYBACK"
      # Its timing is the NEXT JOIN, which is a different answer from the
      # capture constraints' "next arm" three fields above it.
      assert html =~ "next <strong>join</strong>"
      # The env default is rendered into the inherit option, so the page
      # shows what a blank select will actually do.
      assert html =~ "ASR_RELEASE_MIC_DURING_PLAYBACK (false)"
    end

    test "there is no model catalog on this lane", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "asr-model-form"
    end
  end

  describe "saving" do
    test "writes the provider row and takes effect on the next resolve", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{
        "url" => "http://db-asr.test:8000",
        "timeout_ms" => "7000",
        "threshold" => "0.9"
      })

      assert ASRConfig.resolve() == %{
               url: "http://db-asr.test:8000",
               # left blank in the form, so still inherited per-field
               path: "/env/transcribe",
               language: "en",
               timeout_ms: 7000,
               warmup_timeout_ms: 2222,
               threshold: 0.9,
               echo_cancellation: true,
               noise_suppression: true,
               auto_gain_control: true,
               release_mic_during_playback: false
             }
    end

    test "a constraint set to false in the UI is what the voice channel hands the browser",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"echo_cancellation" => "false"})

      assert ASRConfig.capture_constraints() == %{
               echoCancellation: false,
               noiseSuppression: true,
               autoGainControl: true
             }
    end

    test "turning the release on in the UI is what the voice channel hands the browser",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"release_mic_during_playback" => "true"})

      assert ASRConfig.resolve().release_mic_during_playback == true
      # ...and it changed nothing about the constraint object, which is a
      # separate mechanism with a separate timing.
      assert ASRConfig.capture_constraints() == %{
               echoCancellation: true,
               noiseSuppression: true,
               autoGainControl: true
             }
    end

    test "leaving the release blank inherits it from env, off by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"url" => "http://db-asr.test:8000"})

      assert ASRConfig.get_provider_entry().spec["release_mic_during_playback"] == ""
      assert ASRConfig.resolve().release_mic_during_playback == false
    end

    test "leaving a constraint blank inherits that one from env", %{conn: conn} do
      Application.put_env(:orca_hub, :asr_auto_gain_control, "false")

      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"echo_cancellation" => "false"})

      assert ASRConfig.resolve().echo_cancellation == false
      assert ASRConfig.resolve().auto_gain_control == false
      assert ASRConfig.get_provider_entry().spec["auto_gain_control"] == ""
    end

    test "a constraint that is neither true nor false is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#asr-provider-form", %{"asr" => %{"url" => ""}})
        |> render_submit(%{
          "asr" => %{
            "url" => "",
            "path" => "",
            "language" => "",
            "timeout_ms" => "",
            "warmup_timeout_ms" => "",
            "threshold" => "",
            "echo_cancellation" => "maybe",
            "noise_suppression" => "",
            "auto_gain_control" => "",
            "enabled" => "true"
          }
        })

      assert html =~ "Could not save"
      assert html =~ "echo_cancellation must be"
      assert ASRConfig.get_provider_entry() == nil
    end

    test "saving a blank field reverts that field alone to env", %{conn: conn} do
      {:ok, _} = ASRConfig.put_provider(%{url: "http://db-asr.test:8000", language: "fr"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"url" => "http://db-asr.test:8000", "language" => ""})

      assert ASRConfig.resolve().url == "http://db-asr.test:8000"
      assert ASRConfig.resolve().language == "en"
    end

    test "the form pre-fills with the saved overrides, not the env values", %{conn: conn} do
      {:ok, _} = ASRConfig.put_provider(%{url: "http://db-asr.test:8000", threshold: "0.95"})

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "http://db-asr.test:8000"
      assert html =~ "0.95"
    end

    test "an invalid value is reported and nothing is written", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = submit(view, %{"url" => "192.168.1.77:8000"})

      assert html =~ "Could not save"
      assert ASRConfig.get_provider_entry() == nil
      assert ASRConfig.resolve().url == "http://env-asr.test:8000"
    end

    test "an out-of-range threshold is rejected rather than clamped", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = submit(view, %{"threshold" => "2"})

      assert html =~ "Could not save"
      assert ASRConfig.resolve().threshold == 0.5
    end

    test "unchecking Enabled reverts every field to env without losing the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      submit(view, %{"url" => "http://db-asr.test:8000"})
      assert ASRConfig.resolve().url == "http://db-asr.test:8000"

      submit(view, %{"url" => "http://db-asr.test:8000", "enabled" => "false"})

      assert ASRConfig.resolve().url == "http://env-asr.test:8000"
      assert ASRConfig.get_provider_entry().spec["url"] == "http://db-asr.test:8000"
      refute ASRConfig.get_provider_entry().enabled
    end

    test "validate keeps the typed-but-unsaved values in the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#asr-provider-form", %{
          "asr" => %{
            "url" => "http://unsaved.test:8000",
            "path" => "",
            "language" => "",
            "timeout_ms" => "",
            "warmup_timeout_ms" => "",
            "threshold" => "",
            "echo_cancellation" => "",
            "noise_suppression" => "",
            "auto_gain_control" => "",
            "enabled" => "true"
          }
        })
        |> render_change()

      assert html =~ "http://unsaved.test:8000"
      # Validation is not a save.
      assert ASRConfig.get_provider_entry() == nil
    end
  end
end
