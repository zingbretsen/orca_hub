defmodule OrcaHubWeb.ApiRunControllerTest do
  # async: false — the happy-path/retry tests start a real SessionRunner
  # (GenStatem) child under the shared OrcaHub.SessionSupervisor, which needs
  # the DB sandbox in SHARED mode (see session_supervisor_test.exs for the
  # same pattern/rationale).
  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.{ApiRuns, Projects, SessionSupervisor, Sessions}

  @claude_stub Path.expand("../../support/fixtures/claude_stub_noop.sh", __DIR__)
  @token "test-api-token"

  setup do
    Application.put_env(:orca_hub, :api_token, @token)
    on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp insert_assistant_message(session, text) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })

    :ok
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id),
      do: SessionSupervisor.stop_session(session_id)
  end

  describe "POST /api/v1/runs auth" do
    test "503 when the API is disabled (no token configured)", %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)

      conn =
        conn |> authed() |> post(~p"/api/v1/runs", %{"prompt" => "hi", "directory" => "/tmp"})

      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "401 with no Authorization header", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/runs", %{"prompt" => "hi", "directory" => "/tmp"})
      assert json_response(conn, 401)
    end

    test "401 with a mismatched token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> post(~p"/api/v1/runs", %{"prompt" => "hi", "directory" => "/tmp"})

      assert json_response(conn, 401)
    end

    test "400 when prompt is missing", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/v1/runs", %{"directory" => "/tmp"})
      assert json_response(conn, 400)
    end

    test "400 when neither directory nor project_id is given", %{conn: conn} do
      conn = conn |> authed() |> post(~p"/api/v1/runs", %{"prompt" => "hi"})
      assert json_response(conn, 400)
    end
  end

  describe "POST /api/v1/runs happy path" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      dir = Path.join(System.tmp_dir!(), "api_run_ctrl_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      %{dir: dir}
    end

    test "creates a session + run and returns 202", %{conn: conn, dir: dir} do
      conn =
        conn |> authed() |> post(~p"/api/v1/runs", %{"prompt" => "say hi", "directory" => dir})

      body = json_response(conn, 202)
      assert body["status"] == "running"
      assert is_binary(body["run_id"])
      assert is_binary(body["session_id"])

      session = Sessions.get_session!(body["session_id"])
      assert session.triggered == true
      assert session.title == "API run"
      assert session.directory == dir
      assert session.backend == "claude"

      run = ApiRuns.get_run(body["run_id"])
      assert run.session_id == session.id
      assert run.status == "running"

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "no_tools stores an empty --tools override on the session", %{conn: conn, dir: dir} do
      conn =
        conn
        |> authed()
        |> post(~p"/api/v1/runs", %{"prompt" => "say hi", "directory" => dir, "no_tools" => true})

      body = json_response(conn, 202)
      session = Sessions.get_session!(body["session_id"])
      assert session.tools == ""

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "400 when no_tools is combined with a non-claude backend", %{conn: conn, dir: dir} do
      conn =
        conn
        |> authed()
        |> post(~p"/api/v1/runs", %{
          "prompt" => "say hi",
          "directory" => dir,
          "no_tools" => true,
          "backend" => "codex"
        })

      assert json_response(conn, 400)
    end

    test "result_schema is appended as an instruction to the prompt's session", %{
      conn: conn,
      dir: dir
    } do
      schema = %{"type" => "object", "properties" => %{"answer" => %{"type" => "integer"}}}

      conn =
        conn
        |> authed()
        |> post(~p"/api/v1/runs", %{
          "prompt" => "say hi",
          "directory" => dir,
          "result_schema" => schema
        })

      body = json_response(conn, 202)
      run = ApiRuns.get_run(body["run_id"])
      assert run.result_schema == schema

      on_exit(fn -> stop_if_alive(body["session_id"]) end)
    end
  end

  describe "GET /api/v1/runs/:id" do
    setup %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "api_run_get_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, project} =
        Projects.create_project(%{name: "Get Test #{System.unique_integer()}", directory: dir})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          status: "idle",
          triggered: true,
          runner_node: Atom.to_string(node())
        })

      %{conn: authed(conn), session: session}
    end

    test "404 for a missing run", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/runs/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "404 for a malformed id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/runs/not-a-uuid")
      assert json_response(conn, 404)
    end

    test "in_progress while the session is still running", %{conn: conn, session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "running"})
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "in_progress"
      assert body["session_status"] == "running"
    end

    test "completed with plain text when no schema is given", %{conn: conn, session: session} do
      insert_assistant_message(session, "hello there")
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "completed"
      assert body["result_text"] == "hello there"
      refute Map.has_key?(body, "result")
    end

    test "completed with a parsed result when the text is bare JSON and no schema given", %{
      conn: conn,
      session: session
    } do
      insert_assistant_message(session, ~s({"answer": 42}))
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "completed"
      assert body["result"] == %{"answer" => 42}
    end

    test "completed with a validated result when the schema is satisfied", %{
      conn: conn,
      session: session
    } do
      insert_assistant_message(session, "```json\n{\"answer\": 42}\n```")

      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}},
        "required" => ["answer"]
      }

      {:ok, run} = ApiRuns.create_run(%{session_id: session.id, result_schema: schema})

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "completed"
      assert body["result"] == %{"answer" => 42}
    end

    test "retries validation with a corrective prompt when the schema doesn't match", %{
      conn: conn,
      session: session
    } do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      insert_assistant_message(session, ~s({"wrong": true}))

      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}},
        "required" => ["answer"]
      }

      {:ok, run} =
        ApiRuns.create_run(%{
          session_id: session.id,
          result_schema: schema,
          max_validation_attempts: 3
        })

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "in_progress"
      assert body["validation_attempts"] == 1
      assert body["note"] == "retrying validation"

      reloaded = ApiRuns.get_run(run.id)
      assert reloaded.validation_attempts == 1
      assert reloaded.status == "running"

      on_exit(fn -> stop_if_alive(session.id) end)
    end

    test "fails once validation attempts are exhausted", %{conn: conn, session: session} do
      insert_assistant_message(session, ~s({"wrong": true}))

      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}},
        "required" => ["answer"]
      }

      {:ok, run} =
        ApiRuns.create_run(%{
          session_id: session.id,
          result_schema: schema,
          max_validation_attempts: 1,
          validation_attempts: 1
        })

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "failed"
      assert body["error"] =~ "validation failed"
    end

    test "fails when the session errored", %{conn: conn, session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "error"})
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "failed"
      assert body["error"] == "session errored"
    end

    test "marks a run timed out once its timeout has elapsed", %{conn: conn, session: session} do
      {:ok, session} = Sessions.update_session(session, %{status: "running"})
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id, timeout_seconds: 1})

      past =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-10, :second)
        |> NaiveDateTime.truncate(:second)

      run = OrcaHub.Repo.update!(Ecto.Changeset.change(run, inserted_at: past))

      conn = get(conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert body["status"] == "timed_out"
      assert body["session_id"] == session.id
    end
  end
end
