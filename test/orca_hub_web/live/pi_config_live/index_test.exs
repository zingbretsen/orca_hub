defmodule OrcaHubWeb.PiConfigLive.IndexTest do
  @moduledoc """
  LiveView coverage for the Pi Config page (`OrcaHub.PiConfig` CRUD, plus
  the `{:pi_config_updated}` PubSub-driven live refresh). Never touches disk —
  materializing entries onto nodes' `~/.pi/agent/` is `OrcaHub.PiConfigSync`'s
  job, and that GenServer's boot/broadcast loop is disabled entirely in
  `config/test.exs`, so nothing here reaches the real `~/.pi/agent`.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{HubRPC, PiConfig, PiConfig.Entry}

  @pi_config_sync_enabled Application.get_env(:orca_hub, :pi_config_sync_enabled, true)

  setup do
    # Disable PiConfigSync to avoid writing to disk during tests
    Application.put_env(:orca_hub, :pi_config_sync_enabled, false)

    on_exit(fn ->
      Application.put_env(:orca_hub, :pi_config_sync_enabled, @pi_config_sync_enabled)
    end)

    :ok
  end

  describe "index page" do
    test "lists all entries grouped by kind", %{conn: conn} do
      # Create entries of different kinds
      {:ok, _provider} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "ollama",
          spec: %{"baseUrl" => "http://localhost:11434"}
        })

      {:ok, _setting} =
        PiConfig.create_entry(%{
          kind: "setting",
          name: "defaultModel",
          spec: %{"value" => "ollama/llama3"}
        })

      {:ok, _extension} =
        PiConfig.create_entry(%{
          kind: "extension",
          name: "test-ext",
          spec: %{"body" => "console.log('test')"}
        })

      {:ok, _prompt} =
        PiConfig.create_entry(%{
          kind: "prompt",
          name: "test-prompt",
          spec: %{"body" => "# Test prompt"}
        })

      {:ok, _theme} =
        PiConfig.create_entry(%{
          kind: "theme",
          name: "test-theme",
          spec: %{"body" => "{\"name\": \"test\"}"}
        })

      {:ok, _view, html} = live(conn, ~p"/settings/pi-config")

      assert html =~ "Pi Config"
      assert html =~ "ollama"
      assert html =~ "defaultModel"
      assert html =~ "test-ext"
      assert html =~ "test-prompt"
      assert html =~ "test-theme"

      assert html =~ "Provider (models.json)"
      assert html =~ "Setting (settings.json)"
      assert html =~ "Extension (.ts)"
      assert html =~ "Prompt (.md)"
      assert html =~ "Theme (.json)"
    end

    test "shows disabled entries", %{conn: conn} do
      {:ok, _enabled} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "enabled-provider",
          spec: %{"baseUrl" => "http://localhost:11434"},
          enabled: true
        })

      {:ok, _disabled} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "disabled-provider",
          spec: %{"baseUrl" => "http://localhost:11434"},
          enabled: false
        })

      {:ok, _view, html} = live(conn, ~p"/settings/pi-config")

      assert html =~ "enabled"
      assert html =~ "disabled"
    end
  end

  describe "create entry" do
    test "creates a provider entry via form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/pi-config/new")

      # Verify form renders with correct param namespace
      assert html =~ ~s{name="pi_config_entry[name]"}
      assert html =~ ~s{name="pi_config_entry[enabled]"}
      assert html =~ ~s{name="pi_config_entry[kind]"}

      # Submit valid form data
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "test-provider",
            "kind" => "provider",
            "spec" => ~s|{"baseUrl": "http://localhost:11434"}|
          }
        })
        |> render_submit()

      # Verify entry was created
      entry = PiConfig.get_entry_by_kind_and_name("provider", "test-provider")
      assert entry
      assert HubRPC.list_pi_config_entries() |> Enum.any?(&(&1.name == "test-provider"))
    end

    test "shows error for invalid JSON spec", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Submit form with invalid JSON spec
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "invalid-provider",
            "kind" => "provider",
            "spec" => "not valid json{"
          }
        })
        |> render_submit()

      # Verify error is shown (invalid JSON becomes empty map, triggering spec validation)
      # The actual error is "must contain the provider config (baseUrl, api, models, ...)"
      assert html =~ "must contain the provider config"
      assert html =~ "baseUrl"
      refute PiConfig.get_entry_by_kind_and_name("provider", "invalid-provider")
      assert HubRPC.list_pi_config_entries() |> Enum.empty?()
    end

    test "shows error for missing name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Submit form with empty name
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "",
            "kind" => "provider",
            "spec" => ~s|{"baseUrl": "http://localhost:11434"}|
          }
        })
        |> render_submit()

      # Verify error is shown (HTML-encoded as can&#39;t be blank)
      assert html =~ "can&#39;t be blank"
      refute PiConfig.get_entry_by_kind_and_name("provider", "")
      assert HubRPC.list_pi_config_entries() |> Enum.empty?()
    end

    test "creates extension entry via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Submit form for extension type
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "test-extension",
            "kind" => "extension",
            "spec" => "console.log('extension content')"
          }
        })
        |> render_submit()

      # Verify entry was created
      entry = PiConfig.get_entry_by_kind_and_name("extension", "test-extension")
      assert entry
      assert entry.kind == "extension"
      assert entry.spec["body"] == "console.log('extension content')"
      assert HubRPC.list_pi_config_entries() |> Enum.any?(&(&1.name == "test-extension"))
    end

    test "creates setting entry via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Submit form for setting type
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "default-timeout",
            "kind" => "setting",
            "spec" => ~s|{"value": 30}|
          }
        })
        |> render_submit()

      # Verify entry was created
      entry = PiConfig.get_entry_by_kind_and_name("setting", "default-timeout")
      assert entry
      assert entry.kind == "setting"
      assert entry.spec["value"] == 30
    end

    test "creates enabled entry via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Submit form with enabled checkbox checked
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "enabled-provider",
            "kind" => "provider",
            "spec" => ~s|{"baseUrl": "http://localhost:11434"}|
          }
        })
        |> render_submit()

      # Verify entry was created and is enabled
      entry = PiConfig.get_entry_by_kind_and_name("provider", "enabled-provider")
      assert entry
      assert entry.enabled == true
    end
  end

  describe "edit entry" do
    test "edits an existing entry via form", %{conn: conn} do
      {:ok, entry} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "old-name",
          spec: %{"baseUrl" => "http://localhost:11434"}
        })

      {:ok, view, html} = live(conn, ~p"/settings/pi-config/#{entry.id}/edit")

      # Verify form renders with existing data
      assert html =~ "Edit Pi Config Entry"
      assert html =~ "old-name"

      # Submit form with updated data
      html =
        view
        |> form("#pi-config-entry-form", %{
          "pi_config_entry" => %{
            "name" => "new-name",
            "kind" => "provider",
            "spec" => ~s|{"baseUrl": "http://new-host:11434"}|
          }
        })
        |> render_submit()

      # Verify entry was updated
      updated_entry = PiConfig.get_entry!(entry.id)
      assert updated_entry.name == "new-name"
      assert updated_entry.spec["baseUrl"] == "http://new-host:11434"
    end

    test "toggles enabled state via UI button", %{conn: conn} do
      {:ok, entry} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "toggle-provider",
          spec: %{"baseUrl" => "http://localhost:11434"},
          enabled: false
        })

      {:ok, view, html} = live(conn, ~p"/settings/pi-config")

      # Verify initial state
      assert html =~ "disabled"

      # Click toggle button
      html = render_click(view, "toggle", %{"id" => entry.id})

      # Verify state changed
      updated_entry = PiConfig.get_entry!(entry.id)
      assert updated_entry.enabled == true

      # Verify UI updated
      assert html =~ "enabled"
    end
  end

  describe "delete entry" do
    test "deletes an entry via UI button", %{conn: conn} do
      {:ok, entry} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "delete-provider",
          spec: %{"baseUrl" => "http://localhost:11434"}
        })

      {:ok, view, html} = live(conn, ~p"/settings/pi-config")

      # Verify entry exists
      assert html =~ "delete-provider"
      assert PiConfig.get_entry(entry.id)

      # Click delete button - render_click returns the new HTML
      html = render_click(view, "delete", %{"id" => entry.id})

      # Verify entry was deleted
      refute PiConfig.get_entry(entry.id)
      assert html =~ "No pi config entries yet"
    end
  end

  describe "secret API key warning" do
    test "shows warning for literal API key", %{conn: conn} do
      # Test the helper function
      entry = %Entry{kind: "provider", spec: %{"apiKey" => "secret-key-123"}}
      assert OrcaHubWeb.PiConfigLive.Index.literal_api_key_warning(entry)

      # No warning for reference patterns
      entry = %Entry{kind: "provider", spec: %{"apiKey" => "$OLLAMA_API_KEY"}}
      refute OrcaHubWeb.PiConfigLive.Index.literal_api_key_warning(entry)

      entry = %Entry{kind: "provider", spec: %{"apiKey" => "!command"}}
      refute OrcaHubWeb.PiConfigLive.Index.literal_api_key_warning(entry)

      # No warning for settings (no apiKey field)
      entry = %Entry{kind: "setting", spec: %{"value" => "test"}}
      refute OrcaHubWeb.PiConfigLive.Index.literal_api_key_warning(entry)
    end
  end

  describe "live refresh" do
    test "subscribes to pi_config topic", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/pi-config")

      # Verify subscription by creating an entry and re-loading
      {:ok, _} =
        PiConfig.create_entry(%{
          kind: "provider",
          name: "test-broadcast",
          spec: %{"baseUrl" => "http://localhost:11434"}
        })

      {:ok, _view, html} = live(conn, ~p"/settings/pi-config")
      assert html =~ "test-broadcast"
    end
  end

  describe "form validation preserves user input" do
    test "name is preserved when spec textarea changes", %{conn: conn} do
      # Reproduce the browser bug: set name, then change spec
      # and verify name input still renders with its value
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Simulate browser's phx-change that sends the whole form
      # First, set the name
      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{"pi_config_entry" => %{"name" => "verify-delete-me"}})

      assert html =~ "value=\"verify-delete-me\""

      # Now change spec textarea (browser sends ALL form fields including name)
      spec_json = ~s|{"name": "value"}|

      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{
          "pi_config_entry" => %{"name" => "verify-delete-me", "spec" => spec_json}
        })

      # CRITICAL: name input must still render with its value after spec change
      assert html =~ "value=\"verify-delete-me\""
    end

    test "full form submission works with validate round-trip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Simulate browser sending full form on each keystroke
      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{"pi_config_entry" => %{"name" => "test-name"}})

      assert html =~ "value=\"test-name\""

      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{"pi_config_entry" => %{"name" => "test-name", "kind" => "provider"}})

      assert html =~ "value=\"test-name\""

      # Finally: set spec (with name still included)
      spec_json = ~s|{"baseUrl": "http://localhost:11434"}|

      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{
          "pi_config_entry" => %{"name" => "test-name", "kind" => "provider", "spec" => spec_json}
        })

      # Verify name is still there after spec change
      assert html =~ "value=\"test-name\""
    end

    test "end-to-end: create entry with validate round-trip", %{conn: conn} do
      # This test verifies the fix for the bug where the name field was
      # wiped on validate round-trips when typing in the spec textarea
      {:ok, view, _html} = live(conn, ~p"/settings/pi-config/new")

      # Simulate typing "verify-delete-me" in the name field
      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{"pi_config_entry" => %{"name" => "verify-delete-me"}})

      assert html =~ "value=\"verify-delete-me\""

      # Simulate typing in the spec textarea - browser sends ALL form fields
      # including the name field we just typed
      spec_json = ~s|{"baseUrl": "http://localhost:11434"}|

      html =
        view
        |> form("#pi-config-entry-form")
        |> render_change(%{
          "pi_config_entry" => %{
            "name" => "verify-delete-me",
            "spec" => spec_json,
            "kind" => "provider"
          }
        })

      # Verify name is preserved after validate round-trip
      assert html =~ "value=\"verify-delete-me\""

      # Now submit the form
      html =
        view
        |> form("#pi-config-entry-form")
        |> render_submit()

      # Verify entry was created
      entry = PiConfig.get_entry_by_kind_and_name("provider", "verify-delete-me")
      assert entry
      assert entry.spec["baseUrl"] == "http://localhost:11434"
    end
  end
end
