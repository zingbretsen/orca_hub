defmodule OrcaHub.EmailInbox.SessionReuseIntegrationTest do
  @moduledoc """
  Confirms the inbound-email path reaches `TriggerExecutor`'s SHARED
  session-reuse logic rather than bypassing it: `OrcaHub.EmailInbox.Ingest`
  fires a matched trigger through `TriggerExecutor.execute_payload/2` — the
  exact same function (and `resolve_session/1` helper) the cron/webhook
  paths use — so a `reuse_session: true` email trigger accumulates forwarded
  mail into ONE ongoing session rather than spawning a new one per message.

  Drives a REAL `OrcaHub.SessionRunner` (full GenStatem, DB writes), so —
  same pattern and reasoning as
  `OrcaHub.Backend.PiStubIntegrationTest` — async: false with the DB
  sandbox in SHARED mode (`OrcaHub.DataCase`'s `start_owner!(shared: true)`
  for `async: false`), since a spawned process otherwise has no DB
  ownership. Never installs a real/stub backend CLI: nothing here needs a
  turn to actually run, only for `create_session`/`start_session` to
  succeed and the resulting row's `status` to be inspectable.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{EmailInboxes, Projects, Sessions, TriggerExecutor, Triggers}
  alias OrcaHub.Sessions.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "email_reuse_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "email reuse project", directory: dir})

    {:ok, inbox} =
      EmailInboxes.create_email_inbox(%{
        name: "reuse inbox",
        host: "imap.example.com",
        username: "ops@example.com",
        password: "hunter2"
      })

    %{project: project, inbox: inbox}
  end

  defp email_payload(body) do
    %{
      :source => :email,
      "from" => "zach@example.com",
      "to" => "ops@example.com",
      "subject" => "update",
      "body" => body,
      "message_id" => nil,
      "in_reply_to" => nil,
      "attachments" => []
    }
  end

  test "two messages to the same reuse_session: true email trigger land in the same session", %{
    project: project,
    inbox: inbox
  } do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "Reuse email trigger",
        prompt: "Summarize",
        type: "email",
        project_id: project.id,
        reuse_session: true,
        email_inbox_id: inbox.id,
        sender_allowlist: ["zach@example.com"]
      })

    session_count_before = Repo.aggregate(Session, :count)

    assert {:ok, session_id_1} =
             TriggerExecutor.execute_payload(trigger.id, email_payload("first message"))

    on_exit(fn ->
      if OrcaHub.SessionSupervisor.session_alive?(session_id_1) do
        OrcaHub.SessionSupervisor.stop_session(session_id_1)
      end
    end)

    # No real backend CLI is installed for this test, so the freshly-spawned
    # runner won't settle back to idle/ready on its own. Settle it manually —
    # this isolates the REUSE DECISION (what this test is about) from
    # backend/CLI timing, the same way a real second poll cycle would only
    # see the prior turn as reusable once it's actually finished.
    Sessions.update_session(Sessions.get_session!(session_id_1), %{status: "ready"})

    assert {:ok, session_id_2} =
             TriggerExecutor.execute_payload(trigger.id, email_payload("second message"))

    assert session_id_2 == session_id_1
    assert Repo.aggregate(Session, :count) == session_count_before + 1

    reloaded_trigger = Triggers.get_trigger!(trigger.id)
    assert reloaded_trigger.last_session_id == session_id_1
  end

  test "reuse_session: false spawns a separate session per message", %{
    project: project,
    inbox: inbox
  } do
    {:ok, trigger} =
      Triggers.create_trigger(%{
        name: "No-reuse email trigger",
        prompt: "Summarize",
        type: "email",
        project_id: project.id,
        reuse_session: false,
        email_inbox_id: inbox.id,
        sender_allowlist: ["zach@example.com"]
      })

    assert {:ok, session_id_1} =
             TriggerExecutor.execute_payload(trigger.id, email_payload("first message"))

    assert {:ok, session_id_2} =
             TriggerExecutor.execute_payload(trigger.id, email_payload("second message"))

    on_exit(fn ->
      for id <- [session_id_1, session_id_2] do
        if OrcaHub.SessionSupervisor.session_alive?(id) do
          OrcaHub.SessionSupervisor.stop_session(id)
        end
      end
    end)

    refute session_id_1 == session_id_2
  end
end
