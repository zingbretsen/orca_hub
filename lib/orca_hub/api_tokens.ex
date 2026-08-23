defmodule OrcaHub.ApiTokens do
  @moduledoc """
  Context for scoped, revocable API tokens — the fine-grained alternative to
  the single global `ORCA_API_TOKEN` (see `OrcaHubWeb.Plugs.ApiAuth`). Lives
  alongside that legacy token, does not replace it.

  Only a SHA-256 hash of each token's secret is ever persisted; the plaintext
  exists ONLY as the return value of `create_token/1`, at generation time,
  and is never logged, echoed, or stored anywhere. This module talks to the
  database directly and therefore only runs on the hub — callers on any node
  must go through `OrcaHub.HubRPC`.

  Security: `list_tokens/0` is the only function safe to expose to a
  LiveView — it never returns `token_hash` or a secret. Every other function
  here either takes a token/secret the caller already has, or is the
  generation path itself.
  """

  import Ecto.Query

  alias OrcaHub.ApiRuns.ApiRun
  alias OrcaHub.ApiTokens.ApiToken
  alias OrcaHub.Repo

  @touch_min_interval_seconds 60

  @doc """
  List tokens WITHOUT their hash — safe to expose to a LiveView.
  """
  def list_tokens do
    Repo.all(
      from t in ApiToken,
        select: %{
          id: t.id,
          name: t.name,
          token_prefix: t.token_prefix,
          scopes: t.scopes,
          session_id: t.session_id,
          expires_at: t.expires_at,
          last_used_at: t.last_used_at,
          revoked_at: t.revoked_at,
          inserted_at: t.inserted_at
        },
        order_by: [asc: t.name]
    )
  end

  @doc """
  Create a token. Returns the plaintext `secret` alongside the persisted
  `token` row — this is the ONLY place the plaintext ever exists. The caller
  must display/deliver it immediately; it cannot be recovered afterward.
  """
  def create_token(attrs) do
    secret = generate_secret()

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("token_hash", hash_secret(secret))
      |> Map.put("token_prefix", String.slice(secret, 0, 12))

    case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
      {:ok, token} -> {:ok, %{token: token, secret: secret}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Changeset for the token-creation/edit UI form."
  def change_token(%ApiToken{} = token, attrs \\ %{}), do: ApiToken.changeset(token, attrs)

  @doc """
  Revoke a token by id (sets `revoked_at`). Never touches any other token —
  scoped or the legacy global one.
  """
  def revoke_token(id) do
    case Repo.get(ApiToken, id) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
    end
  end

  @doc """
  Authenticate a bearer secret against stored token hashes. Rejects a
  revoked or expired token even if the hash matches.
  """
  def authenticate(secret) when is_binary(secret) do
    hash = hash_secret(secret)

    case Repo.get_by(ApiToken, token_hash: hash) do
      nil ->
        :error

      %ApiToken{} = token ->
        if Plug.Crypto.secure_compare(token.token_hash, hash) and valid?(token) do
          {:ok, token}
        else
          :error
        end
    end
  end

  @doc """
  Scope + session-pin enforcement (see the module doc and the scope table in
  `ApiToken`). An unpinned token (`session_id: nil`) is authorized for any
  target within its granted scopes; a pinned token is additionally confined
  to the one session it names.
  """
  def authorize(%ApiToken{} = token, %Plug.Conn{} = conn) do
    with {:ok, scope} <- required_scope(conn),
         true <- scope in token.scopes do
      check_pin(scope, token, conn)
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc """
  Bump `last_used_at`, but only when it's unset or older than #{@touch_min_interval_seconds}s
  — avoids a write on every single authenticated request.
  """
  def touch_last_used(%ApiToken{} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if stale?(token.last_used_at, now) do
      token
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update()
    else
      {:ok, token}
    end
  end

  # ── Scope resolution ────────────────────────────────────────────────────

  defp required_scope(%{method: "POST", path_info: ["api", "v1", "runs"]}),
    do: {:ok, "runs:create"}

  defp required_scope(%{method: "GET", path_info: ["api", "v1", "runs", _id]}),
    do: {:ok, "runs:read"}

  defp required_scope(%{method: "POST", path_info: ["api", "v1", "runs", _id, "tool_result"]}),
    do: {:ok, "runs:tool_result"}

  defp required_scope(%{method: "GET", path_info: ["api", "v1", "sessions"]}),
    do: {:ok, "sessions:read"}

  defp required_scope(%{method: "GET", path_info: ["api", "v1", "sessions", _id]}),
    do: {:ok, "sessions:read"}

  defp required_scope(%{method: "POST", path_info: ["api", "tts"]}), do: {:ok, "tts"}
  defp required_scope(%{path_info: ["a2a" | _]}), do: {:ok, "a2a"}
  defp required_scope(_conn), do: :error

  # ── Session-pin enforcement ─────────────────────────────────────────────

  defp check_pin(_scope, %ApiToken{session_id: nil}, _conn), do: :ok

  defp check_pin("runs:create", %ApiToken{session_id: session_id}, conn) do
    if conn.params["session_id"] == session_id, do: :ok, else: {:error, :forbidden}
  end

  defp check_pin(scope, %ApiToken{session_id: session_id}, conn)
       when scope in ["runs:read", "runs:tool_result"] do
    with id when is_binary(id) <- conn.path_params["id"],
         {:ok, _} <- Ecto.UUID.cast(id),
         %ApiRun{session_id: ^session_id} <- Repo.get(ApiRun, id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  # path_params (not path_info) is the unambiguous source for the route's
  # :id — it's nil on the index route and the real id on the show route, so
  # this alone also correctly denies the index for a pinned token.
  defp check_pin("sessions:read", %ApiToken{session_id: session_id}, conn) do
    if conn.path_params["id"] == session_id, do: :ok, else: {:error, :forbidden}
  end

  defp check_pin(_scope, _token, _conn), do: {:error, :forbidden}

  # ── Secret generation / hashing ─────────────────────────────────────────

  defp generate_secret do
    "orca_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp hash_secret(secret), do: :crypto.hash(:sha256, secret)

  defp valid?(%ApiToken{} = token) do
    is_nil(token.revoked_at) and not expired?(token)
  end

  defp expired?(%ApiToken{expires_at: nil}), do: false

  defp expired?(%ApiToken{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp stale?(nil, _now), do: true

  defp stale?(last_used_at, now) do
    DateTime.diff(now, last_used_at) >= @touch_min_interval_seconds
  end
end
