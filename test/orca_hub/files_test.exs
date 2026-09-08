defmodule OrcaHub.FilesTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Files, Projects, Sessions}

  # async: false — every test writes real bytes via OrcaHub.ObjectStore.Local,
  # scoped to a per-test tmp dir set in app env (process-wide state).

  setup do
    dir =
      Path.join(System.tmp_dir!(), "files_context_#{System.unique_integer([:positive])}")

    Application.put_env(:orca_hub, :file_store_dir, dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp fixture_project(name) do
    dir = Path.join(System.tmp_dir!(), "files_ctx_proj_#{System.unique_integer([:positive])}")

    {:ok, project} =
      Projects.create_project(%{name: name, directory: dir, node: Atom.to_string(node())})

    project
  end

  defp fixture_session(project) do
    {:ok, session} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    session
  end

  describe "create_file/2" do
    test "stores bytes and metadata, computing size + sha256" do
      project = fixture_project("files-create")
      session = fixture_session(project)
      binary = "hello world"

      assert {:ok, file} =
               Files.create_file(
                 %{project_id: project.id, session_id: session.id, name: "hello.txt"},
                 binary
               )

      assert file.size_bytes == byte_size(binary)
      assert file.sha256 == Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
      assert {:ok, ^binary} = OrcaHub.ObjectStore.get(file.object_key)
    end

    test "refuses a file over the 50MB cap without writing bytes" do
      project = fixture_project("files-cap")
      session = fixture_session(project)
      oversized = :binary.copy(<<0>>, Files.max_file_bytes() + 1)

      assert {:error, :too_large} =
               Files.create_file(
                 %{project_id: project.id, session_id: session.id, name: "big.bin"},
                 oversized
               )
    end

    test "refuses a file that would push the project over quota" do
      project = fixture_project("files-quota")
      session = fixture_session(project)
      Application.put_env(:orca_hub, :file_store_project_quota_bytes, 10)

      on_exit(fn -> Application.delete_env(:orca_hub, :file_store_project_quota_bytes) end)

      assert {:error, :quota_exceeded} =
               Files.create_file(
                 %{project_id: project.id, session_id: session.id, name: "over.bin"},
                 "0123456789ABCDEF"
               )
    end

    test "an unscoped file (no project_id) is never quota-checked" do
      project = fixture_project("files-unscoped-owner")
      session = fixture_session(project)
      Application.put_env(:orca_hub, :file_store_project_quota_bytes, 1)
      on_exit(fn -> Application.delete_env(:orca_hub, :file_store_project_quota_bytes) end)

      assert {:ok, _file} =
               Files.create_file(%{session_id: session.id, name: "unscoped.txt"}, "some bytes")
    end
  end

  describe "visible?/3 and list_visible/1" do
    setup do
      project_a = fixture_project("files-vis-a")
      project_b = fixture_project("files-vis-b")
      creator = fixture_session(project_a)
      same_project_peer = fixture_session(project_a)
      shared_session = fixture_session(project_b)
      shared_project_peer = fixture_session(project_b)
      stranger = fixture_session(project_b)

      {:ok, file} =
        Files.create_file(
          %{project_id: project_a.id, session_id: creator.id, name: "shared.txt"},
          "content"
        )

      {:ok, _} = Files.share_file(file, %{session_id: shared_session.id})
      {:ok, _} = Files.share_file(file, %{project_id: project_b.id})

      %{
        shared_file: file,
        project_a: project_a,
        project_b: project_b,
        creator: creator,
        same_project_peer: same_project_peer,
        shared_session: shared_session,
        shared_project_peer: shared_project_peer,
        stranger: stranger
      }
    end

    test "creator can see its own file", %{
      shared_file: file,
      creator: creator,
      project_a: project_a
    } do
      assert Files.visible?(file, creator.id, project_a.id)
    end

    test "a session in the same project can see it", %{
      shared_file: file,
      same_project_peer: peer,
      project_a: project_a
    } do
      assert Files.visible?(file, peer.id, project_a.id)
    end

    test "a session explicitly shared with can see it", %{
      shared_file: file,
      shared_session: shared_session,
      project_b: project_b
    } do
      assert Files.visible?(file, shared_session.id, project_b.id)
    end

    test "a session in a project explicitly shared with can see it", %{
      shared_file: file,
      shared_project_peer: peer,
      project_b: project_b
    } do
      assert Files.visible?(file, peer.id, project_b.id)
    end

    test "an unrelated session cannot see it (negative case)", %{shared_file: file} do
      other_project = fixture_project("files-vis-unrelated")
      stranger = fixture_session(other_project)
      refute Files.visible?(file, stranger.id, other_project.id)
    end

    test "list_visible/1 returns the file for every visible caller context", %{
      shared_file: file,
      creator: creator,
      project_a: project_a,
      shared_session: shared_session,
      project_b: project_b
    } do
      assert file.id in Enum.map(
               Files.list_visible(%{session_id: creator.id, project_id: project_a.id}),
               & &1.id
             )

      assert file.id in Enum.map(
               Files.list_visible(%{session_id: shared_session.id, project_id: project_b.id}),
               & &1.id
             )
    end

    test "list_visible/1 excludes it for an unrelated caller (negative case)" do
      other_project = fixture_project("files-vis-list-unrelated")
      stranger = fixture_session(other_project)

      assert Files.list_visible(%{session_id: stranger.id, project_id: other_project.id}) == []
    end
  end

  describe "deletable?/3" do
    test "creator and same-project sessions may delete; a shared session may not" do
      project = fixture_project("files-del")
      other_project = fixture_project("files-del-other")
      creator = fixture_session(project)
      peer = fixture_session(project)
      shared_session = fixture_session(other_project)

      {:ok, file} =
        Files.create_file(%{project_id: project.id, session_id: creator.id, name: "f.txt"}, "x")

      {:ok, _} = Files.share_file(file, %{session_id: shared_session.id})

      assert Files.deletable?(file, creator.id, project.id)
      assert Files.deletable?(file, peer.id, project.id)
      refute Files.deletable?(file, shared_session.id, other_project.id)
    end
  end

  describe "delete_file/1" do
    test "removes the metadata row and the underlying bytes" do
      project = fixture_project("files-delete")
      session = fixture_session(project)

      {:ok, file} =
        Files.create_file(
          %{project_id: project.id, session_id: session.id, name: "gone.txt"},
          "bye"
        )

      assert {:ok, _} = Files.delete_file(file)
      assert Files.get_file(file.id) == nil
      assert {:error, _} = OrcaHub.ObjectStore.get(file.object_key)
    end
  end
end
