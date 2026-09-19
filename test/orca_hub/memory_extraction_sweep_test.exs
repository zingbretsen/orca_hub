defmodule OrcaHub.MemoryExtractionSweepTest do
  @moduledoc """
  Coverage for `OrcaHub.MemoryExtractionSweep`'s boot-time cleanup of
  `kind == "memory_extraction"` sessions orphaned by a hub restart landing
  before `OrcaHub.SessionRunner`'s self-archive hook ran. `sweep/0` is the
  `@doc false` test seam (mirrors `SessionResumer.resume_session/1`'s
  pattern) called directly rather than waiting on the real 30s boot delay.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{MemoryExtraction, MemoryExtractionSweep, Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "orca-mem-sweep-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "Sweep", directory: dir})
    %{project: project, dir: dir}
  end

  defp create_child(project, source, overrides) do
    attrs =
      Map.merge(
        %{
          directory: project.directory,
          project_id: project.id,
          parent_session_id: source && source.id,
          kind: "memory_extraction",
          runner_node: Atom.to_string(node()),
          status: "idle"
        },
        overrides
      )

    {:ok, child} = Sessions.create_session(attrs)

    # Backdate updated_at directly (bypassing the changeset, which always
    # stamps "now") so the row looks genuinely stale to the sweep's query.
    stale_at = NaiveDateTime.utc_now() |> NaiveDateTime.add(-15, :minute)

    {1, _} =
      OrcaHub.Repo.update_all(
        Ecto.Query.from(s in OrcaHub.Sessions.Session, where: s.id == ^child.id),
        set: [updated_at: stale_at]
      )

    Sessions.get_session(child.id)
  end

  test "archives a stale unarchived memory_extraction session and deletes its transcript file",
       %{project: project} do
    {:ok, source} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    child = create_child(project, source, %{})

    path = MemoryExtraction.transcript_file_path(%{directory: project.directory, id: source.id})
    MemoryExtraction.write_transcript_file!(path, "stale transcript")

    assert MemoryExtractionSweep.sweep() == 1

    reloaded = Sessions.get_session(child.id)
    refute is_nil(reloaded.archived_at)
    refute File.exists?(path)
  end

  test "ignores a recent (not yet 10 minutes old) memory_extraction session", %{project: project} do
    {:ok, source} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    {:ok, fresh_child} =
      Sessions.create_session(%{
        directory: project.directory,
        project_id: project.id,
        parent_session_id: source.id,
        kind: "memory_extraction",
        runner_node: Atom.to_string(node()),
        status: "idle"
      })

    assert MemoryExtractionSweep.sweep() == 0

    reloaded = Sessions.get_session(fresh_child.id)
    assert is_nil(reloaded.archived_at)
  end

  test "ignores an ordinary (kind == \"session\") stale idle session", %{project: project} do
    child = create_child(project, nil, %{kind: "session", parent_session_id: nil})

    assert MemoryExtractionSweep.sweep() == 0

    reloaded = Sessions.get_session(child.id)
    assert is_nil(reloaded.archived_at)
  end

  test "ignores an already-archived memory_extraction session", %{project: project} do
    {:ok, source} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    child = create_child(project, source, %{})
    {:ok, _} = Sessions.archive_session(child, extract_memories: false)

    assert MemoryExtractionSweep.sweep() == 0
  end

  test "archives only the orphaned extraction session itself, not any session under it",
       %{project: project} do
    {:ok, source} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    child = create_child(project, source, %{})

    {:ok, grandchild} =
      Sessions.create_session(%{
        directory: project.directory,
        project_id: project.id,
        parent_session_id: child.id,
        runner_node: Atom.to_string(node())
      })

    assert MemoryExtractionSweep.sweep() == 1

    refute is_nil(Sessions.get_session(child.id).archived_at)
    assert Sessions.get_session(grandchild.id).archived_at == nil
  end
end
