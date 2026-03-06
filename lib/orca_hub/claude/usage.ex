defmodule OrcaHub.Claude.Usage do
  @moduledoc """
  Retrieves current usage / rate limit metrics from the Anthropic API.
  """

  @usage_url "https://api.anthropic.com/api/oauth/usage"

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
  variable, `~/.claude/.credentials.json`, or the macOS Keychain.

  Returns `{:ok, %Usage{}}` or `{:error, reason}`.
  """
  @spec fetch() :: {:ok, t()} | {:error, term()}
  def fetch do
    with {:ok, token} <- resolve_token() do
      fetch_with_token(token)
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

  defp resolve_token do
    case System.get_env("CLAUDE_CODE_OAUTH_TOKEN") do
      nil -> read_credentials()
      token -> {:ok, token}
    end
  end

  defp read_credentials do
    with {:error, _} <- read_credentials_file(),
         {:error, _} <- read_credentials_keychain() do
      {:error, :credentials_not_found}
    end
  end

  defp read_credentials_file do
    path = Path.expand("~/.claude/.credentials.json")

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> extract_token(data)
          {:error, _} -> {:error, :credentials_parse_error}
        end

      {:error, _} ->
        {:error, :credentials_not_found}
    end
  end

  defp read_credentials_keychain do
    user = System.get_env("USER") || ""

    case System.cmd("security", ["find-generic-password", "-s", "Claude Code-credentials", "-a", user, "-w"],
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
end
