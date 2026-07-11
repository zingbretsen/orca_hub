defmodule OrcaHub.SessionHeartbeat.DigestTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.SessionHeartbeat.Digest
  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.Message

  defp fixture_session(attrs) do
    dir = Path.join(System.tmp_dir!(), "digest-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(Map.merge(%{directory: dir, status: "ready"}, attrs))

    session
  end

  defp insert_message(session, minutes_ago \\ 0) do
    {:ok, message} =
      Sessions.create_message(%{
        session_id: session.id,
        data: %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text"}]}}
      })

    if minutes_ago > 0 do
      ts = NaiveDateTime.utc_now() |> NaiveDateTime.add(-minutes_ago * 60, :second)
      from(m in Message, where: m.id == ^message.id) |> Repo.update_all(set: [inserted_at: ts])
    end

    message
  end

  describe "build/3" do
    test "returns {nil, %{}} when nothing resolves" do
      assert Digest.build("caller-id", [], false) == {nil, %{}}
    end

    test "resolves explicit watch_session_ids" do
      watched = fixture_session(%{title: "worker one", status: "running"})

      {digest, snapshot} = Digest.build("caller-id", [watched.id], false)

      assert digest =~ "worker one"
      assert digest =~ "[running]"
      assert Map.has_key?(snapshot, watched.id)
    end

    test "drops non-existent watch ids silently" do
      assert Digest.build("caller-id", ["00000000-0000-0000-0000-000000000000"], false) ==
               {nil, %{}}
    end

    test "drops archived watched sessions silently" do
      watched = fixture_session(%{title: "archived worker"})
      {:ok, archived} = Sessions.update_session(watched, %{archived_at: DateTime.utc_now()})

      assert Digest.build("caller-id", [archived.id], false) == {nil, %{}}
    end

    test "watch_children resolves the caller's current non-archived children" do
      caller = fixture_session(%{title: "orchestrator"})
      child = fixture_session(%{title: "child", parent_session_id: caller.id})
      grandchild = fixture_session(%{title: "grandchild", parent_session_id: child.id})

      other = fixture_session(%{title: "unrelated"})

      {digest, snapshot} = Digest.build(caller.id, [], true)

      assert digest =~ "child"
      refute digest =~ "grandchild"
      refute digest =~ "unrelated"
      assert Map.has_key?(snapshot, child.id)
      refute Map.has_key?(snapshot, grandchild.id)
      refute Map.has_key?(snapshot, other.id)
    end

    test "excludes archived children" do
      caller = fixture_session(%{title: "orchestrator"})
      child = fixture_session(%{title: "child", parent_session_id: caller.id})
      {:ok, _} = Sessions.update_session(child, %{archived_at: DateTime.utc_now()})

      assert Digest.build(caller.id, [], true) == {nil, %{}}
    end

    test "dedups a session that is both explicitly watched and a resolved child" do
      caller = fixture_session(%{title: "orchestrator"})
      child = fixture_session(%{title: "child", parent_session_id: caller.id})

      {digest, snapshot} = Digest.build(caller.id, [child.id], true)

      # one "-" bullet line for the session, not two
      assert Enum.count(String.split(digest, "\n- ")) - 1 == 1
      assert map_size(snapshot) == 1
    end

    test "includes progress phase/note and activity counts" do
      watched =
        fixture_session(%{
          title: "phased worker",
          status: "running",
          progress_phase: "implementing",
          progress_note: "writing tests"
        })

      insert_message(watched)

      {digest, snapshot} = Digest.build("caller-id", [watched.id], false)

      assert digest =~ "implementing (writing tests)"
      assert digest =~ "1msg/0tool (5m)"

      assert {"running", "implementing", "writing tests", _last_activity_at} =
               snapshot[watched.id]
    end

    test "includes error_detail only when status is error" do
      errored =
        fixture_session(%{
          title: "broken worker",
          status: "error",
          error_detail: "boom: something failed"
        })

      running = fixture_session(%{title: "fine worker", status: "running"})

      {digest, _snapshot} = Digest.build("caller-id", [errored.id, running.id], false)

      assert digest =~ "boom: something failed"
      # the running session should still appear without the error text tacked on
      lines = digest |> String.split("\n") |> Enum.filter(&(&1 =~ "fine worker"))
      assert lines == ["- fine worker [running] | 0msg/0tool (5m)"]
    end

    test "includes last git commit when the directory is a repo" do
      dir = Path.join(System.tmp_dir!(), "digest-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "f.txt"), "hi")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: dir)

      {:ok, watched} =
        Sessions.create_session(%{directory: dir, title: "git worker", status: "idle"})

      {digest, _snapshot} = Digest.build("caller-id", [watched.id], false)

      assert digest =~ ~s(commit) and digest =~ ~s("initial commit")
    end

    test "falls back to a short id when title is nil" do
      watched = fixture_session(%{title: nil})

      {digest, _snapshot} = Digest.build("caller-id", [watched.id], false)

      assert digest =~ "session #{String.slice(watched.id, 0, 8)}"
    end
  end

  describe "changed?/2" do
    test "nil old snapshot always counts as changed" do
      assert Digest.changed?(nil, %{})
      assert Digest.changed?(nil, %{"a" => {"running", nil, nil, nil}})
    end

    test "identical snapshots are not changed" do
      snap = %{"a" => {"running", "implementing", nil, nil}}
      refute Digest.changed?(snap, snap)
    end

    test "different snapshots are changed" do
      old = %{"a" => {"running", "implementing", nil, nil}}
      new = %{"a" => {"idle", "implementing", nil, nil}}
      assert Digest.changed?(old, new)
    end
  end
end
