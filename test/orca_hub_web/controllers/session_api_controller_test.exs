defmodule OrcaHubWeb.SessionApiControllerTest do
  # async: false — this mutates the global `:orca_hub, :api_token` Application
  # env, same as ApiRunControllerTest/A2AControllerTest. Two ASYNC modules
  # doing that race each other for real (confirmed: TTSControllerTest is the
  # only other async: true consumer of this env key, and pairing it with an
  # async: true version of this file reproduced a raw "503 API disabled"
  # failure ~4/5 runs) — async: false modules run serialized relative to each
  # other and never overlap the async pool, which avoids it.
  use OrcaHubWeb.ConnCase, async: false

  import Ecto.Query

  alias OrcaHub.{ApiTokens, Projects, Repo, Sessions}
  alias OrcaHub.Sessions.Message

  @token "test-api-token"

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp with_token(fun) do
    Application.put_env(:orca_hub, :api_token, @token)
    on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)
    fun.()
  end

  defp create_project(name \\ "session-api-test") do
    {:ok, project} =
      Projects.create_project(%{
        name: "#{name} #{System.unique_integer()}",
        directory: "/tmp/session-api-test-#{System.unique_integer()}"
      })

    project
  end

  defp create_session(attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: "/tmp/session-api-test", status: "ready"}, attrs)
      )

    session
  end

  defp assistant_message(text) do
    %{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  # The message-derived activity signal these endpoints sort and filter on —
  # `inserted_at` is forced so a test can pin an exact ordering.
  defp insert_message_at(session, inserted_at, data \\ nil) do
    data = data || assistant_message("reply")
    {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})

    from(m in Message, where: m.id == ^message.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    message
  end

  # Every assertion about ordering/pagination scopes itself to one throwaway
  # project — the suite runs against the shared dev DB, which already holds
  # dozens of unrelated sessions.
  defp ids(body), do: Enum.map(body["sessions"], & &1["id"])

  defp scoped_token(scopes) do
    {:ok, %{secret: secret}} =
      ApiTokens.create_token(%{
        name: "session-api-test-#{System.unique_integer([:positive])}",
        scopes: scopes
      })

    secret
  end

  defp with_bearer(conn, secret), do: put_req_header(conn, "authorization", "Bearer #{secret}")

  describe "auth" do
    test "503 when the API is disabled (no token configured)", %{conn: conn} do
      Application.delete_env(:orca_hub, :api_token)
      conn = conn |> authed() |> get(~p"/api/v1/sessions")
      assert json_response(conn, 503)["error"] == "API disabled"
    end

    test "401 with no Authorization header", %{conn: conn} do
      with_token(fn ->
        conn = get(conn, ~p"/api/v1/sessions")
        assert json_response(conn, 401)
      end)
    end

    test "401 with a mismatched token", %{conn: conn} do
      with_token(fn ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer wrong-token")
          |> get(~p"/api/v1/sessions")

        assert json_response(conn, 401)
      end)
    end

    test "401 with no Authorization header on show", %{conn: conn} do
      with_token(fn ->
        conn = get(conn, ~p"/api/v1/sessions/#{Ecto.UUID.generate()}")
        assert json_response(conn, 401)
      end)
    end
  end

  describe "GET /api/v1/sessions" do
    test "lists non-archived sessions with the compact projection", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        session =
          create_session(%{
            project_id: project.id,
            status: "idle",
            title: "watch test session",
            progress_phase: "implementing",
            progress_note: "writing code"
          })

        insert_message_at(session, ~N[2026-09-01 10:00:00.000000])

        archived = create_session(%{status: "idle"})
        {:ok, _} = Sessions.archive_session(archived)

        conn = conn |> authed() |> get(~p"/api/v1/sessions")
        body = json_response(conn, 200)

        ids = Enum.map(body["sessions"], & &1["id"])
        assert session.id in ids
        refute archived.id in ids

        rendered = Enum.find(body["sessions"], &(&1["id"] == session.id))
        assert rendered["status"] == "idle"
        assert rendered["title"] == "watch test session"
        assert rendered["progress_phase"] == "implementing"
        assert rendered["progress_note"] == "writing code"
        assert rendered["directory"] == session.directory
        assert rendered["project_id"] == project.id
        assert rendered["project_name"] == project.name
        assert rendered["last_activity_at"] == "2026-09-01T10:00:00.000000Z"
      end)
    end

    test "filters by status", %{conn: conn} do
      with_token(fn ->
        running = create_session(%{status: "running"})
        idle = create_session(%{status: "idle"})

        conn = conn |> authed() |> get(~p"/api/v1/sessions", %{"status" => "running"})
        ids = conn |> json_response(200) |> Map.fetch!("sessions") |> Enum.map(& &1["id"])

        assert running.id in ids
        refute idle.id in ids
      end)
    end

    test "filters by project_id", %{conn: conn} do
      with_token(fn ->
        project_a = create_project("project-a")
        project_b = create_project("project-b")

        session_a = create_session(%{project_id: project_a.id})
        session_b = create_session(%{project_id: project_b.id})

        conn = conn |> authed() |> get(~p"/api/v1/sessions", %{"project_id" => project_a.id})
        ids = conn |> json_response(200) |> Map.fetch!("sessions") |> Enum.map(& &1["id"])

        assert session_a.id in ids
        refute session_b.id in ids
      end)
    end
  end

  describe "GET /api/v1/sessions/:id" do
    test "returns the compact projection for an existing session", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        session =
          create_session(%{
            project_id: project.id,
            status: "waiting",
            title: "single fetch test"
          })

        insert_message_at(session, ~N[2026-09-02 08:30:00.000000])

        conn = conn |> authed() |> get(~p"/api/v1/sessions/#{session.id}")
        body = json_response(conn, 200)

        assert body["id"] == session.id
        assert body["status"] == "waiting"
        assert body["title"] == "single fetch test"
        assert body["project_id"] == project.id
        assert body["project_name"] == project.name
        assert body["directory"] == session.directory
        assert body["last_activity_at"] == "2026-09-02T08:30:00.000000Z"
      end)
    end

    test "404 for a well-formed but nonexistent id", %{conn: conn} do
      with_token(fn ->
        conn = conn |> authed() |> get(~p"/api/v1/sessions/#{Ecto.UUID.generate()}")
        assert json_response(conn, 404)["error"] == "session not found"
      end)
    end

    test "400/404 (not a raw CastError) for a malformed id", %{conn: conn} do
      with_token(fn ->
        conn = conn |> authed() |> get(~p"/api/v1/sessions/not-a-uuid")
        assert json_response(conn, 404)["error"] == "session not found"
      end)
    end
  end

  describe "GET /api/v1/sessions — last_activity_at is message-derived" do
    # Regression for the latent bug the /sessions/recent work surfaced: the
    # projection used to report `session.updated_at`, which moves on ANY write
    # — a progress-phase update, an archive flag, a node reassignment — so a
    # client sorting "what just finished" by it got sessions no agent had
    # spoken in for hours.
    test "a write that touches updated_at without adding a message does not move it",
         %{conn: conn} do
      with_token(fn ->
        session = create_session(%{status: "idle", title: "activity regression"})
        insert_message_at(session, ~N[2026-09-01 10:00:00.000000])

        before = fetch_activity(conn, session.id)
        assert before == "2026-09-01T10:00:00.000000Z"

        # Backdate updated_at so the subsequent write is guaranteed to move it
        # (sessions.updated_at is second-precision — a same-second update is
        # a no-op otherwise).
        from(s in OrcaHub.Sessions.Session, where: s.id == ^session.id)
        |> Repo.update_all(set: [updated_at: ~N[2026-01-01 00:00:00]])

        {:ok, updated} =
          session.id
          |> Sessions.get_session()
          |> Sessions.update_session(%{progress_phase: "validating"})

        assert NaiveDateTime.compare(updated.updated_at, ~N[2026-01-01 00:00:00]) == :gt

        assert fetch_activity(conn, session.id) == before
      end)
    end

    test "a session with no messages reports null last_activity_at", %{conn: conn} do
      with_token(fn ->
        session = create_session(%{status: "ready"})

        assert fetch_activity(conn, session.id) == nil
      end)
    end

    defp fetch_activity(conn, session_id) do
      conn
      |> authed()
      |> get(~p"/api/v1/sessions/#{session_id}")
      |> json_response(200)
      |> Map.fetch!("last_activity_at")
    end
  end

  describe "GET /api/v1/sessions — ordering and pagination" do
    test "orders by last_activity_at DESC with nulls last", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        oldest = create_session(%{project_id: project.id})
        newest = create_session(%{project_id: project.id})
        silent = create_session(%{project_id: project.id})

        insert_message_at(oldest, ~N[2026-09-01 10:00:00.000000])
        insert_message_at(newest, ~N[2026-09-03 10:00:00.000000])

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions", %{"project_id" => project.id})
          |> json_response(200)

        assert ids(body) == [newest.id, oldest.id, silent.id]
      end)
    end

    test "breaks ties on id, for both equal timestamps and the null tail", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        [a, b] =
          Enum.sort_by(
            [
              create_session(%{project_id: project.id}),
              create_session(%{project_id: project.id})
            ],
            & &1.id
          )

        [c, d] =
          Enum.sort_by(
            [
              create_session(%{project_id: project.id}),
              create_session(%{project_id: project.id})
            ],
            & &1.id
          )

        same = ~N[2026-09-04 10:00:00.000000]
        insert_message_at(a, same)
        insert_message_at(b, same)

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions", %{"project_id" => project.id})
          |> json_response(200)

        assert ids(body) == [a.id, b.id, c.id, d.id]
      end)
    end

    test "limit/offset page through a stable order without gaps or repeats", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        sessions =
          for minute <- 0..2 do
            session = create_session(%{project_id: project.id})

            insert_message_at(
              session,
              NaiveDateTime.add(~N[2026-09-05 10:00:00.000000], minute, :minute)
            )

            session
          end

        expected = sessions |> Enum.reverse() |> Enum.map(& &1.id)

        page1 =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions", %{"project_id" => project.id, "limit" => "2"})
          |> json_response(200)

        assert ids(page1) == Enum.take(expected, 2)
        assert page1["total"] == 3
        assert page1["limit"] == 2
        assert page1["offset"] == 0
        assert page1["has_more"] == true

        page2 =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions", %{
            "project_id" => project.id,
            "limit" => "2",
            "offset" => "2"
          })
          |> json_response(200)

        assert ids(page2) == Enum.drop(expected, 2)
        assert page2["total"] == 3
        assert page2["offset"] == 2
        assert page2["has_more"] == false

        assert ids(page1) ++ ids(page2) == expected
      end)
    end

    test "clamps an over-max limit instead of rejecting it", %{conn: conn} do
      with_token(fn ->
        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions", %{"limit" => "99999"})
          |> json_response(200)

        assert body["limit"] == 500
        assert length(body["sessions"]) <= 500
      end)
    end

    test "400 for a non-integer or non-positive limit, and a negative offset", %{conn: conn} do
      with_token(fn ->
        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions", %{"limit" => "abc"})
               |> json_response(400) ==
                 %{"error" => "invalid limit"}

        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions", %{"limit" => "0"})
               |> json_response(400) ==
                 %{"error" => "invalid limit"}

        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions", %{"offset" => "-1"})
               |> json_response(400) ==
                 %{"error" => "invalid offset"}
      end)
    end

    test "status is repeatable", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        idle = create_session(%{project_id: project.id, status: "idle"})
        error = create_session(%{project_id: project.id, status: "error"})
        running = create_session(%{project_id: project.id, status: "running"})

        body =
          conn
          |> authed()
          |> get("/api/v1/sessions?status=idle&status=error&project_id=#{project.id}")
          |> json_response(200)

        assert Enum.sort(ids(body)) == Enum.sort([idle.id, error.id])
        refute running.id in ids(body)
      end)
    end
  end

  describe "GET /api/v1/sessions/recent" do
    test "returns the same item shape as /sessions, newest activity first", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        older = create_session(%{project_id: project.id, status: "idle", title: "older"})
        newer = create_session(%{project_id: project.id, status: "error", title: "newer"})
        silent = create_session(%{project_id: project.id, status: "ready"})

        insert_message_at(older, ~N[2026-09-06 10:00:00.000000])
        insert_message_at(newer, ~N[2026-09-06 11:00:00.000000])

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{"project_id" => project.id})
          |> json_response(200)

        assert ids(body) == [newer.id, older.id, silent.id]
        assert body["limit"] == 20
        assert body["total"] == 3
        assert is_binary(body["fetched_at"])

        rendered = hd(body["sessions"])
        assert rendered["status"] == "error"
        assert rendered["title"] == "newer"
        assert rendered["project_name"] == project.name
        assert rendered["last_activity_at"] == "2026-09-06T11:00:00.000000Z"
        refute Map.has_key?(rendered, "last_assistant_text")
      end)
    end

    test "excludes archived sessions and background kinds", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        visible = create_session(%{project_id: project.id, status: "idle"})
        archived = create_session(%{project_id: project.id, status: "idle"})
        background = create_session(%{project_id: project.id, kind: "memory_extraction"})

        {:ok, _} = Sessions.archive_session(archived, extract_memories: false)

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{"project_id" => project.id})
          |> json_response(200)

        assert ids(body) == [visible.id]
        refute archived.id in ids(body)
        refute background.id in ids(body)
      end)
    end

    test "since keeps only sessions with message activity after the instant", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        stale = create_session(%{project_id: project.id})
        fresh = create_session(%{project_id: project.id})
        silent = create_session(%{project_id: project.id})

        insert_message_at(stale, ~N[2026-09-07 09:00:00.000000])
        insert_message_at(fresh, ~N[2026-09-07 11:00:00.000000])

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "since" => "2026-09-07T10:00:00Z"
          })
          |> json_response(200)

        assert ids(body) == [fresh.id]
        refute stale.id in ids(body)
        refute silent.id in ids(body)
        assert body["total"] == 1
      end)
    end

    test "since accepts an offset instant and normalizes it to UTC", %{conn: conn} do
      with_token(fn ->
        project = create_project()
        session = create_session(%{project_id: project.id})
        insert_message_at(session, ~N[2026-09-07 11:00:00.000000])

        # 2026-09-07T08:00:00-04:00 == 12:00:00Z, i.e. AFTER the message.
        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "since" => "2026-09-07T08:00:00-04:00"
          })
          |> json_response(200)

        assert ids(body) == []
      end)
    end

    test "400 for an unparseable since", %{conn: conn} do
      with_token(fn ->
        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions/recent", %{"since" => "yesterday"})
               |> json_response(400) == %{"error" => "invalid since"}
      end)
    end

    test "limit defaults to 20 and is clamped to 100", %{conn: conn} do
      with_token(fn ->
        project = create_project()
        for _ <- 1..3, do: create_session(%{project_id: project.id})

        limited =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{"project_id" => project.id, "limit" => "2"})
          |> json_response(200)

        assert length(limited["sessions"]) == 2
        assert limited["total"] == 3
        assert limited["has_more"] == true

        clamped =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{"limit" => "1000"})
          |> json_response(200)

        assert clamped["limit"] == 100
        assert length(clamped["sessions"]) <= 100
      end)
    end

    test "status is repeatable and combines with project_id", %{conn: conn} do
      with_token(fn ->
        project = create_project()
        other = create_project("other")

        idle = create_session(%{project_id: project.id, status: "idle"})
        error = create_session(%{project_id: project.id, status: "error"})
        running = create_session(%{project_id: project.id, status: "running"})
        elsewhere = create_session(%{project_id: other.id, status: "idle"})

        body =
          conn
          |> authed()
          |> get("/api/v1/sessions/recent?status=idle&status=error&project_id=#{project.id}")
          |> json_response(200)

        assert Enum.sort(ids(body)) == Enum.sort([idle.id, error.id])
        refute running.id in ids(body)
        refute elsewhere.id in ids(body)
      end)
    end

    test "include_tail adds last_assistant_text, truncated to ~400 chars", %{conn: conn} do
      with_token(fn ->
        project = create_project()

        long = create_session(%{project_id: project.id})
        short = create_session(%{project_id: project.id})

        insert_message_at(
          long,
          ~N[2026-09-08 10:00:01.000000],
          assistant_message(String.duplicate("a", 500))
        )

        insert_message_at(short, ~N[2026-09-08 10:00:00.000000], assistant_message("all done"))

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "include_tail" => "true"
          })
          |> json_response(200)

        [long_item, short_item] = body["sessions"]

        assert long_item["id"] == long.id
        assert long_item["last_assistant_text"] == String.duplicate("a", 400) <> "…"
        assert String.length(long_item["last_assistant_text"]) == 401
        assert long_item["last_assistant_text_truncated"] == true

        assert short_item["last_assistant_text"] == "all done"
        assert short_item["last_assistant_text_truncated"] == false
      end)
    end

    # The excerpt rule is OrcaHub.Sessions.truncate_excerpt/2, shared with the
    # Gotify push payload — a notification body and the list row it opens must
    # cut in the same place.
    test "include_tail cuts on a word boundary and collapses whitespace", %{conn: conn} do
      with_token(fn ->
        project = create_project()
        session = create_session(%{project_id: project.id})

        # 80 × "wordy " = 480 chars, so the cut lands mid-word at 400 and must
        # retreat to the preceding space. The newlines must collapse first.
        text = String.duplicate("wordy\n\n", 80)
        insert_message_at(session, ~N[2026-09-08 11:00:00.000000], assistant_message(text))

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "include_tail" => "true"
          })
          |> json_response(200)

        excerpt = hd(body["sessions"])["last_assistant_text"]

        assert String.length(excerpt) <= 401
        assert String.ends_with?(excerpt, "wordy…")
        refute String.contains?(excerpt, "\n")
        refute String.contains?(excerpt, "  ")
        assert hd(body["sessions"])["last_assistant_text_truncated"] == true
      end)
    end

    test "text that only shrinks from whitespace collapsing is not reported as truncated",
         %{conn: conn} do
      with_token(fn ->
        project = create_project()
        session = create_session(%{project_id: project.id})

        # 800 raw chars, but 399 once the blank lines collapse — under budget,
        # so nothing was actually cut and the flag must stay false.
        text = String.duplicate("a\n\n\n", 200)
        insert_message_at(session, ~N[2026-09-08 12:00:00.000000], assistant_message(text))

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "include_tail" => "true"
          })
          |> json_response(200)

        item = hd(body["sessions"])
        assert item["last_assistant_text"] == String.trim(String.duplicate("a ", 200))
        assert item["last_assistant_text_truncated"] == false
        refute String.ends_with?(item["last_assistant_text"], "…")
      end)
    end

    test "include_tail reports null text for a session with no assistant message", %{conn: conn} do
      with_token(fn ->
        project = create_project()
        session = create_session(%{project_id: project.id})

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/recent", %{
            "project_id" => project.id,
            "include_tail" => "1"
          })
          |> json_response(200)

        assert [
                 %{
                   "id" => id,
                   "last_assistant_text" => nil,
                   "last_assistant_text_truncated" => false
                 }
               ] =
                 body["sessions"]

        assert id == session.id
      end)
    end

    test "401 with no Authorization header", %{conn: conn} do
      with_token(fn ->
        assert conn |> get(~p"/api/v1/sessions/recent") |> json_response(401)
      end)
    end

    test "a scoped token needs sessions:read", %{conn: conn} do
      assert conn
             |> with_bearer(scoped_token(["sessions:read"]))
             |> get(~p"/api/v1/sessions/recent")
             |> json_response(200)

      assert conn
             |> with_bearer(scoped_token(["runs:create"]))
             |> get(~p"/api/v1/sessions/recent")
             |> json_response(403) == %{"error" => "forbidden"}
    end
  end

  describe "GET /api/v1/sessions/:id/tail" do
    defp tool_use_message(name, input) do
      %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "name" => name, "input" => input}]}
      }
    end

    defp session_with_tail(project) do
      session = create_session(%{project_id: project.id, status: "idle"})

      insert_message_at(
        session,
        ~N[2026-09-09 10:00:00.000000],
        tool_use_message("Bash", %{"command" => "ls"})
      )

      insert_message_at(
        session,
        ~N[2026-09-09 10:00:00.500000],
        tool_use_message("Read", %{"file_path" => "a.ex"})
      )

      insert_message_at(
        session,
        ~N[2026-09-09 10:00:01.000000],
        assistant_message("tests are green")
      )

      session
    end

    test "returns the session tail", %{conn: conn} do
      with_token(fn ->
        session = session_with_tail(create_project())

        body =
          conn |> authed() |> get(~p"/api/v1/sessions/#{session.id}/tail") |> json_response(200)

        assert body["session_id"] == session.id
        assert body["last_assistant_text"] == "tests are green"
        assert body["tool_calls_truncated"] == false
        assert body["tool_calls_total"] == 2

        assert [%{"name" => "Bash", "input" => %{"command" => "ls"}}, %{"name" => "Read"} | _] =
                 body["recent_tool_calls"]
      end)
    end

    test "tool_call_limit caps the tool calls and flags the truncation", %{conn: conn} do
      with_token(fn ->
        session = session_with_tail(create_project())

        body =
          conn
          |> authed()
          |> get(~p"/api/v1/sessions/#{session.id}/tail", %{"tool_call_limit" => "1"})
          |> json_response(200)

        # Newest-last ordering is session_tail/2's contract: the cap keeps the
        # most recent call, not the oldest.
        assert [%{"name" => "Read"}] = body["recent_tool_calls"]
        assert body["tool_calls_truncated"] == true
        assert body["tool_calls_total"] == 2
      end)
    end

    test "400 for an invalid tool_call_limit", %{conn: conn} do
      with_token(fn ->
        session = create_session(%{})

        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions/#{session.id}/tail", %{"tool_call_limit" => "nope"})
               |> json_response(400) == %{"error" => "invalid tool_call_limit"}
      end)
    end

    test "empty tail for a session with no messages", %{conn: conn} do
      with_token(fn ->
        session = create_session(%{})

        body =
          conn |> authed() |> get(~p"/api/v1/sessions/#{session.id}/tail") |> json_response(200)

        assert body["last_assistant_text"] == nil
        assert body["recent_tool_calls"] == []
        assert body["tool_calls_truncated"] == false
      end)
    end

    test "404 for a nonexistent and for a malformed id", %{conn: conn} do
      with_token(fn ->
        assert conn
               |> authed()
               |> get(~p"/api/v1/sessions/#{Ecto.UUID.generate()}/tail")
               |> json_response(404) == %{"error" => "session not found"}

        assert conn |> authed() |> get("/api/v1/sessions/not-a-uuid/tail") |> json_response(404) ==
                 %{"error" => "session not found"}
      end)
    end

    test "401 with no Authorization header", %{conn: conn} do
      with_token(fn ->
        assert conn
               |> get(~p"/api/v1/sessions/#{Ecto.UUID.generate()}/tail")
               |> json_response(401)
      end)
    end

    test "a session-pinned token reaches only its own session's tail, and not the feed",
         %{conn: conn} do
      session = create_session(%{})
      other = create_session(%{})

      {:ok, %{secret: secret}} =
        ApiTokens.create_token(%{
          name: "pinned-#{System.unique_integer([:positive])}",
          scopes: ["sessions:read"],
          session_id: session.id
        })

      assert conn
             |> with_bearer(secret)
             |> get(~p"/api/v1/sessions/#{session.id}/tail")
             |> json_response(200)

      assert conn
             |> with_bearer(secret)
             |> get(~p"/api/v1/sessions/#{other.id}/tail")
             |> json_response(403)

      assert conn |> with_bearer(secret) |> get(~p"/api/v1/sessions/recent") |> json_response(403)
    end

    test "a scoped token needs sessions:read", %{conn: conn} do
      session = create_session(%{})

      assert conn
             |> with_bearer(scoped_token(["sessions:read"]))
             |> get(~p"/api/v1/sessions/#{session.id}/tail")
             |> json_response(200)

      assert conn
             |> with_bearer(scoped_token(["runs:create"]))
             |> get(~p"/api/v1/sessions/#{session.id}/tail")
             |> json_response(403) == %{"error" => "forbidden"}
    end
  end
end
