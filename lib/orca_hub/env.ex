defmodule OrcaHub.Env do
  @moduledoc """
  Builds a sanitized environment for processes spawned via Erlang ports
  (Claude CLI sessions, terminal PTYs).

  When OrcaHub runs as a production OTP release, the BEAM exports a number of
  release-specific variables (`RELEASE_*`, `BINDIR`, `ROOTDIR`, `PROGNAME`) and
  prepends the release's ERTS directory to `PATH`. If these leak into a spawned
  shell, any `mix`/`elixir`/`erl` command run inside that shell tries to boot the
  orca_hub release instead of running normally and crashes at boot with
  `cannot get bootfile`.

  This module produces a list of Erlang port `:env` tuples that *unset* those
  variables (setting a var to `false` removes it from the child's env) and strip
  release entries out of `PATH`. In dev (`mix phx.server`), none of these
  variables are set, so the result is an empty/harmless list.
  """

  # Standalone release vars that don't share a common prefix.
  @release_vars ~w(BINDIR ROOTDIR PROGNAME)

  @doc """
  Returns the sanitized environment as a list of `:env` tuples.
  """
  @spec sanitized_env() :: [{charlist(), charlist() | false}]
  def sanitized_env, do: sanitized_env([])

  @doc """
  Returns the sanitized environment with `extra` vars layered on top.

  `extra` is a list of `{charlist, charlist}` (or `{charlist, false}`) tuples
  that are appended after the sanitizer's tuples, so callers can add vars such
  as `TERM`/`COLUMNS`/`LINES` on top of the cleaned base.
  """
  @spec sanitized_env([{charlist(), charlist() | false}]) :: [{charlist(), charlist() | false}]
  def sanitized_env(extra) when is_list(extra) do
    unset_vars() ++ path_var() ++ extra
  end

  defp unset_vars do
    names =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn name ->
        String.starts_with?(name, "RELEASE_") or name in @release_vars
      end)

    Enum.map(names, fn name -> {String.to_charlist(name), false} end)
  end

  defp path_var do
    case System.get_env("PATH") do
      nil ->
        []

      path ->
        cleaned =
          path
          |> String.split(":")
          |> Enum.reject(&release_path?/1)
          |> Enum.join(":")

        [{~c"PATH", String.to_charlist(cleaned)}]
    end
  end

  defp release_path?(entry) do
    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) and root != "" ->
        String.starts_with?(entry, root)

      _ ->
        String.contains?(entry, "/erts-") or
          (String.contains?(entry, "_build/") and String.contains?(entry, "/rel/"))
    end
  end
end
