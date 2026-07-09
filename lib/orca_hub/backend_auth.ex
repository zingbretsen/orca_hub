defmodule OrcaHub.BackendAuth do
  @moduledoc """
  Node-local auth plumbing for the codex and pi backends — deliberately
  separate from `OrcaHub.NodeConfig`, which hard-blocklists both backends'
  `auth.json` from its generic config browser/editor (`node_config.ex:305`).
  Every function here is narrow-purpose, reads/writes only what it needs,
  and is meant to be invoked via `OrcaHub.Cluster.rpc/4-5` so it runs ON THE
  TARGET NODE, mirroring `NodeConfig`'s own RPC convention.

  ## codex

  Codex durably persists its own login state to `~/.codex/auth.json` (the
  CLI writes this itself — see `OrcaHub.CodexLoginRunner`, which only drives
  the login process and never touches this file). `codex_status/1` derives a
  UI badge from that file by reading `auth_mode`'s value (not a secret — an
  enum like `"chatgpt"`) plus the mere *presence* of the `OPENAI_API_KEY` /
  `tokens` keys — never any credential value.

  Codex also has a well-documented quirk (`docs/codex_pi_auth_research.md`
  §2/§6): an `OPENAI_API_KEY` environment variable, if set in the node's
  process environment, silently overrides a persisted ChatGPT/device-auth
  login. `codex_env_conflict?/0` surfaces that so the UI can warn — it does
  NOT attempt to fix the env var itself, that's a separate user decision.

  ## pi

  pi has no CLI for key management (`docs/codex_pi_auth_research.md` §3) —
  the only durable way to set a provider key is pi's own interactive
  `/login` TUI command, which doesn't work headlessly. So OrcaHub writes
  `~/.pi/agent/auth.json` directly: `{"<provider>": {"type": "api_key",
  "key": "<secret>"}}`, file mode `0600`, parent dir `0700`. `set_pi_key/3`
  does a read-merge-write that only touches the target provider's entry, so
  concurrent/other providers' entries (including any `type: "oauth"` entry a
  future Anthropic-via-pi login might add) survive untouched.

  Race note: pi's own OAuth-refresh path (if a provider is ever `type:
  "oauth"`) could in principle race a concurrent `set_pi_key/3` write to the
  same file. Low risk today — every entry on record is `api_key` type, which
  pi never rewrites on its own — but worth keeping in mind if/when an
  OAuth-backed provider is ever wired up here.

  ## Security

  Every read function below returns names/labels/enums only — key material
  is written, never read back. `home_dir`/`:orca_hub, :backend_auth_home`
  mirror `NodeConfig`'s own injectable-home pattern for tests, but use a
  distinct app-env key so tests can't accidentally share state with
  `NodeConfig`'s.
  """

  @codex_home ".codex"
  @pi_home Path.join(".pi", "agent")

  # ── codex ─────────────────────────────────────────────────────────────

  @doc """
  Best-effort login-status badge for codex on this node, derived ONLY from
  `auth_mode`'s value and the presence (never the value) of
  `OPENAI_API_KEY`/`tokens` keys in `~/.codex/auth.json`.

  Returns `%{status: :chatgpt | :api_key | :not_logged_in, label: String.t()}`.
  """
  @spec codex_status(keyword) :: %{status: atom, label: String.t()}
  def codex_status(opts \\ []) do
    case read_json(codex_auth_path(opts)) do
      {:ok, %{} = auth} -> classify_codex_auth(auth)
      _ -> %{status: :not_logged_in, label: "Not logged in"}
    end
  end

  defp classify_codex_auth(auth) do
    cond do
      auth["auth_mode"] == "chatgpt" and Map.has_key?(auth, "tokens") ->
        %{status: :chatgpt, label: "ChatGPT (device)"}

      Map.has_key?(auth, "OPENAI_API_KEY") ->
        %{status: :api_key, label: "API key"}

      true ->
        %{status: :not_logged_in, label: "Not logged in"}
    end
  end

  @doc """
  Whether `OPENAI_API_KEY` is set in THIS node's process environment — codex
  treats that as an override that wins over a persisted `auth.json` login
  (`docs/codex_pi_auth_research.md` §2/§6). Purely informational; never
  modifies the env var.
  """
  @spec codex_env_conflict?() :: boolean
  def codex_env_conflict? do
    case System.get_env("OPENAI_API_KEY") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc "Codex's auth.json path on this node."
  @spec codex_auth_path(keyword) :: String.t()
  def codex_auth_path(opts \\ []), do: Path.join([base_home(opts), @codex_home, "auth.json"])

  # ── pi ────────────────────────────────────────────────────────────────

  @doc """
  Sets `provider`'s API key in `~/.pi/agent/auth.json` via read-merge-write
  — every other provider's entry is left untouched. Creates the parent dir
  (`0700`) if needed; the file itself is written `0600`.
  """
  @spec set_pi_key(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def set_pi_key(provider, key, opts \\ [])
      when is_binary(provider) and is_binary(key) and provider != "" and key != "" do
    path = pi_auth_path(opts)

    with {:ok, auth} <- read_json(path, default: %{}) do
      updated = Map.put(auth, provider, %{"type" => "api_key", "key" => key})
      write_pi_auth(path, updated)
    end
  end

  @doc "Removes `provider`'s entry from pi's auth.json, if present."
  @spec delete_pi_key(String.t(), keyword) :: :ok | {:error, term}
  def delete_pi_key(provider, opts \\ []) when is_binary(provider) do
    path = pi_auth_path(opts)

    with {:ok, auth} <- read_json(path, default: %{}) do
      write_pi_auth(path, Map.delete(auth, provider))
    end
  end

  @doc """
  Lists configured pi providers as `%{provider:, type:}` — names and auth
  TYPE only, never key/token values.
  """
  @spec list_pi_providers(keyword) :: [%{provider: String.t(), type: String.t() | nil}]
  def list_pi_providers(opts \\ []) do
    case read_json(pi_auth_path(opts)) do
      {:ok, %{} = auth} ->
        Enum.map(auth, fn {provider, entry} ->
          %{provider: provider, type: entry["type"]}
        end)
        |> Enum.sort_by(& &1.provider)

      _ ->
        []
    end
  end

  @doc """
  Common pi provider ids for the Settings UI dropdown (from `pi-ai`'s
  `env-api-keys.js`, `docs/codex_pi_auth_research.md` §3) — not exhaustive,
  the UI also offers a free-text option for anything else pi supports.
  """
  @spec pi_provider_options() :: [String.t()]
  def pi_provider_options do
    ~w(anthropic openai google fireworks together openrouter mistral groq cerebras xai deepseek)
  end

  @doc "pi's auth.json path on this node."
  @spec pi_auth_path(keyword) :: String.t()
  def pi_auth_path(opts \\ []), do: Path.join(base_home(opts) |> Path.join(@pi_home), "auth.json")

  defp write_pi_auth(path, auth) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, Jason.encode!(auth, pretty: true))
    File.chmod!(path, 0o600)
    :ok
  rescue
    e -> {:error, e}
  end

  # ── shared ────────────────────────────────────────────────────────────

  defp read_json(path, opts \\ []) do
    default = Keyword.get(opts, :default)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _ -> if default, do: {:ok, default}, else: {:error, :invalid_json}
        end

      {:error, :enoent} ->
        if default, do: {:ok, default}, else: {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Injectable base "home" dir for tests — mirrors OrcaHub.NodeConfig's
  # pattern but under a distinct app-env key so the two modules' test seams
  # never collide.
  defp base_home(opts) do
    Keyword.get(opts, :home_dir) ||
      Application.get_env(:orca_hub, :backend_auth_home) ||
      System.user_home!()
  end
end
