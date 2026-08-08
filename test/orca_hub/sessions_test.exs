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

  describe "create_session/1 node default resolution" do
    alias OrcaHub.ClusterNodes

    setup do
      {:ok, node} = ClusterNodes.upsert_seen("orca@discord", "discord")
      %{node: node}
    end

    test "no runner_node means unchanged behavior", %{project: project} do
      {:ok, _} =
        ClusterNodes.update_node(
          ClusterNodes.get_by_name("orca@discord"),
          %{default_backend: "codex", default_model: "some-model"}
        )

      {:ok, session} =
        Sessions.create_session(%{directory: project.directory, project_id: project.id})

      assert session.backend == "claude"
      assert session.model == nil
    end

    test "runner_node with no matching row leaves attrs untouched", %{project: project} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: "orca@ghost-node"
        })

      assert session.backend == "claude"
      assert session.model == nil
    end

    test "matching node with nil defaults leaves attrs untouched", %{project: project, node: node} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name
        })

      assert session.backend == "claude"
      assert session.model == nil
    end

    test "fills backend/model from node defaults with atom-keyed attrs", %{
      project: project,
      node: node
    } do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name
        })

      assert session.backend == "claude"
      assert session.model == "sonnet-5"
    end

    test "fills backend/model from node defaults with string-keyed attrs", %{
      project: project,
      node: node
    } do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          "directory" => project.directory,
          "project_id" => project.id,
          "runner_node" => node.name
        })

      assert session.backend == "claude"
      assert session.model == "sonnet-5"
    end

    test "explicit backend wins over node default_backend", %{project: project, node: node} do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "codex", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name,
          backend: "claude"
        })

      assert session.backend == "claude"
    end

    test "explicit model wins over node default_model", %{project: project, node: node} do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name,
          model: "opus-4"
        })

      assert session.model == "opus-4"
    end

    test "empty-string backend/model count as unset and get the node defaults", %{
      project: project,
      node: node
    } do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          "directory" => project.directory,
          "project_id" => project.id,
          "runner_node" => node.name,
          "backend" => "",
          "model" => ""
        })

      assert session.backend == "claude"
      assert session.model == "sonnet-5"
    end

    test "explicit backend different from node default_backend skips node's default_model", %{
      project: project,
      node: node
    } do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name,
          backend: "codex"
        })

      assert session.backend == "codex"
      assert session.model == nil
    end

    test "explicit backend matching node default_backend still gets the default_model", %{
      project: project,
      node: node
    } do
      {:ok, _} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      {:ok, session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name,
          backend: "claude"
        })

      assert session.model == "sonnet-5"
    end

    test "default_model with no default_backend is treated as configured for claude", %{
      project: project,
      node: node
    } do
      {:ok, _} = ClusterNodes.update_node(node, %{default_model: "sonnet-5"})

      {:ok, no_backend_session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name
        })

      assert no_backend_session.backend == "claude"
      assert no_backend_session.model == "sonnet-5"

      {:ok, codex_session} =
        Sessions.create_session(%{
          directory: project.directory,
          project_id: project.id,
          runner_node: node.name,
          backend: "codex"
        })

      assert codex_session.backend == "codex"
      assert codex_session.model == nil
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

    # Pins the LATERAL join's message-selection semantics against the old
    # whole-table `DISTINCT ON` subquery it replaced (see
    # perf_audit_projects_queue.md §2) — same session, same message, same
    # ordering.
    test "picks the most recent assistant message, ignoring non-assistant messages and older ones",
         %{project: project} do
      session = create_session(project, %{title: "S", status: "idle"})

      insert_message_at(
        session,
        %{"type" => "assistant", "text" => "first"},
        ~N[2026-01-01 00:00:00]
      )

      insert_message_at(
        session,
        %{"type" => "user", "text" => "ignored, not assistant"},
        ~N[2026-01-01 00:00:02]
      )

      insert_message_at(
        session,
        %{"type" => "assistant", "text" => "second"},
        ~N[2026-01-01 00:00:01]
      )

      insert_message_at(
        session,
        %{"type" => "assistant", "text" => "latest"},
        ~N[2026-01-01 00:00:03]
      )

      results = Sessions.list_idle_sessions_with_last_assistant_message()
      {_s, msg} = Enum.find(results, fn {s, _msg} -> s.id == session.id end)

      assert msg.data["text"] == "latest"
    end

    test "returns nil for the message when a session has no assistant message yet",
         %{project: project} do
      session = create_session(project, %{title: "No replies yet", status: "idle"})

      insert_message_at(session, %{"type" => "user", "text" => "hi"}, ~N[2026-01-01 00:00:00])

      results = Sessions.list_idle_sessions_with_last_assistant_message()
      {_s, msg} = Enum.find(results, fn {s, _msg} -> s.id == session.id end)

      assert msg == nil
    end

    defp insert_message_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      message
    end
  end

  describe "last_assistant_text/1" do
    defp text_message(text \\ "here is my reply") do
      %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => text}]}
      }
    end

    defp thinking_message do
      %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "thinking", "thinking" => "hmm"}]}
      }
    end

    defp insert_assistant_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      message
    end

    test "same-second tie: returns the text message even when a thinking-only message shares its inserted_at",
         %{project: project} do
      session = create_session(project)
      ts = ~N[2026-07-20 19:17:09]

      # Inserted first, so it would win a naive "first row back" tie-break —
      # the fix must not depend on insertion order within the same second.
      insert_assistant_at(session, thinking_message(), ts)
      insert_assistant_at(session, text_message(), ts)

      assert Sessions.last_assistant_text(session.id) == "here is my reply"
    end

    test "does not resurrect an older reply from outside the burst window when the newest turn is text-less",
         %{project: project} do
      session = create_session(project)
      old_ts = ~N[2026-07-20 19:10:00]
      new_ts = NaiveDateTime.add(old_ts, 10, :second)

      insert_assistant_at(session, text_message(), old_ts)
      insert_assistant_at(session, thinking_message(), new_ts)

      assert Sessions.last_assistant_text(session.id) == nil
    end

    test "returns nil when the session has no assistant messages", %{project: project} do
      session = create_session(project)

      assert Sessions.last_assistant_text(session.id) == nil
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

  describe "git_log_by_grep/2 and list_session_commits/2 (issues_spec.md §4.2/§5.1)" do
    defp init_git_repo(dir) do
      File.mkdir_p!(dir)
      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    end

    defp commit_in(dir, filename, message) do
      File.write!(Path.join(dir, filename), Ecto.UUID.generate())
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", message], cd: dir)
    end

    setup do
      dir =
        Path.join(System.tmp_dir!(), "sessions-git-grep-#{System.unique_integer([:positive])}")

      init_git_repo(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "list_session_commits/2 finds a commit tagged with the OrcaHub-Session trailer", %{
      dir: dir
    } do
      session_id = Ecto.UUID.generate()
      commit_in(dir, "a.txt", "Fix the thing\n\nOrcaHub-Session: #{session_id}")

      assert [%{subject: "Fix the thing"}] = Sessions.list_session_commits(dir, session_id)
    end

    test "list_session_commits/2 returns [] when no commit references the session", %{dir: dir} do
      commit_in(dir, "a.txt", "Unrelated commit")

      assert Sessions.list_session_commits(dir, Ecto.UUID.generate()) == []
    end

    # issues_spec.md §5: "Repeated trailers must be supported — one commit
    # can carry N issue trailers, and `git log --grep` handles repeats
    # natively." A commit citing two issues shows up independently under
    # EACH issue's own grep — no special multi-trailer parsing needed.
    test "a commit carrying repeated OrcaHub-Issue trailers is found by each issue's own grep", %{
      dir: dir
    } do
      commit_in(
        dir,
        "a.txt",
        "Fix two things at once\n\nOrcaHub-Issue: ORCA-1\nOrcaHub-Issue: ORCA-2"
      )

      assert [%{subject: "Fix two things at once"}] =
               Sessions.git_log_by_grep(dir, "OrcaHub-Issue: ORCA-1")

      assert [%{subject: "Fix two things at once"}] =
               Sessions.git_log_by_grep(dir, "OrcaHub-Issue: ORCA-2")

      assert Sessions.git_log_by_grep(dir, "OrcaHub-Issue: ORCA-3") == []
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

  describe "get_session_tree/1" do
    test "a session with no parent and no children is a lone root", %{project: project} do
      lone = create_session(project, %{title: "Lone"})

      assert {root, members} = Sessions.get_session_tree(lone.id)
      assert root.id == lone.id
      assert Enum.map(members, & &1.id) == [lone.id]
    end

    test "walks up multiple parent generations to find the true root, then returns every descendant",
         %{project: project} do
      root = create_session(project, %{title: "Root"})
      child = create_session(project, %{title: "Child", parent_session_id: root.id})

      grandchild =
        create_session(project, %{title: "Grandchild", parent_session_id: child.id})

      # Asking from any member of the tree — not just the root — returns the
      # same {root, full membership} pair.
      assert {found_root, members} = Sessions.get_session_tree(grandchild.id)
      assert found_root.id == root.id

      assert Enum.map(members, & &1.id) |> Enum.sort() ==
               Enum.sort([root.id, child.id, grandchild.id])
    end

    test "includes archived descendants with no time bound, unlike the old tree page's filter",
         %{project: project} do
      root = create_session(project, %{title: "Root"})

      archived_child =
        create_session(project, %{title: "Archived Child", parent_session_id: root.id})

      {:ok, archived_child} = Sessions.archive_session(archived_child)

      old_time = NaiveDateTime.utc_now() |> NaiveDateTime.add(-30 * 24 * 3600, :second)

      from(s in Session, where: s.id == ^archived_child.id)
      |> Repo.update_all(set: [updated_at: old_time])

      {_root, members} = Sessions.get_session_tree(root.id)
      assert archived_child.id in Enum.map(members, & &1.id)
    end

    test "a session whose parent got filtered/archived is still a member — only membership matters, not status",
         %{project: project} do
      root = create_session(project, %{title: "Root"})
      {:ok, root} = Sessions.archive_session(root)
      child = create_session(project, %{title: "Child", parent_session_id: root.id})

      assert {found_root, members} = Sessions.get_session_tree(child.id)
      assert found_root.id == root.id
      assert Enum.map(members, & &1.id) |> Enum.sort() == Enum.sort([root.id, child.id])
    end
  end

  describe "list_sessions_by_ids/1" do
    test "returns id/title pairs for the given ids only", %{project: project} do
      a = create_session(project, %{title: "A"})
      _b = create_session(project, %{title: "B"})

      assert [%{id: id, title: "A"}] = Sessions.list_sessions_by_ids([a.id])
      assert id == a.id
    end

    test "returns an empty list for an empty id list" do
      assert Sessions.list_sessions_by_ids([]) == []
    end
  end

  describe "list_task_invocations/1" do
    defp assistant_with_tool_uses(blocks) do
      %{"type" => "assistant", "message" => %{"content" => blocks}}
    end

    test "returns only Agent-named tool_use blocks, parsed into subagent_type/description",
         %{project: project} do
      session = create_session(project)

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data:
            assistant_with_tool_uses([
              %{
                "type" => "tool_use",
                "id" => "toolu_agent_1",
                "name" => "Agent",
                "input" => %{
                  "subagent_type" => "code-reviewer",
                  "description" => "Review the diff"
                }
              },
              %{
                "type" => "tool_use",
                "id" => "toolu_bash_1",
                "name" => "Bash",
                "input" => %{"command" => "ls"}
              }
            ])
        })

      assert [
               %{
                 id: "toolu_agent_1",
                 subagent_type: "code-reviewer",
                 description: "Review the diff"
               }
             ] =
               Sessions.list_task_invocations(session.id)
    end

    test "returns an empty list for a session with no Agent tool_use blocks", %{project: project} do
      session = create_session(project)

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data:
            assistant_with_tool_uses([
              %{"type" => "tool_use", "id" => "toolu_bash_2", "name" => "Bash", "input" => %{}}
            ])
        })

      assert Sessions.list_task_invocations(session.id) == []
    end

    test "collects Agent tool_use blocks across multiple messages", %{project: project} do
      session = create_session(project)

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data:
            assistant_with_tool_uses([
              %{
                "type" => "tool_use",
                "id" => "toolu_agent_a",
                "name" => "Agent",
                "input" => %{"subagent_type" => "explore", "description" => "Find the bug"}
              }
            ])
        })

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data:
            assistant_with_tool_uses([
              %{
                "type" => "tool_use",
                "id" => "toolu_agent_b",
                "name" => "Agent",
                "input" => %{"subagent_type" => "fix", "description" => "Fix the bug"}
              }
            ])
        })

      result = Sessions.list_task_invocations(session.id)
      assert length(result) == 2
      assert Enum.map(result, & &1.id) == ["toolu_agent_a", "toolu_agent_b"]
    end
  end

  describe "list_messages_window/2" do
    defp text_msg(text) do
      %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
    end

    defp window_insert_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      %{message | inserted_at: inserted_at}
    end

    defp texts(window) do
      Enum.map(window, &get_in(&1, ["message", "content", Access.at(0), "text"]))
    end

    test "returns only the last N top-level messages, oldest-first, with a cursor + has_more",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      msgs =
        for i <- 1..5,
            do:
              window_insert_at(session, text_msg("msg#{i}"), NaiveDateTime.add(base, i, :second))

      %{messages: window, has_more: has_more, cursor: cursor} =
        Sessions.list_messages_window(session.id, limit: 3)

      assert texts(window) == ["msg3", "msg4", "msg5"]
      assert has_more

      third_oldest = Enum.at(msgs, 2)
      assert cursor == %{inserted_at: third_oldest.inserted_at, id: third_oldest.id}
    end

    test "has_more is false and cursor is nil-safe when the window covers the whole history",
         %{project: project} do
      session = create_session(project)
      window_insert_at(session, text_msg("only"), ~N[2026-01-01 00:00:00.000000])

      %{messages: window, has_more: has_more} =
        Sessions.list_messages_window(session.id, limit: 20)

      assert texts(window) == ["only"]
      refute has_more
    end

    test "an empty session returns an empty window, no cursor, no has_more", %{project: project} do
      session = create_session(project)

      assert Sessions.list_messages_window(session.id, limit: 20) ==
               %{messages: [], has_more: false, cursor: nil}
    end

    test "keyset paging via :before doesn't skip or duplicate rows as new messages arrive between pages",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      for i <- 1..5,
          do: window_insert_at(session, text_msg("m#{i}"), NaiveDateTime.add(base, i, :second))

      %{messages: page1, cursor: cursor1} = Sessions.list_messages_window(session.id, limit: 2)
      assert texts(page1) == ["m4", "m5"]

      # A new message lands (e.g. a live turn) timestamped AFTER everything
      # already paged — an offset-based "page 2" would shift under this, but
      # a keyset :before cursor must be immune to it.
      window_insert_at(session, text_msg("m6-live"), NaiveDateTime.add(base, 100, :second))

      %{messages: page2, cursor: cursor2, has_more: has_more2} =
        Sessions.list_messages_window(session.id, limit: 2, before: cursor1)

      assert texts(page2) == ["m2", "m3"]
      assert has_more2

      %{messages: page3, has_more: has_more3} =
        Sessions.list_messages_window(session.id, limit: 2, before: cursor2)

      assert texts(page3) == ["m1"]
      refute has_more3
    end

    test "a subagent block (children + task_* progress events) is never split across the window boundary",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "id" => "T1", "name" => "Agent", "input" => %{}}]
        }
      }

      window_insert_at(session, parent, NaiveDateTime.add(base, 1, :second))

      # Unrelated top-level messages land between the parent and its own
      # descendants — a naive "last N ROWS" slice (counting children against
      # the same budget as top-level items) would separate "T1" from them.
      for i <- 2..6,
          do:
            window_insert_at(session, text_msg("filler#{i}"), NaiveDateTime.add(base, i, :second))

      child = %{
        "type" => "assistant",
        "parent_tool_use_id" => "T1",
        "message" => %{"content" => [%{"type" => "text", "text" => "child reply"}]}
      }

      window_insert_at(session, child, NaiveDateTime.add(base, 7, :second))

      task_event = %{
        "type" => "system",
        "subtype" => "task_progress",
        "tool_use_id" => "T1",
        "note" => "working..."
      }

      window_insert_at(session, task_event, NaiveDateTime.add(base, 8, :second))

      # limit: 6 = parent + 5 filler messages = exactly every top-level row;
      # "T1" is the OLDEST item in the window, right at the boundary.
      %{messages: window} = Sessions.list_messages_window(session.id, limit: 6)

      assert Enum.any?(window, fn msg ->
               get_in(msg, ["message", "content", Access.at(0), "id"]) == "T1"
             end)

      assert Enum.any?(window, &(&1["parent_tool_use_id"] == "T1"))
      assert Enum.any?(window, &(&1["type"] == "system" and &1["tool_use_id"] == "T1"))

      # Sanity check on the flip side: when "T1" itself is NOT in the loaded
      # top-level window, its descendants must not leak in either — a
      # smaller-than-boundary limit only ever returns the filler messages.
      %{messages: narrow_window} = Sessions.list_messages_window(session.id, limit: 3)
      refute Enum.any?(narrow_window, &(&1["parent_tool_use_id"] == "T1"))
      refute Enum.any?(narrow_window, &(&1["type"] == "system" and &1["tool_use_id"] == "T1"))
    end

    test "a subagent block is pulled in fully even when it's the ONLY top-level item in the window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "id" => "T1", "name" => "Agent", "input" => %{}}]
        }
      }

      window_insert_at(session, parent, base)

      child = %{
        "type" => "assistant",
        "parent_tool_use_id" => "T1",
        "message" => %{"content" => [%{"type" => "text", "text" => "child reply"}]}
      }

      window_insert_at(session, child, NaiveDateTime.add(base, 1, :second))

      %{messages: window} = Sessions.list_messages_window(session.id, limit: 1)

      assert Enum.any?(window, &(&1["parent_tool_use_id"] == "T1"))
    end
  end

  describe "fetch_tool_use_message/2" do
    test "finds the assistant message that owns a given tool_use id", %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      parent = %{
        "type" => "assistant",
        "message" => %{
          "content" => [%{"type" => "tool_use", "id" => "T1", "name" => "Agent", "input" => %{}}]
        }
      }

      window_insert_at(session, parent, base)

      assert %{"message" => %{"content" => [%{"id" => "T1"}]}, "timestamp" => %NaiveDateTime{}} =
               Sessions.fetch_tool_use_message(session.id, "T1")
    end

    test "returns nil when no message carries that tool_use id", %{project: project} do
      session = create_session(project)
      assert Sessions.fetch_tool_use_message(session.id, "does-not-exist") == nil
    end

    test "ignores a tool_use id belonging to a different session", %{project: project} do
      session = create_session(project)
      other = create_session(project)

      window_insert_at(
        session,
        %{
          "type" => "assistant",
          "message" => %{
            "content" => [
              %{"type" => "tool_use", "id" => "T1", "name" => "Agent", "input" => %{}}
            ]
          }
        },
        ~N[2026-01-01 00:00:00.000000]
      )

      assert Sessions.fetch_tool_use_message(other.id, "T1") == nil
    end
  end

  describe "targeted derived-state queries (see SessionLive.Show mount)" do
    defp derived_insert_at(session, data, inserted_at) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])

      message
    end

    defp derived_noise(session, base, count) do
      for i <- 1..count,
          do:
            derived_insert_at(session, text_msg("noise#{i}"), NaiveDateTime.add(base, i, :second))
    end

    test "latest_plan_mode_tool_use_name/1 finds an EnterPlanMode far outside a small window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      enter = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "name" => "EnterPlanMode"}]}
      }

      derived_insert_at(session, enter, base)
      derived_noise(session, base, 30)

      assert Sessions.latest_plan_mode_tool_use_name(session.id) == "EnterPlanMode"
    end

    test "latest_plan_mode_tool_use_name/1 reflects the LAST toggle when Exit follows Enter",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      enter = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "name" => "EnterPlanMode"}]}
      }

      exit_ = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "name" => "ExitPlanMode"}]}
      }

      derived_insert_at(session, enter, base)
      derived_noise(session, base, 10)
      derived_insert_at(session, exit_, NaiveDateTime.add(base, 50, :second))
      derived_noise(session, NaiveDateTime.add(base, 50, :second), 20)

      assert Sessions.latest_plan_mode_tool_use_name(session.id) == "ExitPlanMode"
    end

    test "latest_plan_mode_tool_use_name/1 is nil when plan mode was never toggled",
         %{project: project} do
      session = create_session(project)
      derived_noise(session, ~N[2026-01-01 00:00:00.000000], 5)

      assert Sessions.latest_plan_mode_tool_use_name(session.id) == nil
    end

    test "latest_todos_input/1 survives many unrelated messages after the last TodoWrite",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      todo_write = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "TodoWrite",
              "input" => %{"todos" => [%{"content" => "write tests", "status" => "pending"}]}
            }
          ]
        }
      }

      derived_insert_at(session, todo_write, base)
      derived_noise(session, base, 30)

      assert Sessions.latest_todos_input(session.id) == [
               %{"content" => "write tests", "status" => "pending"}
             ]
    end

    test "pending_ask_user_question/1 finds a still-open question far outside a small window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      ask = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ]
        }
      }

      derived_insert_at(session, ask, base)
      derived_noise(session, base, 25)

      assert %{tool_use_id: "aq1", questions: [%{"header" => "Which approach?"}]} =
               Sessions.pending_ask_user_question(session.id)
    end

    test "pending_ask_user_question/1 clears once a non-error tool_result answers it",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      ask = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ]
        }
      }

      answer = %{
        "type" => "user",
        "message" => %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "aq1", "content" => "A"}]
        }
      }

      derived_insert_at(session, ask, base)
      derived_insert_at(session, answer, NaiveDateTime.add(base, 1, :second))

      assert Sessions.pending_ask_user_question(session.id) == nil
    end

    test "pending_ask_user_question/1 stays pending against the synthetic is_error tool_result",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      ask = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "aq1",
              "name" => "AskUserQuestion",
              "input" => %{"questions" => [%{"header" => "Which approach?"}]}
            }
          ]
        }
      }

      synthetic_error = %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "aq1",
              "is_error" => true,
              "content" => "Answer questions?"
            }
          ]
        }
      }

      derived_insert_at(session, ask, base)
      derived_insert_at(session, synthetic_error, NaiveDateTime.add(base, 1, :second))

      assert %{tool_use_id: "aq1"} = Sessions.pending_ask_user_question(session.id)
    end

    test "pending_pi_ui_request/1 finds a still-open request far outside a small window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      request = %{"type" => "pi_ui_request", "id" => "req1", "method" => "select"}

      derived_insert_at(session, request, base)
      derived_noise(session, base, 25)

      assert Sessions.pending_pi_ui_request(session.id)["id"] == "req1"
    end

    test "pending_pi_ui_request/1 clears once a matching pi_ui_response arrives",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      request = %{"type" => "pi_ui_request", "id" => "req1", "method" => "select"}
      response = %{"type" => "pi_ui_response", "id" => "req1", "value" => "yes"}

      derived_insert_at(session, request, base)
      derived_insert_at(session, response, NaiveDateTime.add(base, 1, :second))

      assert Sessions.pending_pi_ui_request(session.id) == nil
    end

    test "latest_pi_plan_mode_enabled?/1 reflects the last broadcast far outside a small window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      derived_insert_at(session, %{"type" => "pi_plan_mode", "enabled" => true}, base)
      derived_noise(session, base, 25)

      assert Sessions.latest_pi_plan_mode_enabled?(session.id)
    end

    test "latest_pi_plan_mode_enabled?/1 is false when the last broadcast disabled it",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      derived_insert_at(session, %{"type" => "pi_plan_mode", "enabled" => true}, base)

      derived_insert_at(
        session,
        %{"type" => "pi_plan_mode", "enabled" => false},
        NaiveDateTime.add(base, 1, :second)
      )

      refute Sessions.latest_pi_plan_mode_enabled?(session.id)
    end

    test "latest_context_percent/1 finds the last numeric percent far outside a small window",
         %{project: project} do
      session = create_session(project)
      base = ~N[2026-01-01 00:00:00.000000]

      stats = %{"type" => "pi_session_stats", "context_usage" => %{"percent" => 42.5}}
      derived_insert_at(session, stats, base)
      derived_noise(session, base, 25)

      assert Sessions.latest_context_percent(session.id) == 42.5
    end

    test "latest_context_percent/1 is nil when no pi_session_stats event ever arrived",
         %{project: project} do
      session = create_session(project)
      derived_noise(session, ~N[2026-01-01 00:00:00.000000], 5)

      assert Sessions.latest_context_percent(session.id) == nil
    end
  end
end
