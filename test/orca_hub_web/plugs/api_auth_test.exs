defmodule OrcaHubWeb.Plugs.ApiAuthTest do
  @moduledoc """
  Integration coverage for the two-tier bearer auth in
  `OrcaHubWeb.Plugs.ApiAuth`: the legacy global `:api_token` must keep
  working byte-identically, and scoped `OrcaHub.ApiTokens` rows must layer
  on top without weakening it.
  """

  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{ApiTokens, Sessions}

  @legacy_token "legacy-test-token"

  defp legacy_authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@legacy_token}")
  defp scoped_authed(conn, secret), do: put_req_header(conn, "authorization", "Bearer #{secret}")

  defp session_fixture(attrs \\ %{}) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{
            directory:
              Path.join(System.tmp_dir!(), "api_auth_#{System.unique_integer([:positive])}"),
            title: "fixture session",
            status: "idle",
            runner_node: Atom.to_string(node())
          },
          attrs
        )
      )

    session
  end

  describe "legacy global token (byte-identical preservation)" do
    test "503 when no legacy token is configured and no scoped tokens match", %{conn: conn} do
      # Explicit, not ambient — ORCA_API_TOKEN may be set in the shared local
      # .env, which config/runtime.exs bakes into this key at boot regardless
      # of the `-u` flags in the canonical test invocation.
      Application.delete_env(:orca_hub, :api_token)

      conn = conn |> legacy_authed() |> get(~p"/api/v1/sessions")
      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "503 when unset, even with unrelated scoped tokens in the table", %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)
      {:ok, _} = ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      conn = conn |> legacy_authed() |> get(~p"/api/v1/sessions")
      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "still works once configured", %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      conn = conn |> legacy_authed() |> get(~p"/api/v1/sessions")
      assert %{"sessions" => _} = json_response(conn, 200)
    end

    test "401 on a mismatched legacy token, unaffected by scoped tokens existing", %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
      {:ok, _} = ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      conn =
        conn |> put_req_header("authorization", "Bearer wrong") |> get(~p"/api/v1/sessions")

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "401 with no Authorization header, once configured", %{conn: conn} do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      conn = get(conn, ~p"/api/v1/sessions")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end

  describe "scoped tokens" do
    test "an unpinned scoped token works even with the legacy token unset", %{conn: conn} do
      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      conn = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert %{"sessions" => _} = json_response(conn, 200)

      # Only id/name/scopes are assigned — never the secret or the hash.
      assert %{name: "watch", scopes: ["sessions:read"]} = conn.assigns.api_token
      refute Map.has_key?(conn.assigns.api_token, :token_hash)
      refute inspect(conn.assigns.api_token) =~ secret
    end

    test "revoked token 401s (falls back to the legacy check, which then mismatches)", %{
      conn: conn
    } do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      {:ok, _} = ApiTokens.revoke_token(token.id)

      conn = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "expired token 401s (falls back to the legacy check, which then mismatches)", %{
      conn: conn
    } do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      {:ok, _} = token |> Ecto.Changeset.change(expires_at: past) |> OrcaHub.Repo.update()

      conn = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "revoked token 503s when the legacy token is ALSO unset (matches today's no-header-match behavior)",
         %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)

      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      {:ok, _} = ApiTokens.revoke_token(token.id)

      conn = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "a scoped token missing the required scope 403s", %{conn: conn} do
      {:ok, %{secret: secret}} = ApiTokens.create_token(%{name: "watch", scopes: ["tts"]})

      conn = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "a wrong scoped secret falls back to the legacy token instead of 401ing outright", %{
      conn: conn
    } do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
      {:ok, %{}} = ApiTokens.create_token(%{name: "watch", scopes: ["sessions:read"]})

      conn = conn |> legacy_authed() |> get(~p"/api/v1/sessions")
      assert %{"sessions" => _} = json_response(conn, 200)
    end

    test "revoking one scoped token leaves another scoped token and the legacy token working", %{
      conn: conn
    } do
      Application.put_env(:orca_hub, :api_token, @legacy_token)
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      {:ok, %{token: token_a, secret: secret_a}} =
        ApiTokens.create_token(%{name: "a", scopes: ["sessions:read"]})

      {:ok, %{secret: secret_b}} =
        ApiTokens.create_token(%{name: "b", scopes: ["sessions:read"]})

      {:ok, _} = ApiTokens.revoke_token(token_a.id)

      assert conn |> scoped_authed(secret_a) |> get(~p"/api/v1/sessions") |> json_response(401)

      assert %{"sessions" => _} =
               conn |> scoped_authed(secret_b) |> get(~p"/api/v1/sessions") |> json_response(200)

      assert %{"sessions" => _} =
               conn |> legacy_authed() |> get(~p"/api/v1/sessions") |> json_response(200)
    end
  end

  describe "pinned tokens" do
    test "runs:create 403s with no session_id (new-session creation denied)", %{conn: conn} do
      session = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      conn =
        conn
        |> scoped_authed(secret)
        |> post(~p"/api/v1/runs", %{"prompt" => "hi", "directory" => "/tmp"})

      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "runs:create 403s against a different session_id", %{conn: conn} do
      session = session_fixture()
      other = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      conn =
        conn
        |> scoped_authed(secret)
        |> post(~p"/api/v1/runs", %{"prompt" => "hi", "session_id" => other.id})

      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "runs:create succeeds against the pinned session_id", %{conn: conn} do
      Application.put_env(:orca_hub, :claude_executable, "/bin/true")
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      session = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      conn =
        conn
        |> scoped_authed(secret)
        |> post(~p"/api/v1/runs", %{"prompt" => "hi", "session_id" => session.id})

      body = json_response(conn, 202)
      assert body["session_id"] == session.id

      on_exit(fn ->
        if OrcaHub.SessionSupervisor.session_alive?(session.id),
          do: OrcaHub.SessionSupervisor.stop_session(session.id)
      end)
    end

    test "403s on /api/tts (pinned tokens can never hold the tts scope)", %{conn: conn} do
      session = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      conn = conn |> scoped_authed(secret) |> post(~p"/api/tts", %{"text" => "hi"})
      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "403s on /a2a/* (pinned tokens can never hold the a2a scope)", %{conn: conn} do
      session = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      conn = conn |> scoped_authed(secret) |> get(~p"/a2a/agents")
      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "sessions:read allows show of the pinned session only, denies the index", %{conn: conn} do
      session = session_fixture()

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["sessions:read"],
          session_id: session.id
        })

      assert %{"id" => id} =
               conn
               |> scoped_authed(secret)
               |> get(~p"/api/v1/sessions/#{session.id}")
               |> json_response(200)

      assert id == session.id

      conn2 = conn |> scoped_authed(secret) |> get(~p"/api/v1/sessions")
      assert json_response(conn2, 403)["error"] == "forbidden"
    end
  end

  describe "touch_last_used_best_effort/1" do
    test "does not raise when the token row vanished out from under it (e.g. pinned session deleted mid-request)" do
      session = session_fixture()

      {:ok, %{token: token}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      # Simulates the on_delete: :delete_all race: this in-memory struct was
      # already read (as if by authenticate/1) before its backing row went
      # away.
      {:ok, _} = OrcaHub.Repo.delete(token)

      assert :ok = OrcaHubWeb.Plugs.ApiAuth.touch_last_used_best_effort(token)
    end
  end
end
