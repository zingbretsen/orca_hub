defmodule OrcaHub.Claude.Usage do
  @moduledoc """
  Retrieves current usage / rate limit metrics from the Anthropic API.

  The OAuth access token used for the usage endpoint is short-lived. This
  node (the hub) often sits idle, so its token is usually expired by the time
  someone opens the usage page — the Claude CLI only refreshes the token when
  it actually runs a session.

  To wake the token up without us having to know anything about Anthropic's
  OAuth flow, we let the CLI do it: when the credentials file's `expiresAt`
  has passed (or the usage call returns a 401), we run a throwaway
  `claude -p 'hi'`, which refreshes the token and rewrites
  `~/.claude/.credentials.json` in place. We then re-read the file and retry.
  Access tokens are account-scoped (not per-node), so the refreshed token is
  in sync with the rest of the cluster.
  """

  require Logger

  @usage_url "https://api.anthropic.com/api/oauth/usage"

  @credentials_path "~/.claude/.credentials.json"

  # A throwaway prompt whose only purpose is to make the CLI refresh the token.
  # We strip it down to the bare minimum: no tools, empty system prompt, the
  # cheapest model, thinking disabled, and a tiny output cap. (A cap of 1 is
  # rejected — the CLI truncates the reply, retries, and exits non-zero — so 16
  # is the practical floor for a clean, fast exit. Cost is still negligible.)
  @refresh_args ["-p", "hi", "--tools", "", "--system-prompt", "", "--model", "haiku"]

  @refresh_env [
    {"MAX_THINKING_TOKENS", "0"},
    {"CLAUDE_CODE_MAX_OUTPUT_TOKENS", "16"}
  ]

  # Cap the refresh shell-out so a hung CLI can't block the usage page forever.
  @refresh_timeout_s "60"

  # Refresh this many ms before the stored expiry to absorb clock skew.
  @expiry_skew_ms 60_000

  defstruct [:session, :weekly]

  @type window :: %{
          utilization: float(),
          resets_at: String.t()
        }

  @type t :: %__MODULE__{
          session: window() | nil,
          weekly: window() | nil
        }

  @doc """
  Fetches current usage metrics from the Anthropic API.

  Reads the OAuth token from the `CLAUDE_CODE_OAUTH_TOKEN` environment
  variable, `~/.claude/.credentials.json`, or the macOS Keychain. When the
  file-based credentials are expired (or the API rejects the token) the token
  is refreshed via the Claude CLI before retrying.

  Returns `{:ok, %Usage{}}` or `{:error, reason}` — a `{:credential_expired,
  cli_reason}` reason means the CLI-driven refresh itself failed (e.g. the
  OAuth session can no longer be refreshed at all) and someone needs to
  re-`claude login` on this node; any other reason is a lower-level failure
  (CLI not found, credentials file missing/corrupt, network/parse error).
  """
  @spec fetch() :: {:ok, t()} | {:error, term()}
  def fetch do
    case resolve_token() do
      {:ok, token} ->
        fetch_with_resolved_token(token)

      # A {:credential_expired, _} here means resolve_token/0 already
      # attempted (and failed) a CLI refresh for a known-expired token — the
      # credential is confirmed bad, so short-circuit instead of falling
      # through to fetch_with_resolved_token, which is what used to shell
      # out to `claude -p` a second, doomed time for the exact same failure
      # (plus the HTTP round trip in between) — see
      # perf_audit_projects_queue.md §1. Any other resolve_token/0 error
      # (CLI not found, no credentials at all, ...) passes through as-is.
      {:error, _} = err ->
        err
    end
  end

  defp fetch_with_resolved_token(token) do
    case fetch_with_token(token) do
      {:error, {:http_error, 22, _}} ->
        # 401 from the usage endpoint (curl exit 22). The token may have been
        # invalidated server-side before its stored expiry; force the CLI to
        # refresh and retry once.
        case refresh_via_cli() do
          {:ok, fresh} -> fetch_with_token(fresh)
          {:error, reason} -> {:error, {:credential_expired, reason}}
        end

      result ->
        result
    end
  end

  @doc """
  Fetches usage metrics using the provided OAuth token.
  """
  @spec fetch_with_token(String.t()) :: {:ok, t()} | {:error, term()}
  def fetch_with_token(token) do
    args = [
      "-s",
      "-f",
      "-H",
      "Authorization: Bearer #{token}",
      "-H",
      "anthropic-beta: oauth-2025-04-20",
      "-H",
      "Accept: application/json",
      @usage_url
    ]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {body, 0} ->
        parse_response(body)

      {output, code} ->
        {:error, {:http_error, code, output}}
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        {:ok,
         %__MODULE__{
           session: parse_window(data["five_hour"]),
           weekly: parse_window(data["seven_day"])
         }}

      {:error, _} ->
        {:error, {:parse_error, body}}
    end
  end

  defp parse_window(nil), do: nil

  defp parse_window(window) do
    %{
      utilization: window["utilization"] || 0.0,
      resets_at: window["resets_at"]
    }
  end

  # --- Token resolution --------------------------------------------------

  defp resolve_token do
    case System.get_env("CLAUDE_CODE_OAUTH_TOKEN") do
      nil -> token_from_file_or_keychain()
      token -> {:ok, token}
    end
  end

  defp token_from_file_or_keychain do
    case read_credentials_file() do
      {:ok, data} ->
        if expired?(data) do
          # Proactively refresh so the usage call doesn't have a guaranteed
          # 401. If the refresh itself fails, the credential is confirmed
          # bad — tag it distinctly so `fetch/0` can fail fast instead of
          # calling the API with a token already known to be stale (which
          # would just 401 and trigger an identical, doomed second refresh).
          case refresh_via_cli() do
            {:ok, token} -> {:ok, token}
            {:error, reason} -> {:error, {:credential_expired, reason}}
          end
        else
          extract_token(data)
        end

      {:error, _} ->
        read_credentials_keychain()
    end
  end

  defp read_credentials_file do
    path = Path.expand(@credentials_path)

    with {:ok, contents} <- File.read(path),
         {:ok, data} <- Jason.decode(contents) do
      {:ok, data}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :credentials_parse_error}
      {:error, _} -> {:error, :credentials_not_found}
    end
  end

  defp read_credentials_keychain do
    user = System.get_env("USER") || ""

    case System.cmd(
           "security",
           ["find-generic-password", "-s", "Claude Code-credentials", "-a", user, "-w"],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        case Jason.decode(String.trim(json)) do
          {:ok, data} -> extract_token(data)
          {:error, _} -> {:error, :keychain_parse_error}
        end

      _ ->
        {:error, :keychain_not_found}
    end
  end

  defp extract_token(%{"claudeAiOauth" => %{"accessToken" => token}}) when is_binary(token),
    do: {:ok, token}

  defp extract_token(%{"claudeCodeOAuthAccessToken" => token}) when is_binary(token),
    do: {:ok, token}

  defp extract_token(%{"accessToken" => token}) when is_binary(token),
    do: {:ok, token}

  defp extract_token(_), do: {:error, :no_token_in_credentials}

  # --- Token refresh (delegated to the Claude CLI) -----------------------

  defp expired?(%{"claudeAiOauth" => %{"expiresAt" => exp}}) when is_integer(exp) do
    System.system_time(:millisecond) >= exp - @expiry_skew_ms
  end

  defp expired?(_), do: false

  # Run a throwaway prompt so the CLI refreshes the token and rewrites the
  # credentials file, then read the freshly-stored access token back out.
  defp refresh_via_cli do
    with {:ok, claude} <- claude_executable(),
         {_out, 0} <- run_refresh(claude),
         {:ok, data} <- read_credentials_file(),
         {:ok, token} <- extract_token(data) do
      Logger.info("Refreshed Claude OAuth token for usage metrics via CLI")
      {:ok, token}
    else
      {:error, reason} = err ->
        Logger.warning("Claude OAuth token refresh via CLI failed: #{inspect(reason)}")
        err

      {out, code} ->
        Logger.warning("`claude -p` exited #{code} during token refresh: #{inspect(out)}")
        {:error, {:refresh_cli_exit, code}}
    end
  end

  defp claude_executable do
    case System.find_executable("claude") do
      nil -> {:error, :claude_not_found}
      path -> {:ok, path}
    end
  end

  # Wrap with `timeout(1)` when available so a hung CLI can't block forever.
  # `System.cmd/3` has no built-in timeout.
  defp run_refresh(claude) do
    case System.find_executable("timeout") do
      nil ->
        System.cmd(claude, @refresh_args, env: @refresh_env, stderr_to_stdout: true)

      timeout ->
        System.cmd(timeout, [@refresh_timeout_s, claude | @refresh_args],
          env: @refresh_env,
          stderr_to_stdout: true
        )
    end
  end
end
