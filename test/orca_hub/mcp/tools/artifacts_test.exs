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

    {:ok, project: project, session: session, dir: dir, state: %{orca_session_id: session.id}}
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
      assert save_tool["inputSchema"]["required"] == ["name"]
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

  describe "save_artifact — content_path (ORCAHUB3-56)" do
    test "reads content from a file inside the session directory and saves it", %{
      dir: dir,
      state: state
    } do
      path = Path.join(dir, "deck.html")
      File.write!(path, "<html><body>from disk</body></html>")

      assert %{"isError" => false} =
               result =
               ArtifactsTool.call(
                 "save_artifact",
                 %{"name" => "from-path", "content_path" => path},
                 state
               )

      body = decode(result)
      assert body["content_path"] == path

      artifact = Artifacts.get_artifact(body["id"])
      assert artifact.content == "<html><body>from disk</body></html>"
    end

    test "errors when both content and content_path are given", %{dir: dir, state: state} do
      path = Path.join(dir, "x.html")
      File.write!(path, "x")

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               ArtifactsTool.call(
                 "save_artifact",
                 %{"name" => "x", "content" => "y", "content_path" => path},
                 state
               )

      assert msg =~ "exactly one of `content` or `content_path`"
    end

    test "refuses an absolute path outside the session directory", %{state: state} do
      result =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "x", "content_path" => "/etc/passwd"},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "outside this session's working directory"
    end

    test "refuses a symlink inside the session directory pointing outside it", %{
      dir: dir,
      state: state
    } do
      outside_dir =
        Path.join(
          Path.dirname(dir),
          "mcp_artifacts_symlink_target_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      real_file = Path.join(outside_dir, "real.html")
      File.write!(real_file, "real content")
      on_exit(fn -> File.rm_rf(outside_dir) end)

      link = Path.join(dir, "escape_link.html")
      File.ln_s!(real_file, link)

      result =
        ArtifactsTool.call("save_artifact", %{"name" => "x", "content_path" => link}, state)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "outside this session's working directory"
    end

    test "refuses a file over the 50MB cap", %{dir: dir, state: state} do
      path = Path.join(dir, "big.html")
      File.write!(path, :binary.copy(<<0>>, OrcaHub.Files.max_file_bytes() + 1))

      result =
        ArtifactsTool.call("save_artifact", %{"name" => "x", "content_path" => path}, state)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "exceeding"
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

    test "returns the exact expected key set", %{state: state} do
      ArtifactsTool.call("save_artifact", %{"name" => "keyset", "content" => "<p>x</p>"}, state)

      body = ArtifactsTool.call("get_artifact", %{"name" => "keyset"}, state) |> decode()

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort(~w(id name kind version content data raw_url updated_at))
    end

    test "returns an empty data map for a freshly-saved artifact", %{state: state} do
      ArtifactsTool.call("save_artifact", %{"name" => "no-data-yet", "content" => "x"}, state)

      body = ArtifactsTool.call("get_artifact", %{"name" => "no-data-yet"}, state) |> decode()
      assert body["data"] == %{}
    end

    test "round-trips a populated _user_state through data", %{state: state} do
      %{"id" => id} =
        ArtifactsTool.call(
          "save_artifact",
          %{"name" => "with-state", "content" => "<p>x</p>"},
          state
        )
        |> decode()

      ArtifactsTool.call(
        "update_artifact_data",
        %{"artifact_id" => id, "data" => %{"_user_state" => %{"checked" => true}}},
        state
      )

      body = ArtifactsTool.call("get_artifact", %{"artifact_id" => id}, state) |> decode()
      assert body["data"] == %{"_user_state" => %{"checked" => true}}
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

    test "not-available error contains the install hint and the artifact's raw URL", %{
      artifact: artifact,
      session: session
    } do
      result =
        ArtifactsTool.render_screenshots(artifact, [375], session.id, fn -> false end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} = result
      assert msg =~ "isn't available"
      assert msg =~ "npx playwright install chromium"
      assert msg =~ "/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
    end

    test "saves one real screenshot file per viewport under .agents/media/<session-id>/, " <>
           "passing the rendered artifact's own html + a 900px height, and cleans up the " <>
           "temp html file afterward",
         %{artifact: artifact, session: session, dir: dir} do
      test_pid = self()

      screenshot_fn = fn html_path, width, height, out_path ->
        send(test_pid, {:screenshot_call, html_path, width, height, out_path})
        assert File.exists?(html_path)
        assert File.read!(html_path) == OrcaHub.Artifacts.Render.body(artifact)
        assert height == 900
        File.write!(out_path, "fake png for #{width}")
        :ok
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375, 768],
          session.id,
          fn -> true end,
          screenshot_fn
        )

      assert %{"isError" => false} = result
      body = decode(result)
      assert length(body["screenshots"]) == 2

      Enum.each(body["screenshots"], fn shot ->
        assert is_binary(shot["path"])
        refute Map.has_key?(shot, "error")
        assert File.read!(shot["path"]) == "fake png for #{shot["width"]}"
        assert Path.dirname(shot["path"]) == Path.join([dir, ".agents", "media", session.id])
        assert Path.basename(shot["path"]) == "artifact-shot-me-#{shot["width"]}px.png"
      end)

      assert_receive {:screenshot_call, html_path, _width, _height, _out_path}
      refute File.exists?(html_path)
    end

    test "a per-viewport CLI failure doesn't abort the other viewports", %{
      artifact: artifact,
      session: session
    } do
      screenshot_fn = fn
        _html_path, 375, _height, _out_path -> {:error, "boom"}
        _html_path, _width, _height, out_path -> File.write!(out_path, "ok") && :ok
      end

      result =
        ArtifactsTool.render_screenshots(
          artifact,
          [375, 768],
          session.id,
          fn -> true end,
          screenshot_fn
        )

      body = decode(result)
      by_width = Map.new(body["screenshots"], &{&1["width"], &1})

      assert by_width[375]["error"] == "boom"
      refute Map.has_key?(by_width[375], "path")
      assert is_binary(by_width[768]["path"])
    end
  end

  describe "run_bounded/3 (shell-out behind playwright_available?/run_playwright_screenshot)" do
    test "returns :ok for a clean exit" do
      assert ArtifactsTool.run_bounded("sh", ["-c", "exit 0"], 2_000) == :ok
    end

    test "returns the trimmed combined stdout+stderr on a non-zero exit" do
      assert ArtifactsTool.run_bounded(
               "sh",
               ["-c", "echo boom 1>&2; exit 3"],
               2_000
             ) == {:error, "boom"}
    end

    test "on timeout, returns the timeout error and kills the whole process tree" do
      pidfile =
        Path.join(System.tmp_dir!(), "run_bounded_test_#{System.unique_integer([:positive])}")

      # A grandchild (nested `sh -c`) stands in for npx -> node -> chromium:
      # if only the immediate child were killed (the old Task.shutdown
      # behavior), this grandchild would survive and keep running.
      assert ArtifactsTool.run_bounded(
               "sh",
               ["-c", "sh -c 'echo $$ > #{pidfile}; sleep 20' & wait"],
               200
             ) == {:error, "playwright timed out after 200ms"}

      grandchild_pid = pidfile |> File.read!() |> String.trim()
      File.rm(pidfile)

      # Poll briefly rather than a single fixed sleep — kill -9 delivery is
      # async, but should land well within a couple hundred ms.
      assert wait_until(500, fn ->
               match?({_, 1}, System.cmd("ps", ["-p", grandchild_pid], stderr_to_stdout: true))
             end),
             "expected process #{grandchild_pid} to be reaped after the timeout, but it's still alive"
    end
  end

  defp wait_until(budget_ms, check, interval_ms \\ 25)
  defp wait_until(budget_ms, _check, _interval_ms) when budget_ms <= 0, do: false

  defp wait_until(budget_ms, check, interval_ms) do
    if check.() do
      true
    else
      Process.sleep(interval_ms)
      wait_until(budget_ms - interval_ms, check, interval_ms)
    end
  end
end
