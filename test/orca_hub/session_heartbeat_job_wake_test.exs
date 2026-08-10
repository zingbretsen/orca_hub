defmodule OrcaHub.SessionHeartbeatJobWakeTest do
  @moduledoc """
  Coverage for ORCAHUB3-26 item 1: waking a session on `OrcaHub.Jobs` job
  completion, via both `schedule_heartbeat`'s `watch_job_ids`/`wake_on` and
  the standalone `SessionHeartbeat.watch_job/2` (the backing call for
  `start_job`'s `wake_when_done`).

  Real detached jobs (same reasoning as `OrcaHub.JobWatcherTest` - no
  mocking) and the real `SessionHeartbeat` singleton throughout. Most cases
  here drive a session that stays `"running"` for the whole
  register/resolve dance (so a wake QUEUES rather than touching a live
  `SessionRunner`) and flush it with a single simulated turn-end at the
  end, the same restrained pattern `SessionHeartbeatDeliveryTest` uses -
  only the two tests that specifically need to prove real end-to-end
  delivery spin up a live, cold session, matching that file's own
  discipline. `async: false` throughout.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Jobs, JobSupervisor, SessionHeartbeat, Sessions, SessionSupervisor}
  alias OrcaHub.Jobs.Paths
  alias OrcaHub.MCP.Tools.Jobs, as: JobsTool

  @claude_stub Path.expand("support/fixtures/claude_stub_noop.sh", __DIR__ <> "/..")

  setup do
    Application.put_env(:orca_hub, :claude_executable, @claude_stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "job-wake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp fixture_session(dir, attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: dir, runner_node: Atom.to_string(node())}, attrs)
      )

    session
  end

  defp job_attrs(dir, overrides) do
    Map.merge(%{directory: dir, runner_node: Atom.to_string(node())}, overrides)
  end

  defp start_job!(dir, overrides) do
    {:ok, job} = Jobs.create_job(job_attrs(dir, overrides))
    {:ok, started} = JobSupervisor.start_job(job.id)
    started
  end

  defp wait_for_job_status(job_id, statuses, tries \\ 100) do
    job = Jobs.get_job(job_id)

    cond do
      job.status in statuses ->
        job

      tries <= 0 ->
        flunk("job #{job_id} never reached #{inspect(statuses)}, stuck at #{job.status}")

      true ->
        Process.sleep(50)
        wait_for_job_status(job_id, statuses, tries - 1)
    end
  end

  defp cleanup_job(job_id) do
    [
      Paths.cmd_script_path(job_id),
      Paths.wrapper_script_path(job_id),
      Paths.log_path(job_id),
      Paths.sentinel_path(job_id),
      Paths.pid_path(job_id),
      Paths.verify_cmd_script_path(job_id),
      Paths.verify_wrapper_script_path(job_id),
      Paths.verify_log_path(job_id),
      Paths.verify_sentinel_path(job_id),
      Paths.verify_pid_path(job_id)
    ]
    |> Enum.each(&File.rm/1)
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.stop_session(session_id)
    end
  end

  # Flushes any pending queued delivery for `session_id` without needing a
  # real `SessionRunner` - `SessionHeartbeat` only cares about the raw
  # `{session_id, {:status, atom}}` broadcast on the "sessions" topic (see
  # `handle_status_broadcast/3`), the exact shape `SessionRunner.broadcast/2`
  # itself would emit on a real running->idle transition.
  defp flush_turn_end(session_id) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session_id, {:status, :idle}})
  end

  defp message_text(message) do
    get_in(message.data, ["message", "content", Access.at(0), "text"])
  end

  defp wait_for_message(session_id, pattern, timeout_ms \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_message(session_id, pattern, deadline)
  end

  defp poll_for_message(session_id, pattern, deadline) do
    match =
      session_id
      |> Sessions.list_messages()
      |> Enum.find(fn m -> (message_text(m) || "") =~ pattern end)

    cond do
      match ->
        match

      System.monotonic_time(:millisecond) > deadline ->
        nil

      true ->
        Process.sleep(25)
        poll_for_message(session_id, pattern, deadline)
    end
  end

  describe "standalone watch_job/2 (wake_when_done)" do
    test "wakes an idle session with the job's status and exit code once it succeeds", %{dir: dir} do
      session = fixture_session(dir, %{status: "idle"})
      on_exit(fn -> stop_if_alive(session.id) end)

      job = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)

      assert :ok = SessionHeartbeat.watch_job(session.id, job.id)
      wait_for_job_status(job.id, ~w(succeeded failed))

      message = wait_for_message(session.id, ~r/#{job.id}/)
      refute is_nil(message), "expected a job-wake message"
      text = message_text(message)
      assert text =~ "status=succeeded"
      assert text =~ "exit_code=0"
    end

    test "works standalone, with no heartbeat ever scheduled for the session", %{dir: dir} do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)

      assert SessionHeartbeat.get(session.id) == nil

      job = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)

      assert :ok = SessionHeartbeat.watch_job(session.id, job.id)
      wait_for_job_status(job.id, ~w(succeeded failed))

      # Give the async job-finished broadcast a moment to land - it must
      # queue (session is "running"), not touch a live SessionRunner.
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      flush_turn_end(session.id)

      refute is_nil(wait_for_message(session.id, ~r/#{job.id}/))
      # Still no heartbeat entry for this session - this really was standalone.
      assert SessionHeartbeat.get(session.id) == nil
    end

    test "a job that already finished before watch_job/2 was called resolves immediately", %{
      dir: dir
    } do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)

      job = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)
      wait_for_job_status(job.id, ~w(succeeded failed))

      assert :ok = SessionHeartbeat.watch_job(session.id, job.id)

      # Resolved synchronously inside watch_job/2 itself - already queued,
      # nothing delivered until the (simulated) turn ends.
      assert Sessions.list_messages(session.id) == []
      flush_turn_end(session.id)

      refute is_nil(wait_for_message(session.id, ~r/#{job.id}/))
    end

    test "queues while the session is running and flushes, annotated, at turn end", %{dir: dir} do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)

      job = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)

      assert :ok = SessionHeartbeat.watch_job(session.id, job.id)
      wait_for_job_status(job.id, ~w(succeeded failed))

      # Give the async job-finished broadcast a moment to land - it must
      # queue, not interrupt the running turn with a delivery.
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      flush_turn_end(session.id)

      message = wait_for_message(session.id, ~r/#{job.id}/)
      refute is_nil(message)
      assert message_text(message) =~ "delivered late"
    end

    test "two simultaneous wake_when_done jobs (on different sessions) resolve independently, without clobbering each other in job_watches",
         %{dir: dir} do
      # job_watches is keyed by job_id, not session_id - two DIFFERENT
      # sessions is enough to prove entries don't clobber each other while
      # both are live at once (registered before either resolves), without
      # needing two real deliveries to land on the very same session (a
      # pattern that's fragile in this harness for reasons unrelated to
      # this feature - see deliver_now's mid-delivery-exit hardening).
      session_a = fixture_session(dir, %{status: "idle"})
      session_b = fixture_session(dir, %{status: "idle"})
      on_exit(fn -> stop_if_alive(session_a.id) end)
      on_exit(fn -> stop_if_alive(session_b.id) end)

      job_a = start_job!(dir, %{command: "exit 0"})
      job_b = start_job!(dir, %{command: "sleep 1; exit 7"})

      on_exit(fn ->
        cleanup_job(job_a.id)
        cleanup_job(job_b.id)
      end)

      assert :ok = SessionHeartbeat.watch_job(session_a.id, job_a.id)
      assert :ok = SessionHeartbeat.watch_job(session_b.id, job_b.id)

      msg_a = wait_for_message(session_a.id, ~r/#{job_a.id}/)
      refute is_nil(msg_a), "expected job_a's own wake message on session_a"
      assert Sessions.list_messages(session_b.id) == []

      wait_for_job_status(job_b.id, ~w(succeeded failed))
      msg_b = wait_for_message(session_b.id, ~r/#{job_b.id}/)
      refute is_nil(msg_b), "expected job_b's own wake message on session_b"
      assert message_text(msg_b) =~ "exit_code=7"

      assert Sessions.list_messages(session_a.id) |> Enum.count(&(message_text(&1) =~ "Job wake")) ==
               1
    end
  end

  describe "schedule_heartbeat watch_job_ids/wake_on" do
    test "wake_on any fires as soon as the first watched job finishes, and stops watching the rest",
         %{dir: dir} do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      fast = start_job!(dir, %{command: "exit 0"})
      slow = start_job!(dir, %{command: "sleep 5"})
      on_exit(fn -> cleanup_job(fast.id) end)
      on_exit(fn -> cleanup_job(slow.id) end)

      assert :ok =
               SessionHeartbeat.schedule(session.id, 30, "checking jobs", %{
                 watch_job_ids: [fast.id, slow.id],
                 wake_on: "any"
               })

      wait_for_job_status(fast.id, ~w(succeeded failed))
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      flush_turn_end(session.id)

      message = wait_for_message(session.id, ~r/checking jobs/)
      refute is_nil(message)
      text = message_text(message)
      assert text =~ fast.id
      refute text =~ slow.id

      assert %{watch_job_ids: []} = SessionHeartbeat.get(session.id)

      JobSupervisor.cancel_job(slow.id)
      wait_for_job_status(slow.id, ~w(succeeded failed cancelled))
    end

    test "wake_on all waits for every watched job before delivering", %{dir: dir} do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      slow = start_job!(dir, %{command: "sleep 1; exit 0"})
      fast = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(slow.id) end)
      on_exit(fn -> cleanup_job(fast.id) end)

      assert :ok =
               SessionHeartbeat.schedule(session.id, 30, "checking jobs", %{
                 watch_job_ids: [slow.id, fast.id],
                 wake_on: "all"
               })

      wait_for_job_status(fast.id, ~w(succeeded failed))
      # fast alone must not deliver yet - still waiting on slow.
      Process.sleep(300)
      assert Sessions.list_messages(session.id) == []

      wait_for_job_status(slow.id, ~w(succeeded failed))
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      flush_turn_end(session.id)

      message = wait_for_message(session.id, ~r/checking jobs/)
      refute is_nil(message)
      text = message_text(message)
      assert text =~ slow.id
      assert text =~ fast.id
    end

    test "a job still in verifying does not wake anything - only its later terminal status does",
         %{dir: dir} do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      job = start_job!(dir, %{command: "exit 0", verify_command: "sleep 1; exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)

      assert :ok =
               SessionHeartbeat.schedule(session.id, 30, "checking jobs", %{
                 watch_job_ids: [job.id]
               })

      wait_for_job_status(job.id, ["verifying"])
      # In verifying now - must not have woken (or even queued) yet.
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      final = wait_for_job_status(job.id, ~w(succeeded verification_failed failed))
      assert final.status == "succeeded"
      Process.sleep(200)
      assert Sessions.list_messages(session.id) == []

      flush_turn_end(session.id)

      message = wait_for_message(session.id, ~r/checking jobs/)
      refute is_nil(message)
      assert message_text(message) =~ "status=succeeded"
    end

    test "a watch_job_id that already finished before scheduling resolves immediately", %{
      dir: dir
    } do
      session = fixture_session(dir, %{status: "running"})
      on_exit(fn -> stop_if_alive(session.id) end)
      on_exit(fn -> SessionHeartbeat.cancel(session.id) end)

      job = start_job!(dir, %{command: "exit 0"})
      on_exit(fn -> cleanup_job(job.id) end)
      wait_for_job_status(job.id, ~w(succeeded failed))

      assert :ok =
               SessionHeartbeat.schedule(session.id, 30, "checking jobs", %{
                 watch_job_ids: [job.id]
               })

      assert Sessions.list_messages(session.id) == []
      flush_turn_end(session.id)

      message = wait_for_message(session.id, ~r/checking jobs/)
      refute is_nil(message)
      assert message_text(message) =~ job.id
    end
  end

  describe "start_job wake_when_done, end to end through the MCP tool" do
    test "wires through to a standalone wake", %{dir: dir} do
      session = fixture_session(dir, %{status: "idle"})
      on_exit(fn -> stop_if_alive(session.id) end)

      result =
        JobsTool.call(
          "start_job",
          %{"command" => "exit 0", "cwd" => dir, "wake_when_done" => true},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => false, "content" => [%{"text" => body}]} = result
      job_id = body |> Jason.decode!() |> Map.fetch!("job_id")
      on_exit(fn -> cleanup_job(job_id) end)

      wait_for_job_status(job_id, ~w(succeeded failed))

      message = wait_for_message(session.id, ~r/#{job_id}/)
      refute is_nil(message), "expected wake_when_done to wake the session"
      assert message_text(message) =~ "status=succeeded"
    end
  end
end
