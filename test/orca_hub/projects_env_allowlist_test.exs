defmodule OrcaHub.ProjectsEnvAllowlistTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Projects

  defp attrs(env_allowlist) do
    %{
      name: "p-#{System.unique_integer([:positive])}",
      directory: "/tmp/p-#{System.unique_integer([:positive])}",
      env_allowlist: env_allowlist
    }
  end

  describe "env_allowlist validation (shared with OrcaHub.ClusterNodes.ClusterNode)" do
    test "accepts exact names and NAME* prefix entries" do
      assert {:ok, project} = Projects.create_project(attrs(["AWS_REGION", "AWS_*", "_FOO123"]))
      assert project.env_allowlist == ["AWS_REGION", "AWS_*", "_FOO123"]
    end

    test "defaults to [] when omitted" do
      {:ok, project} =
        Projects.create_project(%{
          name: "p-#{System.unique_integer([:positive])}",
          directory: "/tmp/p-#{System.unique_integer([:positive])}"
        })

      assert project.env_allowlist == []
    end

    test "rejects an entry with invalid characters" do
      assert {:error, changeset} = Projects.create_project(attrs(["AWS-REGION"]))
      assert "invalid entry \"AWS-REGION\"" <> _ = errors_on(changeset).env_allowlist |> hd()
    end

    test "silently drops a bare empty-string entry (Ecto's array cast strips blanks per-element)" do
      assert {:ok, project} = Projects.create_project(attrs([""]))
      assert project.env_allowlist == []
    end

    test "rejects * appearing anywhere but the trailing position" do
      assert {:error, changeset} = Projects.create_project(attrs(["FOO*BAR"]))
      assert errors_on(changeset).env_allowlist != []
    end

    test "rejects an entry starting with a digit" do
      assert {:error, changeset} = Projects.create_project(attrs(["1FOO"]))
      assert errors_on(changeset).env_allowlist != []
    end

    test "one invalid entry among valid ones still fails the whole changeset" do
      assert {:error, changeset} = Projects.create_project(attrs(["GOOD_VAR", "bad var"]))
      assert errors_on(changeset).env_allowlist != []
    end

    test "update_project/2 re-validates env_allowlist" do
      {:ok, project} = Projects.create_project(attrs(["GOOD_VAR"]))

      assert {:error, changeset} = Projects.update_project(project, %{env_allowlist: ["bad!"]})
      assert errors_on(changeset).env_allowlist != []

      assert {:ok, updated} = Projects.update_project(project, %{env_allowlist: ["OTHER_*"]})
      assert updated.env_allowlist == ["OTHER_*"]
    end
  end

  describe "commit_trailer (SharedPrompts.commit_trailer_prompt/1 gate, see backend tests)" do
    test "defaults to true when omitted" do
      {:ok, project} =
        Projects.create_project(%{
          name: "p-#{System.unique_integer([:positive])}",
          directory: "/tmp/p-#{System.unique_integer([:positive])}"
        })

      assert project.commit_trailer == true
    end

    test "is cast on create and update" do
      {:ok, project} = Projects.create_project(attrs([]) |> Map.put(:commit_trailer, false))
      assert project.commit_trailer == false

      assert {:ok, updated} = Projects.update_project(project, %{commit_trailer: true})
      assert updated.commit_trailer == true
    end

    test "get_commit_trailer/1 returns the raw column, nil for a missing project" do
      {:ok, project} = Projects.create_project(attrs([]) |> Map.put(:commit_trailer, false))

      assert Projects.get_commit_trailer(project.id) == false
      assert Projects.get_commit_trailer(Ecto.UUID.generate()) == nil
    end
  end
end
