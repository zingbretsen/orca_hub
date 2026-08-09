defmodule OrcaHub.ArtifactsTest do
  @moduledoc """
  Coverage for `OrcaHub.Artifacts` — the upsert-by-(project_id, name)
  save path, version bumping, the read/list helpers, and the
  `{:artifact_updated, artifact}` broadcast on `"artifact:<id>"`.
  """
  use OrcaHub.DataCase, async: true

  import Ecto.Query

  alias OrcaHub.Artifacts
  alias OrcaHub.Artifacts.Artifact
  alias OrcaHub.Projects
  alias OrcaHub.Repo

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

    test "re-saving content preserves the existing data map (including _user_state)", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "sticky-state", content: "v1"})

      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"done" => true})

      {:ok, resaved} =
        Artifacts.save_artifact(%{project_id: project.id, name: "sticky-state", content: "v2"})

      assert resaved.id == artifact.id
      assert resaved.version == 2
      assert resaved.content == "v2"
      assert resaved.data == %{"_user_state" => %{"done" => true}}
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

    test "preserves _user_state when the incoming data omits it", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "dashboard", content: "x"})

      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"checked" => true})

      {:ok, updated} = Artifacts.update_artifact_data(artifact, %{"count" => 7})

      assert updated.data == %{"count" => 7, "_user_state" => %{"checked" => true}}
    end

    test "an explicit _user_state in the incoming data wins (the agent reset path)", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "dashboard", content: "x"})

      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"checked" => true})

      {:ok, updated} =
        Artifacts.update_artifact_data(artifact, %{"count" => 7, "_user_state" => %{}})

      assert updated.data == %{"count" => 7, "_user_state" => %{}}
    end
  end

  describe "merge_user_state/2" do
    test "shallow-merges a patch into data[\"_user_state\"], leaving other data keys alone", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      {:ok, artifact} = Artifacts.update_artifact_data(artifact, %{"top" => ["a"]})
      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"item1" => true})

      assert {:ok, updated} = Artifacts.merge_user_state(artifact, %{"item2" => false})

      assert updated.data == %{
               "top" => ["a"],
               "_user_state" => %{"item1" => true, "item2" => false}
             }
    end

    test "an existing _user_state key survives a patch that doesn't mention it", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"a" => 1, "b" => 2})
      {:ok, updated} = Artifacts.merge_user_state(artifact, %{"c" => 3})

      assert updated.data["_user_state"] == %{"a" => 1, "b" => 2, "c" => 3}
    end

    test "a null value in the patch deletes that key", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      {:ok, artifact} = Artifacts.merge_user_state(artifact, %{"a" => 1, "b" => 2})
      {:ok, updated} = Artifacts.merge_user_state(artifact, %{"a" => nil})

      assert updated.data["_user_state"] == %{"b" => 2}
    end

    test "accepts an artifact id (string) as well as an %Artifact{}", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      assert {:ok, updated} = Artifacts.merge_user_state(artifact.id, %{"a" => 1})
      assert updated.data["_user_state"] == %{"a" => 1}
    end

    test "does not bump version", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      assert artifact.version == 1
      {:ok, updated} = Artifacts.merge_user_state(artifact, %{"a" => 1})
      assert updated.version == 1
    end

    test "broadcasts {:artifact_data_updated, artifact} on \"artifact:<id>\" (no new message type)",
         %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{artifact.id}")

      {:ok, updated} = Artifacts.merge_user_state(artifact, %{"a" => 1})

      assert_receive {:artifact_data_updated, %Artifact{id: id}}
      assert id == artifact.id
      assert updated.data["_user_state"] == %{"a" => 1}
    end

    test "returns {:error, :not_found} for a missing artifact id" do
      assert Artifacts.merge_user_state(Ecto.UUID.generate(), %{"a" => 1}) ==
               {:error, :not_found}
    end

    test "two concurrent merges each survive (genuine merge, not last-write-wins on the whole data map)",
         %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "checklist", content: "x"})

      {:ok, _} = Artifacts.merge_user_state(artifact, %{"item1" => true})
      {:ok, updated} = Artifacts.merge_user_state(artifact, %{"item2" => true})

      assert updated.data["_user_state"] == %{"item1" => true, "item2" => true}
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

    test "broadcasts {:artifact_changed, id} on the aggregate \"artifacts\" topic", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "to-delete-bcast", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifacts")
      assert {:ok, _} = Artifacts.delete_artifact(artifact)

      assert_receive {:artifact_changed, id}
      assert id == artifact.id
    end
  end

  describe "list_all_artifacts/1" do
    test "returns artifacts from every project, with :project preloaded", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "artifacts-ctx-test-all-1",
          directory: "/tmp/artifacts-ctx-all-1-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, mine} =
        Artifacts.save_artifact(%{project_id: project.id, name: "all-a", content: "a"})

      {:ok, theirs} =
        Artifacts.save_artifact(%{project_id: other_project.id, name: "all-b", content: "b"})

      artifacts = Artifacts.list_all_artifacts()
      ids = Enum.map(artifacts, & &1.id)

      assert mine.id in ids
      assert theirs.id in ids

      found = Enum.find(artifacts, &(&1.id == mine.id))
      assert %OrcaHub.Projects.Project{} = found.project
      assert found.project.id == project.id
    end

    test "orders most recently updated first", %{project: project} do
      {:ok, older} =
        Artifacts.save_artifact(%{project_id: project.id, name: "order-older", content: "x"})

      {:ok, newer} =
        Artifacts.save_artifact(%{project_id: project.id, name: "order-newer", content: "x"})

      # updated_at is second-precision (plain `timestamps()`, not
      # `_usec`) — backdate explicitly rather than relying on wall-clock
      # gaps between the two saves above, which could tie within the same
      # second and make this assertion flaky.
      old_time = NaiveDateTime.utc_now() |> NaiveDateTime.add(-60, :second)

      from(a in Artifact, where: a.id == ^older.id)
      |> Repo.update_all(set: [updated_at: old_time])

      ids =
        Artifacts.list_all_artifacts(%{project_id: project.id})
        |> Enum.map(& &1.id)
        |> Enum.filter(&(&1 in [older.id, newer.id]))

      assert ids == [newer.id, older.id]
    end

    test "filters by name (case-insensitive substring)", %{project: project} do
      {:ok, groceries} =
        Artifacts.save_artifact(%{project_id: project.id, name: "Grocery List", content: "x"})

      {:ok, _other} =
        Artifacts.save_artifact(%{project_id: project.id, name: "Dashboard", content: "x"})

      ids =
        Artifacts.list_all_artifacts(%{name: "grocery", project_id: project.id})
        |> Enum.map(& &1.id)

      assert ids == [groceries.id]
    end

    test "filters by project_id", %{project: project} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "artifacts-ctx-test-all-2",
          directory: "/tmp/artifacts-ctx-all-2-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      {:ok, mine} =
        Artifacts.save_artifact(%{project_id: project.id, name: "scoped-a", content: "a"})

      {:ok, _theirs} =
        Artifacts.save_artifact(%{project_id: other_project.id, name: "scoped-b", content: "b"})

      ids =
        Artifacts.list_all_artifacts(%{project_id: project.id}) |> Enum.map(& &1.id)

      assert ids == [mine.id]
    end
  end

  describe "pin_artifact/1 and unpin_artifact/1" do
    test "pin_artifact/1 stamps pinned_at", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "pin-me", content: "x"})

      refute artifact.pinned_at

      assert {:ok, pinned} = Artifacts.pin_artifact(artifact)
      assert %DateTime{} = pinned.pinned_at
    end

    test "unpin_artifact/1 clears pinned_at", %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "unpin-me", content: "x"})

      {:ok, pinned} = Artifacts.pin_artifact(artifact)
      assert pinned.pinned_at

      assert {:ok, unpinned} = Artifacts.unpin_artifact(pinned)
      assert unpinned.pinned_at == nil
    end

    test "pin_artifact/1 and unpin_artifact/1 broadcast {:artifact_changed, id} on \"artifacts\"",
         %{project: project} do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "pin-bcast", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifacts")

      {:ok, pinned} = Artifacts.pin_artifact(artifact)
      assert_receive {:artifact_changed, id}
      assert id == artifact.id

      {:ok, _} = Artifacts.unpin_artifact(pinned)
      assert_receive {:artifact_changed, id}
      assert id == artifact.id
    end
  end

  describe "aggregate \"artifacts\" broadcast on save/data-update (in addition to per-artifact broadcasts)" do
    test "save_artifact/1 also broadcasts {:artifact_changed, id} on \"artifacts\"", %{
      project: project
    } do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifacts")

      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "agg-save", content: "x"})

      assert_receive {:artifact_changed, id}
      assert id == artifact.id
    end

    test "update_artifact_data/2 also broadcasts {:artifact_changed, id} on \"artifacts\"", %{
      project: project
    } do
      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "agg-data", content: "x"})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifacts")

      {:ok, _} = Artifacts.update_artifact_data(artifact, %{"n" => 1})

      assert_receive {:artifact_changed, id}
      assert id == artifact.id
    end
  end
end
