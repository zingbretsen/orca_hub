defmodule OrcaHub.AgentPresence do
  @moduledoc """
  Manages .agents/ presence files in session working directories.
  Each running session writes a file so other agents can discover siblings.
  """
  require Logger

  @agents_dir ".agents"

  def write(directory, session_id, attrs \\ %{}) do
    dir = Path.join(directory, @agents_dir)
    File.mkdir_p!(dir)
    ensure_gitignore(dir)

    content = format_file(session_id, attrs)
    File.write!(Path.join(dir, "#{session_id}.md"), content)
  end

  def update_status(directory, session_id, status) do
    path = Path.join([directory, @agents_dir, "#{session_id}.md"])

    if File.exists?(path) do
      content = File.read!(path)

      updated =
        Regex.replace(~r/\*\*Status:\*\* \w+/, content, "**Status:** #{status}")
        |> maybe_update_timestamp()

      File.write!(path, updated)
    end
  end

  def remove(directory, session_id) do
    path = Path.join([directory, @agents_dir, "#{session_id}.md"])
    File.rm(path)
    maybe_remove_agents_dir(Path.join(directory, @agents_dir))
  end

  def list_siblings(directory, exclude_session_id) do
    dir = Path.join(directory, @agents_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.reject(&(&1 == "#{exclude_session_id}.md"))
      |> Enum.map(fn filename ->
        session_id = String.trim_trailing(filename, ".md")
        content = File.read!(Path.join(dir, filename))
        {session_id, content}
      end)
    else
      []
    end
  end

  def cleanup_all_stale do
    import Ecto.Query

    directories =
      OrcaHub.Repo.all(
        from s in OrcaHub.Sessions.Session,
          select: s.directory,
          distinct: true
      )

    # At app startup, no SessionRunners are alive yet, so all presence files are stale
    Enum.each(directories, fn dir ->
      cleanup_stale(dir, [])
    end)
  end

  def cleanup_stale(directory, alive_session_ids) do
    dir = Path.join(directory, @agents_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.each(fn filename ->
        session_id = String.trim_trailing(filename, ".md")

        unless session_id in alive_session_ids do
          Logger.info("Cleaning up stale agent presence file: #{filename}")
          File.rm(Path.join(dir, filename))
        end
      end)

      maybe_remove_agents_dir(dir)
    end
  end

  defp format_file(session_id, attrs) do
    title = attrs[:title] || "Untitled"
    status = attrs[:status] || "idle"
    task = attrs[:task]

    lines = [
      "# Session #{session_id}",
      "**Status:** #{status}",
      "**Task:** #{title}",
      "**Updated:** #{NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)}"
    ]

    lines =
      if task do
        lines ++ ["", "## Scope", task]
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n"
  end

  defp maybe_update_timestamp(content) do
    Regex.replace(
      ~r/\*\*Updated:\*\* .+/,
      content,
      "**Updated:** #{NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)}"
    )
  end

  defp maybe_remove_agents_dir(dir) do
    if File.dir?(dir) do
      remaining =
        File.ls!(dir)
        |> Enum.reject(&(&1 == ".gitignore"))

      if remaining == [], do: File.rm_rf(dir)
    end
  end

  defp ensure_gitignore(agents_dir) do
    gitignore_path = Path.join(Path.dirname(agents_dir), ".gitignore")

    if File.exists?(gitignore_path) do
      content = File.read!(gitignore_path)

      unless String.contains?(content, ".agents/") do
        File.write!(gitignore_path, String.trim_trailing(content) <> "\n.agents/\n")
      end
    else
      # No .gitignore exists — check if this is a git repo before creating one
      if File.dir?(Path.join(Path.dirname(agents_dir), ".git")) do
        File.write!(gitignore_path, ".agents/\n")
      end
    end
  end
end
