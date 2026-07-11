defmodule OrcaHub.SessionHeartbeatTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.SessionHeartbeat
  alias OrcaHub.Sessions

  defp fixture_session(attrs) do
    dir = Path.join(System.tmp_dir!(), "heartbeat-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(Map.merge(%{directory: dir, status: "ready"}, attrs))

    session
  end

  defp base_entry(overrides \\ %{}) do
    Map.merge(
      %{
        message: "wake up",
        watch_session_ids: [],
        watch_children: false,
        only_if_changed: false,
        last_snapshot: nil
      },
      overrides
    )
  end

  describe "schedule/4, get/1, cancel/1" do
    test "stores watch fields and defaults them when omitted" do
      id = Ecto.UUID.generate()
      on_exit(fn -> SessionHeartbeat.cancel(id) end)

      assert :ok = SessionHeartbeat.schedule(id, 30, "hello")

      assert %{watch_session_ids: [], watch_children: false, only_if_changed: false} =
               SessionHeartbeat.get(id)
    end

    test "stores explicit watch options" do
      id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      on_exit(fn -> SessionHeartbeat.cancel(id) end)

      assert :ok =
               SessionHeartbeat.schedule(id, 30, "hello", %{
                 watch_session_ids: [other_id],
                 watch_children: true,
                 only_if_changed: true
               })

      assert %{watch_session_ids: [^other_id], watch_children: true, only_if_changed: true} =
               SessionHeartbeat.get(id)
    end

    test "rescheduling resets watch options to the new call's values" do
      id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      on_exit(fn -> SessionHeartbeat.cancel(id) end)

      assert :ok =
               SessionHeartbeat.schedule(id, 30, "hello", %{watch_session_ids: [other_id]})

      assert :ok = SessionHeartbeat.schedule(id, 30, "hello again")

      assert %{watch_session_ids: [], watch_children: false, only_if_changed: false} =
               SessionHeartbeat.get(id)
    end

    test "rejects an interval below the minimum" do
      id = Ecto.UUID.generate()
      assert {:error, _} = SessionHeartbeat.schedule(id, 10, "hello")
      assert SessionHeartbeat.get(id) == nil
    end

    test "cancel clears the heartbeat" do
      id = Ecto.UUID.generate()
      assert :ok = SessionHeartbeat.schedule(id, 30, "hello")
      assert :ok = SessionHeartbeat.cancel(id)
      assert SessionHeartbeat.get(id) == nil
    end
  end

  describe "build_fire/2" do
    test "no watch list: always delivers the plain message" do
      result = SessionHeartbeat.build_fire("caller", base_entry())

      assert result.deliver? == true
      assert result.message == "wake up"
      assert result.snapshot == %{}
    end

    test "appends the watch digest to the message" do
      watched = fixture_session(%{title: "worker"})
      entry = base_entry(%{watch_session_ids: [watched.id]})

      result = SessionHeartbeat.build_fire("caller", entry)

      assert result.deliver? == true
      assert result.message =~ "wake up"
      assert result.message =~ "worker"
      assert Map.has_key?(result.snapshot, watched.id)
    end

    test "only_if_changed with no resolved watch list still delivers" do
      entry = base_entry(%{only_if_changed: true})

      result = SessionHeartbeat.build_fire("caller", entry)

      assert result.deliver? == true
    end

    test "only_if_changed delivers on the first fire (nil last_snapshot)" do
      watched = fixture_session(%{title: "worker"})
      entry = base_entry(%{watch_session_ids: [watched.id], only_if_changed: true})

      result = SessionHeartbeat.build_fire("caller", entry)

      assert result.deliver? == true
    end

    test "only_if_changed suppresses delivery when nothing changed since the last fire" do
      watched = fixture_session(%{title: "worker", status: "running"})
      entry = base_entry(%{watch_session_ids: [watched.id], only_if_changed: true})

      first = SessionHeartbeat.build_fire("caller", entry)
      second = SessionHeartbeat.build_fire("caller", %{entry | last_snapshot: first.snapshot})

      assert second.deliver? == false
    end

    test "only_if_changed re-delivers once a watched session changes" do
      watched = fixture_session(%{title: "worker", status: "running"})
      entry = base_entry(%{watch_session_ids: [watched.id], only_if_changed: true})

      first = SessionHeartbeat.build_fire("caller", entry)
      {:ok, _} = Sessions.update_session(watched, %{status: "idle"})
      second = SessionHeartbeat.build_fire("caller", %{entry | last_snapshot: first.snapshot})

      assert second.deliver? == true
    end
  end
end
