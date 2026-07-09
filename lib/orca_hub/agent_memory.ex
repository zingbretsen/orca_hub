defmodule OrcaHub.AgentMemory do
  @moduledoc """
  Reads/writes the durable memory stores that agent CLIs accumulate for a
  project, so `ProjectLive.Show` can review/edit them.

  Three sources, per `agent-memory-locations` (see repo Claude memory):

    * **Claude Code** — `~/.claude/projects/<slug>/memory/` on the project's
      node, where `<slug>` is `project.directory` with every
      non-alphanumeric char replaced by `-`. Contains a `MEMORY.md` index
      (one markdown list line per memory, linking to its file) plus one
      `*.md` file per memory with YAML frontmatter (`name`, `description`,
      `metadata.type`) and a markdown body.
    * **AGENTS.md `## Project memory` section**, in the project directory —
      shared store read by Codex and pi. Checked into git; edits here just
      modify the working tree.
    * **Codex native memories** — `~/.codex/memories/` on the project's
      node. Only populated if Codex's built-in memories feature is enabled
      (off by default, via `[features]\nmemories = true` in
      `~/.codex/config.toml`); the missing-dir case is expected, not an
      error. Contains flat files (canonically `MEMORY.md`,
      `memory_summary.md`, `raw_memories.md`) plus three known
      subdirectories one level deep: `rollout_summaries/`, `skills/`, and
      `memories_extensions/`. **These memories are GLOBAL to the node's
      current OS user, not scoped to any one project** — every project
      routed to the same node shares (and can edit/delete) the same
      Codex memory files.

  pi has no memory store of its own — it reads AGENTS.md and, via an
  extension, the Claude MEMORY.md index.

  Every function here is meant to be invoked via `OrcaHub.Cluster.rpc/4` so
  it executes ON THE PROJECT'S OWNING NODE — `System.user_home!/0` must
  resolve to that node's home directory, not the hub's. For tests, the base
  "home" directory is injectable via the `:home_dir` option or the
  `:orca_hub, :agent_memory_home` Application env (checked in that order,
  falling back to `System.user_home!/0`) so tests never touch a real
  `~/.claude` or `~/.codex`.

  **Path safety**: every function that takes a bare filename rejects
  filenames containing `/` or `..` — operations are confined to the memory
  directory (or the single AGENTS.md file for that group). User-supplied
  absolute paths are never followed.
  """

  @claude_index_filename "MEMORY.md"
  @codex_memories_subpath ".codex/memories"
  @project_memory_heading "## Project memory"

  # -------------------------------------------------------------------
  # Claude Code memories
  # -------------------------------------------------------------------

  @doc """
  Computes `~/.claude/projects/<slug>/memory` for `project_directory`.
  """
  def claude_memory_dir(project_directory, opts \\ []) do
    Path.join([home_dir(opts), ".claude", "projects", slugify(project_directory), "memory"])
  end

  @doc """
  Turns a project directory path into the slug Claude Code uses under
  `~/.claude/projects/` — every char that isn't `[A-Za-z0-9]` becomes `-`.
  """
  def slugify(path), do: String.replace(path, ~r/[^A-Za-z0-9]/, "-")

  @doc """
  Lists Claude Code memories for a project.

  Returns `{:ok, %{index: index_content, memories: [...], orphaned: [...],
  dangling: [...]}}` or `{:error, :no_memory_dir}` if the memory directory
  doesn't exist on this node.

  Each entry in `memories` is `%{filename, name, description, type,
  content}`. `orphaned` lists filenames present on disk but not linked from
  `MEMORY.md`; `dangling` lists `MEMORY.md` link targets with no matching
  file. Memories linked from the index come first (in index order),
  followed by any orphaned files.
  """
  def list_claude_memories(project_directory, opts \\ []) do
    dir = claude_memory_dir(project_directory, opts)

    if File.dir?(dir) do
      index_content =
        case File.read(Path.join(dir, @claude_index_filename)) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      linked_filenames = extract_index_links(index_content)

      disk_filenames =
        dir
        |> File.ls!()
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != @claude_index_filename))
        |> Enum.sort()

      ordered_filenames =
        Enum.filter(linked_filenames, &(&1 in disk_filenames)) ++
          (disk_filenames -- linked_filenames)

      memories =
        Enum.map(ordered_filenames, fn filename ->
          content = File.read!(Path.join(dir, filename))
          {frontmatter, _body} = parse_frontmatter(content)

          %{
            filename: filename,
            name: Map.get(frontmatter, "name", Path.rootname(filename)),
            description: Map.get(frontmatter, "description", ""),
            type: Map.get(frontmatter, "type"),
            content: content
          }
        end)

      {:ok,
       %{
         index: index_content,
         memories: memories,
         orphaned: disk_filenames -- linked_filenames,
         dangling: linked_filenames -- disk_filenames
       }}
    else
      {:error, :no_memory_dir}
    end
  end

  @doc "Overwrites (or creates) a single Claude memory file's raw content."
  def save_claude_memory(project_directory, filename, content, opts \\ []) do
    with :ok <- validate_safe_filename(filename) do
      dir = claude_memory_dir(project_directory, opts)
      File.mkdir_p!(dir)
      File.write(Path.join(dir, filename), content)
    end
  end

  @doc """
  Deletes a Claude memory file and removes its line from `MEMORY.md` (any
  line linking to `(filename)`).
  """
  def delete_claude_memory(project_directory, filename, opts \\ []) do
    with :ok <- validate_safe_filename(filename) do
      dir = claude_memory_dir(project_directory, opts)

      file_result =
        case File.rm(Path.join(dir, filename)) do
          :ok -> :ok
          # Already gone (e.g. deleting an already-dangling index entry) —
          # not fatal, we still want to clean up the index line below.
          {:error, :enoent} -> :ok
          error -> error
        end

      index_result = remove_from_index(dir, filename)

      case {file_result, index_result} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _} -> {:error, reason}
        {_, {:error, reason}} -> {:error, reason}
      end
    end
  end

  @doc "Overwrites the raw content of the `MEMORY.md` index file."
  def save_claude_index(project_directory, content, opts \\ []) do
    dir = claude_memory_dir(project_directory, opts)
    File.mkdir_p!(dir)
    File.write(Path.join(dir, @claude_index_filename), content)
  end

  defp remove_from_index(dir, filename) do
    index_path = Path.join(dir, @claude_index_filename)

    case File.read(index_path) do
      {:ok, content} ->
        new_content =
          content
          |> String.split("\n")
          |> Enum.reject(&String.contains?(&1, "(#{filename})"))
          |> Enum.join("\n")

        File.write(index_path, new_content)

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp extract_index_links(content) do
    ~r/\]\(([^)]+)\)/
    |> Regex.scan(content)
    |> Enum.map(fn [_, target] -> target end)
    |> Enum.uniq()
  end

  @doc """
  Lenient hand-rolled YAML-frontmatter parser (no YAML dependency) for a
  Claude memory file. Returns `{frontmatter_map, body}` where
  `frontmatter_map` may have `"name"`, `"description"`, and `"type"` (the
  latter flattened from `metadata.type`). Falls back to `{%{}, content}`
  for content with no `---`-delimited frontmatter block.
  """
  def parse_frontmatter(content) do
    lines = String.split(content, "\n")

    case lines do
      ["---" | rest] ->
        case Enum.split_while(rest, &(&1 != "---")) do
          {frontmatter_lines, ["---" | body_lines]} ->
            body =
              body_lines
              |> Enum.join("\n")
              |> String.trim_leading("\n")

            {parse_frontmatter_lines(frontmatter_lines), body}

          _ ->
            {%{}, content}
        end

      _ ->
        {%{}, content}
    end
  end

  defp parse_frontmatter_lines(lines) do
    {frontmatter, _current_key} =
      Enum.reduce(lines, {%{}, nil}, fn line, {acc, current_key} ->
        cond do
          Regex.match?(~r/^\S/, line) ->
            case Regex.run(~r/^([A-Za-z0-9_]+):\s*(.*)$/, line) do
              [_, key, raw_value] ->
                value = unquote_value(raw_value)
                if value == "", do: {acc, key}, else: {Map.put(acc, key, value), key}

              nil ->
                {acc, current_key}
            end

          current_key == "metadata" ->
            case Regex.run(~r/^\s+([A-Za-z0-9_]+):\s*(.*)$/, line) do
              [_, "type", raw_value] ->
                {Map.put(acc, "type", unquote_value(raw_value)), current_key}

              _ ->
                {acc, current_key}
            end

          true ->
            {acc, current_key}
        end
      end)

    frontmatter
  end

  defp unquote_value(raw_value) do
    value = String.trim(raw_value)

    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
         String.length(value) >= 2 do
      value
      |> String.slice(1..-2//1)
      |> String.replace("\\\"", "\"")
    else
      value
    end
  end

  # -------------------------------------------------------------------
  # AGENTS.md "## Project memory" section (shared by Codex & pi)
  # -------------------------------------------------------------------

  @doc """
  Lists the bullets in `project_directory`/AGENTS.md's `## Project memory`
  section. Returns `{:ok, [%{index: i, text: text}, ...]}`, `:no_section`
  if AGENTS.md exists but has no such section, or `:no_file` if AGENTS.md
  doesn't exist.
  """
  def list_agents_md_memories(project_directory) do
    path = agents_md_path(project_directory)

    if File.exists?(path) do
      lines = path |> File.read!() |> String.split("\n")

      case section_bounds(lines) do
        nil ->
          :no_section

        {start_idx, end_idx} ->
          bullets =
            lines
            |> bullet_line_indices(start_idx, end_idx)
            |> Enum.with_index()
            |> Enum.map(fn {line_idx, bullet_idx} ->
              %{index: bullet_idx, text: bullet_text(Enum.at(lines, line_idx))}
            end)

          {:ok, bullets}
      end
    else
      :no_file
    end
  end

  @doc """
  Replaces the text of bullet `index` (0-based, in document order) within
  the `## Project memory` section. Rewrites only that line; the rest of the
  file is preserved byte-for-byte.
  """
  def update_agents_md_memory(project_directory, index, text) do
    with_bullet_line(project_directory, index, fn lines, line_idx ->
      clean_text = text |> String.trim() |> String.replace("\n", " ")
      new_lines = List.replace_at(lines, line_idx, "- " <> clean_text)
      write_agents_md(project_directory, new_lines)
    end)
  end

  @doc """
  Removes bullet `index` (0-based) from the `## Project memory` section
  entirely. The rest of the file is preserved byte-for-byte.
  """
  def delete_agents_md_memory(project_directory, index) do
    with_bullet_line(project_directory, index, fn lines, line_idx ->
      new_lines = List.delete_at(lines, line_idx)
      write_agents_md(project_directory, new_lines)
    end)
  end

  defp with_bullet_line(project_directory, index, fun) do
    path = agents_md_path(project_directory)

    if File.exists?(path) do
      lines = path |> File.read!() |> String.split("\n")

      case section_bounds(lines) do
        nil ->
          {:error, :no_section}

        {start_idx, end_idx} ->
          case lines |> bullet_line_indices(start_idx, end_idx) |> Enum.at(index) do
            nil -> {:error, :invalid_index}
            line_idx -> fun.(lines, line_idx)
          end
      end
    else
      {:error, :no_file}
    end
  end

  defp write_agents_md(project_directory, lines) do
    File.write(agents_md_path(project_directory), Enum.join(lines, "\n"))
  end

  defp agents_md_path(project_directory), do: Path.join(project_directory, "AGENTS.md")

  defp section_bounds(lines) do
    case Enum.find_index(lines, &(String.trim_trailing(&1) == @project_memory_heading)) do
      nil ->
        nil

      start_idx ->
        end_idx =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, idx} -> idx > start_idx and String.starts_with?(line, "## ") end)
          |> case do
            {_line, idx} -> idx
            nil -> length(lines)
          end

        {start_idx, end_idx}
    end
  end

  defp bullet_line_indices(lines, start_idx, end_idx) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, idx} ->
      idx > start_idx and idx < end_idx and String.starts_with?(String.trim_leading(line), "- ")
    end)
    |> Enum.map(fn {_line, idx} -> idx end)
  end

  defp bullet_text(line), do: line |> String.trim_leading() |> String.trim_leading("- ")

  # -------------------------------------------------------------------
  # Codex native memories (~/.codex/memories/, feature usually off)
  # -------------------------------------------------------------------

  @codex_config_subpath ".codex/config.toml"
  @codex_canonical_files ["MEMORY.md", "memory_summary.md", "raw_memories.md"]
  @codex_known_subdirs ["rollout_summaries", "skills", "memories_extensions"]

  @doc "Path to `~/.codex/memories` on this node."
  def codex_memories_dir(opts \\ []), do: Path.join(home_dir(opts), @codex_memories_subpath)

  @doc """
  Best-effort check for whether Codex's built-in memories feature is
  enabled, via a plain string/regex scan of `~/.codex/config.toml` for
  `memories = true` inside a `[features]` table — no TOML dependency.
  Returns `false` if the config file is absent, unreadable, or the flag
  isn't set to `true`.
  """
  def codex_memories_enabled?(opts \\ []) do
    path = Path.join(home_dir(opts), @codex_config_subpath)

    case File.read(path) do
      {:ok, content} -> toml_bool_flag?(content, "features", "memories")
      {:error, _} -> false
    end
  end

  @doc """
  Lists Codex native memories. Returns `{:ok, [%{filename, group,
  content}, ...]}` or `{:error, :not_enabled}` if `~/.codex/memories/`
  doesn't exist (the normal case — Codex's built-in memories feature is a
  preview flag that's off by default; see `codex_memories_enabled?/1` to
  distinguish "not enabled" from "enabled, nothing consolidated yet").

  `filename` is the path relative to `~/.codex/memories/` — a bare name
  for top-level files, or `"<subdir>/<name>"` for the known subdirectories.
  `group` is `nil` for top-level files, else the subdir name. Canonical
  files (`MEMORY.md`, `memory_summary.md`, `raw_memories.md`) sort first
  in that order, then other top-level files alphabetically, then each
  known subdirectory's files alphabetically. Unknown subdirectories and
  sqlite state files are skipped.
  """
  def list_codex_memories(opts \\ []) do
    dir = codex_memories_dir(opts)

    if File.dir?(dir) do
      flat_files =
        dir
        |> File.ls!()
        |> Enum.filter(&codex_memory_file?(dir, &1))
        |> order_codex_flat_files()
        |> Enum.map(fn filename ->
          %{filename: filename, group: nil, content: File.read!(Path.join(dir, filename))}
        end)

      subdir_files =
        for subdir <- @codex_known_subdirs,
            subdir_path = Path.join(dir, subdir),
            File.dir?(subdir_path),
            filename <- subdir_path |> File.ls!() |> Enum.sort(),
            File.regular?(Path.join(subdir_path, filename)) do
          relative = Path.join(subdir, filename)
          %{filename: relative, group: subdir, content: File.read!(Path.join(dir, relative))}
        end

      {:ok, flat_files ++ subdir_files}
    else
      {:error, :not_enabled}
    end
  end

  # Filtering @codex_canonical_files (rather than `files`) keeps them in
  # canonical order automatically, since we walk the canonical list itself.
  defp order_codex_flat_files(files) do
    canonical = Enum.filter(@codex_canonical_files, &(&1 in files))
    canonical ++ Enum.sort(files -- @codex_canonical_files)
  end

  defp codex_memory_file?(dir, filename) do
    File.regular?(Path.join(dir, filename)) and not String.contains?(filename, "sqlite")
  end

  @doc "Reads a single Codex memory file's raw content (bare name or `<subdir>/<name>`)."
  def read_codex_memory(filename, opts \\ []) do
    with :ok <- validate_safe_codex_path(filename) do
      File.read(Path.join(codex_memories_dir(opts), filename))
    end
  end

  @doc "Overwrites (or creates) a single Codex memory file's raw content."
  def save_codex_memory(filename, content, opts \\ []) do
    with :ok <- validate_safe_codex_path(filename) do
      path = Path.join(codex_memories_dir(opts), filename)
      File.mkdir_p!(Path.dirname(path))
      File.write(path, content)
    end
  end

  @doc "Deletes a single Codex memory file."
  def delete_codex_memory(filename, opts \\ []) do
    with :ok <- validate_safe_codex_path(filename) do
      File.rm(Path.join(codex_memories_dir(opts), filename))
    end
  end

  # Accepts either a bare filename (validated like Claude's) or exactly one
  # known-subdir segment followed by a bare filename — still rejects `..`,
  # absolute paths, and any deeper nesting or unknown subdir.
  defp validate_safe_codex_path(path) when is_binary(path) do
    case String.split(path, "/") do
      [filename] ->
        validate_safe_filename(filename)

      [subdir, filename] when subdir in @codex_known_subdirs ->
        validate_safe_filename(filename)

      _ ->
        {:error, :unsafe_filename}
    end
  end

  defp validate_safe_codex_path(_), do: {:error, :unsafe_filename}

  # Naive `[section]`-scoped boolean lookup for a TOML file: finds the
  # `[section]` table header (bounded by the next `[...]` header or EOF)
  # and checks for `key = true` inside it. Deliberately simplistic — good
  # enough for the one flag we care about, not a general TOML parser.
  defp toml_bool_flag?(content, section, key) do
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &(String.trim(&1) == "[#{section}]")) do
      nil ->
        false

      start_idx ->
        end_idx =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, idx} ->
            idx > start_idx and Regex.match?(~r/^\[.*\]$/, String.trim(line))
          end)
          |> case do
            {_line, idx} -> idx
            nil -> length(lines)
          end

        lines
        |> Enum.slice((start_idx + 1)..(end_idx - 1)//1)
        |> Enum.any?(&Regex.match?(~r/^\s*#{Regex.escape(key)}\s*=\s*true\s*(#.*)?$/, &1))
    end
  end

  # -------------------------------------------------------------------
  # Shared helpers
  # -------------------------------------------------------------------

  # Injectable base "home" dir: explicit opt wins, then an Application env
  # override (used by tests so they never touch a real ~/.claude or
  # ~/.codex), then the real home directory.
  defp home_dir(opts) do
    Keyword.get(opts, :home_dir) ||
      Application.get_env(:orca_hub, :agent_memory_home) ||
      System.user_home!()
  end

  # Confines every filename-taking operation to its memory dir (or the
  # single AGENTS.md file, which doesn't go through this check since it
  # isn't a user-supplied filename) — rejects any attempt to escape via a
  # path separator or ".." component, and never follows an absolute path.
  defp validate_safe_filename(filename) when is_binary(filename) do
    if filename != "" and not String.contains?(filename, "/") and
         not String.contains?(filename, "..") do
      :ok
    else
      {:error, :unsafe_filename}
    end
  end

  defp validate_safe_filename(_), do: {:error, :unsafe_filename}
end
