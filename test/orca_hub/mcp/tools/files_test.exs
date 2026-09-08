defmodule OrcaHub.MCP.Tools.FilesTest do
  @moduledoc """
  Coverage for the cross-node file store MCP tools (ORCAHUB3-72):
  `put_file`/`get_file`/`list_files`/`share_file`/`delete_file`. Uses real
  tmp directories (session working dirs + real symlinks) and a real
  `OrcaHub.ObjectStore.Local` root, since `put_file`'s path confinement
  and `get_file`'s `.orca_inbox/` write are both real filesystem
  operations, not mocked. `async: false` — the object store root is
  process-wide Application env.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Files, as: FilesTool
  alias OrcaHub.{ClusterNodes, Files, Projects, Sessions}

  setup do
    session_dir =
      Path.join(System.tmp_dir!(), "mcp_files_session_#{System.unique_integer([:positive])}")

    File.mkdir_p!(session_dir)

    store_dir =
      Path.join(System.tmp_dir!(), "mcp_files_store_#{System.unique_integer([:positive])}")

    Application.put_env(:orca_hub, :file_store_dir, store_dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(session_dir)
      File.rm_rf(store_dir)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "mcp-files-test-#{System.unique_integer([:positive])}",
        directory: session_dir,
        node: Atom.to_string(node())
      })

    {:ok, session} =
      Sessions.create_session(%{directory: session_dir, project_id: project.id})

    {:ok,
     project: project, session: session, dir: session_dir, state: %{orca_session_id: session.id}}
  end

  defp decode(%{"content" => [%{"text" => body}]}), do: body

  describe "put_file — path confinement (invariant 1)" do
    test "stores a file whose path is inside the session directory", %{dir: dir, state: state} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert %{"isError" => false} = result = FilesTool.call("put_file", %{"path" => path}, state)
      assert decode(result) =~ "Stored file"
    end

    test "refuses an absolute path outside the session directory", %{state: state} do
      result = FilesTool.call("put_file", %{"path" => "/etc/passwd"}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "outside this session's working directory"
    end

    test "refuses a relative path that escapes via ..", %{dir: dir, state: state} do
      outside_dir =
        Path.join(Path.dirname(dir), "mcp_files_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "secret.txt"), "secret")
      on_exit(fn -> File.rm_rf(outside_dir) end)

      escape_path = Path.join(dir, "../#{Path.basename(outside_dir)}/secret.txt")
      result = FilesTool.call("put_file", %{"path" => escape_path}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "outside this session's working directory"
    end

    test "refuses a symlink inside the session directory pointing outside it", %{
      dir: dir,
      state: state
    } do
      outside_dir =
        Path.join(
          Path.dirname(dir),
          "mcp_files_symlink_target_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside_dir)
      real_file = Path.join(outside_dir, "real.txt")
      File.write!(real_file, "real content")
      on_exit(fn -> File.rm_rf(outside_dir) end)

      link = Path.join(dir, "escape_link")
      File.ln_s!(real_file, link)

      result = FilesTool.call("put_file", %{"path" => link}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "outside this session's working directory"
    end

    test "refuses a file over the 50MB cap", %{dir: dir, state: state} do
      path = Path.join(dir, "big.bin")
      File.write!(path, :binary.copy(<<0>>, Files.max_file_bytes() + 1))

      result = FilesTool.call("put_file", %{"path" => path}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "50MB"
    end
  end

  describe "put_file -> get_file round trip" do
    test "get_file writes the file under .orca_inbox/, id-prefixed", %{dir: dir, state: state} do
      path = Path.join(dir, "roundtrip.txt")
      File.write!(path, "roundtrip content")

      put_result = FilesTool.call("put_file", %{"path" => path}, state)
      assert %{"isError" => false} = put_result
      "Stored file " <> rest = decode(put_result)
      [file_id | _] = String.split(rest, " ")

      get_result = FilesTool.call("get_file", %{"file_id" => file_id}, state)
      assert %{"isError" => false} = get_result
      text = decode(get_result)
      assert text =~ "Saved roundtrip.txt"

      inbox_dir = Path.join(dir, ".orca_inbox")
      [written] = File.ls!(inbox_dir)
      assert written == "#{String.slice(file_id, 0, 8)}_roundtrip.txt"
      assert File.read!(Path.join(inbox_dir, written)) == "roundtrip content"
    end

    test "get_file refuses a file not visible to the caller", %{dir: dir, state: state} do
      other_project_dir =
        Path.join(System.tmp_dir!(), "mcp_files_other_#{System.unique_integer([:positive])}")

      File.mkdir_p!(other_project_dir)
      on_exit(fn -> File.rm_rf(other_project_dir) end)

      {:ok, other_project} =
        Projects.create_project(%{
          name: "mcp-files-other-#{System.unique_integer([:positive])}",
          directory: other_project_dir,
          node: Atom.to_string(node())
        })

      {:ok, file} =
        Files.create_file(
          %{project_id: other_project.id, session_id: nil, name: "hidden.txt"},
          "hidden"
        )

      result = FilesTool.call("get_file", %{"file_id" => file.id}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not found or not visible"
      refute File.exists?(Path.join(dir, ".orca_inbox"))
    end
  end

  describe "list_files" do
    test "lists a file the session just created", %{dir: dir, state: state} do
      path = Path.join(dir, "listed.txt")
      File.write!(path, "content")
      FilesTool.call("put_file", %{"path" => path}, state)

      result = FilesTool.call("list_files", %{}, state)
      assert %{"isError" => false} = result
      assert decode(result) =~ "listed.txt"
    end

    test "reports no files when none are visible", %{state: state} do
      result = FilesTool.call("list_files", %{}, state)
      assert decode(result) == "No files visible to this session."
    end
  end

  describe "share_file" do
    test "shares with another session in the same project", %{
      dir: dir,
      project: project,
      state: state
    } do
      path = Path.join(dir, "share_me.txt")
      File.write!(path, "content")
      put_result = FilesTool.call("put_file", %{"path" => path}, state)
      "Stored file " <> rest = decode(put_result)
      [file_id | _] = String.split(rest, " ")

      {:ok, peer} = Sessions.create_session(%{directory: dir, project_id: project.id})

      result =
        FilesTool.call("share_file", %{"file_id" => file_id, "session_id" => peer.id}, state)

      assert %{"isError" => false} = result
      assert decode(result) =~ "Shared file"
    end

    test "denies sharing to a session on another node when this node is isolated", %{
      dir: dir,
      state: state
    } do
      node_row =
        ClusterNodes.get_by_name(Atom.to_string(node())) ||
          (
            {:ok, row} = ClusterNodes.upsert_seen(Atom.to_string(node()), Atom.to_string(node()))
            row
          )

      {:ok, _} = ClusterNodes.update_node(node_row, %{isolated: true})

      path = Path.join(dir, "share_isolated.txt")
      File.write!(path, "content")
      put_result = FilesTool.call("put_file", %{"path" => path}, state)
      "Stored file " <> rest = decode(put_result)
      [file_id | _] = String.split(rest, " ")

      {:ok, remote_target} =
        Sessions.create_session(%{directory: dir, runner_node: "debian@totally-offline-host"})

      result =
        FilesTool.call(
          "share_file",
          %{"file_id" => file_id, "session_id" => remote_target.id},
          state
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
    end
  end

  describe "delete_file" do
    test "the creating session can delete its own file", %{dir: dir, state: state} do
      path = Path.join(dir, "delete_me.txt")
      File.write!(path, "content")
      put_result = FilesTool.call("put_file", %{"path" => path}, state)
      "Stored file " <> rest = decode(put_result)
      [file_id | _] = String.split(rest, " ")

      result = FilesTool.call("delete_file", %{"file_id" => file_id}, state)
      assert %{"isError" => false} = result
      assert decode(result) =~ "Deleted file"
      assert Files.get_file(file_id) == nil
    end

    test "a session that can only see a file via a share cannot delete it", %{state: state} do
      {:ok, file} =
        Files.create_file(%{session_id: session_from(state).id, name: "shared_only.txt"}, "x")

      other_dir =
        Path.join(System.tmp_dir!(), "mcp_files_del_other_#{System.unique_integer([:positive])}")

      File.mkdir_p!(other_dir)
      on_exit(fn -> File.rm_rf(other_dir) end)

      {:ok, other_project} =
        Projects.create_project(%{
          name: "mcp-files-del-other-#{System.unique_integer([:positive])}",
          directory: other_dir,
          node: Atom.to_string(node())
        })

      {:ok, other_session} =
        Sessions.create_session(%{directory: other_dir, project_id: other_project.id})

      {:ok, _} = Files.share_file(file, %{session_id: other_session.id})

      result =
        FilesTool.call(
          "delete_file",
          %{"file_id" => file.id},
          %{orca_session_id: other_session.id}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not eligible for deletion"
      assert Files.get_file(file.id) != nil
    end
  end

  defp session_from(%{orca_session_id: id}), do: OrcaHub.HubRPC.get_session(id)
end
