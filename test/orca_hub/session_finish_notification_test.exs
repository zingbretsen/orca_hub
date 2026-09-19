defmodule OrcaHub.SessionFinishNotificationTest do
  @moduledoc """
  The turn-end Gotify push (orca-watch DESIGN.md §7c, risk R12).

  It is OPT-IN and OFF by default (D6 — the Android app takes finish events
  from a direct authenticated channel on the hub instead), so every test
  below that asserts either delivery OR suppression turns the flag on
  explicitly in `setup`; otherwise a suppression test would pass for the
  wrong reason. The one test that exercises the default leaves it unset.

  When enabled it fires on every genuine `running -> idle|error` transition,
  and the Android client renders its notification ENTIRELY from the payload —
  it cannot call back to OrcaHub when OrcaHub is the unreachable thing (§1.4
  step 3). So the four fields under `extras["orca"]` are a CONTRACT, asserted
  here field by field.

  State-transition tests drive `SessionRunner.running/3` directly against a
  real DB-backed session (no live port needed) — same pattern as
  `SessionRunnerLifecycleNotifyTest`. Delivery is fired async
  (`Task.Supervisor`), so the Gotify stub is put in Req.Test SHARED mode and
  the request body is asserted via `assert_receive`.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Notify, SessionRunner, Sessions}

  @stub OrcaHub.SessionFinishNotificationStub

  setup do
    # The push is opt-in since D6 — nothing fires without this.
    Application.put_env(:orca_hub, :notify_on_finish, true)
    Application.put_env(:orca_hub, :gotify_token, "test-token")
    Application.put_env(:orca_hub, :gotify_url, "https://gotify.example.com")
    Application.put_env(:orca_hub, :gotify_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:orca_hub, :gotify_token)
      Application.delete_env(:orca_hub, :gotify_url)
      Application.delete_env(:orca_hub, :gotify_req_options)
      Application.delete_env(:orca_hub, :notify_on_finish)
    end)

    # The notification is delivered from a TaskSupervisor child, not the test
    # process — shared mode is what lets that process find the stub.
    Req.Test.set_req_test_to_shared()

    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:gotify, Jason.decode!(raw)})
      Req.Test.json(conn, %{"id" => 1})
    end)

    dir = Path.join(System.tmp_dir!(), "finish_notify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
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

  defp assistant_message(session_id, text) do
    {:ok, _} =
      Sessions.create_message(%{
        session_id: session_id,
        data: %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => text}]}
        }
      })
  end

  defp refute_gotify do
    refute_receive {:gotify, _}, 400
  end

  # ── the four-field payload contract ────────────────────────────────────

  describe "running -> idle" do
    test "carries session_id, session_title, status and excerpt", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "All three migrations applied cleanly.")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      assert_receive {:gotify, body}, 2000

      assert body["extras"]["orca"] == %{
               "session_id" => session.id,
               "session_title" => "the worker",
               "status" => "idle",
               "excerpt" => "All three migrations applied cleanly."
             }
    end

    test "sets a sensible title, message and priority, and links back to the session page",
         %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "Done.")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      assert_receive {:gotify, body}, 2000

      assert body["title"] == "the worker"
      assert body["message"] == "Done."
      assert body["priority"] == 4

      assert body["extras"]["client::notification"]["click"]["url"] =~ "/sessions/#{session.id}"
    end

    test "an untitled session falls back to a truncation of the first prompt", %{dir: dir} do
      {:ok, session} = Sessions.create_session(%{directory: dir, status: "running"})
      assistant_message(session.id, "ok")

      data = base_data(session, %{first_prompt: "Fix the flaky triggers test\nand report back"})

      assert {:next_state, :idle, _} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      assert_receive {:gotify, body}, 2000
      assert body["extras"]["orca"]["session_title"] == "Fix the flaky triggers test"
    end

    test "a long excerpt is truncated on a word boundary", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "verbose"})

      long = String.duplicate("alpha bravo charlie delta ", 60)
      assistant_message(session.id, long)

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      assert_receive {:gotify, body}, 2000
      excerpt = body["extras"]["orca"]["excerpt"]

      assert String.length(excerpt) <= 401
      assert String.ends_with?(excerpt, "…")
      # Word boundary: no partial word before the ellipsis.
      assert String.trim_trailing(excerpt, "…") |> String.ends_with?("delta") or
               String.trim_trailing(excerpt, "…") |> String.ends_with?("charlie") or
               String.trim_trailing(excerpt, "…") |> String.ends_with?("bravo") or
               String.trim_trailing(excerpt, "…") |> String.ends_with?("alpha")
    end
  end

  describe "running -> error" do
    test "carries status \"error\" and a higher priority", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "the worker"})

      assistant_message(session.id, "Attempting the migration…")

      data = base_data(session, %{error_output: "boom: something broke\n"})

      assert {:next_state, :error, _} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 1}}, data)

      assert_receive {:gotify, body}, 2000

      assert body["extras"]["orca"] == %{
               "session_id" => session.id,
               "session_title" => "the worker",
               "status" => "error",
               "excerpt" => "Attempting the migration…"
             }

      assert body["priority"] == 8
      assert body["title"] =~ "the worker"
    end
  end

  # ── when it must NOT fire ──────────────────────────────────────────────

  describe "suppression" do
    test "a memory_extraction session never notifies", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "memory extraction",
          kind: "memory_extraction"
        })

      assistant_message(session.id, "extracted two memories")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      refute_gotify()
    end

    test "a child session never notifies — workers report to their orchestrator", %{dir: dir} do
      {:ok, parent} =
        Sessions.create_session(%{directory: dir, status: "idle", title: "the orchestrator"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          title: "worker 7",
          parent_session_id: parent.id
        })

      assistant_message(session.id, "migration written")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      refute_gotify()
    end

    test "an archived session never notifies", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "archived one"})

      {:ok, _} = Sessions.archive_session(session, extract_memories: false)
      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      refute_gotify()
    end

    test "with no ORCA_NOTIFY_ON_FINISH set at all, the hook is a no-op", %{dir: dir} do
      # D6: the push is opt-in. Unset means OFF — not "off unless someone
      # remembered to silence it" — so a turn end must produce NO Gotify call.
      Application.delete_env(:orca_hub, :notify_on_finish)
      refute SessionRunner.finish_notifications_enabled?()

      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "default quiet"})

      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      refute_gotify()
    end

    test "an explicit ORCA_NOTIFY_ON_FINISH=false (config :notify_on_finish false) silences it",
         %{dir: dir} do
      Application.put_env(:orca_hub, :notify_on_finish, false)
      refute SessionRunner.finish_notifications_enabled?()

      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "quiet one"})

      assistant_message(session.id, "done")

      assert {:next_state, :idle, _} =
               SessionRunner.running(
                 :info,
                 {:fake_port, {:exit_status, 0}},
                 base_data(session, %{})
               )

      refute_gotify()
    end

    test "the switch defaults OFF when unset, and only a literal true opts in" do
      Application.delete_env(:orca_hub, :notify_on_finish)
      refute SessionRunner.finish_notifications_enabled?()

      Application.put_env(:orca_hub, :notify_on_finish, true)
      assert SessionRunner.finish_notifications_enabled?()
    end

    test "an unanswered AskUserQuestion (\"waiting\") is not a turn end", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "asking"})

      assistant_message(session.id, "which one?")
      data = base_data(session, %{pending_questions: [%{"question" => "which?"}]})

      assert {:next_state, :idle, _} =
               SessionRunner.running(:info, {:fake_port, {:exit_status, 0}}, data)

      refute_gotify()
    end

    test "an unconfigured Gotify is a silent no-op, not an error", %{dir: dir} do
      Application.delete_env(:orca_hub, :gotify_token)

      {:ok, session} =
        Sessions.create_session(%{directory: dir, status: "running", title: "no token"})

      assert Notify.deliver_session_finished(%{
               session_id: session.id,
               session_title: "no token",
               status: "idle"
             }) == {:ok, :skipped}

      refute_gotify()
    end
  end

  # ── direct unit coverage of the excerpt rule ───────────────────────────

  describe "Notify.truncate_excerpt/2" do
    test "leaves a short string alone",
      do: assert(Notify.truncate_excerpt("hi there") == "hi there")

    test "collapses whitespace" do
      assert Notify.truncate_excerpt("a\n\n  b") == "a b"
    end

    test "cuts on a word boundary and ellipsises" do
      assert Notify.truncate_excerpt("alpha bravo charlie delta", 18) == "alpha bravo…"
    end

    test "still cuts a single unbroken word" do
      assert Notify.truncate_excerpt(String.duplicate("x", 30), 10) ==
               String.duplicate("x", 10) <> "…"
    end

    test "nil stays nil", do: assert(Notify.truncate_excerpt(nil) == nil)
  end
end
