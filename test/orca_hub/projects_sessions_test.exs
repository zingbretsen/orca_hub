defmodule OrcaHub.ProjectsSessionsTest do
  @moduledoc """
  `Projects.get_project/1` and `get_project!/1` used to preload every
  session of the project, archived included: about 24 ms and a 2.5 MB term
  per lookup for a project with 1,420 sessions, on pages that never render
  them. Sessions now load only through `list_project_sessions/2`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Projects, Repo, Sessions}
  alias OrcaHub.Sessions.Session

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "projects-sessions-test",
        directory: "/tmp/projects_sessions_#{System.unique_integer([:positive])}"
      })

    {:ok, project: project}
  end

  defp session_at(project, updated_at, attrs \\ %{}) do
    {:ok, s} =
      Sessions.create_session(
        Map.merge(%{directory: project.directory, project_id: project.id}, attrs)
      )

    Repo.update!(Ecto.Changeset.change(s, Map.put(attrs, :updated_at, updated_at)))
  end

  test "get_project/1 and get_project!/1 do not load sessions", %{project: project} do
    session_at(project, ~N[2026-01-01 00:00:00])

    assert %Ecto.Association.NotLoaded{} = Projects.get_project(project.id).sessions
    assert %Ecto.Association.NotLoaded{} = Projects.get_project!(project.id).sessions
    assert Projects.get_project(Ecto.UUID.generate()) == nil
  end

  test "list_project_sessions/2 returns unarchived sessions, most recently updated first",
       %{project: project} do
    older = session_at(project, ~N[2026-01-01 00:00:00])
    newer = session_at(project, ~N[2026-01-02 00:00:00])

    archived =
      session_at(project, ~N[2026-01-03 00:00:00], %{archived_at: ~U[2026-01-03 00:00:00Z]})

    {:ok, other} =
      Projects.create_project(%{name: "other", directory: "/tmp/other_#{project.id}"})

    session_at(other, ~N[2026-01-04 00:00:00])

    assert Enum.map(Projects.list_project_sessions(project.id), & &1.id) == [newer.id, older.id]

    assert Enum.map(Projects.list_project_sessions(project.id, include_archived: true), & &1.id) ==
             [archived.id, newer.id, older.id]

    assert [%Session{}] = Projects.list_project_sessions(other.id)
  end
end
