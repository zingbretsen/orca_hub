defmodule OrcaHubWeb.SettingsLive.BackendAuthTest do
  @moduledoc """
  LiveView coverage for SettingsLive.Index's codex login (device-auth +
  API-key) and pi provider-key sections.

  Not async: uses the `:orca_hub, :backend_auth_home` Application env
  override (`OrcaHub.BackendAuth`) to keep RPCs off the real
  `~/.codex`/`~/.pi`, and `:codex_executable` to keep the login flow off the
  real `codex` binary — same rationale/pattern as
  `NodeLive.BackendInstallerTest`.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @fake_codex Path.expand("../../../support/fixtures/fake_codex.sh", __DIR__)

  setup do
    original_home = Application.get_env(:orca_hub, :backend_auth_home)
    original_codex = Application.get_env(:orca_hub, :codex_executable)
    original_openai_key = System.get_env("OPENAI_API_KEY")

    home =
      Path.join(System.tmp_dir!(), "backend_auth_live_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:orca_hub, :backend_auth_home, home)
    Application.put_env(:orca_hub, :codex_executable, @fake_codex)
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      OrcaHub.CodexLoginRunner.cancel()
      File.rm_rf(home)

      if original_home,
        do: Application.put_env(:orca_hub, :backend_auth_home, original_home),
        else: Application.delete_env(:orca_hub, :backend_auth_home)

      if original_codex,
        do: Application.put_env(:orca_hub, :codex_executable, original_codex),
        else: Application.delete_env(:orca_hub, :codex_executable)

      if original_openai_key,
        do: System.put_env("OPENAI_API_KEY", original_openai_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    {:ok, home: home}
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      result ->
        result
    end
  end

  describe "codex status badge" do
    test "shows nothing extra when no auth.json exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "codex: ChatGPT"
      refute html =~ "codex: API key"
      refute html =~ "codex env conflict"
    end

    test "shows the ChatGPT (device) badge once auth.json says so (FAKE values)", %{
      conn: conn,
      home: home
    } do
      write_codex_auth(home, %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "fake-access-token"}
      })

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "codex: ChatGPT (device)"
    end

    test "shows the codex env conflict warning when OPENAI_API_KEY is set", %{conn: conn} do
      System.put_env("OPENAI_API_KEY", "sk-fake-env-key")

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "codex env conflict"
    end
  end

  describe "codex API key login" do
    test "the key form is masked and the submitted key is never rendered back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> element("button[phx-click=codex_login_api_key_open]")
        |> render_click()

      assert html =~ ~s(type="password")
      assert html =~ "never stored, logged, or displayed"

      secret = "sk-fake-do-not-leak-this-9182"

      html =
        view
        |> form("form[phx-submit=submit_codex_api_key]", %{"key" => secret})
        |> render_submit()

      refute html =~ secret

      html =
        wait_until(fn ->
          html = render(view)
          if html =~ "now logged in to codex", do: html, else: false
        end)

      refute html =~ secret
    end

    test "reports an error without leaking the key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("button[phx-click=codex_login_api_key_open]")
      |> render_click()

      view
      |> form("form[phx-submit=submit_codex_api_key]", %{"key" => "fail-me"})
      |> render_submit()

      html =
        wait_until(fn ->
          html = render(view)
          if html =~ "Login failed", do: html, else: false
        end)

      refute html =~ "fail-me"
    end
  end

  describe "pi provider keys" do
    test "save shows a configured badge and never renders the key back; remove clears it", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> element("button[phx-click=open_pi_keys]")
        |> render_click()

      assert html =~ "pi prefers a stored"
      assert html =~ ~s(type="password")

      secret = "fake-fireworks-key-do-not-leak"

      html =
        view
        |> form("form[phx-submit=save_pi_key]", %{
          "provider" => "fireworks",
          "custom_provider" => "",
          "key" => secret
        })
        |> render_submit()

      refute html =~ secret
      assert html =~ "fireworks"
      assert html =~ "configured"

      html =
        view
        |> element("button[phx-click=delete_pi_key][phx-value-provider=fireworks]")
        |> render_click()

      refute html =~ secret
      assert html =~ "No pi provider keys configured"
    end
  end

  defp write_codex_auth(home, data) do
    path = Path.join(home, ".codex/auth.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end
end
