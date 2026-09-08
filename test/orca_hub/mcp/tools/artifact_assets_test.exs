defmodule OrcaHub.MCP.Tools.ArtifactAssetsTest do
  @moduledoc """
  Coverage for the `attach_artifact_asset` MCP tool (ORCAHUB3-72 slice 2):
  authorization (the file must be visible to the calling session; the
  artifact must belong to the caller's project or have been created by the
  caller) plus the happy path. `async: false` — fixture files are written
  via `OrcaHub.ObjectStore.Local`, scoped to a per-test tmp dir set in app
  env (process-wide state), same as `OrcaHub.FilesTest`.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Artifacts
  alias OrcaHub.MCP.Tools.Artifacts, as: ArtifactsTool
  alias OrcaHub.{Files, Projects, Sessions}

  setup do
    store_dir =
      Path.join(
        System.tmp_dir!(),
        "mcp_artifact_assets_store_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:orca_hub, :file_store_dir, store_dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(store_dir)
    end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "mcp_artifact_assets_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "mcp-artifact-assets-test", directory: dir, node: "n1@x"})

    {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})

    {:ok, artifact} =
      Artifacts.save_artifact(%{
        project_id: project.id,
        session_id: session.id,
        name: "with-assets",
        content: "<html><body>hi</body></html>"
      })

    {:ok, asset_file} =
      Files.create_file(
        %{project_id: project.id, session_id: session.id, name: "hero.png"},
        "fake png bytes"
      )

    {:ok,
     project: project,
     session: session,
     artifact: artifact,
     asset_file: asset_file,
     state: %{orca_session_id: session.id}}
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: body

  describe "list/0" do
    test "exposes attach_artifact_asset with the expected required args" do
      tool = Enum.find(ArtifactsTool.list(), &(&1["name"] == "attach_artifact_asset"))
      assert tool["inputSchema"]["required"] == ["artifact_id", "file_id"]
    end
  end

  describe "attach_artifact_asset — happy path" do
    test "attaches a visible file to an owned artifact, defaulting name to the file's name", %{
      artifact: artifact,
      asset_file: file,
      state: state
    } do
      assert %{"isError" => false} =
               result =
               ArtifactsTool.call(
                 "attach_artifact_asset",
                 %{"artifact_id" => artifact.id, "file_id" => file.id},
                 state
               )

      text = decode(result)
      assert text =~ "hero.png"
      assert text =~ "assets/hero.png"

      [asset] = Artifacts.list_assets(artifact)
      assert asset.name == "hero.png"
      assert asset.file_id == file.id
    end

    test "an explicit name is basename-sanitized", %{
      artifact: artifact,
      asset_file: file,
      state: state
    } do
      assert %{"isError" => false} =
               ArtifactsTool.call(
                 "attach_artifact_asset",
                 %{
                   "artifact_id" => artifact.id,
                   "file_id" => file.id,
                   "name" => "../etc/evil name.png"
                 },
                 state
               )

      [asset] = Artifacts.list_assets(artifact)
      assert asset.name == "evil_name.png"
    end

    test "re-attaching under the same name repoints the asset at the new file", %{
      project: project,
      session: session,
      artifact: artifact,
      asset_file: file,
      state: state
    } do
      {:ok, other_file} =
        Files.create_file(
          %{project_id: project.id, session_id: session.id, name: "hero.png"},
          "different bytes"
        )

      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "file_id" => file.id, "name" => "hero.png"},
        state
      )

      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "file_id" => other_file.id, "name" => "hero.png"},
        state
      )

      assert [asset] = Artifacts.list_assets(artifact)
      assert asset.file_id == other_file.id
    end
  end

  describe "attach_artifact_asset — authorization negatives" do
    test "errors when the file is not visible to the calling session", %{
      artifact: artifact,
      state: state
    } do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "mcp-artifact-assets-other",
          directory: Path.join(System.tmp_dir!(), "other-#{System.unique_integer([:positive])}"),
          node: "n1@x"
        })

      {:ok, other_session} =
        Sessions.create_session(%{
          directory: other_project.directory,
          project_id: other_project.id
        })

      {:ok, invisible_file} =
        Files.create_file(
          %{project_id: other_project.id, session_id: other_session.id, name: "secret.png"},
          "secret bytes"
        )

      result =
        ArtifactsTool.call(
          "attach_artifact_asset",
          %{"artifact_id" => artifact.id, "file_id" => invisible_file.id},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "not found or not visible"
      assert Artifacts.list_assets(artifact) == []
    end

    test "errors when the artifact belongs to a different project and wasn't created by the caller",
         %{asset_file: file} do
      {:ok, other_project} =
        Projects.create_project(%{
          name: "mcp-artifact-assets-other-artifact",
          directory: Path.join(System.tmp_dir!(), "other2-#{System.unique_integer([:positive])}"),
          node: "n1@x"
        })

      {:ok, other_session} =
        Sessions.create_session(%{
          directory: other_project.directory,
          project_id: other_project.id
        })

      {:ok, other_artifact} =
        Artifacts.save_artifact(%{
          project_id: other_project.id,
          session_id: other_session.id,
          name: "other-project-artifact",
          content: "<p>x</p>"
        })

      # A brand-new session in a THIRD project — can see `file` only via the
      # normal same-project rule, but has no claim on `other_artifact`.
      {:ok, caller_project} =
        Projects.create_project(%{
          name: "mcp-artifact-assets-caller",
          directory: Path.join(System.tmp_dir!(), "caller-#{System.unique_integer([:positive])}"),
          node: "n1@x"
        })

      {:ok, caller_session} =
        Sessions.create_session(%{
          directory: caller_project.directory,
          project_id: caller_project.id
        })

      result =
        ArtifactsTool.call(
          "attach_artifact_asset",
          %{"artifact_id" => other_artifact.id, "file_id" => file.id},
          %{orca_session_id: caller_session.id}
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "not found or not accessible"
      assert Artifacts.list_assets(other_artifact) == []
    end

    test "errors for an unknown artifact_id", %{asset_file: file, state: state} do
      result =
        ArtifactsTool.call(
          "attach_artifact_asset",
          %{"artifact_id" => Ecto.UUID.generate(), "file_id" => file.id},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "No artifact found"
    end

    test "errors for an unknown file_id", %{artifact: artifact, state: state} do
      result =
        ArtifactsTool.call(
          "attach_artifact_asset",
          %{"artifact_id" => artifact.id, "file_id" => Ecto.UUID.generate()},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "not found"
    end

    test "errors on a missing artifact_id/file_id" do
      state = %{orca_session_id: Ecto.UUID.generate()}

      assert %{"isError" => true, "content" => [%{"text" => msg1}]} =
               ArtifactsTool.call("attach_artifact_asset", %{}, state)

      assert msg1 =~ "artifact_id"
    end
  end
end
