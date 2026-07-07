defmodule OrcaHub.Secrets do
  @moduledoc """
  Context for OrcaHub-managed secrets injected into upstream MCP tool calls
  (see `OrcaHub.MCP.UpstreamClient`).

  Values are encrypted at rest with AES-256-GCM (`:crypto`), keyed by
  `ORCA_SECRETS_KEY` (a base64-encoded 32-byte key — see `config/runtime.exs`).
  This module talks to the database directly and therefore only runs on the
  hub. Callers on any node must go through `OrcaHub.HubRPC`.

  Security: `list_keys/0` is the only function safe to expose to a LiveView —
  it returns key names and timestamps, never values. `all_decrypted/0` is for
  the injection/masking path in `UpstreamClient` ONLY; nothing else may call it.
  """

  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.Secrets.UpstreamSecret

  defmodule KeyNotConfiguredError do
    defexception message: "ORCA_SECRETS_KEY is not set or invalid; cannot use secret injection"
  end

  @doc "Insert or update the value for `key` (upsert on key)."
  def put_secret(key, value) when is_binary(key) and is_binary(value) do
    encrypted = encrypt(value)

    result =
      %UpstreamSecret{}
      |> UpstreamSecret.changeset(%{key: key, value_encrypted: encrypted})
      |> Repo.insert(
        on_conflict: [set: [value_encrypted: encrypted, updated_at: DateTime.utc_now()]],
        conflict_target: :key
      )

    with {:ok, _secret} <- result, do: notify_change()

    result
  end

  @doc "Delete the secret stored under `key`, if any."
  def delete_secret(key) when is_binary(key) do
    {count, _} = Repo.delete_all(from s in UpstreamSecret, where: s.key == ^key)
    if count > 0, do: notify_change()
    {:ok, count}
  end

  @doc """
  List stored secret key names and their last-updated timestamp. Never
  returns values — this is the only function in this module safe to expose
  to a LiveView.
  """
  def list_keys do
    Repo.all(
      from s in UpstreamSecret,
        select: %{key: s.key, updated_at: s.updated_at},
        order_by: [asc: s.key]
    )
  end

  @doc false
  # Internal: decrypted key => value map, for the UpstreamClient
  # injection/masking path only. Never expose this to a LiveView or MCP tool.
  def all_decrypted do
    Repo.all(UpstreamSecret)
    |> Map.new(fn secret -> {secret.key, decrypt(secret.value_encrypted)} end)
  end

  # ── Encryption (AES-256-GCM via :crypto) ────────────────────────────────

  @doc false
  def encrypt(plaintext) when is_binary(plaintext) do
    key = secret_key!()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    iv <> tag <> ciphertext
  end

  @doc false
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = secret_key!()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) ->
        plaintext

      :error ->
        raise "Failed to decrypt secret (ORCA_SECRETS_KEY mismatch or corrupted data)"
    end
  end

  defp secret_key! do
    with b64 when is_binary(b64) <- Application.get_env(:orca_hub, :secrets_key),
         {:ok, key} <- Base.decode64(b64),
         32 <- byte_size(key) do
      key
    else
      _ -> raise KeyNotConfiguredError
    end
  end

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "upstream_servers", :upstream_servers_changed)
  end
end
