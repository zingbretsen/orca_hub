defmodule OrcaHub.MemoryGit do
  @moduledoc """
  Per-node git-backed snapshotting for the two on-disk agent memory stores:

    * `~/.claude/projects` — every Claude Code project's transcripts,
      settings, and history live here too, so this repo is whitelist-.gitignored
      to track ONLY `<slug>/memory/**` (see `@gitignore_content`).
    * `~/.codex/memories` — Codex's flat global memory store; the whole dir
      is tracked (nothing else lives there).

  `ensure_repo/2` makes a directory a git repo (if it isn't already) and
  makes sure it has a Gitea remote (creating the Gitea-side repo via the API
  if needed), under the `agent-memories` org, named `<node>-claude` /
  `<node>-codex`. `snapshot/3` commits whatever's dirty and best-effort
  pushes.

  **Soft-degrade is load-bearing, not an afterthought**: a missing `git`
  binary, missing/unreachable Gitea, or a push failure must never raise or
  block the caller (this is invoked from a session's idle transition, via
  `OrcaHub.MemoryGit.Server`) — every public function here returns `:ok`
  and logs a rate-limited warning instead. Reserve `{:error, _}` returns for
  cases the caller can usefully react to (there are none from these two
  entry points today; both always resolve to `:ok`).

  Every path is injectable via opts/Application env so tests never touch a
  real `~/.claude`/`~/.codex` — same convention as `OrcaHub.AgentMemory` /
  `OrcaHub.SkillSync` (`:home_dir` opt, falling back to
  `:orca_hub, :memory_git_home`, falling back to `System.user_home!/0`).
  """

  require Logger

  @gitea_org "agent-memories"
  @claude_projects_subpath ".claude/projects"
  @codex_memories_subpath ".codex/memories"

  # Whitelist chain: `*` ignores everything, `!*/` re-allows traversal into
  # every directory (git won't look inside an ignored dir otherwise), then
  # `!*/memory/` and `!*/memory/**` re-allow a project's `memory/` dir and
  # its contents specifically. `!.gitignore` keeps the ignore file itself
  # trackable (it would otherwise be caught by the leading `*`). Verified
  # against real git behavior in `MemoryGitTest`.
  @gitignore_content """
  *
  !*/
  !*/memory/
  !*/memory/**
  !.gitignore
  """

  @warn_rate_limit_ms :timer.minutes(5)

  # -------------------------------------------------------------------
  # Paths
  # -------------------------------------------------------------------

  @doc "`~/.claude/projects` on this node (the Claude memory repo root)."
  def claude_projects_dir(opts \\ []), do: Path.join(home_dir(opts), @claude_projects_subpath)

  @doc "`~/.claude` on this node (parent of `claude_projects_dir/1`)."
  def claude_home_dir(opts \\ []), do: Path.join(home_dir(opts), ".claude")

  @doc "`~/.codex/memories` on this node (the Codex memory repo root)."
  def codex_memories_dir(opts \\ []), do: Path.join(home_dir(opts), @codex_memories_subpath)

  @doc """
  Gitea repo name for `kind` (`:claude` | `:codex`) on this node —
  `<node>-claude` / `<node>-codex`, sanitized to a safe repo-name charset.
  """
  def repo_name(kind, opts \\ []) when kind in [:claude, :codex] do
    "#{node_slug(opts)}-#{kind}"
  end

  defp node_slug(opts) do
    (Keyword.get(opts, :node_name) || OrcaHub.Cluster.display_name())
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")
    |> then(fn s -> if s == "", do: "node", else: s end)
  end

  # -------------------------------------------------------------------
  # ensure_repo
  # -------------------------------------------------------------------

  @doc """
  Idempotently ensures `dir` is a git repo, wired to a Gitea remote.
  Never raises and never returns an error — every failure soft-degrades to
  a rate-limited warning so the caller (the per-node serializing
  `OrcaHub.MemoryGit.Server`) can always proceed to the next step.

  Options:

    * `:whitelist_memory?` — when `true`, writes the whitelist `.gitignore`
      (see moduledoc) on first init. Never clobbers a pre-existing
      `.gitignore` in an already-initialized repo. Default `false`.
    * `:repo_name` — required; the Gitea repo name to create/wire up
      (see `repo_name/2`).
    * `:home_dir`, `:gitea_url`, `:gitea_token` — test overrides (see
      `home_dir/1`, `gitea_url/1`, `gitea_token/1`).

  Returns `:ok` always.
  """
  def ensure_repo(dir, opts \\ []) do
    if git_available?() do
      File.mkdir_p!(dir)

      unless git_repo?(dir) do
        init_repo(dir, opts)
      end

      ensure_remote(dir, Keyword.fetch!(opts, :repo_name), opts)
    else
      warn_once(:no_git, "MemoryGit: `git` executable not found — memory snapshotting disabled")
    end

    :ok
  end

  defp init_repo(dir, opts) do
    with {:ok, _} <- git(dir, ["init"], opts) do
      if Keyword.get(opts, :whitelist_memory?, false) do
        File.write!(Path.join(dir, ".gitignore"), @gitignore_content)
      end

      git(dir, ["add", "-A"], opts)

      if dirty?(dir, opts) do
        commit(dir, "snapshot: initial commit", opts)
      end
    else
      {:error, reason} ->
        warn_once(:git_init, "MemoryGit: `git init` failed in #{dir}: #{reason}")
    end
  end

  defp ensure_remote(dir, repo_name, opts) do
    case git(dir, ["remote", "get-url", "origin"], opts) do
      {:ok, _url} ->
        # Already configured (by us on a prior run, or by hand) — leave it alone.
        :ok

      {:error, _} ->
        create_and_add_remote(dir, repo_name, opts)
    end
  end

  defp create_and_add_remote(dir, repo_name, opts) do
    with {:ok, url} <- gitea_base_url(opts),
         {:ok, token} <- gitea_token(opts),
         :ok <- ensure_gitea_repo(url, token, repo_name, opts) do
      remote_url = push_url(url, token, repo_name)
      git(dir, ["remote", "add", "origin", remote_url], opts)
      :ok
    else
      {:error, :not_configured} ->
        warn_once(
          :gitea_not_configured,
          "MemoryGit: ORCA_GITEA_URL/ORCA_GITEA_TOKEN not set on this node — " <>
            "memory snapshots stay local-only (no push)"
        )

      {:error, reason} ->
        warn_once(
          :gitea_remote,
          "MemoryGit: could not set up Gitea remote for #{repo_name}: #{inspect(reason)}"
        )
    end
  end

  defp push_url(base_url, token, repo_name) do
    uri = URI.parse(base_url)

    %{uri | userinfo: token}
    |> URI.to_string()
    |> Path.join(@gitea_org)
    |> Path.join("#{repo_name}.git")
  end

  # -------------------------------------------------------------------
  # Gitea API (best-effort — every failure is `{:error, _}`, never raises)
  # -------------------------------------------------------------------

  defp ensure_gitea_repo(base_url, token, repo_name, opts) do
    case gitea_request(:get, base_url, "/api/v1/repos/#{@gitea_org}/#{repo_name}", token, opts) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        create_gitea_repo(base_url, token, repo_name, opts)

      {:ok, %{status: status}} ->
        {:error, "Gitea repo lookup returned HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_gitea_repo(base_url, token, repo_name, opts) do
    body = %{"name" => repo_name, "private" => true, "auto_init" => false}

    case gitea_request(:post, base_url, "/api/v1/orgs/#{@gitea_org}/repos", token, opts,
           json: body
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "create repo HTTP #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp gitea_request(method, base_url, path, token, opts, extra_opts \\ []) do
    url = String.trim_trailing(base_url, "/") <> path
    headers = [{"authorization", "token #{token}"}]
    req_opts = [method: method, url: url, headers: headers] ++ extra_opts ++ req_opts(opts)

    case Req.request(req_opts) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req_opts(opts) do
    Keyword.get(opts, :req_options) || Application.get_env(:orca_hub, :memory_git_req_options, [])
  end

  # -------------------------------------------------------------------
  # snapshot
  # -------------------------------------------------------------------

  @doc """
  Commits `dir` if it has any dirty tracked changes (`git add -A` + commit),
  then best-effort pushes to `origin`. A clean tree, a missing remote, or an
  unreachable Gitea are all normal, silent (or rate-limited-warned) no-ops —
  never an error to the caller. Returns `:ok` always.
  """
  def snapshot(dir, message, opts \\ []) do
    if git_available?() and git_repo?(dir) do
      git(dir, ["add", "-A"], opts)

      if dirty?(dir, opts) do
        commit(dir, message, opts)
      end

      push(dir, opts)
    end

    :ok
  end

  defp dirty?(dir, opts) do
    case git(dir, ["status", "--porcelain"], opts) do
      {:ok, ""} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp commit(dir, message, opts) do
    case git(dir, ["commit", "-m", message], opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        warn_once(:git_commit, "MemoryGit: commit failed in #{dir}: #{reason}")
    end
  end

  defp push(dir, opts) do
    case git(dir, ["remote", "get-url", "origin"], opts) do
      {:error, _} ->
        # No remote configured (never wired up, or ensure_repo already
        # warned about missing Gitea creds) — nothing to push to.
        :ok

      {:ok, _url} ->
        case git(dir, ["rev-parse", "--abbrev-ref", "HEAD"], opts) do
          {:ok, branch} ->
            case git(dir, ["push", "origin", String.trim(branch)], opts) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                warn_once(:git_push, "MemoryGit: push failed for #{dir}: #{reason}")
            end

          {:error, reason} ->
            warn_once(:git_push, "MemoryGit: could not resolve branch in #{dir}: #{reason}")
        end
    end
  end

  # -------------------------------------------------------------------
  # git plumbing
  # -------------------------------------------------------------------

  @doc false
  def git_available?, do: System.find_executable("git") != nil

  defp git_repo?(dir), do: File.dir?(Path.join(dir, ".git"))

  defp git(dir, args, opts) do
    case System.cmd("git", args, cd: dir, env: git_env(opts), stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  # Fixed author/committer identity (this is automation, not a human) so
  # commits work even on a node whose global git config never set
  # user.name/user.email. Also scrubs global-config lookup to the injected
  # home dir in tests, mirroring OrcaHub.GlobalGitignore.
  defp git_env(opts) do
    identity = [
      {"GIT_AUTHOR_NAME", "OrcaHub"},
      {"GIT_AUTHOR_EMAIL", "orca-hub@localhost"},
      {"GIT_COMMITTER_NAME", "OrcaHub"},
      {"GIT_COMMITTER_EMAIL", "orca-hub@localhost"}
    ]

    case Keyword.get(opts, :home_dir) || Application.get_env(:orca_hub, :memory_git_home) do
      nil -> identity
      home -> identity ++ [{"HOME", home}, {"XDG_CONFIG_HOME", nil}, {"GIT_CONFIG_GLOBAL", nil}]
    end
  end

  # -------------------------------------------------------------------
  # Config (injectable — see moduledoc)
  # -------------------------------------------------------------------

  defp home_dir(opts) do
    Keyword.get(opts, :home_dir) ||
      Application.get_env(:orca_hub, :memory_git_home) ||
      System.user_home!()
  end

  defp gitea_base_url(opts) do
    case Keyword.get(opts, :gitea_url) || Application.get_env(:orca_hub, :gitea_url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :not_configured}
    end
  end

  defp gitea_token(opts) do
    case Keyword.get(opts, :gitea_token) || Application.get_env(:orca_hub, :gitea_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_configured}
    end
  end

  @doc "Whether MemoryGit's automatic idle-triggered snapshotting should run — off in `config/test.exs`."
  def enabled? do
    Application.get_env(:orca_hub, :memory_git_enabled, true)
  end

  # -------------------------------------------------------------------
  # Rate-limited warning logs
  # -------------------------------------------------------------------

  defp warn_once(key, message) do
    pt_key = {:memory_git_warned_at, key}
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(pt_key, nil)

    if is_nil(last) or now - last >= @warn_rate_limit_ms do
      :persistent_term.put(pt_key, now)
      Logger.warning(message)
    end
  end
end
