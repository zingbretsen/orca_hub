defmodule OrcaHub.SessionRunnerLifecycleNotifyTest do
  @moduledoc """
  Coverage for feedback item 1 (orchestrator-feedback-2026-07-10, "biggest
  win"): orchestrators were polling `schedule_heartbeat` every few minutes
  just to learn a child session went idle/errored. `SessionRunner` now
  auto-notifies a session's `parent_session_id` (if any, and if
  `notify_parent`) on a genuine running->idle/running->error turn-end
  transition, and `start_session` stamps that link server-side.

  State-transition tests drive `SessionRunner.running/3` directly against a
  real DB-backed session (no live port needed) — same pattern as
  `SessionRunnerErrorDetailTest`. Delivery is fired async
  (`Task.Supervisor`), so those tests poll the parent's persisted messages
  for the `[Session lifecycle]` callback instead of asserting synchronously.
  The deleted-parent race is tested by calling
  `SessionRunner.deliver_parent_notification/2` (a `@doc false` test seam)
  directly, which sidesteps the Task.Supervisor scheduling entirely.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Sessions, as: SessionsTool
  alias OrcaHub.{SessionRunner, Sessions, SessionSupervisor}

  # A parent's runner may need to be auto-started to receive its
  # notification (Cluster.send_message's ensure_started) — stub `claude` so
  # that never touches the network. It just reads/discards stdin until the
  # port closes, so it never itself completes a turn (see the fixture's own
  # moduledoc) — irrelevant here since we only assert on the persisted
  # "[Session lifecycle]" user message, written before the port is opened.
  @claude_stub Path.expand("../support/fixtures/claude_stub_noop.sh", __DIR__)

  setup do
    Application.put_env(:orca_hub, :claude_executable, @claude_stub)
    on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

    dir = Path.join(System.tmp_dir!(), "lifecycle_notify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.stop_session(session_id)
    end
  end

  defp base_data(session, overrides) do
    Map.merge(
      %{
        session_id: session.id,
        directory: session.directory,
        port: :fake_port,
        engine: :one_shot,
        pending_prompts: [],
        pending_questions: nil,
        buffer: "",
        error_output: "",
        messages: [],
        first_prompt: "hi"
      },
      overrides
    )
  end

  defp message_text(message) do
    get_in(message.data, ["message", "content", Access.at(0), "text"])
  end

  defp wait_for_message(session_id, pattern, timeout_ms \\ 2000) do
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

  # ── start_session parent stamping ───────────────────────────────────────

  describe "start_session parent stamping" do
    test "an orchestrator caller links the child as parent and defaults notify_parent to true",
         %{dir: dir} do
      {:ok, caller} = Sessions.create_session(%{directory: dir, orchestrator: true})
      state = %{orca_session_id: caller.id, orchestrator: true}

      result = SessionsTool.call("start_session", %{"prompt" => "hi"}, state)
      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      %{"session_id" => child_id} = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(child_id) end)

      child = Sessions.get_session!(child_id)
      assert child.parent_session_id == caller.id
      assert child.notify_parent == true
    end

    test "notify_on_completion: false links the parent but suppresses notification", %{dir: dir} do
      {:ok, caller} = Sessions.create_session(%{directory: dir, orchestrator: true})
      state = %{orca_session_id: caller.id, orchestrator: true}

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "notify_on_completion" => false},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      %{"session_id" => child_id} = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(child_id) end)

      child = Sessions.get_session!(child_id)
      assert child.parent_session_id == caller.id
      assert child.notify_parent == false
    end

    test "a non-orchestrator caller ALSO links the child as parent and defaults notify_parent to true (child spawning is first-class for every session, not just orchestrators)",
         %{dir: dir} do
      {:ok, caller} = Sessions.create_session(%{directory: dir, orchestrator: false})
      state = %{orca_session_id: caller.id, orchestrator: false}

      result = SessionsTool.call("start_session", %{"prompt" => "hi"}, state)
      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      %{"session_id" => child_id} = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(child_id) end)

      child = Sessions.get_session!(child_id)
      assert child.parent_session_id == caller.id
      assert child.notify_parent == true
    end

    test "a non-orchestrator caller: notify_on_completion: false links the parent but suppresses notification",
         %{dir: dir} do
      {:ok, caller} = Sessions.create_session(%{directory: dir, orchestrator: false})
      state = %{orca_session_id: caller.id, orchestrator: false}

      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi", "notify_on_completion" => false},
          state
        )

      assert %{"isError" => false, "content" => [%{"text" => text}]} = result
      %{"session_id" => child_id} = Jason.decode!(text)
      on_exit(fn -> stop_if_alive(child_id) end)

      child = Sessions.get_session!(child_id)
      assert child.parent_session_id == caller.id
      assert child.notify_parent == false
    end

    test "start_session with no caller session id at all still creates no parent link" do
      # An HTTP/API-triggered start_session (no MCP connection, hence no
      # orca_session_id) has no caller to link to — call/3 rejects it before
      # ever reaching maybe_link_parent/4, whose own nil-caller_session_id
      # clause is the same "no link" behavior as a defensive fallback.
      result =
        SessionsTool.call(
          "start_session",
          %{"prompt" => "hi"},
          %{orca_session_id: nil, orchestrator: false}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "No OrcaHub session linked"
    end
  end

  # ── running->idle / running->error notification wiring ──────────────────

  describe "running->idle/error transitions notify the parent" do
    test "a clean exit notifies the parent that the child is idle", %{dir: dir} do
      {:ok, parent} =
        Sessions.create_session(%{
          directory: dir,
          title: "the parent",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(parent.id) end)

      {:ok, child} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "child-title",
          parent_session_id: parent.id,
          notify_parent: true
        })

      data = base_data(child, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      message =
        wait_for_message(
          parent.id,
          ~r/^\[Session lifecycle\] Child session #{child.id} \("child-title"\) is now idle\.$/
        )

      refute is_nil(message), "expected a [Session lifecycle] idle message on the parent"
    end

    test "a non-zero exit notifies the parent that the child errored, including error_detail",
         %{dir: dir} do
      {:ok, parent} =
        Sessions.create_session(%{
          directory: dir,
          title: "the parent",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(parent.id) end)

      {:ok, child} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "child-title",
          parent_session_id: parent.id,
          notify_parent: true
        })

      data = base_data(child, %{error_output: "boom: something broke\n"})

      assert {:next_state, :error, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

      message =
        wait_for_message(
          parent.id,
          ~r/^\[Session lifecycle\] Child session #{child.id} \("child-title"\) is now error\. Error: boom: something broke$/
        )

      refute is_nil(message), "expected a [Session lifecycle] error message with error_detail"
    end

    test "notify_parent: false suppresses the notification entirely", %{dir: dir} do
      {:ok, parent} =
        Sessions.create_session(%{
          directory: dir,
          title: "the parent",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(parent.id) end)

      {:ok, child} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "child-title",
          parent_session_id: parent.id,
          notify_parent: false
        })

      data = base_data(child, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      # notify_parent: false means maybe_notify_parent/2 never schedules a
      # Task at all — nothing async to race, so this check is immediate and
      # deterministic (see maybe_notify_parent/2's `%{notify_parent: false}`
      # clause).
      assert Sessions.list_messages(parent.id) == []
    end

    test "a session with no parent_session_id never touches notification delivery", %{dir: dir} do
      {:ok, child} = Sessions.create_session(%{directory: dir, status: "running"})
      data = base_data(child, %{})

      assert {:next_state, :idle, _new_data} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      # Nothing to assert beyond "did not raise" — there's no parent to check.
    end
  end

  # ── deleted-parent race (deliver_parent_notification/2 test seam) ───────

  describe "deliver_parent_notification/2 — deleted parent" do
    test "skips silently (no crash) when the parent no longer exists", %{dir: dir} do
      {:ok, parent} = Sessions.create_session(%{directory: dir, title: "soon deleted"})

      {:ok, child} =
        Sessions.create_session(%{
          directory: dir,
          title: "child-title",
          parent_session_id: parent.id,
          notify_parent: true
        })

      # Capture the child row with a still-populated parent_session_id
      # BEFORE deleting the parent — mirrors the real race: the transition
      # handler's `session = db_call(data, :get_session!, ...)` fetch can
      # win against a delete that lands a moment later, before delivery
      # actually runs `Cluster.find_session/1`.
      stale_child = Sessions.get_session!(child.id)
      assert stale_child.parent_session_id == parent.id

      {:ok, _} = Sessions.delete_session(parent)

      assert SessionRunner.deliver_parent_notification(stale_child, :idle) == :ok
    end
  end
end
