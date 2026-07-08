defmodule OrcaHub.ApiRunsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{ApiRuns, Projects, Sessions}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/api-runs-test"})

    {:ok, session} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    %{project: project, session: session}
  end

  describe "create_run/1, get_run/1, update_run/2" do
    test "round-trips a run", %{session: session} do
      assert {:ok, run} =
               ApiRuns.create_run(%{
                 session_id: session.id,
                 timeout_seconds: 60,
                 max_validation_attempts: 2
               })

      assert run.status == "running"
      assert run.timeout_seconds == 60

      fetched = ApiRuns.get_run(run.id)
      assert fetched.id == run.id
      assert fetched.session.id == session.id

      assert {:ok, updated} = ApiRuns.update_run(run, %{status: "completed", result: %{"a" => 1}})
      assert updated.status == "completed"
      assert updated.result == %{"a" => 1}
    end

    test "get_run/1 returns nil for a missing id" do
      assert ApiRuns.get_run(Ecto.UUID.generate()) == nil
    end

    test "create_run/1 requires a session_id" do
      assert {:error, changeset} = ApiRuns.create_run(%{})
      assert "can't be blank" in errors_on(changeset).session_id
    end
  end

  describe "get_run_by_session_id/1" do
    test "returns the run for a session", %{session: session} do
      {:ok, run} = ApiRuns.create_run(%{session_id: session.id})
      assert ApiRuns.get_run_by_session_id(session.id).id == run.id
    end

    test "returns nil when the session has no run" do
      assert ApiRuns.get_run_by_session_id(Ecto.UUID.generate()) == nil
    end

    test "returns the most recently created run when a session has more than one", %{
      session: session
    } do
      {:ok, older} = ApiRuns.create_run(%{session_id: session.id})
      {:ok, newer} = ApiRuns.create_run(%{session_id: session.id})

      # timestamps() defaults to second-level precision — force `older` to be
      # unambiguously earlier rather than relying on wall-clock granularity.
      past = NaiveDateTime.add(older.inserted_at, -10, :second)
      OrcaHub.Repo.update!(Ecto.Changeset.change(older, inserted_at: past))

      assert ApiRuns.get_run_by_session_id(session.id).id == newer.id
    end
  end

  describe "extract_json/1" do
    test "parses bare JSON" do
      assert ApiRuns.extract_json(~s({"a": 1})) == {:ok, %{"a" => 1}}
    end

    test "parses JSON inside a ```json fence" do
      text = "Here you go:\n```json\n{\"a\": 1}\n```\nThanks."
      assert ApiRuns.extract_json(text) == {:ok, %{"a" => 1}}
    end

    test "parses JSON inside a bare fence" do
      text = "```\n{\"a\": 1}\n```"
      assert ApiRuns.extract_json(text) == {:ok, %{"a" => 1}}
    end

    test "returns :error for non-JSON text" do
      assert ApiRuns.extract_json("just some prose") == :error
    end

    test "returns :error for nil" do
      assert ApiRuns.extract_json(nil) == :error
    end
  end

  describe "validate_against_schema/2" do
    @schema %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    }

    test "returns :ok for valid data" do
      assert ApiRuns.validate_against_schema(%{"name" => "hi"}, @schema) == :ok
    end

    test "returns {:error, errors} for invalid data" do
      assert {:error, errors} = ApiRuns.validate_against_schema(%{}, @schema)
      assert is_list(errors)
      assert errors != []
    end

    test "returns {:schema_error, _} for a malformed schema" do
      assert {:schema_error, _message} =
               ApiRuns.validate_against_schema(%{"name" => "hi"}, %{"type" => "not-a-real-type"})
    end
  end
end
