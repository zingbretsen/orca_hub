defmodule OrcaHub.SessionsTest do
  use OrcaHub.DataCase

  alias OrcaHub.{Sessions, Projects}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/test-sessions"})
    %{project: project}
  end

  defp create_session(project, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{directory: project.directory, project_id: project.id},
        overrides
      )

    {:ok, session} = Sessions.create_session(attrs)
    session
  end

  describe "list_sessions/1 filtering" do
    test "defaults to manual sessions only", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions()
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      refute triggered.id in session_ids
    end

    test ":manual filter excludes triggered sessions", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:manual)
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      refute triggered.id in session_ids
    end

    test ":automated filter shows only triggered sessions", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:automated)
      session_ids = Enum.map(sessions, & &1.id)

      refute manual.id in session_ids
      assert triggered.id in session_ids
    end

    test ":all filter shows everything", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:all)
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      assert triggered.id in session_ids
    end

    test "excludes archived sessions from all filters", %{project: project} do
      manual = create_session(project, %{title: "Archived Manual"})
      triggered = create_session(project, %{title: "Archived Triggered", triggered: true})

      Sessions.archive_session(manual)
      Sessions.archive_session(triggered)

      for filter <- [:all, :manual, :automated] do
        session_ids = Sessions.list_sessions(filter) |> Enum.map(& &1.id)
        refute manual.id in session_ids
        refute triggered.id in session_ids
      end
    end
  end

  describe "get_session/1" do
    test "returns session when it exists", %{project: project} do
      session = create_session(project)
      assert %{id: id} = Sessions.get_session(session.id)
      assert id == session.id
    end

    test "returns nil when session does not exist" do
      assert Sessions.get_session(Ecto.UUID.generate()) == nil
    end
  end

  describe "triggered field" do
    test "defaults to false", %{project: project} do
      session = create_session(project)
      assert session.triggered == false
    end

    test "can be set to true on creation", %{project: project} do
      session = create_session(project, %{triggered: true})
      assert session.triggered == true
    end
  end
end
