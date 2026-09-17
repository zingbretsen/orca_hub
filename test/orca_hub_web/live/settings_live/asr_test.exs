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
    :asr_intent_threshold
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
               threshold: 0.9
             }
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
