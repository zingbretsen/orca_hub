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

  `strict_env/2` is a stronger mode, opt-in per node via
  `OrcaHub.NodePolicy.scrub_session_env?/0`: instead of only unsetting
  release cruft, it unsets EVERY variable not in a small base allow-list
  (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TERM`, `LANG`, `LC_*` by
  prefix, `TMPDIR`, `COLUMNS`, `LINES`) plus, as of Stage 2, any
  `additional_allow` entries the caller passes in — for nodes that run
  sessions triggered by untrusted input and shouldn't leak pod/host secrets
  (API keys, `DISCORD_TOKEN`, `SECRET_KEY_BASE`, etc.) into a session's Bash
  tool via inherited environment. Anything a backend legitimately needs
  (auth tokens, MCP URLs) must be layered back on top via `extra` — see
  `OrcaHub.Backend.Claude`/`Codex`/`Pi`'s `*_env/0` helpers.

  ## Per-node/per-project allow-list extension (Stage 2)

  The base allow-list above is fixed and always in effect. On top of it, an
  operator can configure a per-node `env_allowlist` (`nodes` table /
  `/nodes` UI) and a per-project `env_allowlist` (`projects` table /
  project edit form) — `OrcaHub.NodePolicy.extra_env_allowlist/1` combines
  the two (node ∪ project, for the node running the spawn and the project
  the session/terminal belongs to, if any) into the `additional_allow` list
  passed to `strict_env/2`. Each entry is either an exact variable name
  (`AWS_REGION`) or a name ending in `*` for a prefix match (`AWS_*` matches
  `AWS_REGION`, `AWS_SECRET_ACCESS_KEY`, etc. — validated at the
  changeset level, see `OrcaHub.ClusterNodes.ClusterNode.validate_env_allowlist/1`).
  Allow-listing only controls whether a variable is left unset-as-inherited
  vs. explicitly unset — it NEVER sets a new value; a var not present in the
  BEAM's own environment is simply absent either way. This extension is
  inert unless `scrub_session_env?/0` is already true for the node — it
  cannot turn scrubbing on by itself.

  Erlang port `:env` semantics (verified, not assumed): the child process
  inherits the BEAM's own environment for any variable NOT mentioned in the
  `:env` list at all; a variable IS mentioned via `{name, false}` (unset) or
  `{name, value}` (set). When the SAME name appears more than once in the
  list, the LAST tuple wins — so appending explicit `extra` tuples after a
  block of unsets reliably overrides them.
  """

  # Standalone release vars that don't share a common prefix.
  @release_vars ~w(BINDIR ROOTDIR PROGNAME)

  # Base allow-list for strict_env/2 — always in effect, independent of any
  # per-node/per-project `additional_allow` entries a caller passes in (see
  # moduledoc's "Per-node/per-project allow-list extension" section).
  @base_allow_list ~w(PATH HOME USER LOGNAME SHELL TERM LANG TMPDIR COLUMNS LINES)

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

  @doc """
  Returns a strict allow-list environment (see moduledoc) with `extra`
  layered on top, same convention as `sanitized_env/1`. `additional_allow`
  (Stage 2: per-node/per-project `env_allowlist` entries, see
  `OrcaHub.NodePolicy.extra_env_allowlist/1`) extends the base allow-list —
  each entry is an exact var name or a `NAME*` prefix match.
  """
  @spec strict_env([{charlist(), charlist() | false}], [String.t()]) :: [
          {charlist(), charlist() | false}
        ]
  def strict_env(extra \\ [], additional_allow \\ [])
      when is_list(extra) and is_list(additional_allow) do
    strict_unset_vars(@base_allow_list ++ additional_allow) ++ path_var() ++ extra
  end

  defp strict_unset_vars(allow_list) do
    System.get_env()
    |> Map.keys()
    |> Enum.reject(&allowed_var?(&1, allow_list))
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp allowed_var?(name, allow_list) do
    name in allow_list or String.starts_with?(name, "LC_") or
      Enum.any?(allow_list, &prefix_allow_match?(name, &1))
  end

  # A `NAME*` allow-list entry matches any var starting with `NAME` — `*`
  # alone (empty prefix) never matches anything (that would allow through
  # the ENTIRE environment, defeating the point of strict_env/2).
  defp prefix_allow_match?(name, entry) do
    case String.ends_with?(entry, "*") do
      true ->
        prefix = String.trim_trailing(entry, "*")
        prefix != "" and String.starts_with?(name, prefix)

      false ->
        false
    end
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
