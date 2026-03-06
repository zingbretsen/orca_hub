defmodule OrcaHub.Claude.Config do
  @moduledoc """
  Builds CLI arguments for the Claude Code CLI.
  """

  @doc """
  Builds CLI args and port options from a prompt and keyword opts.

  Returns `{args_list, port_opts}`.

  ## Options

    * `:output_format` - output format (default: `"stream-json"`)
    * `:verbose` - enable verbose output (default: `true`)
    * `:skip_permissions` - skip permission prompts (default: `true`)
    * `:session_id` - resume a session by ID
    * `:allowed_tools` - list of allowed tool names
    * `:max_turns` - maximum number of turns
    * `:max_budget` - maximum budget in USD
    * `:system_prompt` - text appended to the system prompt
    * `:model` - model name to use
    * `:cwd` - working directory (returned in port opts, not CLI args)

  """
  @spec build_args(String.t(), keyword()) :: {[String.t()], keyword()}
  def build_args(prompt, opts \\ []) do
    format = Keyword.get(opts, :output_format, "stream-json")

    args =
      ["-p", prompt, "--output-format", format]
      |> maybe_add_flag("--verbose", Keyword.get(opts, :verbose, true))
      |> maybe_add_flag(
        "--dangerously-skip-permissions",
        Keyword.get(opts, :skip_permissions, true)
      )
      |> maybe_add_opt("--resume", Keyword.get(opts, :session_id))
      |> maybe_add_opt("--allowedTools", maybe_join(Keyword.get(opts, :allowed_tools)))
      |> maybe_add_opt("--max-turns", maybe_to_string(Keyword.get(opts, :max_turns)))
      |> maybe_add_opt("--max-budget-usd", maybe_to_string(Keyword.get(opts, :max_budget)))
      |> maybe_add_opt("--append-system-prompt", Keyword.get(opts, :system_prompt))
      |> maybe_add_opt("--model", Keyword.get(opts, :model))

    port_opts =
      case Keyword.get(opts, :cwd) do
        nil -> []
        cwd -> [cd: String.to_charlist(cwd)]
      end

    {args, port_opts}
  end

  @doc """
  Shell-escapes a single argument for safe inclusion in a command string.
  """
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, _), do: args ++ [flag]

  defp maybe_add_opt(args, _flag, nil), do: args
  defp maybe_add_opt(args, flag, value), do: args ++ [flag, value]

  defp maybe_join(nil), do: nil
  defp maybe_join(tools), do: Enum.join(tools, ",")

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)
end
