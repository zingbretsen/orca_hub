defmodule OrcaHubWeb.SettingsLive.TTSTest do
  @moduledoc """
  LiveView coverage for the Text-to-Speech section on the Settings page
  (`OrcaHub.TTSConfig`-backed).

  `async: false` for the same reason as `OrcaHub.TTSConfigTest`: these tests
  mutate the global `:tts_*` application env that the async controller suite
  also reads.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.TTSConfig

  @stub __MODULE__

  @env_keys [:tts_provider, :tts_url, :tts_model, :tts_language]

  setup do
    saved = Map.new(@env_keys, fn key -> {key, Application.fetch_env(:orca_hub, key)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:orca_hub, key, value)
        {key, :error} -> Application.delete_env(:orca_hub, key)
      end)
    end)

    Application.put_env(:orca_hub, :tts_provider, "local")
    Application.put_env(:orca_hub, :tts_url, "http://env-gateway.test")
    Application.put_env(:orca_hub, :tts_model, "env-model")
    Application.put_env(:orca_hub, :tts_language, "en")

    :ok
  end

  defp stub_tts(test_name, fun) do
    Application.put_env(:orca_hub, :tts_req_options, plug: {Req.Test, {@stub, test_name}})
    on_exit(fn -> Application.delete_env(:orca_hub, :tts_req_options) end)
    Req.Test.stub({@stub, test_name}, fun)
  end

  describe "provider settings" do
    test "renders each env value as the placeholder for its blank override", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Text to Speech"
      assert html =~ "http://env-gateway.test"
      assert html =~ "Inherit from TTS_PROVIDER (local)"
    end

    test "saving writes the provider row and takes effect on the next resolve", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#tts-provider-form", %{
        "tts" => %{"provider" => "elevenlabs", "url" => "http://db.test", "language" => ""}
      })
      |> render_submit()

      assert TTSConfig.resolve() == %{
               provider: "elevenlabs",
               url: "http://db.test",
               # left blank in the form, so still inherited per-field
               language: "en",
               model: "env-model"
             }
    end

    test "saving a blank provider reverts that field alone to env", %{conn: conn} do
      {:ok, _} =
        TTSConfig.put_provider(%{provider: "elevenlabs", url: "http://db.test", language: "fr"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#tts-provider-form", %{
        "tts" => %{"provider" => "", "url" => "http://db.test", "language" => "fr"}
      })
      |> render_submit()

      assert TTSConfig.resolve().provider == "local"
      assert TTSConfig.resolve().url == "http://db.test"
    end
  end

  describe "model catalog" do
    test "shows the env fallback when the catalog is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "No models yet"
      assert html =~ "env-model"
    end

    test "adds a model, which becomes the default while nothing else is marked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#tts-model-form", %{
          "tts_model" => %{"name" => "fast-model"}
        })
        |> render_submit()

      assert html =~ "fast-model"
      assert TTSConfig.resolve().model == "fast-model"
    end

    test "rejects an invalid model name without adding a row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#tts-model-form", %{
        "tts_model" => %{"name" => "not a model id"}
      })
      |> render_submit()

      assert TTSConfig.list_models() == []
    end

    test "make-default repoints synthesis, and clear-default returns it to env", %{conn: conn} do
      {:ok, _first} = TTSConfig.create_model(%{name: "first"})
      {:ok, second} = TTSConfig.create_model(%{name: "second"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click='set_default_tts_model'][phx-value-id='#{second.id}']")
      |> render_click()

      assert TTSConfig.resolve().model == "second"

      view |> element("button[phx-click='clear_default_tts_model']") |> render_click()

      assert TTSConfig.resolve().model == "env-model"
    end

    test "removing a model deletes it from the catalog", %{conn: conn} do
      {:ok, model} = TTSConfig.create_model(%{name: "doomed"})

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click='delete_tts_model'][phx-value-id='#{model.id}']")
      |> render_click()

      assert TTSConfig.list_models() == []
    end
  end

  describe "speak sample" do
    test "synthesizes with the LIVE, unsaved form values and pushes the audio down", %{
      conn: conn,
      test: test_name
    } do
      stub_tts(test_name, fn c ->
        # The unsaved URL from the form, not the saved/env one.
        assert c.host == "unsaved.test"

        {:ok, raw, c} = Plug.Conn.read_body(c)
        assert Jason.decode!(raw)["language"] == "de"

        Plug.Conn.send_resp(c, 200, "RIFF0000WAVEfmt ")
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      # Change the form without submitting it — exactly the case the button
      # exists for (compare a model before committing to it).
      view
      |> form("#tts-provider-form", %{
        "tts" => %{"provider" => "local", "url" => "http://unsaved.test", "language" => "de"}
      })
      |> render_change()

      html = view |> element("button[phx-click='speak_tts_sample']") |> render_click()

      assert_push_event(view, "tts-sample", %{audio: audio})
      assert audio == "data:audio/wav;base64,#{Base.encode64("RIFF0000WAVEfmt ")}"

      # Wall time and size are the point of the button — a model catalog
      # exists to compare speed, which a bare "success" can't answer.
      assert html =~ "ms,"
      assert html =~ "16 B"
    end

    test "a per-row Speak button synthesizes with THAT row's model", %{
      conn: conn,
      test: test_name
    } do
      {:ok, _} = TTSConfig.create_model(%{name: "default-model"})
      {:ok, other} = TTSConfig.create_model(%{name: "other-model"})

      stub_tts(test_name, fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)
        assert Jason.decode!(raw)["model"] == "other-model"
        Plug.Conn.send_resp(c, 200, "RIFF")
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click='speak_tts_sample'][phx-value-model='#{other.name}']")
      |> render_click()

      assert_push_event(view, "tts-sample", %{audio: _})
      # `other` is not the default — the row button must not fall through to it.
      assert TTSConfig.resolve().model == "default-model"
    end

    test "reports a failure without pushing audio", %{conn: conn, test: test_name} do
      stub_tts(test_name, fn c -> Req.Test.transport_error(c, :econnrefused) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element("button[phx-click='speak_tts_sample']") |> render_click()

      assert html =~ "Sample failed"
      assert html =~ "econnrefused"
      refute_push_event(view, "tts-sample", %{})
    end
  end
end
