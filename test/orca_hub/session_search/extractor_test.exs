defmodule OrcaHub.SessionSearch.ExtractorTest do
  use ExUnit.Case, async: true

  alias OrcaHub.SessionSearch.Extractor
  alias OrcaHub.Sessions.{Message, Session}

  @sid "11111111-1111-1111-1111-111111111111"
  @pid "22222222-2222-2222-2222-222222222222"

  defp session(attrs \\ %{}) do
    struct(
      %Session{
        id: @sid,
        kind: "session",
        backend: "claude",
        runner_node: "debian",
        project_id: @pid,
        directory: "/home/zach/x"
      },
      attrs
    )
  end

  defp msg(data, ts \\ ~N[2026-10-06 12:00:00.123456]) do
    %Message{
      id: "33333333-3333-3333-3333-333333333333",
      session_id: @sid,
      data: data,
      inserted_at: ts
    }
  end

  defp user(content, extra \\ %{}),
    do:
      msg(
        Map.merge(
          %{"type" => "user", "message" => %{"role" => "user", "content" => content}},
          extra
        )
      )

  defp assistant(blocks, extra \\ %{}),
    do: msg(Map.merge(%{"type" => "assistant", "message" => %{"content" => blocks}}, extra))

  test "user string prompt becomes a contract doc" do
    assert {:ok, doc} = Extractor.extract(user("how do I deploy?"), session())

    assert doc == %{
             "id" => "33333333-3333-3333-3333-333333333333",
             "group_id" => @sid,
             "text" => "how do I deploy?",
             "fields" => %{
               "role" => "user",
               "backend" => "claude",
               "node" => "debian",
               "project_id" => @pid,
               "directory" => "/home/zach/x",
               "inserted_at" => "2026-10-06T12:00:00.123456Z"
             }
           }
  end

  test "user text blocks are joined; tool_result blocks are ignored" do
    content = [
      %{"type" => "tool_result", "tool_use_id" => "t", "content" => "SECRET FILE DUMP"},
      %{"type" => "text", "text" => "first"},
      %{"type" => "text", "text" => "second"}
    ]

    assert {:ok, %{"text" => "first\nsecond"}} = Extractor.extract(user(content), session())
  end

  test "a user message carrying only tool results is skipped" do
    content = [%{"type" => "tool_result", "tool_use_id" => "t", "content" => "x"}]
    assert :skip = Extractor.extract(user(content), session())
  end

  test "strips a leading <orca-memory> block, keeping what the human typed" do
    text = "<orca-memory>\n- fact one\n- fact two\n</orca-memory>\n\nactual question"
    assert {:ok, %{"text" => "actual question"}} = Extractor.extract(user(text), session())

    assert {:ok, %{"text" => "actual question"}} =
             Extractor.extract(user([%{"type" => "text", "text" => text}]), session())
  end

  test "a prompt that is only the memory block is skipped" do
    assert :skip = Extractor.extract(user("<orca-memory>\nx\n</orca-memory>\n\n"), session())
  end

  test "a memory block that is not leading, or unterminated, is left alone" do
    mid = "see this: <orca-memory>\nx\n</orca-memory>\n\nok"
    assert {:ok, %{"text" => ^mid}} = Extractor.extract(user(mid), session())
    open = "<orca-memory>\nnever closed"
    assert {:ok, %{"text" => ^open}} = Extractor.extract(user(open), session())
  end

  test "dictation note and session-lifecycle messages are real content and kept" do
    note = "[Dictated via speech recognition — expect misheard words.]\n\nfix the build"
    assert {:ok, %{"text" => ^note}} = Extractor.extract(user(note), session())
    lifecycle = "[Session lifecycle] worker abc went idle"
    assert {:ok, %{"text" => ^lifecycle}} = Extractor.extract(user(lifecycle), session())
  end

  test "assistant: text blocks only; tool_use and thinking dropped" do
    blocks = [
      %{"type" => "thinking", "thinking" => "hmm"},
      %{"type" => "text", "text" => "Here is the answer."},
      %{
        "type" => "tool_use",
        "id" => "t",
        "name" => "Bash",
        "input" => %{"command" => "rm -rf /"}
      },
      %{"type" => "text", "text" => "And more."}
    ]

    assert {:ok,
            %{"text" => "Here is the answer.\nAnd more.", "fields" => %{"role" => "assistant"}}} =
             Extractor.extract(assistant(blocks), session())
  end

  test "assistant with no text (tool_use only / thinking only / blank text) is skipped" do
    assert :skip =
             Extractor.extract(assistant([%{"type" => "tool_use", "name" => "Bash"}]), session())

    assert :skip =
             Extractor.extract(assistant([%{"type" => "thinking", "thinking" => "x"}]), session())

    assert :skip =
             Extractor.extract(assistant([%{"type" => "text", "text" => "  \n "}]), session())
  end

  test "non-conversation event types are skipped" do
    for type <-
          ~w(system result rate_limit_event cli_error pi_session_stats pi_plan_mode pi_ui_request) do
      assert :skip =
               Extractor.extract(
                 msg(%{"type" => type, "message" => %{"content" => "x"}}),
                 session()
               ),
             type
    end
  end

  test "subagent traffic, isMeta and isSynthetic rows are skipped; compact summaries kept" do
    assert :skip =
             Extractor.extract(
               user("sub prompt", %{"parent_tool_use_id" => "toolu_1"}),
               session()
             )

    assert :skip =
             Extractor.extract(
               assistant([%{"type" => "text", "text" => "sub"}], %{
                 "parent_tool_use_id" => "toolu_1"
               }),
               session()
             )

    assert :skip = Extractor.extract(user("# /deploy skill body", %{"isMeta" => true}), session())
    assert :skip = Extractor.extract(user("synthetic", %{"isSynthetic" => true}), session())

    assert {:ok, _} =
             Extractor.extract(
               user("This session is being continued...", %{"isCompactSummary" => true}),
               session()
             )
  end

  test "background session kinds are skipped wholesale" do
    assert :skip =
             Extractor.extract(user("replayed transcript"), session(%{kind: "memory_extraction"}))

    refute Extractor.indexable_session?(session(%{kind: "memory_extraction"}))
  end

  test "codex and pi sessions use the same normalized shapes" do
    for backend <- ~w(codex pi) do
      assert {:ok, %{"fields" => %{"backend" => ^backend, "role" => "user"}}} =
               Extractor.extract(
                 user([%{"type" => "text", "text" => "Reply with Pong"}]),
                 session(%{backend: backend})
               )

      assert {:ok,
              %{"text" => "Pong", "fields" => %{"role" => "assistant", "backend" => ^backend}}} =
               Extractor.extract(
                 assistant([%{"type" => "text", "text" => "Pong"}]),
                 session(%{backend: backend})
               )
    end
  end

  test "nil session fields are omitted, except project_id which is sent as null" do
    s = session(%{runner_node: nil, directory: nil, project_id: nil})
    assert {:ok, %{"fields" => fields}} = Extractor.extract(user("hi"), s)
    refute Map.has_key?(fields, "node")
    refute Map.has_key?(fields, "directory")
    assert Map.fetch!(fields, "project_id") == nil
  end

  test "inserted_at is explicit UTC ISO8601 from a naive_datetime_usec" do
    m = %{user("hi") | inserted_at: ~N[2026-01-02 03:04:05.000007]}

    assert {:ok, %{"fields" => %{"inserted_at" => "2026-01-02T03:04:05.000007Z"}}} =
             Extractor.extract(m, session())
  end

  test "malformed data never raises" do
    assert :skip = Extractor.extract(msg(%{"type" => "user"}), session())

    assert :skip =
             Extractor.extract(
               msg(%{"type" => "user", "message" => %{"content" => 5}}),
               session()
             )

    assert :skip =
             Extractor.extract(
               msg(%{"type" => "assistant", "message" => %{"content" => [nil, "x"]}}),
               session()
             )
  end
end
