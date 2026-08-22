defmodule OrcaHubWeb.SessionApiControllerTest do
  # async: false — this mutates the global `:orca_hub, :api_token` Application
  # env, same as ApiRunControllerTest/A2AControllerTest. Two ASYNC modules
  # doing that race each other for real (confirmed: TTSControllerTest is the
  # only other async: true consumer of this env key, and pairing it with an
  # async: true version of this file reproduced a raw "503 API disabled"
  # failure ~4/5 runs) — async: false modules run serialized relative to each
  # other and never overlap the async pool, which avoids it.
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{Projects, Sessions}

  @token "test-api-token"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp with_token(fun) do
    Application.put_env(:orca_hub, :api_token, @token)
    on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
    fun.()
  end

  defp create_project(name \\ "session-api-test") do
    {:ok, project} =
      Projects.create_project(%{
        name: "#{name} #{System.unique_integer()}",
        directory: "/tmp/session-api-test-#{System.unique_integer()}"
      })

    project
  end

  defp create_session(attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: "/tmp/session-api-test", status: "ready"}, attrs)
      )

    session
  end

  describe "auth" do
    test "503 when the API is disabled (no token configured)", %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)
      conn = conn |> authed() |> get(~p"/api/v1/sessions")
      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "401 with no Authorization header", %{conn: conn} do
      with_token(fn ->
        conn = get(conn, ~p"/api/v1/sessions")
        assert json_response(conn, 401)
      end)
    end

    test "401 with a mismatched token", %{conn: conn} do
      with_token(fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer wrong-token")
          |> get(~p"/api/v1/sessions")

        assert json_response(conn, 401)
      end)
    end

    test "401 with no Authorization header on show", %{conn: conn} do
      with_token(fn ->
        conn = get(conn, ~p"/api/v1/sessions/#{Ecto.UUID.generate()}")
        assert json_response(conn, 401)
      end)
    end
  end

  describe "GET /api/v1/sessions" do
    test "lists non-archived sessions with the compact projection", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        session =
          create_session(%{
            project_id: project.id,
            status: "idle",
            title: "watch test session",
            progress_phase: "implementing",
            progress_note: "writing code"
          })

        archived = create_session(%{status: "idle"})
        {:ok, _} = Sessions.archive_session(archived)

        conn = conn |> authed() |> get(~p"/api/v1/sessions")
        body = json_response(conn, 200)

        ids = Enum.map(body["sessions"], & &1["id"])
        assert session.id in ids
        refute archived.id in ids

        rendered = Enum.find(body["sessions"], &(&1["id"] == session.id))
        assert rendered["status"] == "idle"
        assert rendered["title"] == "watch test session"
        assert rendered["progress_phase"] == "implementing"
        assert rendered["progress_note"] == "writing code"
        assert rendered["directory"] == session.directory
        assert rendered["project_id"] == project.id
        assert rendered["project_name"] == project.name
        assert is_binary(rendered["last_activity_at"])
      end)
    end

    test "filters by status", %{conn: conn} do
      with_token(fn ->
        running = create_session(%{status: "running"})
        idle = create_session(%{status: "idle"})

        conn = conn |> authed() |> get(~p"/api/v1/sessions", %{"status" => "running"})
        ids = conn |> json_response(200) |> Map.fetch!("sessions") |> Enum.map(& &1["id"])

        assert running.id in ids
        refute idle.id in ids
      end)
    end

    test "filters by project_id", %{conn: conn} do
      with_token(fn ->
        project_a = create_project("project-a")
        project_b = create_project("project-b")

        session_a = create_session(%{project_id: project_a.id})
        session_b = create_session(%{project_id: project_b.id})

        conn = conn |> authed() |> get(~p"/api/v1/sessions", %{"project_id" => project_a.id})
        ids = conn |> json_response(200) |> Map.fetch!("sessions") |> Enum.map(& &1["id"])

        assert session_a.id in ids
        refute session_b.id in ids
      end)
    end
  end

  describe "GET /api/v1/sessions/:id" do
    test "returns the compact projection for an existing session", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        session =
          create_session(%{
            project_id: project.id,
            status: "waiting",
            title: "single fetch test"
          })

        conn = conn |> authed() |> get(~p"/api/v1/sessions/#{session.id}")
        body = json_response(conn, 200)

        assert body["id"] == session.id
        assert body["status"] == "waiting"
        assert body["title"] == "single fetch test"
        assert body["project_id"] == project.id
        assert body["project_name"] == project.name
        assert body["directory"] == session.directory
        assert is_binary(body["last_activity_at"])
      end)
    end

    test "404 for a well-formed but nonexistent id", %{conn: conn} do
      with_token(fn ->
        conn = conn |> authed() |> get(~p"/api/v1/sessions/#{Ecto.UUID.generate()}")
        assert json_response(conn, 404)["error"] == "session not found"
      end)
    end

    test "400/404 (not a raw CastError) for a malformed id", %{conn: conn} do
      with_token(fn ->
        conn = conn |> authed() |> get(~p"/api/v1/sessions/not-a-uuid")
        assert json_response(conn, 404)["error"] == "session not found"
      end)
    end
  end
end
