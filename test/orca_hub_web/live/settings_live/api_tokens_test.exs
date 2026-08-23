defmodule OrcaHubWeb.SettingsLive.ApiTokensTest do
  @moduledoc """
  LiveView coverage for the scoped API Tokens UI on the Settings page
  (`OrcaHub.ApiTokens`-backed).

  The plaintext secret is only ever available at creation time and lives in
  socket assigns between create and dismiss — see the `revealed_secret`
  handling in `OrcaHubWeb.SettingsLive.Index`. This suite never hardcodes a
  token value; every secret asserted on here is generated at runtime by the
  real `OrcaHub.ApiTokens.create_token/1` path (through the LiveView form or
  directly, depending on the test).
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ApiTokens
  alias OrcaHub.Sessions

  defp session_fixture(attrs \\ %{}) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{
            directory:
              Path.join(
                System.tmp_dir!(),
                "settings_api_tokens_#{System.unique_integer([:positive])}"
              ),
            title: "fixture session",
            status: "idle",
            runner_node: Atom.to_string(node())
          },
          attrs
        )
      )

    session
  end

  defp extract_revealed_secret(html) do
    case Regex.run(~r/<code id="revealed-token-secret"[^>]*>([^<]+)<\/code>/, html) do
      [_, secret] -> String.trim(secret)
      nil -> nil
    end
  end

  describe "index" do
    test "renders the API Tokens section with an empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "API Tokens"
      assert html =~ "No API tokens configured."
    end

    test "lists an existing token without ever rendering a secret", %{conn: conn} do
      {:ok, %{token: token}} =
        ApiTokens.create_token(%{name: "watcher", scopes: ["sessions:read"]})

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "watcher"
      assert html =~ token.token_prefix
      refute html =~ "revealed-token-secret"
    end
  end

  describe "create" do
    test "shows the plaintext secret exactly once, then it disappears after dismiss", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("button", "Add Token") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_token]", %{
          "api_token" => %{"name" => "ci-runner", "scopes" => ["runs:create"]}
        })
        |> render_submit()

      assert html =~ "created — copy this secret now"

      secret = extract_revealed_secret(html)
      assert secret
      assert String.starts_with?(secret, "orca_")

      [token] = ApiTokens.list_tokens()
      assert token.name == "ci-runner"
      assert token.scopes == ["runs:create"]
      assert String.starts_with?(secret, token.token_prefix)

      html = view |> element("button", "Dismiss") |> render_click()

      refute html =~ "revealed-token-secret"
      refute html =~ secret
      assert html =~ "ci-runner"
    end

    test "an empty scope selection surfaces a changeset error and creates nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("button", "Add Token") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_token]", %{
          "api_token" => %{"name" => "bad", "scopes" => []}
        })
        |> render_submit()

      assert html =~ "should have at least 1 item(s)"
      assert ApiTokens.list_tokens() == []
    end

    test "a forbidden scope on a session-pinned token surfaces its error", %{conn: conn} do
      session = session_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("button", "Add Token") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_token]", %{
          "api_token" => %{
            "name" => "pinned",
            "scopes" => ["a2a"],
            "session_id" => session.id
          }
        })
        |> render_submit()

      assert html =~ "session-pinned token cannot hold"
      assert ApiTokens.list_tokens() == []
    end

    test "each created token gets a fresh runtime-generated secret", %{conn: _conn} do
      {:ok, %{secret: secret_a}} =
        ApiTokens.create_token(%{name: "a", scopes: ["sessions:read"]})

      {:ok, %{secret: secret_b}} =
        ApiTokens.create_token(%{name: "b", scopes: ["sessions:read"]})

      assert String.starts_with?(secret_a, "orca_")
      assert String.starts_with?(secret_b, "orca_")
      refute secret_a == secret_b
    end
  end

  describe "revoke" do
    test "marks the token revoked and renders it visibly distinct rather than hidden", %{
      conn: conn
    } do
      {:ok, %{token: token}} =
        ApiTokens.create_token(%{name: "watcher", scopes: ["sessions:read"]})

      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ "watcher"
      refute html =~ "revoked"

      html =
        view
        |> element("button[phx-click=revoke_token][phx-value-id='#{token.id}']")
        |> render_click()

      assert html =~ "watcher"
      assert html =~ "revoked"

      [row] = ApiTokens.list_tokens()
      assert row.revoked_at
    end
  end
end
