defmodule OrcaHub.BackendAuthTest do
  # Uses only tmp-dir fixtures (never a real ~/.codex or ~/.pi/agent), so
  # this is safe to run async alongside everything else.
  use ExUnit.Case, async: true

  alias OrcaHub.BackendAuth

  setup do
    home = Path.join(System.tmp_dir!(), "backend_auth_home_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    {:ok, home: home, opts: [home_dir: home]}
  end

  describe "codex_status/1" do
    test "reports not_logged_in when auth.json is absent", %{opts: opts} do
      assert BackendAuth.codex_status(opts) == %{status: :not_logged_in, label: "Not logged in"}
    end

    test "reports chatgpt/device when auth_mode is chatgpt with tokens present (FAKE values)", %{
      home: home,
      opts: opts
    } do
      write_json(Path.join(home, ".codex/auth.json"), %{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "fake-access-token", "account_id" => "fake-acct"},
        "last_refresh" => "2026-07-09T00:00:00Z"
      })

      assert BackendAuth.codex_status(opts) == %{status: :chatgpt, label: "ChatGPT (device)"}
    end

    test "reports api_key when OPENAI_API_KEY key is present (FAKE value)", %{
      home: home,
      opts: opts
    } do
      write_json(Path.join(home, ".codex/auth.json"), %{
        "auth_mode" => "apikey",
        "OPENAI_API_KEY" => "sk-fake-not-a-real-key"
      })

      assert BackendAuth.codex_status(opts) == %{status: :api_key, label: "API key"}
    end

    test "falls back to not_logged_in on unparseable auth.json", %{home: home, opts: opts} do
      File.mkdir_p!(Path.join(home, ".codex"))
      File.write!(Path.join(home, ".codex/auth.json"), "not json")

      assert BackendAuth.codex_status(opts) == %{status: :not_logged_in, label: "Not logged in"}
    end
  end

  describe "codex_env_conflict?/0" do
    test "false when OPENAI_API_KEY is unset" do
      System.delete_env("OPENAI_API_KEY")
      refute BackendAuth.codex_env_conflict?()
    end

    test "true when OPENAI_API_KEY is set" do
      System.put_env("OPENAI_API_KEY", "sk-fake-env-key")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert BackendAuth.codex_env_conflict?()
    end
  end

  describe "set_pi_key/3" do
    test "creates auth.json with 0600 mode and 0700 parent dir", %{home: home, opts: opts} do
      assert :ok = BackendAuth.set_pi_key("fireworks", "fake-fireworks-key", opts)

      path = Path.join(home, ".pi/agent/auth.json")
      assert File.regular?(path)
      assert file_mode(path) == 0o600
      assert file_mode(Path.dirname(path)) == 0o700

      assert Jason.decode!(File.read!(path)) == %{
               "fireworks" => %{"type" => "api_key", "key" => "fake-fireworks-key"}
             }
    end

    test "read-merge-write preserves other providers' entries untouched", %{
      home: home,
      opts: opts
    } do
      write_json(Path.join(home, ".pi/agent/auth.json"), %{
        "anthropic" => %{
          "type" => "oauth",
          "access" => "fake-access",
          "refresh" => "fake-refresh"
        }
      })

      assert :ok = BackendAuth.set_pi_key("openai", "fake-openai-key", opts)

      auth = Jason.decode!(File.read!(Path.join(home, ".pi/agent/auth.json")))

      assert auth["anthropic"] == %{
               "type" => "oauth",
               "access" => "fake-access",
               "refresh" => "fake-refresh"
             }

      assert auth["openai"] == %{"type" => "api_key", "key" => "fake-openai-key"}
    end

    test "overwrites only the target provider's own prior entry", %{home: home, opts: opts} do
      write_json(Path.join(home, ".pi/agent/auth.json"), %{
        "openai" => %{"type" => "api_key", "key" => "fake-old-key"}
      })

      assert :ok = BackendAuth.set_pi_key("openai", "fake-new-key", opts)

      auth = Jason.decode!(File.read!(Path.join(home, ".pi/agent/auth.json")))
      assert auth["openai"] == %{"type" => "api_key", "key" => "fake-new-key"}
      assert map_size(auth) == 1
    end
  end

  describe "delete_pi_key/2" do
    test "removes only the target provider", %{home: home, opts: opts} do
      write_json(Path.join(home, ".pi/agent/auth.json"), %{
        "openai" => %{"type" => "api_key", "key" => "fake-openai-key"},
        "fireworks" => %{"type" => "api_key", "key" => "fake-fireworks-key"}
      })

      assert :ok = BackendAuth.delete_pi_key("openai", opts)

      auth = Jason.decode!(File.read!(Path.join(home, ".pi/agent/auth.json")))
      refute Map.has_key?(auth, "openai")
      assert Map.has_key?(auth, "fireworks")
    end

    test "no-ops when auth.json is absent", %{opts: opts} do
      assert :ok = BackendAuth.delete_pi_key("openai", opts)
    end
  end

  describe "list_pi_providers/1" do
    test "returns names and types only (never key values)", %{home: home, opts: opts} do
      write_json(Path.join(home, ".pi/agent/auth.json"), %{
        "openai" => %{"type" => "api_key", "key" => "fake-openai-key"},
        "anthropic" => %{"type" => "oauth", "access" => "fake-access"}
      })

      providers = BackendAuth.list_pi_providers(opts)

      assert Enum.sort(providers) ==
               Enum.sort([
                 %{provider: "anthropic", type: "oauth"},
                 %{provider: "openai", type: "api_key"}
               ])

      refute Enum.any?(providers, &Map.has_key?(&1, :key))
    end

    test "returns [] when auth.json is absent", %{opts: opts} do
      assert BackendAuth.list_pi_providers(opts) == []
    end
  end

  describe "pi_provider_options/0" do
    test "includes the common providers from the research doc" do
      options = BackendAuth.pi_provider_options()
      assert "anthropic" in options
      assert "openai" in options
      assert "openrouter" in options
    end
  end

  defp write_json(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end

  defp file_mode(path) do
    import Bitwise
    File.stat!(path).mode &&& 0o777
  end
end
