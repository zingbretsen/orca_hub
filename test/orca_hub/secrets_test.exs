defmodule OrcaHub.SecretsTest do
  use OrcaHub.DataCase

  alias OrcaHub.Secrets

  describe "put_secret/2 and all_decrypted/0" do
    test "round-trips a value through encryption" do
      assert {:ok, _} = Secrets.put_secret("PHX_AGENT_PASSWORD", "s3cr3t-value")
      assert Secrets.all_decrypted() == %{"PHX_AGENT_PASSWORD" => "s3cr3t-value"}
    end

    test "upserts on key (no duplicate rows, value replaced)" do
      {:ok, _} = Secrets.put_secret("KEY", "old")
      {:ok, _} = Secrets.put_secret("KEY", "new")

      assert Secrets.all_decrypted() == %{"KEY" => "new"}
      assert length(Secrets.list_keys()) == 1
    end

    test "stores ciphertext, not plaintext, in the DB" do
      {:ok, secret} = Secrets.put_secret("KEY", "super-secret-plaintext")
      refute secret.value_encrypted =~ "super-secret-plaintext"
    end
  end

  describe "list_keys/0" do
    test "returns only key names and timestamps, never values" do
      {:ok, _} = Secrets.put_secret("A", "value-a")
      {:ok, _} = Secrets.put_secret("B", "value-b")

      keys = Secrets.list_keys()
      assert Enum.map(keys, & &1.key) == ["A", "B"]

      dump = inspect(keys)
      refute dump =~ "value-a"
      refute dump =~ "value-b"

      assert Enum.all?(keys, &Map.has_key?(&1, :updated_at))
      refute Enum.any?(keys, &Map.has_key?(&1, :value_encrypted))
    end
  end

  describe "delete_secret/1" do
    test "removes the secret" do
      {:ok, _} = Secrets.put_secret("KEY", "value")
      assert {:ok, 1} = Secrets.delete_secret("KEY")
      assert Secrets.all_decrypted() == %{}
    end

    test "returns {:ok, 0} when the key doesn't exist" do
      assert {:ok, 0} = Secrets.delete_secret("NOPE")
    end
  end

  describe "encryption key handling" do
    test "raises a clear error when ORCA_SECRETS_KEY is unset" do
      previous = Application.get_env(:orca_hub, :secrets_key)
      Application.delete_env(:orca_hub, :secrets_key)

      try do
        assert_raise Secrets.KeyNotConfiguredError, fn ->
          Secrets.put_secret("KEY", "value")
        end
      after
        Application.put_env(:orca_hub, :secrets_key, previous)
      end
    end

    test "raises when the configured key is not a valid base64 32-byte key" do
      previous = Application.get_env(:orca_hub, :secrets_key)
      Application.put_env(:orca_hub, :secrets_key, "not-valid-base64-or-right-length")

      try do
        assert_raise Secrets.KeyNotConfiguredError, fn ->
          Secrets.put_secret("KEY", "value")
        end
      after
        Application.put_env(:orca_hub, :secrets_key, previous)
      end
    end
  end
end
