defmodule OrcaHub.NodeConfig do
  @moduledoc """
  Reads/writes the GLOBAL (per-OS-user) config files each agent-CLI backend
  accumulates on a node, so `NodeLive.Show` can browse/view/create/raw-edit
  them. This is distinct from `OrcaHub.AgentMemory`, which covers
  per-project auto-memory stores — this module covers each backend's
  static, node-wide configuration (settings, instructions, skills, etc).

  The catalog of paths, formats, create templates, and safety notes below is
  the validated result of `docs/node_config_catalog.md` — read that doc for
  the research/sourcing behind every entry. Three backends are covered:

    * **`:claude`** — `~/.claude/`
    * **`:codex`** — `~/.codex/`
    * **`:pi`** — `~/.pi/agent/`

  Every function here is meant to be invoked via `OrcaHub.Cluster.rpc/4` so
  it executes ON THE TARGET NODE — `System.user_home!/0` must resolve to
  that node's home directory, not the hub's. For tests, the base "home"
  directory is injectable via the `:home_dir` option or the
  `:orca_hub, :node_config_home` Application env (checked in that order,
  falling back to `System.user_home!/0`), mirroring `OrcaHub.AgentMemory`.

  ## Path safety

  Every function that takes a `path` (relative to the backend's home root,
  e.g. `"CLAUDE.md"`, `"skills/my-skill/SKILL.md"`) validates it against
  this module's catalog before touching disk:

    * Absolute paths, `..` segments, and any path segment starting with `.`
      (blocks vendor-owned subdirectories like Codex's `skills/.system/`)
      are rejected outright.
    * The path must resolve to a known catalog file entry, or a valid
      direct child of a known catalog directory entry (one flat file for
      `:flat` dirs, or `<skill>/SKILL.md` for `:skill_dirs`).
    * A hard-coded blocklist (`.credentials.json`, `auth.json`) is checked
      before catalog lookup and refuses those paths even if a caller passes
      them explicitly — these are never listed, read, or written, no matter
      what the catalog otherwise allows.
    * Catalog entries flagged `:view_only` (pi's `trust.json`) refuse
      `write_entry/4` and `delete_entry/3` with `{:error, :view_only}`.
  """

  alias OrcaHub.Backend

  @claude_home ".claude"
  @codex_home ".codex"
  @pi_home Path.join(".pi", "agent")

  @json_settings_template """
  {
    "$schema": "https://json.schemastore.org/claude-code-settings.json"
  }
  """

  @keybindings_template """
  {
    "$schema": "https://json.schemastore.org/claude-code-keybindings.json",
    "bindings": []
  }
  """

  @pi_extension_template """
  // pi ExtensionAPI module — see pi's docs for available hooks.
  export default function activate(api) {
    // api.registerTool(...), api.on(...), etc.
  }
  """

  @catalog %{
    claude: [
      %{
        path: "CLAUDE.md",
        kind: :file,
        format: :markdown,
        label: "CLAUDE.md",
        create_template: "# Personal instructions\n\n- \n",
        flags: []
      },
      %{
        path: "settings.json",
        kind: :file,
        format: :json,
        label: "settings.json",
        create_template: @json_settings_template,
        flags: []
      },
      %{
        path: "settings.local.json",
        kind: :file,
        format: :json,
        label: "settings.local.json",
        create_template: @json_settings_template,
        flags: []
      },
      %{
        path: "keybindings.json",
        kind: :file,
        format: :json,
        label: "keybindings.json",
        create_template: @keybindings_template,
        flags: []
      },
      %{
        path: "agents",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "agents/",
        create_template: """
        ---
        name: my-agent
        description: When to use this subagent.
        tools: Read, Grep, Glob
        ---

        System prompt for the subagent.
        """,
        flags: []
      },
      %{
        path: "skills",
        kind: :dir,
        dir_kind: :skill_dirs,
        skill_filename: "SKILL.md",
        format: :markdown,
        label: "skills/",
        create_template: """
        ---
        description: When Claude should use this skill.
        ---

        Instructions for Claude.
        """,
        flags: []
      },
      %{
        path: "commands",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "commands/",
        create_template: """
        ---
        description: What this command does.
        ---

        Instructions.
        """,
        flags: [:legacy]
      },
      %{
        path: "rules",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "rules/",
        create_template: "# Topic\n\n- Rule 1\n- Rule 2\n",
        flags: []
      }
    ],
    codex: [
      %{
        path: "config.toml",
        kind: :file,
        format: :toml,
        label: "config.toml",
        create_template:
          "# Codex config — see https://developers.openai.com/codex/config-reference\n",
        flags: []
      },
      %{
        path: "AGENTS.md",
        kind: :file,
        format: :markdown,
        label: "AGENTS.md",
        create_template: "# Instructions\n\n- \n",
        flags: []
      },
      %{
        path: "AGENTS.override.md",
        kind: :file,
        format: :markdown,
        label: "AGENTS.override.md",
        create_template: "# Instructions\n\n- \n",
        flags: []
      },
      %{
        path: "rules",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "rules/",
        create_template: "# Topic\n\n- Rule\n",
        flags: []
      },
      %{
        path: "prompts",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "prompts/",
        create_template: """
        ---
        description: What this does.
        ---

        Prompt body with $ARGUMENTS.
        """,
        flags: [:deprecated]
      },
      %{
        path: "skills",
        kind: :dir,
        dir_kind: :skill_dirs,
        skill_filename: "SKILL.md",
        format: :markdown,
        label: "skills/",
        create_template: """
        ---
        name: my-skill
        description: When Codex should use this.
        ---

        Instructions.
        """,
        flags: []
      }
    ],
    pi: [
      %{
        path: "settings.json",
        kind: :file,
        format: :json,
        label: "settings.json",
        create_template: "{}\n",
        flags: []
      },
      %{
        path: "SYSTEM.md",
        kind: :file,
        format: :markdown,
        label: "SYSTEM.md",
        create_template: "# System prompt\n\n",
        flags: []
      },
      %{
        path: "extensions",
        kind: :dir,
        dir_kind: :flat,
        format: :code,
        label: "extensions/",
        create_template: @pi_extension_template,
        flags: [:code_caution]
      },
      %{
        path: "skills",
        kind: :dir,
        dir_kind: :skill_dirs,
        skill_filename: "SKILL.md",
        format: :markdown,
        label: "skills/",
        create_template: """
        ---
        name: my-skill
        description: When pi should use this.
        ---

        Instructions.
        """,
        flags: []
      },
      %{
        path: "prompts",
        kind: :dir,
        dir_kind: :flat,
        format: :markdown,
        label: "prompts/",
        create_template: "# Prompt\n\n",
        flags: []
      },
      %{
        path: "themes",
        kind: :dir,
        dir_kind: :flat,
        format: :other,
        label: "themes/",
        create_template: nil,
        flags: []
      },
      %{
        path: "trust.json",
        kind: :file,
        format: :json,
        label: "trust.json",
        create_template: nil,
        flags: [:view_only]
      }
    ]
  }

  # Never listed, read, or written — checked before catalog lookup so a
  # caller can't reach these via a crafted path even if the catalog logic
  # above had a bug.
  @blocklist %{
    claude: [".credentials.json"],
    codex: ["auth.json"],
    pi: ["auth.json"]
  }

  @doc "The three supported backend keys, in catalog/UI display order."
  def backends, do: [:claude, :codex, :pi]

  @doc "This backend's global config home directory on this node."
  def home_root(backend, opts \\ [])
  def home_root(:claude, opts), do: Path.join(base_home(opts), @claude_home)
  def home_root(:codex, opts), do: Path.join(base_home(opts), @codex_home)
  def home_root(:pi, opts), do: Path.join(base_home(opts), @pi_home)

  @doc """
  Best-effort check for whether `backend`'s CLI is installed on this node
  (delegates to the backend adapter's own `installed?/0`, e.g.
  `System.find_executable/1` plus the same executable-override env vars the
  session runner itself honors). Never raises — an unresolvable backend
  reads as "not installed" rather than crashing the caller.
  """
  def cli_installed?(backend, _opts \\ []) when backend in [:claude, :codex, :pi] do
    backend |> Atom.to_string() |> Backend.resolve() |> apply(:installed?, [])
  rescue
    _ -> false
  end

  @doc """
  Lists `backend`'s full catalog with on-disk status. Returns
  `%{backend:, home:, installed?:, entries: [...]}` (plus
  `agents_override_conflict?: boolean` for `:codex`, flagging when both
  `AGENTS.md` and `AGENTS.override.md` exist — the override silently
  replaces the base file rather than merging with it).

  Each file entry is `%{path:, kind: :file, format:, label:, create_template:,
  flags:, exists?:}`. Each dir entry additionally has `dir_kind:`
  (`:flat` or `:skill_dirs`), `exists?:`, and `children:` (`[]` when the
  dir doesn't exist yet — the caller offers a "Create directory"
  affordance instead of listing).

  `:flat` dir children are `%{name:, path:}`. `:skill_dirs` children are
  `%{name:, path:, exists?:}` — one entry per subdirectory found (excluding
  dot-prefixed vendor subdirs like Codex's `.system/`), `path` pointing at
  that skill's `SKILL.md` and `exists?` reflecting whether that file is
  actually present yet.
  """
  def list_config(backend, opts \\ []) when backend in [:claude, :codex, :pi] do
    home = home_root(backend, opts)
    entries = Enum.map(catalog(backend), &entry_status(home, &1))

    base = %{
      backend: backend,
      home: home,
      installed?: cli_installed?(backend, opts),
      entries: entries
    }

    if backend == :codex do
      Map.put(base, :agents_override_conflict?, agents_override_conflict?(entries))
    else
      base
    end
  end

  @doc "Reads a single config entry's raw content."
  def read_entry(backend, path, opts \\ []) do
    with {:ok, full, _entry} <- resolve_path(backend, path, opts) do
      File.read(full)
    end
  end

  @doc """
  Overwrites (or creates) a single config entry's raw content. Creates
  parent directories as needed, so this also covers "Create" for a
  currently-missing catalog file or a new dir child.
  """
  def write_entry(backend, path, content, opts \\ []) do
    with {:ok, full, entry} <- resolve_path(backend, path, opts),
         :ok <- check_writable(entry) do
      File.mkdir_p!(Path.dirname(full))
      File.write(full, content)
    end
  end

  @doc "Deletes a single config entry."
  def delete_entry(backend, path, opts \\ []) do
    with {:ok, full, entry} <- resolve_path(backend, path, opts),
         :ok <- check_writable(entry) do
      File.rm(full)
    end
  end

  @doc """
  Creates an empty catalog directory (e.g. `agents/`) that doesn't exist
  yet, so a subsequent `write_entry/4` has somewhere to land — mostly
  redundant with `write_entry/4`'s own `mkdir_p!`, but lets the UI offer a
  bare "Create directory" affordance before any child file is named.
  """
  def create_directory(backend, dir_path, opts \\ []) when backend in [:claude, :codex, :pi] do
    case Enum.find(catalog(backend), &(&1.kind == :dir and &1.path == dir_path)) do
      nil -> {:error, :unknown_path}
      _entry -> File.mkdir_p(Path.join(home_root(backend, opts), dir_path))
    end
  end

  # -------------------------------------------------------------------
  # Catalog helpers
  # -------------------------------------------------------------------

  defp catalog(backend), do: Map.fetch!(@catalog, backend)

  defp entry_status(home, %{kind: :file} = entry) do
    Map.put(entry, :exists?, File.regular?(Path.join(home, entry.path)))
  end

  defp entry_status(home, %{kind: :dir} = entry) do
    full = Path.join(home, entry.path)
    exists? = File.dir?(full)

    entry
    |> Map.put(:exists?, exists?)
    |> Map.put(:children, if(exists?, do: dir_children(full, entry), else: []))
  end

  defp dir_children(full, %{dir_kind: :flat} = entry) do
    full
    |> File.ls!()
    |> Enum.filter(fn name -> not hidden?(name) and File.regular?(Path.join(full, name)) end)
    |> Enum.sort()
    |> Enum.map(fn name -> %{name: name, path: Path.join(entry.path, name)} end)
  end

  defp dir_children(full, %{dir_kind: :skill_dirs, skill_filename: skill_filename} = entry) do
    full
    |> File.ls!()
    |> Enum.filter(fn name -> not hidden?(name) and File.dir?(Path.join(full, name)) end)
    |> Enum.sort()
    |> Enum.map(fn name ->
      skill_path = Path.join([entry.path, name, skill_filename])

      %{
        name: name,
        path: skill_path,
        exists?: File.regular?(Path.join(full, [name, "/", skill_filename]))
      }
    end)
  end

  defp hidden?(name), do: String.starts_with?(name, ".")

  defp agents_override_conflict?(entries) do
    agents = Enum.find(entries, &(&1.path == "AGENTS.md"))
    override = Enum.find(entries, &(&1.path == "AGENTS.override.md"))
    !!(agents && agents.exists? && override && override.exists?)
  end

  # -------------------------------------------------------------------
  # Path resolution / safety
  # -------------------------------------------------------------------

  defp resolve_path(backend, path, opts) when backend in [:claude, :codex, :pi] do
    with :ok <- check_blocklist(backend, path),
         :ok <- validate_relative_path(path),
         {:ok, entry} <- catalog_lookup(backend, path) do
      {:ok, Path.join(home_root(backend, opts), path), entry}
    end
  end

  defp validate_relative_path(path) when is_binary(path) and path != "" do
    if Path.type(path) == :relative do
      segments = Path.split(path)

      if ".." in segments or Enum.any?(segments, &hidden?/1) do
        {:error, :unsafe_path}
      else
        :ok
      end
    else
      {:error, :unsafe_path}
    end
  end

  defp validate_relative_path(_), do: {:error, :unsafe_path}

  defp check_blocklist(backend, path) do
    if path in Map.get(@blocklist, backend, []), do: {:error, :blocked}, else: :ok
  end

  defp catalog_lookup(backend, path) do
    entries = catalog(backend)

    case Enum.find(entries, &(&1.kind == :file and &1.path == path)) do
      nil -> catalog_child_lookup(entries, path)
      entry -> {:ok, entry}
    end
  end

  defp catalog_child_lookup(entries, path) do
    Enum.find_value(entries, {:error, :unknown_path}, &child_match(&1, path))
  end

  defp child_match(%{kind: :dir, dir_kind: :flat} = entry, path) do
    prefix = entry.path <> "/"

    if String.starts_with?(path, prefix) do
      rest = String.replace_prefix(path, prefix, "")
      if rest != "" and not String.contains?(rest, "/"), do: {:ok, entry}
    end
  end

  defp child_match(
         %{kind: :dir, dir_kind: :skill_dirs, skill_filename: skill_filename} = entry,
         path
       ) do
    prefix = entry.path <> "/"

    if String.starts_with?(path, prefix) do
      rest = String.replace_prefix(path, prefix, "")

      case Path.split(rest) do
        [skill_name, ^skill_filename] when skill_name != "" -> {:ok, entry}
        _ -> nil
      end
    end
  end

  defp child_match(_entry, _path), do: nil

  defp check_writable(%{flags: flags}) do
    if :view_only in flags, do: {:error, :view_only}, else: :ok
  end

  # Injectable base "home" dir — see OrcaHub.AgentMemory for the same
  # pattern (explicit opt, then Application env override for tests, then
  # the real home directory).
  defp base_home(opts) do
    Keyword.get(opts, :home_dir) ||
      Application.get_env(:orca_hub, :node_config_home) ||
      System.user_home!()
  end
end
