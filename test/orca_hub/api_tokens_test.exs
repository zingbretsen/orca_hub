defmodule OrcaHub.ApiTokensTest do
  use OrcaHub.DataCase

  alias OrcaHub.{ApiRuns, ApiTokens, Sessions}
  alias OrcaHub.ApiTokens.ApiToken

  defp session_fixture(attrs \\ %{}) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{
            directory:
              Path.join(System.tmp_dir!(), "api_tokens_#{System.unique_integer([:positive])}"),
            title: "fixture session",
            status: "idle",
            runner_node: Atom.to_string(node())
          },
          attrs
        )
      )

    session
  end

  describe "create_token/1" do
    test "returns the plaintext secret alongside the persisted row, and only a hash is stored" do
      assert {:ok, %{token: %ApiToken{} = token, secret: secret}} =
               ApiTokens.create_token(%{name: "watch", scopes: ["runs:create"]})

      assert String.starts_with?(secret, "orca_")
      assert token.token_prefix == String.slice(secret, 0, 12)
      assert token.token_hash == :crypto.hash(:sha256, secret)
      refute token.token_hash == secret

      dump = inspect(token)
      refute dump =~ secret
    end

    test "rejects an empty scopes list" do
      assert {:error, changeset} = ApiTokens.create_token(%{name: "x", scopes: []})
      assert "should have at least 1 item(s)" in errors_on(changeset).scopes
    end

    test "rejects an unknown scope string" do
      assert {:error, changeset} =
               ApiTokens.create_token(%{name: "x", scopes: ["runs:create", "sudo"]})

      assert errors_on(changeset).scopes != []
    end

    test "rejects tts scope on a session-pinned token" do
      session = session_fixture()

      assert {:error, changeset} =
               ApiTokens.create_token(%{
                 name: "pinned",
                 scopes: ["tts"],
                 session_id: session.id
               })

      assert errors_on(changeset).scopes != []
    end

    test "rejects a2a scope on a session-pinned token" do
      session = session_fixture()

      assert {:error, changeset} =
               ApiTokens.create_token(%{
                 name: "pinned",
                 scopes: ["runs:create", "a2a"],
                 session_id: session.id
               })

      assert errors_on(changeset).scopes != []
    end

    test "allows tts/a2a scopes on an unpinned token" do
      assert {:ok, _} = ApiTokens.create_token(%{name: "browser", scopes: ["tts", "a2a"]})
    end

    test "enforces a unique token_hash (astronomically unlikely collision aside, the index exists)" do
      {:ok, %{token: token}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})

      assert {:error, changeset} =
               %ApiToken{}
               |> ApiToken.changeset(%{
                 name: "b",
                 scopes: ["runs:create"],
                 token_hash: token.token_hash
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token_hash
    end
  end

  describe "list_tokens/0" do
    test "never includes token_hash, and includes the display fields" do
      {:ok, _} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      {:ok, _} = ApiTokens.create_token(%{name: "b", scopes: ["sessions:read"]})

      rows = ApiTokens.list_tokens()
      assert length(rows) == 2
      refute Enum.any?(rows, &Map.has_key?(&1, :token_hash))

      row = Enum.find(rows, &(&1.name == "a"))
      assert Map.has_key?(row, :id)
      assert Map.has_key?(row, :token_prefix)
      assert Map.has_key?(row, :scopes)
      assert Map.has_key?(row, :session_id)
      assert Map.has_key?(row, :expires_at)
      assert Map.has_key?(row, :last_used_at)
      assert Map.has_key?(row, :revoked_at)
      assert Map.has_key?(row, :inserted_at)
    end
  end

  describe "authenticate/1" do
    test "succeeds for the exact issued secret" do
      {:ok, %{secret: secret}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      assert {:ok, %ApiToken{name: "a"}} = ApiTokens.authenticate(secret)
    end

    test "fails for a wrong secret" do
      {:ok, %{}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      assert :error = ApiTokens.authenticate("orca_not-the-right-secret")
    end

    test "fails for a revoked token" do
      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})

      {:ok, _} = ApiTokens.revoke_token(token.id)
      assert :error = ApiTokens.authenticate(secret)
    end

    test "fails for an expired token" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})

      {:ok, _} =
        token |> Ecto.Changeset.change(expires_at: past) |> Repo.update()

      assert :error = ApiTokens.authenticate(secret)
    end

    test "succeeds for a token with a future expires_at" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "a",
          scopes: ["runs:create"],
          expires_at: future
        })

      assert {:ok, _} = ApiTokens.authenticate(secret)
    end
  end

  describe "revoke_token/1" do
    test "revokes only the requested token, leaving others untouched" do
      {:ok, %{token: a, secret: secret_a}} =
        ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})

      {:ok, %{secret: secret_b}} = ApiTokens.create_token(%{name: "b", scopes: ["runs:create"]})

      assert {:ok, %ApiToken{revoked_at: %DateTime{}}} = ApiTokens.revoke_token(a.id)

      assert :error = ApiTokens.authenticate(secret_a)
      assert {:ok, _} = ApiTokens.authenticate(secret_b)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = ApiTokens.revoke_token(Ecto.UUID.generate())
    end
  end

  describe "touch_last_used/1" do
    test "sets last_used_at when it was nil" do
      {:ok, %{token: token}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      assert is_nil(token.last_used_at)

      assert {:ok, %ApiToken{last_used_at: %DateTime{}}} = ApiTokens.touch_last_used(token)
    end

    test "does not write when last used less than 60s ago" do
      recent = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, %{token: token}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      {:ok, token} = token |> Ecto.Changeset.change(last_used_at: recent) |> Repo.update()

      assert {:ok, %ApiToken{last_used_at: ^recent}} = ApiTokens.touch_last_used(token)
    end

    test "does write when last used more than 60s ago" do
      stale = DateTime.utc_now() |> DateTime.add(-61, :second) |> DateTime.truncate(:second)

      {:ok, %{token: token}} = ApiTokens.create_token(%{name: "a", scopes: ["runs:create"]})
      {:ok, token} = token |> Ecto.Changeset.change(last_used_at: stale) |> Repo.update()

      assert {:ok, %ApiToken{last_used_at: last_used_at}} = ApiTokens.touch_last_used(token)
      refute last_used_at == stale
    end
  end

  describe "session deletion revokes the token (on_delete: :delete_all)" do
    test "deleting the pinned session deletes the token row instead of nilifying the pin" do
      session = session_fixture()

      {:ok, %{token: token, secret: secret}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      {:ok, _} = Sessions.delete_session(session)

      assert :error = ApiTokens.authenticate(secret)
      refute Repo.get(ApiToken, token.id)
    end
  end

  describe "authorize/2" do
    defp conn(method, path_info, params \\ %{}, path_params \\ %{}) do
      %Plug.Conn{method: method, path_info: path_info, params: params, path_params: path_params}
    end

    test "unpinned token is authorized for any target within its scopes" do
      {:ok, %{token: token}} =
        ApiTokens.create_token(%{name: "a", scopes: ["runs:create", "sessions:read"]})

      assert :ok =
               ApiTokens.authorize(token, conn("POST", ~w(api v1 runs), %{"session_id" => nil}))

      assert :ok = ApiTokens.authorize(token, conn("GET", ~w(api v1 sessions)))

      assert :ok =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 sessions) ++ [Ecto.UUID.generate()])
               )
    end

    test "denies a scope the token doesn't have" do
      {:ok, %{token: token}} = ApiTokens.create_token(%{name: "a", scopes: ["sessions:read"]})

      assert {:error, :forbidden} =
               ApiTokens.authorize(token, conn("POST", ~w(api v1 runs), %{}))
    end

    test "denies an unrecognized route" do
      {:ok, %{token: token}} =
        ApiTokens.create_token(%{name: "a", scopes: ApiToken.scopes()})

      assert {:error, :forbidden} = ApiTokens.authorize(token, conn("GET", ~w(nope)))
    end

    test "pinned token: runs:create requires the exact pinned session_id" do
      session = session_fixture()
      other = session_fixture()

      {:ok, %{token: token}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:create"],
          session_id: session.id
        })

      assert :ok =
               ApiTokens.authorize(
                 token,
                 conn("POST", ~w(api v1 runs), %{"session_id" => session.id})
               )

      assert {:error, :forbidden} =
               ApiTokens.authorize(
                 token,
                 conn("POST", ~w(api v1 runs), %{"session_id" => other.id})
               )

      assert {:error, :forbidden} =
               ApiTokens.authorize(token, conn("POST", ~w(api v1 runs), %{}))
    end

    test "pinned token: runs:read/runs:tool_result requires the run to belong to the pinned session" do
      session = session_fixture()
      other = session_fixture()

      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})
      {:ok, other_run} = ApiRuns.create_run(%{session_id: other.id})

      {:ok, %{token: token}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["runs:read", "runs:tool_result"],
          session_id: session.id
        })

      assert :ok =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 runs) ++ [run.id], %{}, %{"id" => run.id})
               )

      assert {:error, :forbidden} =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 runs) ++ [other_run.id], %{}, %{"id" => other_run.id})
               )

      missing_id = Ecto.UUID.generate()

      assert {:error, :forbidden} =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 runs) ++ [missing_id], %{}, %{"id" => missing_id})
               )
    end

    test "pinned token: sessions:read allows show of the pinned id only, denies index" do
      session = session_fixture()

      {:ok, %{token: token}} =
        ApiTokens.create_token(%{
          name: "watch",
          scopes: ["sessions:read"],
          session_id: session.id
        })

      assert :ok =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 sessions) ++ [session.id], %{}, %{"id" => session.id})
               )

      assert {:error, :forbidden} =
               ApiTokens.authorize(token, conn("GET", ~w(api v1 sessions)))

      other_id = Ecto.UUID.generate()

      assert {:error, :forbidden} =
               ApiTokens.authorize(
                 token,
                 conn("GET", ~w(api v1 sessions) ++ [other_id], %{}, %{"id" => other_id})
               )
    end
  end
end
