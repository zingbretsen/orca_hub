defmodule OrcaHub.ArtifactsTest do
  @moduledoc """
  Coverage for `OrcaHub.Artifacts` — the upsert-by-(project_id, name)
  save path, version bumping, the read/list helpers, and the
  `{:artifact_updated, artifact}` broadcast on `"artifact:<id>"`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Artifacts
  alias OrcaHub.Artifacts.Artifact
  alias OrcaHub.Projects

  setup do
    dir = Path.join(System.tmp_dir!(), "artifacts_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "artifacts-ctx-test", directory: dir, node: "n1@x"})

    {:ok, project: project}
  end

  describe "save_artifact/1" do
    test "creates a new artifact with version 1", %{project: project} do
      assert {:ok, %Artifact{} = artifact} =
               Artifacts.save_artifact(%{
                 project_id: project.id,
                 name: "dashboard",
                 kind: "html",
                 content: "<html></html>"
               })

      assert artifact.name == "dashboard"
      assert artifact.kind == "html"
      assert artifact.version == 1
    end

    test "defaults kind to html when omitted", %{project: project} do
      assert {:ok, artifact} =
               Artifacts.save_artifact(%{
                 project_id: project.id,
                 name: "no-kind",
                 content: "<p>hi</p>"
               })

      assert artifact.kind == "html"
    end

    test "requires a project_id and name" do
      assert {:error, changeset} = Artifacts.save_artifact(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.project_id
      assert "can't be blank" in errors.name
    end

    test "rejects an unknown kind", %{project: project} do
      assert {:error, changeset} =
               Artifacts.save_artifact(%{
                 project_id: project.id,
                 name: "bad-kind",
                 kind: "pdf",
                 content: "x"
               })

      assert "is invalid" in errors_on(changeset).kind
    end

    test "saving under an existing (project_id, name) updates in place and bumps version", %{
      project: project
    } do
      {:ok, first} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "iterating",
          content: "<p>v1</p>"
        })

      assert first.version == 1

      {:ok, second} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "iterating",
          content: "<p>v2</p>"
        })

      assert second.id == first.id
      assert second.version == 2
      assert second.content == "<p>v2</p>"

      assert Artifacts.list_artifacts_for_project(project.id) |> length() == 1
    end

    test "same name in different projects creates independent artifacts", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "artifacts-ctx-test-2",
          directory: "/tmp/artifacts-ctx-2-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, a} =
        Artifacts.save_artifact(%{project_id: project.id, name: "shared-name", content: "a"})

      {:ok, b} =
        Artifacts.save_artifact(%{
          project_id: other_project.id,
          name: "shared-name",
          content: "b"
        })

      assert a.id != b.id
      assert a.version == 1
      assert b.version == 1
    end

    test "broadcasts {:artifact_updated, artifact} on save", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "bcast", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{artifact.id}")

      {:ok, updated} =
        Artifacts.save_artifact(%{project_id: project.id, name: "bcast", content: "y"})

      assert_receive {:artifact_updated, %Artifact{id: id, version: 2}}
      assert id == artifact.id
      assert updated.version == 2
    end
  end

  describe "update_artifact_data/2" do
    test "replaces the data map without bumping version", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          name: "dashboard",
          content: "<html></html>"
        })

      assert artifact.version == 1
      assert artifact.data == %{}

      assert {:ok, updated} =
               Artifacts.update_artifact_data(artifact, %{"top" => ["a", "b"], "count" => 2})

      assert updated.id == artifact.id
      assert updated.version == 1
      assert updated.data == %{"top" => ["a", "b"], "count" => 2}
    end

    test "a second call fully replaces the previous data (not a merge)", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "dashboard", content: "x"})

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"a" => 1, "b" => 2})
      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"c" => 3})

      assert artifact.data == %{"c" => 3}
    end

    test "broadcasts {:artifact_data_updated, artifact} (not {:artifact_updated, ...})", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "dashboard", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{artifact.id}")

      {:ok, updated} = Artifacts.update_artifact_data(artifact, %{"n" => 42})

      assert_receive {:artifact_data_updated, %Artifact{id: id, data: %{"n" => 42}}}
      assert id == artifact.id
      refute_received {:artifact_updated, _}
      assert updated.version == artifact.version
    end
  end

  describe "get_artifact/1" do
    test "fetches an existing artifact", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "get-me", content: "x"})

      assert Artifacts.get_artifact(artifact.id).id == artifact.id
    end

    test "returns nil for a missing id" do
      assert Artifacts.get_artifact(Ecto.UUID.generate()) == nil
    end

    test "returns nil (not a raise) for a non-uuid id" do
      assert Artifacts.get_artifact("not-a-uuid") == nil
    end
  end

  describe "get_artifact_by_name/2" do
    test "fetches by project + name", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "named", content: "x"})

      assert Artifacts.get_artifact_by_name(project.id, "named").id == artifact.id
    end

    test "returns nil when no artifact matches", %{project: project} do
      assert Artifacts.get_artifact_by_name(project.id, "missing") == nil
    end
  end

  describe "list_artifacts_for_project/1" do
    test "excludes artifacts from other projects", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "artifacts-ctx-test-3",
          directory: "/tmp/artifacts-ctx-3-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, mine} =
        Artifacts.save_artifact(%{project_id: project.id, name: "mine", content: "x"})

      {:ok, _theirs} =
        Artifacts.save_artifact(%{project_id: other_project.id, name: "theirs", content: "x"})

      ids = Artifacts.list_artifacts_for_project(project.id) |> Enum.map(& &1.id)
      assert ids == [mine.id]
    end
  end

  describe "list_artifacts_for_session/1" do
    test "returns only artifacts created by that session", %{project: project} do
      session_id = Ecto.UUID.generate()
      other_session_id = Ecto.UUID.generate()

      {:ok, mine} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          session_id: session_id,
          name: "session-mine",
          content: "x"
        })

      {:ok, _theirs} =
        Artifacts.save_artifact(%{
          project_id: project.id,
          session_id: other_session_id,
          name: "session-theirs",
          content: "x"
        })

      ids = Artifacts.list_artifacts_for_session(session_id) |> Enum.map(& &1.id)
      assert ids == [mine.id]
    end
  end

  describe "delete_artifact/1" do
    test "removes the artifact", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "to-delete", content: "x"})

      assert {:ok, _} = Artifacts.delete_artifact(artifact)
      assert Artifacts.get_artifact(artifact.id) == nil
    end
  end
end
