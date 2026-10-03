defmodule OrcaHub.MCP.Tools.ArtifactAssetsTest do
  @moduledoc """
  Coverage for the `attach_artifact_asset` MCP tool (ORCAHUB3-72 slice 2):
  authorization (the file must be visible to the calling session; the
  artifact must belong to the caller's project or have been created by the
  caller) plus the happy path; and for ORCAHUB3-128's by-path assets
  (save_artifact `assets`, attach_artifact_asset `path`) and
  screenshot_artifact's temp render directory. `async: false` — fixture files are written
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
    test "exposes attach_artifact_asset with `path` and `file_id` as alternative sources" do
      tool = Enum.find(ArtifactsTool.list(), &(&1["name"] == "attach_artifact_asset"))
      assert tool["inputSchema"]["required"] == ["artifact_id"]
      assert Map.has_key?(tool["inputSchema"]["properties"], "path")
      assert Map.has_key?(tool["inputSchema"]["properties"], "file_id")
    end

    test "save_artifact takes an `assets` object and says never to inline base64" do
      tool = Enum.find(ArtifactsTool.list(), &(&1["name"] == "save_artifact"))
      assert tool["inputSchema"]["properties"]["assets"]["type"] == "object"
      assert tool["description"] =~ "never inline them as base64"
      assert tool["description"] =~ ~s(<video src="assets/clip.mp4" controls playsinline>)
      assert tool["description"] =~ "allow-downloads"
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

  # ── ORCAHUB3-128: assets by path ──────────────────────────────────────

  defp json(result), do: result |> decode() |> Jason.decode!()

  defp write!(dir, rel, bytes) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  # A sparse file one byte over the per-file cap: instant, and takes no
  # real disk space.
  defp write_oversized!(dir, rel) do
    path = Path.join(dir, rel)
    {:ok, fd} = :file.open(path, [:write])
    {:ok, _} = :file.position(fd, Files.max_file_bytes() + 1)
    :ok = :file.truncate(fd)
    :ok = :file.close(fd)
    path
  end

  # GETs the path of an absolute URL a tool returned through the real
  # router, so the URL contract between the tools and the token routes is
  # exercised end to end.
  defp fetch_url(url) do
    %URI{path: path} = URI.parse(url)

    conn =
      Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), OrcaHubWeb.Endpoint, :get, path)

    {conn.status, conn.resp_body}
  end

  defp project_file_count(project) do
    OrcaHub.Repo.aggregate(
      from(f in OrcaHub.Files.File, where: f.project_id == ^project.id),
      :count
    )
  end

  defp asset_bytes(artifact, name) do
    %{file: file} = Artifacts.get_asset(artifact.id, name)
    {:ok, binary} = Files.get_binary(file)
    {file, binary}
  end

  describe "save_artifact `assets` (ORCAHUB3-128)" do
    test "uploads and attaches every asset in the same call and lists ref + url for each", %{
      project: project,
      session: session,
      state: state
    } do
      dir = session.directory
      write!(dir, "out/hero.png", "png bytes")
      write!(dir, "out/data.json", ~s({"a":1}))
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{
            "name" => "gallery",
            "content" =>
              ~s|<html><body><img src="assets/hero.png"><script>fetch("assets/data.json")</script></body></html>|,
            "assets" => %{"hero.png" => "out/hero.png", "data.json" => "out/data.json"}
          },
          state
        )

      assert %{"isError" => false} = result
      body = json(result)
      artifact = Artifacts.get_artifact_by_name(project.id, "gallery")
      assert body["id"] == artifact.id
      assert body["warnings"] == []

      assert [data, hero] = body["assets"]
      assert hero["name"] == "hero.png"
      assert hero["ref"] == "assets/hero.png"
      assert hero["path"] == "out/hero.png"
      assert hero["size_bytes"] == byte_size("png bytes")
      assert hero["unchanged"] == false
      assert hero["usage"] == ~s(<img src="assets/hero.png">)
      # The signed url really serves the bytes (via the Authelia-bypassed
      # /api token route), so an agent can WebFetch it to verify.
      assert fetch_url(hero["url"]) == {200, "png bytes"}
      assert fetch_url(data["url"]) == {200, ~s({"a":1})}
      assert body["raw_url"] =~ "/api/artifacts/view/"
      assert data["name"] == "data.json"
      assert data["usage"] == ~s[fetch("assets/data.json")]

      assert {hero_file, "png bytes"} = asset_bytes(artifact, "hero.png")
      assert hero_file.content_type == "image/png"
      assert hero_file.session_id == session.id
      assert {_file, ~s({"a":1})} = asset_bytes(artifact, "data.json")

      # The viewer is only told to open once the assets are attached.
      artifact_id = artifact.id
      assert_received {:open_artifact, ^artifact_id, "split"}
    end

    test "re-saving replaces a changed asset, reuses identical bytes, and keeps unlisted ones",
         %{session: session, state: state} do
      dir = session.directory
      write!(dir, "a.png", "A1")
      write!(dir, "b.png", "B1")

      save = fn assets ->
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "iter", "content" => "<p>x</p>", "assets" => assets},
          state
        )
      end

      json(save.(%{"a.png" => "a.png", "b.png" => "b.png"}))
      artifact = Artifacts.get_artifact_by_name(session.project_id, "iter")
      {a_before, _} = asset_bytes(artifact, "a.png")
      {b_before, _} = asset_bytes(artifact, "b.png")

      write!(dir, "a.png", "A2 changed")
      body = json(save.(%{"a.png" => "a.png"}))
      assert body["version"] == 2

      by_name = Map.new(body["assets"], &{&1["name"], &1})
      assert by_name["a.png"]["unchanged"] == false
      # Unlisted in this call, still attached, listed without call-specific keys.
      refute Map.has_key?(by_name["b.png"], "unchanged")

      {a_after, a_bytes} = asset_bytes(artifact, "a.png")
      assert a_bytes == "A2 changed"
      refute a_after.id == a_before.id
      assert {^b_before, "B1"} = asset_bytes(artifact, "b.png")

      # Identical bytes again: no upload, same file.
      body = json(save.(%{"a.png" => "a.png"}))
      assert Enum.find(body["assets"], &(&1["name"] == "a.png"))["unchanged"] == true
      assert {^a_after, _} = asset_bytes(artifact, "a.png")
    end

    test "refuses an asset path outside the session directory and persists nothing", %{
      project: project,
      session: session,
      state: state
    } do
      write!(session.directory, "ok.png", "fine")
      files_before = project_file_count(project)

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{
            "name" => "escape",
            "content" => "<p>x</p>",
            "assets" => %{"ok.png" => "ok.png", "passwd" => "/etc/passwd"}
          },
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ ~s(assets["passwd"])
      assert msg =~ "outside this session's working directory"
      assert msg =~ "Nothing was saved"
      assert Artifacts.get_artifact_by_name(project.id, "escape") == nil
      assert project_file_count(project) == files_before
    end

    test "refuses a missing asset file and persists nothing", %{project: project, state: state} do
      result =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "missing", "content" => "<p>x</p>", "assets" => %{"x.png" => "nope.png"}},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ ~s(Could not read assets["x.png"] "nope.png")
      assert Artifacts.get_artifact_by_name(project.id, "missing") == nil
    end

    test "refuses an asset over the 50MB cap and persists nothing", %{
      project: project,
      session: session,
      state: state
    } do
      write_oversized!(session.directory, "huge.mp4")

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "huge", "content" => "<p>x</p>", "assets" => %{"huge.mp4" => "huge.mp4"}},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "exceeding"
      assert msg =~ "50MB"
      assert Artifacts.get_artifact_by_name(project.id, "huge") == nil
    end

    test "refuses an asset name that isn't one safe URL segment, suggesting one", %{
      project: project,
      session: session,
      state: state
    } do
      write!(session.directory, "hero.png", "x")

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{
            "name" => "bad-name",
            "content" => "<p>x</p>",
            "assets" => %{"img/hero image.png" => "hero.png"}
          },
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "not a usable asset name"
      assert msg =~ ~s(Try "hero_image.png")
      assert Artifacts.get_artifact_by_name(project.id, "bad-name") == nil
    end

    test "refuses `assets` that isn't a name -> path object", %{state: state} do
      for bad <- [["a.png"], %{"a.png" => ""}, "a.png"] do
        result =
          ArtifactsTool.call(
            "save_artifact",
            %{"name" => "x", "content" => "<p>x</p>", "assets" => bad},
            state
          )

        assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
        assert msg =~ "`assets`"
      end
    end

    test "a failed upload deletes the uploads before it and leaves an existing artifact untouched",
         %{project: project, session: session, artifact: artifact, state: state} do
      dir = session.directory
      write!(dir, "a.png", "aaaa")
      write!(dir, "b.png", :binary.copy("b", 4096))
      files_before = project_file_count(project)

      # Room for a.png (sorted first) but not b.png.
      project_used =
        OrcaHub.Repo.one(
          from f in OrcaHub.Files.File,
            where: f.project_id == ^project.id,
            select: coalesce(sum(f.size_bytes), 0)
        )

      Application.put_env(:orca_hub, :file_store_project_quota_bytes, project_used + 100)
      on_exit(fn -> Application.delete_env(:orca_hub, :file_store_project_quota_bytes) end)

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{
            "name" => artifact.name,
            "content" => "<p>new content</p>",
            "assets" => %{"a.png" => "a.png", "b.png" => "b.png"}
          },
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ ~s(assets["b.png"])
      assert msg =~ "quota"
      assert msg =~ "Nothing was saved"
      assert project_file_count(project) == files_before

      unchanged = Artifacts.get_artifact(artifact.id)
      assert unchanged.version == artifact.version
      assert unchanged.content == artifact.content
      assert Artifacts.list_assets(artifact) == []
    end

    test "warns about inlined base64 and about refs to assets that aren't attached", %{
      state: state
    } do
      big_png = "data:image/png;base64," <> String.duplicate("QUJD", 600)
      tiny_svg = "data:image/svg+xml;base64,PHN2Zy8+"

      result =
        ArtifactsTool.call(
          "save_artifact",
          %{
            "name" => "lint",
            "kind" => "markdown",
            "content" =>
              "![a](#{big_png}) ![b](#{tiny_svg}) ![c](assets/typo.png) " <>
                "<script src=\"https://cdn.example.com/assets/lib.js\"></script>"
          },
          state
        )

      warnings = json(result)["warnings"]
      assert Enum.any?(warnings, &(&1 =~ "Inlines 1 base64 data: URI"))
      assert Enum.any?(warnings, &(&1 =~ ~s(no asset named "typo.png")))
      # A CDN URL that merely contains /assets/ is not an artifact ref.
      refute Enum.any?(warnings, &(&1 =~ "lib.js"))
    end
  end

  describe "attach_artifact_asset `path` (ORCAHUB3-128)" do
    test "uploads a local file and attaches it in one call", %{
      artifact: artifact,
      session: session,
      state: state
    } do
      write!(session.directory, "media/clip.mp4", "mp4 bytes")

      result =
        ArtifactsTool.call(
          "attach_artifact_asset",
          %{"artifact_id" => artifact.id, "path" => "media/clip.mp4"},
          state
        )

      assert %{"isError" => false} = result
      body = json(result)
      assert body["name"] == "clip.mp4"
      assert body["ref"] == "assets/clip.mp4"
      assert body["path"] == "media/clip.mp4"
      assert body["usage"] == ~s(<video src="assets/clip.mp4" controls playsinline></video>)
      assert fetch_url(body["url"]) == {200, "mp4 bytes"}

      {file, "mp4 bytes"} = asset_bytes(artifact, "clip.mp4")
      assert body["file_id"] == file.id
      assert file.content_type == "video/mp4"
    end

    test "an explicit name wins and picks the content type", %{
      artifact: artifact,
      session: session,
      state: state
    } do
      write!(session.directory, "render-output", "svg bytes")

      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "path" => "render-output", "name" => "diagram.svg"},
        state
      )

      {file, _} = asset_bytes(artifact, "diagram.svg")
      assert file.content_type == "image/svg+xml"
    end

    test "requires exactly one of path or file_id", %{
      artifact: artifact,
      asset_file: file,
      session: session,
      state: state
    } do
      write!(session.directory, "x.png", "x")

      for args <- [
            %{"artifact_id" => artifact.id},
            %{"artifact_id" => artifact.id, "path" => "x.png", "file_id" => file.id}
          ] do
        assert %{"isError" => true, "content" => [%{"text" => msg}]} =
                 ArtifactsTool.call("attach_artifact_asset", args, state)

        assert msg =~ "exactly one of `path`"
      end

      assert Artifacts.list_assets(artifact) == []
    end

    test "refuses a path outside the session directory without uploading", %{
      project: project,
      artifact: artifact,
      state: state
    } do
      files_before = project_file_count(project)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "attach_artifact_asset",
                 %{"artifact_id" => artifact.id, "path" => "../../etc/passwd"},
                 state
               )

      assert msg =~ "outside this session's working directory"
      assert project_file_count(project) == files_before
      assert Artifacts.list_assets(artifact) == []
    end
  end

  describe "get_artifact `assets` (ORCAHUB3-131)" do
    test "lists every attached asset with ref, content_type, size_bytes and a fresh signed url",
         %{artifact: artifact, asset_file: file, session: session, state: state} do
      write!(session.directory, "media/clip.mp4", "mp4 bytes")

      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "path" => "media/clip.mp4"},
        state
      )

      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "file_id" => file.id},
        state
      )

      body = ArtifactsTool.call("get_artifact", %{"artifact_id" => artifact.id}, state) |> json()

      assert [clip, hero] = body["assets"]

      assert Map.delete(clip, "url") == %{
               "name" => "clip.mp4",
               "ref" => "assets/clip.mp4",
               "usage" => ~s(<video src="assets/clip.mp4" controls playsinline></video>),
               "content_type" => "video/mp4",
               "size_bytes" => byte_size("mp4 bytes")
             }

      assert hero["name"] == "hero.png"
      assert hero["ref"] == "assets/hero.png"
      assert hero["content_type"] == file.content_type
      assert hero["size_bytes"] == byte_size("fake png bytes")

      for {asset, bytes} <- [{clip, "mp4 bytes"}, {hero, "fake png bytes"}] do
        # Absolute, and its token is scoped to exactly this artifact.
        assert %URI{scheme: scheme, host: host, path: path} = URI.parse(asset["url"])
        assert scheme in ["http", "https"] and is_binary(host)
        name = asset["name"]
        assert ["", "api", "artifacts", "view", token, "assets", ^name] = String.split(path, "/")
        assert OrcaHubWeb.ArtifactURL.verify(token) == {:ok, artifact.id}
        assert fetch_url(asset["url"]) == {200, bytes}
      end
    end

    test "list_assets/1 preloads each asset's file in the one call", %{
      artifact: artifact,
      asset_file: file,
      state: state
    } do
      ArtifactsTool.call(
        "attach_artifact_asset",
        %{"artifact_id" => artifact.id, "file_id" => file.id},
        state
      )

      assert [%{file: %Files.File{id: file_id}}] = Artifacts.list_assets(artifact)
      assert file_id == file.id
    end

    test "the descriptions point at get_artifact for a fresh url" do
      tools = Map.new(ArtifactsTool.list(), &{&1["name"], &1["description"]})
      assert tools["get_artifact"] =~ "a fresh signed absolute `url`"
      assert tools["save_artifact"] =~ "call get_artifact for a fresh one"
      refute tools["save_artifact"] =~ "re-save or re-attach for a fresh one"
    end
  end

  describe "render_screenshots/5 with assets (ORCAHUB3-128)" do
    test "renders from a temp dir with index.html + assets/<name>, then removes the dir", %{
      artifact: artifact,
      asset_file: file,
      session: session
    } do
      {:ok, _} = Artifacts.attach_asset(artifact, file, "hero.png")
      test_pid = self()

      screenshot_fn = fn html_path, width, _height, out_path ->
        dir = Path.dirname(html_path)
        assert Path.basename(html_path) == "index.html"
        assert File.read!(html_path) == OrcaHub.Artifacts.Render.body(artifact)
        assert File.read!(Path.join([dir, "assets", "hero.png"])) == "fake png bytes"
        send(test_pid, {:render_dir, dir})
        File.write!(out_path, "png #{width}")
        :ok
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375],
          session.id,
          fn -> true end,
          screenshot_fn
        )

      assert %{"isError" => false} = result
      refute Map.has_key?(json(result), "missing_assets")
      assert_received {:render_dir, dir}
      refute File.exists?(dir)
    end

    test "an asset whose bytes can't be fetched is reported, and the dir is still removed", %{
      artifact: artifact,
      asset_file: file,
      session: session
    } do
      {:ok, _} = Artifacts.attach_asset(artifact, file, "gone.png")
      :ok = OrcaHub.ObjectStore.delete(file.object_key)
      test_pid = self()

      screenshot_fn = fn html_path, _width, _height, out_path ->
        send(test_pid, {:render_dir, Path.dirname(html_path)})
        refute File.exists?(Path.join([Path.dirname(html_path), "assets", "gone.png"]))
        File.write!(out_path, "png")
        :ok
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375],
          session.id,
          fn -> true end,
          screenshot_fn
        )

      assert json(result)["missing_assets"] == ["gone.png"]
      assert_received {:render_dir, dir}
      refute File.exists?(dir)
    end

    test "the temp dir is removed even when rendering raises", %{
      artifact: artifact,
      session: session
    } do
      test_pid = self()

      screenshot_fn = fn html_path, _width, _height, _out_path ->
        send(test_pid, {:render_dir, Path.dirname(html_path)})
        raise "browser exploded"
      end

      assert_raise RuntimeError, "browser exploded", fn ->
        ArtifactsTool.render_screenshots(
          artifact,
          [375],
          session.id,
          fn -> true end,
          screenshot_fn
        )
      end

      assert_received {:render_dir, dir}
      refute File.exists?(dir)
    end
  end
end
