defmodule OrcaHub.SessionsTest do
  use OrcaHub.DataCase

  import Ecto.Query

  alias OrcaHub.{Projects, Repo, Sessions}
  alias OrcaHub.Sessions.{Message, Session}

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", directory: "/tmp/test-sessions"})
    %{project: project}
  end

  defp create_session(project, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{directory: project.directory, project_id: project.id},
        overrides
      )

    {:ok, session} = Sessions.create_session(attrs)
    session
  end

  describe "list_sessions/1 filtering" do
    test "defaults to manual sessions only", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions()
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      refute triggered.id in session_ids
    end

    test ":manual filter excludes triggered sessions", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:manual)
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      refute triggered.id in session_ids
    end

    test ":automated filter shows only triggered sessions", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:automated)
      session_ids = Enum.map(sessions, & &1.id)

      refute manual.id in session_ids
      assert triggered.id in session_ids
    end

    test ":all filter shows everything", %{project: project} do
      manual = create_session(project, %{title: "Manual"})
      triggered = create_session(project, %{title: "Triggered", triggered: true})

      sessions = Sessions.list_sessions(:all)
      session_ids = Enum.map(sessions, & &1.id)

      assert manual.id in session_ids
      assert triggered.id in session_ids
    end

    test "excludes archived sessions from all filters", %{project: project} do
      manual = create_session(project, %{title: "Archived Manual"})
      triggered = create_session(project, %{title: "Archived Triggered", triggered: true})

      Sessions.archive_session(manual)
      Sessions.archive_session(triggered)

      for filter <- [:all, :manual, :automated] do
        session_ids = Sessions.list_sessions(filter) |> Enum.map(& &1.id)
        refute manual.id in session_ids
        refute triggered.id in session_ids
      end
    end
  end

  describe "get_session/1" do
    test "returns session when it exists", %{project: project} do
      session = create_session(project)
      assert %{id: id} = Sessions.get_session(session.id)
      assert id == session.id
    end

    test "returns nil when session does not exist" do
      assert Sessions.get_session(Ecto.UUID.generate()) == nil
    end
  end

  describe "triggered field" do
    test "defaults to false", %{project: project} do
      session = create_session(project)
      assert session.triggered == false
    end

    test "can be set to true on creation", %{project: project} do
      session = create_session(project, %{triggered: true})
      assert session.triggered == true
    end
  end

  describe "backend field" do
    test "defaults to \"claude\"", %{project: project} do
      session = create_session(project)
      assert session.backend == "claude"
    end

    test "accepts \"claude\" explicitly", %{project: project} do
      session = create_session(project, %{backend: "claude"})
      assert session.backend == "claude"
    end

    test "accepts \"codex\" at the data layer (adapter lands in Phase 2)", %{project: project} do
      session = create_session(project, %{backend: "codex"})
      assert session.backend == "codex"
    end

    test "rejects an unrecognized backend value", %{project: project} do
      attrs = %{directory: project.directory, project_id: project.id, backend: "not-a-backend"}
      changeset = Session.changeset(%Session{}, attrs)

      refute changeset.valid?
      assert %{backend: ["is invalid"]} = errors_on(changeset)
    end

    test "round-trips through create_session same as other fields", %{project: project} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          backend: "claude"
        })

      reloaded = Sessions.get_session(session.id)
      assert reloaded.backend == "claude"
    end
  end

  describe "list_idle_sessions_with_last_assistant_message/0" do
    test "includes top-level idle sessions but excludes orchestrator-spawned children",
         %{project: project} do
      parent = create_session(project, %{title: "Parent", status: "idle"})

      child =
        create_session(project, %{
          title: "Child",
          status: "idle",
          parent_session_id: parent.id
        })

      results = Sessions.list_idle_sessions_with_last_assistant_message()
      ids = Enum.map(results, fn {s, _msg} -> s.id end)

      assert parent.id in ids
      refute child.id in ids
    end
  end

  describe "activity_metadata/1" do
    defp insert_message(session, data, minutes_ago) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      if minutes_ago > 0 do
        ts = NaiveDateTime.utc_now() |> NaiveDateTime.add(-minutes_ago * 60, :second)
        from(m in Message, where: m.id == ^message.id) |> Repo.update_all(set: [inserted_at: ts])
      end

      message
    end

    defp assistant_with_tool_calls(names) do
      %{
        "type" => "assistant",
        "message" => %{
          "content" =>
            Enum.map(names, fn name -> %{"type" => "tool_use", "name" => name, "input" => %{}} end) ++
              [%{"type" => "text", "text" => "hi"}]
        }
      }
    end

    test "returns zeroed defaults for a session with no messages", %{project: project} do
      session = create_session(project)

      assert Sessions.activity_metadata([session.id]) == %{
               session.id => %{
                 messages_5m: 0,
                 messages_15m: 0,
                 messages_30m: 0,
                 tool_calls_5m: 0,
                 tool_calls_15m: 0,
                 tool_calls_30m: 0,
                 last_activity_at: nil
               }
             }
    end

    test "returns an empty map for an empty id list" do
      assert Sessions.activity_metadata([]) == %{}
    end

    test "buckets messages and tool calls by age, and computes last_activity_at",
         %{project: project} do
      session = create_session(project)

      insert_message(session, assistant_with_tool_calls(["Bash"]), 1)
      insert_message(session, assistant_with_tool_calls(["Read", "Edit"]), 10)
      insert_message(session, assistant_with_tool_calls(["Write"]), 20)
      insert_message(session, assistant_with_tool_calls(["Bash"]), 40)

      result = Sessions.activity_metadata([session.id])[session.id]

      # 5m bucket: only the 1-minute-old message/tool call
      assert result.messages_5m == 1
      assert result.tool_calls_5m == 1

      # 15m bucket: 1m + 10m messages (2 tool_use blocks in the 10m message)
      assert result.messages_15m == 2
      assert result.tool_calls_15m == 3

      # 30m bucket: 1m + 10m + 20m messages
      assert result.messages_30m == 3
      assert result.tool_calls_30m == 4

      assert result.last_activity_at != nil
    end

    test "does not N+1 — computes metadata for many sessions in a fixed number of queries",
         %{project: project} do
      sessions = for _ <- 1..5, do: create_session(project)
      Enum.each(sessions, &insert_message(&1, assistant_with_tool_calls(["Bash"]), 1))

      ids = Enum.map(sessions, & &1.id)

      {queries, result} =
        with_query_count(fn -> Sessions.activity_metadata(ids) end)

      assert map_size(result) == 5
      assert queries <= 2
    end

    defp with_query_count(fun) do
      test_pid = self()
      ref = make_ref()

      handler = fn _event, _measurements, _metadata, _config ->
        send(test_pid, {ref, :query})
      end

      :telemetry.attach(
        {ref, __MODULE__},
        [:orca_hub, :repo, :query],
        handler,
        nil
      )

      result = fun.()
      :telemetry.detach({ref, __MODULE__})

      count =
        Stream.repeatedly(fn ->
          receive do
            {^ref, :query} -> :ok
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> length()

      {count, result}
    end
  end

  describe "git_head_info/1" do
    test "returns sha/short_sha/subject for a git repo" do
      dir =
        Path.join(System.tmp_dir!(), "sessions-git-head-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      File.write!(Path.join(dir, "f.txt"), "hi")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: dir)

      assert %{sha: sha, short_sha: short_sha, subject: "initial commit"} =
               Sessions.git_head_info(dir)

      assert is_binary(sha)
      assert String.starts_with?(sha, short_sha)
    end

    test "returns nil for a non-repo directory" do
      dir =
        Path.join(System.tmp_dir!(), "sessions-not-a-repo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert Sessions.git_head_info(dir) == nil
    end

    test "returns nil (does not raise) for a missing directory" do
      assert Sessions.git_head_info("/nonexistent/path/#{System.unique_integer([:positive])}") ==
               nil
    end
  end

  describe "get_session_by_idempotency_key/1" do
    test "returns nil for nil/blank keys" do
      assert Sessions.get_session_by_idempotency_key(nil) == nil
      assert Sessions.get_session_by_idempotency_key("") == nil
    end

    test "finds a non-archived session by key", %{project: project} do
      session = create_session(project, %{idempotency_key: "abc-123"})

      found = Sessions.get_session_by_idempotency_key("abc-123")
      assert found.id == session.id
    end

    test "ignores archived sessions", %{project: project} do
      session = create_session(project, %{idempotency_key: "abc-456"})
      Sessions.archive_session(session)

      assert Sessions.get_session_by_idempotency_key("abc-456") == nil
    end

    test "returns nil when no session matches" do
      assert Sessions.get_session_by_idempotency_key("does-not-exist") == nil
    end
  end

  describe "session_interactions" do
    test "create_session_interaction/1 inserts an edge with a default kind", %{project: project} do
      a = create_session(project)
      b = create_session(project)

      assert {:ok, interaction} =
               Sessions.create_session_interaction(%{
                 sender_session_id: a.id,
                 recipient_session_id: b.id
               })

      assert interaction.sender_session_id == a.id
      assert interaction.recipient_session_id == b.id
      assert interaction.kind == "message"
    end

    test "create_session_interaction/1 requires sender and recipient" do
      assert {:error, changeset} = Sessions.create_session_interaction(%{})

      assert %{sender_session_id: ["can't be blank"], recipient_session_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "create_session_interaction/1 accepts an explicit inserted_at for backfilling", %{
      project: project
    } do
      a = create_session(project)
      b = create_session(project)
      stamp = ~N[2026-01-01 00:00:00]

      assert {:ok, interaction} =
               Sessions.create_session_interaction(%{
                 sender_session_id: a.id,
                 recipient_session_id: b.id,
                 inserted_at: stamp
               })

      assert interaction.inserted_at == stamp
    end

    test "list_session_interactions/1 filters by sender, recipient, and since", %{
      project: project
    } do
      a = create_session(project)
      b = create_session(project)
      c = create_session(project)

      {:ok, old} =
        Sessions.create_session_interaction(%{
          sender_session_id: a.id,
          recipient_session_id: b.id,
          inserted_at: ~N[2020-01-01 00:00:00]
        })

      {:ok, recent} =
        Sessions.create_session_interaction(%{
          sender_session_id: a.id,
          recipient_session_id: c.id,
          inserted_at: ~N[2026-06-01 00:00:00]
        })

      {:ok, other_sender} =
        Sessions.create_session_interaction(%{
          sender_session_id: c.id,
          recipient_session_id: b.id,
          inserted_at: ~N[2026-06-01 00:00:00]
        })

      by_sender = Sessions.list_session_interactions(sender_session_id: a.id)
      assert Enum.map(by_sender, & &1.id) |> Enum.sort() == Enum.sort([old.id, recent.id])

      by_recipient = Sessions.list_session_interactions(recipient_session_id: b.id)

      assert Enum.map(by_recipient, & &1.id) |> Enum.sort() ==
               Enum.sort([old.id, other_sender.id])

      since_2025 = Sessions.list_session_interactions(since: ~N[2025-01-01 00:00:00])
      ids = Enum.map(since_2025, & &1.id)
      assert recent.id in ids
      assert other_sender.id in ids
      refute old.id in ids
    end

    test "list_session_interactions_for_sessions/1 returns edges touching any given session id (either direction)",
         %{project: project} do
      a = create_session(project)
      b = create_session(project)
      c = create_session(project)
      unrelated = create_session(project)

      {:ok, a_to_b} =
        Sessions.create_session_interaction(%{
          sender_session_id: a.id,
          recipient_session_id: b.id
        })

      {:ok, c_to_a} =
        Sessions.create_session_interaction(%{
          sender_session_id: c.id,
          recipient_session_id: a.id
        })

      {:ok, _unrelated_edge} =
        Sessions.create_session_interaction(%{
          sender_session_id: unrelated.id,
          recipient_session_id: c.id
        })

      result = Sessions.list_session_interactions_for_sessions([a.id])
      assert Enum.map(result, & &1.id) |> Enum.sort() == Enum.sort([a_to_b.id, c_to_a.id])

      assert Sessions.list_session_interactions_for_sessions([]) == []
    end
  end
end
