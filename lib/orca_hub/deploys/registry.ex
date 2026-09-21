defmodule OrcaHub.Deploys.Registry do
  @moduledoc """
  The catalogue of deployable targets, plus the argument validation that
  stands between an LLM-authored tool call and a production deploy.

  See `.context/deploy-jobs-design.md` §2.4. Two things live here and
  nothing else — this module has no DB access, takes no lease and launches
  no job (that is `OrcaHub.Deploys`):

  1. **The target map.** A checked-in default (the three deploy scripts that
     exist in the private `~/homelab/scripts/` repo) deep-merged with
     `Application.get_env(:orca_hub, :deploy_targets, %{})`, so a fourth
     target can be added in config without a code change. A DB table was
     rejected: three rows that change roughly never, no lifecycle, no UI,
     and it would put host-specific private-repo paths in the database.

  2. **Argument validation.** `allowed_flags` is an **exact-match
     allow-list, not a parser** — anything not in the list is refused before
     launch. This is defence against shell injection on an LLM-reachable
     production-deploy trigger, NOT a re-modelling of each script's
     semantics: we deliberately do not know or care which flag combinations
     make sense. The single optional positional is validated by SHAPE, and
     every composed piece is shell-quoted with `OrcaHub.Jobs.Paths.shq/1`.

  ## The `node` field

  The registry stores an Erlang node name as a string, matched against
  `jobs.runner_node` (`Atom.to_string(node())`). A deploy is the single most
  host-specific action in the system (sops keys, ssh trust, buildx nodes,
  systemd units), so it is pinned to a node and **never re-routed** — an
  offline node is a refusal, not a fallback.

  The default is resolved from `node()` **at call time** rather than baked
  into the map, because the literal differs per host (this host is
  `debian@192.168.1.177`, built by `rel/env.sh.eex` from `NODE_NAME`; an
  earlier draft of the design doc guessed `orca@debian`, which is wrong and
  would produce a confusing `node_unavailable` refusal for a healthy host).

  Caveat worth stating rather than glossing: "the evaluating node" is the
  right default only when the registry is consulted on the host that can
  actually deploy. On a multi-node cluster, an agent node would resolve the
  default to *itself*. Pin it explicitly in config when that matters:

      config :orca_hub, deploy_targets: %{
        "orca_hub" => %{node: "debian@192.168.1.177"}
      }

  ## Config override shape

  The override is deep-merged per target, so a config entry names only the
  keys it changes:

      config :orca_hub, deploy_targets: %{
        "orca_hub" => %{ttl_seconds: 7200},
        "some-new-app" => %{
          name: "Some New App",
          command: "/home/zach/homelab/scripts/deploy-some-new-app.sh",
          directory: "/home/zach/some-new-app",
          allowed_flags: ~w(--dry-run),
          positional: :ref
        }
      }
  """

  alias OrcaHub.Jobs.Paths

  # Shape regexes for the single optional positional (§2.4).
  @version_re ~r/^[0-9]+\.[0-9]+\.[0-9]+$/
  @ref_re ~r/^[A-Za-z0-9._\/-]+$/

  # A positional is never a flag. The design's `:ref` shape alone would
  # accept "--force" (every character is in [A-Za-z0-9._/-]), which would
  # smuggle an argument past the allow-list by riding in the positional
  # slot. Leading "-" is refused for every positional kind.
  @max_positional_length 200

  @default_targets %{
    "orca_hub" => %{
      name: "OrcaHub",
      command: "/home/zach/homelab/scripts/deploy-orca-hub.sh",
      directory: "/home/zach/orca_hub",
      allowed_flags: ~w(--skip-push --skip-build --skip-local --skip-k3s
                        --skip-env --skip-mini --skip-gb10 --skip-arm64
                        --allow-dirty),
      positional: :none,
      # §2.3 — this script restarts its own hub at step 7, so its job must
      # be launched outside the systemd cgroup or the restart kills it.
      escape_cgroup: true,
      ttl_seconds: 5400,
      timeout_seconds: 5400,
      verify_command: "/home/zach/homelab/scripts/verify-orca-deploy.sh"
    },
    "content-studio" => %{
      name: "Content Studio",
      command: "/home/zach/homelab/scripts/deploy-content-studio.sh",
      directory: "/home/zach/circus-of-puffins/voice_prompt",
      allowed_flags: ~w(--show --status --major --minor --dry-run
                        --allow-dirty --skip-build),
      positional: :version,
      escape_cgroup: false,
      ttl_seconds: 2700,
      timeout_seconds: 2700,
      verify_command: nil
    },
    "video-search" => %{
      name: "Video Search",
      command: "/home/zach/homelab/scripts/deploy-video-search.sh",
      directory: "/home/zach/dell/elastic-video-search",
      allowed_flags: ~w(--dry-run --force --skip-build --no-lockfile-rewrite),
      positional: :ref,
      escape_cgroup: false,
      ttl_seconds: 2700,
      timeout_seconds: 2700,
      verify_command: nil
    }
  }

  @doc """
  The checked-in defaults, before the config override and before `node` is
  resolved. Exposed for tests and for showing what shipped in code.
  """
  def default_targets, do: @default_targets

  @doc """
  Every target, deep-merged with `:deploy_targets` config and with each
  entry's `node` resolved (config value if given, else this node).
  """
  def all do
    @default_targets
    |> deep_merge(Application.get_env(:orca_hub, :deploy_targets, %{}))
    |> Map.new(fn {key, config} -> {key, Map.put_new(config, :node, default_node())} end)
  end

  @doc "Registry keys, sorted — what `list_deploy_targets` enumerates."
  def keys, do: all() |> Map.keys() |> Enum.sort()

  @doc """
  Look a target up by key.

      iex> {:ok, t} = OrcaHub.Deploys.Registry.fetch("orca_hub")
      iex> t.escape_cgroup
      true

      iex> OrcaHub.Deploys.Registry.fetch("nope")
      {:error, :unknown_target}
  """
  def fetch(target) when is_binary(target) do
    case Map.fetch(all(), target) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :unknown_target}
    end
  end

  def fetch(_), do: {:error, :unknown_target}

  @doc """
  This node's name as a string, the default for a target that does not pin
  one in config. See the moduledoc's caveat.
  """
  def default_node, do: Atom.to_string(node())

  @doc """
  Confirm the target's script is actually on this filesystem and executable.

  §2.7: checked **before** the lease is taken, so a typo or a missing
  private-repo checkout cannot hold the mutex. Kept separate from
  `build_command/2` so command composition stays a pure function.
  """
  def check_script(%{command: command}) do
    cond do
      not File.exists?(command) -> {:error, :script_missing, command}
      not executable?(command) -> {:error, :script_not_executable, command}
      true -> :ok
    end
  end

  def check_script(target) when is_binary(target) do
    with {:ok, config} <- fetch(target), do: check_script(config)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @doc """
  Validate `flags` against the target's exact-match allow-list.

  Returns `{:ok, flags}` or `{:error, :disallowed_flag, details}`, where
  `details` echoes the offending flag and the full allow-list so the refusal
  can tell the caller what it *could* have passed.
  """
  def validate_flags(config, flags)

  def validate_flags(%{allowed_flags: allowed}, flags) when is_list(flags) do
    case Enum.find(flags, &(not (is_binary(&1) and &1 in allowed))) do
      nil -> {:ok, flags}
      bad -> {:error, :disallowed_flag, %{flag: to_string_safe(bad), allowed_flags: allowed}}
    end
  end

  def validate_flags(%{allowed_flags: allowed}, flags) do
    {:error, :disallowed_flag,
     %{
       flag: to_string_safe(flags),
       allowed_flags: allowed,
       reason: "flags must be a list of strings"
     }}
  end

  @doc """
  Validate the single optional positional against the target's shape.

  `nil` (or `""`) is always valid — every target's positional is optional.
  A target with `positional: :none` refuses any value at all.
  """
  def validate_positional(config, positional)

  def validate_positional(_config, nil), do: {:ok, nil}
  def validate_positional(config, ""), do: validate_positional(config, nil)

  def validate_positional(%{positional: kind} = config, value) when is_binary(value) do
    cond do
      kind == :none ->
        invalid(config, value, "this target takes no positional argument")

      String.length(value) > @max_positional_length ->
        invalid(config, value, "longer than #{@max_positional_length} characters")

      String.starts_with?(value, "-") ->
        # Would otherwise be parsed as a flag by the script, smuggling an
        # argument past `allowed_flags`.
        invalid(config, value, "must not start with '-'")

      kind == :version and not Regex.match?(@version_re, value) ->
        invalid(config, value, "expected a version like 1.2.3")

      kind == :ref and not Regex.match?(@ref_re, value) ->
        invalid(config, value, "expected a git ref matching [A-Za-z0-9._/-]+")

      true ->
        {:ok, value}
    end
  end

  def validate_positional(config, value), do: invalid(config, value, "must be a string")

  defp invalid(config, value, why) do
    {:error, :invalid_positional,
     %{value: to_string_safe(value), positional: Map.get(config, :positional), reason: why}}
  end

  @doc """
  Validate `flags`/`positional` and compose the shell-safe command line.

  Options: `:flags` (list of strings, default `[]`) and `:positional`
  (string or `nil`).

  On success returns `{:ok, %{target:, config:, argv:, command:}}`:

    * `argv` — the raw, unquoted parts (`[script, flag..., positional]`);
      the human-readable form for tool output and `note`s.
    * `command` — the same parts run through `OrcaHub.Jobs.Paths.shq/1` and
      joined. This is the string to execute; it is safe to interpolate into
      an `sh -c` argument, which is what the `escape_cgroup` wrapper does.

  Composing the wrapper (`ssh … 'cd <dir> && …'`) is `OrcaHub.Deploys`' job,
  not this module's.
  """
  def build_command(target, opts \\ [])

  def build_command(target, opts) when is_binary(target) do
    with {:ok, config} <- fetch(target),
         do: build_command(config, Keyword.put(opts, :target, target))
  end

  def build_command(%{command: script} = config, opts) do
    flags = Keyword.get(opts, :flags) || []
    positional = Keyword.get(opts, :positional)

    with {:ok, flags} <- validate_flags(config, flags),
         {:ok, positional} <- validate_positional(config, positional) do
      argv = [script] ++ flags ++ List.wrap(positional)

      {:ok,
       %{
         target: Keyword.get(opts, :target),
         config: config,
         argv: argv,
         command: argv |> Enum.map(&Paths.shq/1) |> Enum.join(" ")
       }}
    end
  end

  @doc """
  Recursive map merge — the config override replaces scalars and lists but
  keeps every default key it does not mention.
  """
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r when not is_struct(l) and not is_struct(r) -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)
end
