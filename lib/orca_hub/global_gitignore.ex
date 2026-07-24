defmodule OrcaHub.GlobalGitignore do
  @moduledoc """
  Opt-in, per-node management of git's GLOBAL ignore file
  (`git config --global core.excludesfile`) for the working-directory
  artifacts OrcaHub drops into session directories: `.agents/`,
  `.orca_uploads/`, and `.worktrees/`.

  OrcaHub deliberately never writes a project's tracked `.gitignore`
  (the per-repo writers in `AgentPresence`/`Projects` were removed in
  favor of this module). Instead, an operator triggers `ensure/1` from
  `NodeLive.Show`, which adds the patterns to the node's global ignore
  file once — excluding them from every repo on that node without
  touching any tracked file.

  Every function here is meant to be invoked via `OrcaHub.Cluster.rpc/4`
  so it executes ON THE TARGET NODE — paths and `git config` state must
  resolve there, not on the hub. For tests, the base "home" directory is
  injectable via the `:home_dir` option or the
  `:orca_hub, :global_gitignore_home` Application env (checked in that
  order, falling back to the real environment), mirroring
  `OrcaHub.NodeConfig`. When a custom home is injected, git subcommands
  run with `HOME` pointed at it and `XDG_CONFIG_HOME`/`GIT_CONFIG_GLOBAL`
  unset, so tests never read or write the developer machine's real git
  config.
  """

  @patterns [".agents/", ".orca_uploads/", ".worktrees/"]

  @doc "The managed ignore patterns, in display order."
  def patterns, do: @patterns

  @doc """
  Reports the live state of this node's global gitignore. Returns

      %{
        git_available?: boolean,   # git executable found on this node
        configured?: boolean,      # core.excludesfile explicitly set
        path: String.t() | nil,    # effective ignore file (git default when unset)
        present: [pattern],        # managed patterns already in that file
        missing: [pattern]
      }

  Never raises: a missing git binary reads as `git_available?: false`
  with every pattern missing, and a missing/unreadable ignore file just
  reads as "nothing present yet".
  """
  def status(opts \\ []) do
    if git?() do
      {configured?, path} = effective_excludesfile(opts)
      present = present_patterns(path)

      %{
        git_available?: true,
        configured?: configured?,
        path: path,
        present: present,
        missing: @patterns -- present
      }
    else
      %{git_available?: false, configured?: false, path: nil, present: [], missing: @patterns}
    end
  end

  @doc """
  Idempotently ensures every managed pattern is in this node's global
  gitignore. If `core.excludesfile` is unset, first sets it (via
  `git config --global`) to git's own default path
  (`$XDG_CONFIG_HOME/git/ignore`, i.e. `~/.config/git/ignore`), then
  appends whichever patterns are missing — preserving any unrelated
  existing content and never duplicating entries. Safe to call
  repeatedly. Returns `:ok` or `{:error, reason}`.
  """
  def ensure(opts \\ []) do
    if git?() do
      with {:ok, path} <- ensure_excludesfile_configured(opts) do
        append_missing_patterns(path)
      end
    else
      {:error, :git_not_found}
    end
  end

  # -------------------------------------------------------------------
  # excludesfile resolution
  # -------------------------------------------------------------------

  defp git?, do: System.find_executable("git") != nil

  # {explicitly_configured?, effective_path}
  defp effective_excludesfile(opts) do
    case git_config_get(opts) do
      {:ok, path} -> {true, expand_home(path, opts)}
      :unset -> {false, default_ignore_path(opts)}
    end
  end

  defp git_config_get(opts) do
    case System.cmd("git", ["config", "--global", "--get", "core.excludesfile"],
           env: git_env(opts),
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :unset
          path -> {:ok, path}
        end

      {_out, _} ->
        :unset
    end
  end

  defp ensure_excludesfile_configured(opts) do
    case effective_excludesfile(opts) do
      {true, path} ->
        {:ok, path}

      {false, path} ->
        case System.cmd("git", ["config", "--global", "core.excludesfile", path],
               env: git_env(opts),
               stderr_to_stdout: true
             ) do
          {_out, 0} -> {:ok, path}
          {out, _} -> {:error, "git config failed: #{String.trim(out)}"}
        end
    end
  end

  # Git's documented default when core.excludesfile is unset.
  defp default_ignore_path(opts) do
    config_home =
      case custom_home(opts) do
        nil -> System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
        home -> Path.join(home, ".config")
      end

    Path.join([config_home, "git", "ignore"])
  end

  # git config values may store the path with a literal leading `~`.
  defp expand_home("~/" <> rest, opts), do: Path.join(base_home(opts), rest)
  defp expand_home(path, _opts), do: path

  # -------------------------------------------------------------------
  # Ignore-file reading/writing
  # -------------------------------------------------------------------

  defp present_patterns(path) do
    lines =
      case File.read(path) do
        {:ok, content} -> content |> String.split("\n") |> Enum.map(&String.trim/1)
        {:error, _} -> []
      end

    Enum.filter(@patterns, fn pattern ->
      # `.agents` (no slash) ignores the directory just the same
      pattern in lines or String.trim_trailing(pattern, "/") in lines
    end)
  end

  defp append_missing_patterns(path) do
    case @patterns -- present_patterns(path) do
      [] ->
        :ok

      missing ->
        existing =
          case File.read(path) do
            {:ok, content} -> content
            {:error, _} -> ""
          end

        base =
          cond do
            existing == "" -> ""
            String.ends_with?(existing, "\n") -> existing
            true -> existing <> "\n"
          end

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, base <> Enum.join(missing, "\n") <> "\n") do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # -------------------------------------------------------------------
  # Injectable home — see OrcaHub.NodeConfig for the same pattern.
  # -------------------------------------------------------------------

  defp custom_home(opts) do
    Keyword.get(opts, :home_dir) || Application.get_env(:orca_hub, :global_gitignore_home)
  end

  defp base_home(opts), do: custom_home(opts) || System.user_home!()

  # With an injected home, scrub every other var git would consult for
  # global-config resolution so tests can't touch the real machine state.
  defp git_env(opts) do
    case custom_home(opts) do
      nil -> []
      home -> [{"HOME", home}, {"XDG_CONFIG_HOME", nil}, {"GIT_CONFIG_GLOBAL", nil}]
    end
  end
end
