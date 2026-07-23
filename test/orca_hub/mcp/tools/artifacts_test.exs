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
end
