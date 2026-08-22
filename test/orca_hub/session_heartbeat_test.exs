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

  # ── deliver_message_now/3's bounded retry (Track D fix) ─────────────────
  # A raised exception or process EXIT from `send_fn` simulates the target
  # runner vanishing mid-call (idle teardown, warm-pool eviction, a
  # kill-switch downgrade) - the exact race deliver_message_now/3's own doc
  # describes. An injected `send_fn` pins the retry-then-succeed and
  # retry-then-give-up paths deterministically, without depending on a
  # genuine, timing-dependent teardown race.
  #
  # Reasons matter, not just "did it raise/exit": only UNAMBIGUOUSLY
  # not-delivered reasons (:noproc, :normal, :shutdown, {:shutdown, _}) may
  # retry - a real `GenStatem.call/3` failure with one of these means the
  # target's exit :DOWN raced (and preceded) any possible reply, per
  # `retry_decision/1`'s doc. `{:timeout, _}` and anything unrecognized is
  # AMBIGUOUS (the target may have already processed the message before the
  # timeout fired) and must give up immediately rather than retry - retrying
  # an ambiguous outcome is exactly the bug class that caused the duplicate
  # fork-child-spawn incident (project-duplicate-child-spawns-rca).
  defp gen_error(reason) do
    GenStatem.GenError.exception(
      class: :exit,
      reason: reason,
      mfargs: {GenStatem, :call, [:some_ref, :some_request, :infinity]}
    )
  end

  describe "deliver_with_retry/5" do
    test "a GenError with :noproc IS retried and the next attempt's success is returned" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        |> case do
          0 -> raise gen_error(:noproc)
          _ -> :ok
        end
      end

      assert :ok = SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)
      assert Agent.get(counter, & &1) == 2
    end

    test "a process EXIT with :shutdown IS retried the same as a raise" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        |> case do
          0 -> exit(:shutdown)
          _ -> :ok
        end
      end

      assert :ok = SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)
      assert Agent.get(counter, & &1) == 2
    end

    test "exhausting every attempt on a persistently-noproc target gives up and reports an ordinary delivery failure" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.update(counter, &(&1 + 1))
        raise gen_error(:noproc)
      end

      assert {:error, :delivery_failed} =
               SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)

      # Exactly the configured attempt count - not one more, not fewer.
      assert Agent.get(counter, & &1) == 3
    end

    test "a GenError with {:timeout, _} is NOT retried - the target may have already received it" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.update(counter, &(&1 + 1))
        raise gen_error({:timeout, {GenStatem, :call, [:some_ref, :some_request, 5_000]}})
      end

      assert {:error, :delivery_failed} =
               SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)

      # A single attempt only - a timeout is ambiguous, not evidence of
      # non-delivery, so it must NOT be retried.
      assert Agent.get(counter, & &1) == 1
    end

    test "a process EXIT with an unrecognized reason is NOT retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.update(counter, &(&1 + 1))
        exit({:some_crash, [some: :details]})
      end

      assert {:error, :delivery_failed} =
               SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)

      assert Agent.get(counter, & &1) == 1
    end

    test "an ordinary {:error, reason} return is passed through, not retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.update(counter, &(&1 + 1))
        {:error, :node_unavailable}
      end

      assert {:error, :node_unavailable} =
               SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)

      assert Agent.get(counter, & &1) == 1
    end

    test "a clean first-attempt success never retries" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      send_fn = fn _node, _session_id, _message, :interrupt ->
        Agent.update(counter, &(&1 + 1))
        :ok
      end

      assert :ok = SessionHeartbeat.deliver_with_retry("n", "s", "hi", 3, send_fn)
      assert Agent.get(counter, & &1) == 1
    end
  end

  # ── item 4: auto-cancel wiring matches the REAL broadcast shape ─────────
  # Regression coverage for ORCAHUB3-26 item 4: the old handle_info clauses
  # matched {:session_archived, id}/{:session_deleted, id}, tuples nothing in
  # `lib/` ever broadcasts — the real shape (see `SessionRunner.broadcast/2`,
  # `Sessions.archive_session/1`, `Sessions.delete_session/1`) is
  # `{session_id, {:status, atom}}` on the "sessions" PubSub topic. These
  # tests drive the real broadcast path (not a synthetic message shape) so a
  # regression back to the wrong tuple shape would actually fail them.
  describe "auto-cancel on archive/delete" do
    defp wait_until(fun, attempts \\ 100)
    defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

    defp wait_until(fun, attempts) do
      if fun.() do
        :ok
      else
        Process.sleep(20)
        wait_until(fun, attempts - 1)
      end
    end

    test "archiving a session auto-cancels its heartbeat" do
      session = fixture_session(%{})
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "hello")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert {:ok, _} = Sessions.archive_session(session)

      wait_until(fn -> SessionHeartbeat.get(session.id) == nil end)
    end

    test "deleting a session auto-cancels its heartbeat" do
      session = fixture_session(%{})
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "hello")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      assert {:ok, _} = Sessions.delete_session(session)

      wait_until(fn -> SessionHeartbeat.get(session.id) == nil end)
    end

    test "a status broadcast unrelated to archive/delete does not touch the heartbeat" do
      session = fixture_session(%{})
      assert :ok = SessionHeartbeat.schedule(session.id, 30, "hello")
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :running}})

      # No async cancellation to wait for; give the (non-)event a moment to
      # land, then assert the heartbeat is still there.
      Process.sleep(50)
      refute SessionHeartbeat.get(session.id) == nil
    end
  end

  # ── item 5: lifecycle_snapshot_changed?/2 ────────────────────────────────
  describe "lifecycle_snapshot_changed?/2" do
    test "the first check for a session id always reports changed" do
      id = Ecto.UUID.generate()
      assert SessionHeartbeat.lifecycle_snapshot_changed?(id, {"idle", nil, nil}) == true
    end

    test "an identical follow-up snapshot reports unchanged" do
      id = Ecto.UUID.generate()
      snapshot = {"idle", "implementing", "writing tests"}

      assert SessionHeartbeat.lifecycle_snapshot_changed?(id, snapshot) == true
      assert SessionHeartbeat.lifecycle_snapshot_changed?(id, snapshot) == false
      # Still unchanged on a third identical check - not a one-shot latch.
      assert SessionHeartbeat.lifecycle_snapshot_changed?(id, snapshot) == false
    end

    test "a differing snapshot reports changed, then settles back to unchanged" do
      id = Ecto.UUID.generate()

      assert SessionHeartbeat.lifecycle_snapshot_changed?(id, {"idle", nil, nil}) == true

      assert SessionHeartbeat.lifecycle_snapshot_changed?(
               id,
               {"idle", "implementing", "writing tests"}
             ) == true

      assert SessionHeartbeat.lifecycle_snapshot_changed?(
               id,
               {"idle", "implementing", "writing tests"}
             ) == false
    end

    test "different session ids track independent baselines" do
      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()
      snapshot = {"idle", "implementing", nil}

      assert SessionHeartbeat.lifecycle_snapshot_changed?(id_a, snapshot) == true
      # id_b has never been checked, so it's still a fresh baseline too.
      assert SessionHeartbeat.lifecycle_snapshot_changed?(id_b, snapshot) == true
    end
  end

  describe "churn detection in digest" do
    test "a churn-suspected session renders the CHURN? segment" do
      dir = Path.join(System.tmp_dir!(), "churn-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
        })

      # Create messages to simulate churn: many repeated tool calls
      Enum.each(1..30, fn _i ->
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Bash",
                  "input" => %{"command" => String.duplicate("a", 100)}
                }
              ]
            }
          }
        })
      end)

      # The digest message should contain CHURN? segment
      digest =
        SessionHeartbeat.build_fire(
          "caller",
          base_entry(%{watch_session_ids: [session.id], only_if_changed: false})
        )

      assert digest.message =~ "CHURN?"
      assert digest.message =~ "30 calls/15m"
    end

    test "a normal session's digest line remains unchanged (no CHURN? segment)" do
      dir = Path.join(System.tmp_dir!(), "normal-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-5, :minute)
        })

      Sessions.create_message(%{
        session_id: session.id,
        data: %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "name" => "Bash", "input" => %{}},
              %{"type" => "tool_use", "name" => "Edit", "input" => %{}}
            ]
          }
        }
      })

      digest =
        SessionHeartbeat.build_fire(
          "caller",
          base_entry(%{watch_session_ids: [session.id], only_if_changed: false})
        )

      # Normal session should NOT have CHURN? segment
      refute digest.message =~ "CHURN?"
    end

    test "churn_suspected in snapshot_entry triggers heartbeat when flag flips" do
      dir = Path.join(System.tmp_dir!(), "snapshot-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.mkdir_p!(Path.join(dir, ".git"))
      on_exit(fn -> File.rm_rf(dir) end)

      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "test.txt"), "initial")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-m", "initial"], cd: dir)

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running"
        })

      # First fire - no churn
      entry = base_entry(%{watch_session_ids: [session.id], only_if_changed: true})
      first = SessionHeartbeat.build_fire("caller", entry)

      # Simulate session entering churn state by updating messages
      Enum.each(1..30, fn _i ->
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Bash",
                  "input" => %{"command" => String.duplicate("a", 100)}
                }
              ]
            }
          }
        })
      end)

      # Update session to have stale progress
      Sessions.update_session(session, %{
        progress_updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.add(-20, :minute)
      })

      # Second fire should detect churn and deliver (flag changed)
      second = SessionHeartbeat.build_fire("caller", %{entry | last_snapshot: first.snapshot})

      assert second.deliver? == true
      assert second.message =~ "CHURN?"
    end
  end
end
