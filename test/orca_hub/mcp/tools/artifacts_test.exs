defmodule OrcaHub.MCP.Tools.ArtifactsTest do
  @moduledoc """
  Coverage for the `save_artifact`/`open_artifact`/`list_artifacts`/
  `get_artifact` MCP tools. Every tool resolves the calling session's
  project via `state.orca_session_id` (see `OrcaHub.MCP.Tools.Artifacts`
  moduledoc) — these tests use a real session/project row rather than
  spawning a `SessionRunner`, since the tools only ever call
  `HubRPC.get_session/1`, not the runner.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Artifacts
  alias OrcaHub.MCP.Tools.Artifacts, as: ArtifactsTool
  alias OrcaHub.{Projects, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp_artifacts_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "mcp-artifacts-test", directory: dir, node: "n1@x"})

    {:ok, session} = Sessions.create_session(%{directory: dir, project_id: project.id})

    {:ok, project: project, session: session, state: %{orca_session_id: session.id}}
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: Jason.decode!(body)

  describe "list/0" do
    test "exposes all four tools with expected required args" do
      tools = ArtifactsTool.list()
      names = Enum.map(tools, & &1["name"])

      assert "save_artifact" in names
      assert "open_artifact" in names
      assert "list_artifacts" in names
      assert "get_artifact" in names

      save_tool = Enum.find(tools, &(&1["name"] == "save_artifact"))
      assert save_tool["inputSchema"]["required"] == ["name", "content"]
    end
  end

  describe "save_artifact" do
    test "creates an artifact and returns its id/raw_url", %{project: project, state: state} do
      assert %{"isError" => false} =
               result =
               ArtifactsTool.call(
                 "save_artifact",
                 %{"name" => "dash", "content" => "<html><body>hi</body></html>"},
                 state
               )

      body = decode(result)
      assert body["kind"] == "html"
      assert body["version"] == 1
      assert body["opened"] == true
      assert body["raw_url"] == "/artifacts/#{body["id"]}/raw?v=1"

      artifact = Artifacts.get_artifact(body["id"])
      assert artifact.project_id == project.id
      assert artifact.session_id == state.orca_session_id
    end

    test "errors on a missing name", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("save_artifact", %{"content" => "x"}, state)

      assert msg =~ "name"
    end

    test "errors on a missing content", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("save_artifact", %{"name" => "x"}, state)

      assert msg =~ "content"
    end

    test "errors on an invalid kind", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "save_artifact",
                 %{"name" => "x", "content" => "y", "kind" => "pdf"},
                 state
               )

      assert msg =~ "kind"
    end

    test "errors when the MCP connection has no linked session" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "save_artifact",
                 %{"name" => "x", "content" => "y"},
                 %{orca_session_id: nil}
               )

      assert msg =~ "No OrcaHub session"
    end

    test "saving twice under the same name updates in place and bumps version", %{state: state} do
      %{"id" => id1} =
        ArtifactsTool.call("save_artifact", %{"name" => "iter", "content" => "v1"}, state)
        |> decode()

      %{"id" => id2, "version" => version} =
        ArtifactsTool.call("save_artifact", %{"name" => "iter", "content" => "v2"}, state)
        |> decode()

      assert id1 == id2
      assert version == 2
    end

    test "includes non-fatal HTML warnings for mismatched tags but still saves", %{state: state} do
      result =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "broken-html", "content" => "<div><span>oops</div>"},
          state
        )

      assert %{"isError" => false} = result
      body = decode(result)
      assert body["warnings"] != []
      assert Enum.any?(body["warnings"], &(&1 =~ "span"))
    end

    test "no warnings key for kind=svg", %{state: state} do
      body =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "an-svg", "content" => "<svg></svg>", "kind" => "svg"},
          state
        )
        |> decode()

      refute Map.has_key?(body, "warnings")
    end

    test "open: false does not broadcast open_artifact", %{state: state} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{state.orca_session_id}")

      %{"opened" => false} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "no-open", "content" => "x", "open" => false},
          state
        )
        |> decode()

      refute_receive {:open_artifact, _id, _mode}
    end

    test "open: true (default) broadcasts open_artifact on the session topic", %{state: state} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{state.orca_session_id}")

      %{"id" => id} =
        ArtifactsTool.call("save_artifact", %{"name" => "opens", "content" => "x"}, state)
        |> decode()

      assert_receive {:open_artifact, ^id, "split"}
    end

    test "mode: full is included in the broadcast", %{state: state} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{state.orca_session_id}")

      %{"id" => id} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "opens-full", "content" => "x", "mode" => "full"},
          state
        )
        |> decode()

      assert_receive {:open_artifact, ^id, "full"}
    end
  end

  describe "open_artifact" do
    test "opens by name within the calling session's project", %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "by-name", "content" => "x", "open" => false},
          state
        )
        |> decode()

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{state.orca_session_id}")

      assert %{"isError" => false} =
               result = ArtifactsTool.call("open_artifact", %{"name" => "by-name"}, state)

      assert decode(result)["id"] == id
      assert_receive {:open_artifact, ^id, "split"}
    end

    test "opens by artifact_id regardless of project scoping", %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "by-id", "content" => "x", "open" => false},
          state
        )
        |> decode()

      assert %{"isError" => false} =
               result = ArtifactsTool.call("open_artifact", %{"artifact_id" => id}, state)

      assert decode(result)["id"] == id
    end

    test "errors when neither name nor artifact_id given", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("open_artifact", %{}, state)

      assert msg =~ "name"
    end

    test "errors for an unknown name", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("open_artifact", %{"name" => "nope"}, state)

      assert msg =~ "No artifact named"
    end

    test "errors for an unknown artifact_id", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "open_artifact",
                 %{"artifact_id" => Ecto.UUID.generate()},
                 state
               )

      assert msg =~ "No artifact found"
    end
  end

  describe "list_artifacts" do
    test "lists only the calling session's project artifacts", %{project: project, state: state} do
      {:ok, _other_project} =
        Projects.create_project(%{
          name: "mcp-artifacts-test-2",
          directory: "/tmp/mcp-artifacts-2-#{System.unique_integer([:positive])}",
          node: "n1@x"
        })

      ArtifactsTool.call("save_artifact", %{"name" => "l1", "content" => "x"}, state)
      ArtifactsTool.call("save_artifact", %{"name" => "l2", "content" => "x"}, state)

      body = ArtifactsTool.call("list_artifacts", %{}, state) |> decode()

      assert body["count"] == 2
      names = Enum.map(body["artifacts"], & &1["name"])
      assert "l1" in names
      assert "l2" in names
      assert Enum.all?(body["artifacts"], &Map.has_key?(&1, "version"))
      refute Enum.any?(body["artifacts"], &Map.has_key?(&1, "content"))

      assert Artifacts.list_artifacts_for_project(project.id) |> length() == 2
    end
  end

  describe "get_artifact" do
    test "returns full content by name", %{state: state} do
      ArtifactsTool.call(
        "save_artifact",
        %{"name" => "full-content", "content" => "<p>the body</p>"},
        state
      )

      body = ArtifactsTool.call("get_artifact", %{"name" => "full-content"}, state) |> decode()
      assert body["content"] == "<p>the body</p>"
    end

    test "returns full content by artifact_id from a different session (later iteration)", %{
      state: state
    } do
      %{"id" => id} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "later", "content" => "<p>original</p>"},
          state
        )
        |> decode()

      other_state = %{orca_session_id: nil}
      body = ArtifactsTool.call("get_artifact", %{"artifact_id" => id}, other_state) |> decode()
      assert body["content"] == "<p>original</p>"
    end

    test "errors for an unknown name", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("get_artifact", %{"name" => "missing"}, state)

      assert msg =~ "No artifact named"
    end
  end

  describe "update_artifact_data" do
    test "replaces the artifact's data without bumping version", %{state: state} do
      %{"id" => id, "version" => v1} =
        ArtifactsTool.call("save_artifact", %{"name" => "dash", "content" => "<p>hi</p>"}, state)
        |> decode()

      assert v1 == 1

      result =
        ArtifactsTool.call(
          "update_artifact_data",
          %{"artifact_id" => id, "data" => %{"count" => 7}},
          state
        )

      assert %{"isError" => false} = result
      body = decode(result)
      assert body["id"] == id
      assert body["version"] == 1
      assert body["data_updated"] == true

      artifact = Artifacts.get_artifact(id)
      assert artifact.data == %{"count" => 7}
      assert artifact.version == 1
    end

    test "resolves the artifact by name within the calling session's project", %{state: state} do
      ArtifactsTool.call("save_artifact", %{"name" => "by-name", "content" => "x"}, state)

      result =
        ArtifactsTool.call(
          "update_artifact_data",
          %{"name" => "by-name", "data" => %{"a" => 1}},
          state
        )

      assert %{"isError" => false} = result
    end

    test "broadcasts {:artifact_data_updated, artifact} on the artifact topic", %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call("save_artifact", %{"name" => "bcast", "content" => "x"}, state)
        |> decode()

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{id}")

      ArtifactsTool.call(
        "update_artifact_data",
        %{"artifact_id" => id, "data" => %{"n" => 1}},
        state
      )

      assert_receive {:artifact_data_updated, %{id: ^id, data: %{"n" => 1}}}
    end

    test "errors when `data` is missing or not an object", %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call("save_artifact", %{"name" => "no-data", "content" => "x"}, state)
        |> decode()

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("update_artifact_data", %{"artifact_id" => id}, state)

      assert msg =~ "data"

      assert %{"isError" => true} =
               ArtifactsTool.call(
                 "update_artifact_data",
                 %{"artifact_id" => id, "data" => "not an object"},
                 state
               )
    end

    test "errors for an unknown artifact_id", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "update_artifact_data",
                 %{"artifact_id" => Ecto.UUID.generate(), "data" => %{}},
                 state
               )

      assert msg =~ "No artifact found"
    end
  end

  describe "screenshot_artifact" do
    test "errors with the manual recipe (including the raw URL) when playwright isn't connected",
         %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call("save_artifact", %{"name" => "no-upstream", "content" => "x"}, state)
        |> decode()

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call("screenshot_artifact", %{"artifact_id" => id}, state)

      assert msg =~ "isn't connected"
      assert msg =~ "http://orca-hub.lab.svc.cluster.local:4000/artifacts/#{id}/raw?v=1"
      assert msg =~ "browser_resize"
      assert msg =~ "browser_navigate"
      assert msg =~ "browser_take_screenshot"
    end

    test "errors for an unknown artifact", %{state: state} do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "screenshot_artifact",
                 %{"artifact_id" => Ecto.UUID.generate()},
                 state
               )

      assert msg =~ "No artifact found"
    end

    test "list/0 advertises the [375, 768, 1440] viewport default in its schema" do
      tool = Enum.find(ArtifactsTool.list(), &(&1["name"] == "screenshot_artifact"))
      assert tool["inputSchema"]["properties"]["viewports"]["type"] == "array"
      assert tool["inputSchema"]["properties"]["viewports"]["description"] =~ "375, 768, 1440"
    end
  end

  describe "render_screenshots/5 (dependency-injected)" do
    setup %{project: project} do
      dir = project.directory

      {:ok, artifact} =
        Artifacts.save_artifact(%{project_id: project.id, name: "shot-me", content: "<p>x</p>"})

      {:ok, artifact: artifact, dir: dir}
    end

    defp fake_png do
      # Smallest possible content is irrelevant — any bytes stand in for a
      # real screenshot, since decode/save only care about the base64 wire
      # format and the mimeType, never the image contents.
      Base.encode64("fake png bytes")
    end

    test "saves one screenshot per viewport under .agents/media/<session-id>/ and returns paths",
         %{artifact: artifact, session: session, dir: dir} do
      call_fn = fn
        "playwright__browser_resize", _args, _opts ->
          %{"content" => [%{"type" => "text", "text" => "resized"}], "isError" => false}

        "playwright__browser_navigate", _args, _opts ->
          %{"content" => [%{"type" => "text", "text" => "navigated"}], "isError" => false}

        "playwright__browser_take_screenshot", args, _opts ->
          refute Map.has_key?(args, "filename")

          %{
            "content" => [
              %{"type" => "image", "data" => fake_png(), "mimeType" => "image/png"}
            ],
            "isError" => false
          }
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375, 768],
          session.id,
          fn -> true end,
          call_fn
        )

      assert %{"isError" => false} = result
      body = decode(result)
      assert length(body["screenshots"]) == 2

      Enum.each(body["screenshots"], fn shot ->
        assert is_binary(shot["path"])
        refute Map.has_key?(shot, "error")
        assert File.read!(shot["path"]) == "fake png bytes"
        assert Path.dirname(shot["path"]) == Path.join([dir, ".agents", "media", session.id])
        assert Path.basename(shot["path"]) == "artifact-shot-me-#{shot["width"]}px.png"
      end)
    end

    test "a per-viewport upstream error doesn't abort the other viewports", %{
      artifact: artifact,
      session: session
    } do
      call_fn = fn
        "playwright__browser_resize", %{"width" => 375}, _opts ->
          %{"content" => [%{"type" => "text", "text" => "boom"}], "isError" => true}

        "playwright__browser_resize", _args, _opts ->
          %{"content" => [], "isError" => false}

        "playwright__browser_navigate", _args, _opts ->
          %{"content" => [], "isError" => false}

        "playwright__browser_take_screenshot", _args, _opts ->
          %{
            "content" => [%{"type" => "image", "data" => fake_png(), "mimeType" => "image/png"}],
            "isError" => false
          }
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375, 768],
          session.id,
          fn -> true end,
          call_fn
        )

      body = decode(result)
      by_width = Map.new(body["screenshots"], &{&1["width"], &1})

      assert by_width[375]["error"] =~ "boom"
      refute Map.has_key?(by_width[375], "path")
      assert is_binary(by_width[768]["path"])
    end

    test "an image-less screenshot response is reported as a per-viewport error", %{
      artifact: artifact,
      session: session
    } do
      call_fn = fn
        "playwright__browser_take_screenshot", _args, _opts ->
          %{"content" => [%{"type" => "text", "text" => "no image here"}], "isError" => false}

        _name, _args, _opts ->
          %{"content" => [], "isError" => false}
      end

      result =
        ArtifactsTool.render_screenshots(artifact, [375], session.id, fn -> true end, call_fn)

      [shot] = decode(result)["screenshots"]
      assert shot["error"] =~ "did not return an image"
    end
  end
end
