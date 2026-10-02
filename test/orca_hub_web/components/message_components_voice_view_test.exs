defmodule OrcaHubWeb.MessageComponentsVoiceViewTest do
  @moduledoc """
  The server half of the phone voice view (ORCAHUB3-113 phase C) that lives
  in `OrcaHubWeb.MessageComponents`:

    * the CONTENT MARKERS (`data-voice-content` + `data-voice-msg`) the
      VoiceView hook pages through — top-level user/assistant bubbles only,
      never a subagent's (D4: the pager steps through what you said and what
      the agent said back, not its internal working);
    * `voice_turn/1`, the "agent working" facts (D5) — the current turn's
      last three top-level tool calls, done or running, and their count;
    * `voice_activity/1`, which renders them as one-liners through the same
      `tool_summary` the feed uses.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OrcaHubWeb.MessageComponents

  defp user(id, text, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "user",
        "uuid" => id,
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
      },
      extra
    )
  end

  defp assistant(id, content, extra \\ %{}) do
    Map.merge(
      %{"type" => "assistant", "uuid" => id, "message" => %{"content" => content}},
      extra
    )
  end

  defp text(t), do: %{"type" => "text", "text" => t}

  defp tool_use(id, name, input \\ %{}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp tool_result(uuid, tool_use_id, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "user",
        "uuid" => uuid,
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "ok"}
          ]
        }
      },
      extra
    )
  end

  defp render_feed(messages) do
    render_component(&MessageComponents.message_feed/1, %{messages: messages, session_node: nil})
  end

  # [{role, id}] for every marked element, in document order.
  defp markers(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-voice-content]")
    |> Enum.map(fn node ->
      {LazyHTML.attribute(node, "data-voice-content") |> List.first(),
       LazyHTML.attribute(node, "data-voice-msg") |> List.first()}
    end)
  end

  describe "content markers" do
    test "top-level user and assistant bubbles carry the role and their tts id" do
      html =
        render_feed([
          user("u1", "what failed?"),
          assistant("a1", [text("the gb10 install")])
        ])

      assert markers(html) == [{"user", "u1"}, {"assistant", "a1"}]
    end

    test "the marker is on the bubble element itself (.chat), next to the TTS ids" do
      html = render_feed([assistant("a1", [text("hello")])])
      doc = LazyHTML.from_fragment(html)

      assert [_] =
               LazyHTML.query(doc, ~s(.chat.chat-start[data-voice-msg="a1"] #tts-text-a1))
               |> Enum.to_list()
    end

    test "tool calls, tool results and thinking carry no marker" do
      html =
        render_feed([
          user("u1", "go"),
          assistant("a1", [tool_use("t1", "Bash", %{"command" => "ls"})]),
          tool_result("r1", "t1"),
          assistant("a2", [%{"type" => "thinking", "thinking" => "hmm"}]),
          assistant("a3", [text("done")])
        ])

      assert markers(html) == [{"user", "u1"}, {"assistant", "a3"}]
    end

    test "an assistant message that also called a tool is marked once, for its text" do
      html = render_feed([assistant("a1", [text("let me look"), tool_use("t1", "Read")])])
      assert markers(html) == [{"assistant", "a1"}]
    end

    test "a subagent's prompt and replies are NOT marked; only the top level is" do
      html =
        render_feed([
          user("u1", "review it"),
          assistant("a1", [
            text("spawning a reviewer"),
            tool_use("agent1", "Agent", %{"description" => "review"})
          ]),
          user("su1", "subagent prompt", %{"parent_tool_use_id" => "agent1"}),
          assistant("sa1", [text("subagent reply")], %{"parent_tool_use_id" => "agent1"}),
          assistant("a2", [text("the reviewer says ok")])
        ])

      # The nested ones really are rendered — inside the subagent block —
      # they are just not voice content.
      assert html =~ "subagent prompt"
      assert html =~ "subagent reply"
      assert html =~ ~s(id="tts-text-sa1")

      assert markers(html) == [{"user", "u1"}, {"assistant", "a1"}, {"assistant", "a2"}]
    end

    test "a subagent of a subagent is not marked either" do
      html =
        render_feed([
          assistant("a1", [text("outer"), tool_use("agent1", "Agent")]),
          assistant("sa1", [text("middle"), tool_use("agent2", "Agent")], %{
            "parent_tool_use_id" => "agent1"
          }),
          assistant("ssa1", [text("innermost")], %{"parent_tool_use_id" => "agent2"})
        ])

      # The middle agent's reply renders nested (and is itself a subagent
      # with an Agent call of its own); none of it is voice content.
      assert html =~ "middle"
      assert html =~ ~s(id="tts-text-sa1")
      assert markers(html) == [{"assistant", "a1"}]
    end
  end

  describe "voice_turn/1" do
    test "the current turn starts after the last user PROMPT" do
      turn =
        MessageComponents.voice_turn([
          user("u1", "old turn"),
          assistant("a0", [tool_use("t0", "Read")]),
          tool_result("r0", "t0"),
          user("u2", "new turn", %{"timestamp" => ~N[2026-10-02 12:00:00]}),
          assistant("a1", [tool_use("t1", "Bash", %{"command" => "make"})])
        ])

      assert turn.complete
      assert turn.count == 1
      assert [%{id: "t1", name: "Bash", done: false}] = turn.tools
      assert turn.current == "Bash"
      assert turn.started_at == DateTime.to_unix(~U[2026-10-02 12:00:00Z], :millisecond)
    end

    test "a tool-result-only user message is not a turn boundary" do
      turn =
        MessageComponents.voice_turn([
          user("u1", "go"),
          assistant("a1", [tool_use("t1", "Read")]),
          tool_result("r1", "t1"),
          assistant("a2", [tool_use("t2", "Grep")])
        ])

      assert turn.count == 2
      assert Enum.map(turn.tools, &{&1.id, &1.done}) == [{"t1", true}, {"t2", false}]
    end

    test "only the last three are listed, the count is all of them, the running one is current" do
      msgs =
        [user("u1", "go")] ++
          Enum.flat_map(1..5, fn i ->
            [assistant("a#{i}", [tool_use("t#{i}", "Read")]), tool_result("r#{i}", "t#{i}")]
          end) ++ [assistant("a6", [tool_use("t6", "Bash")])]

      turn = MessageComponents.voice_turn(msgs)

      assert turn.count == 6
      assert Enum.map(turn.tools, & &1.id) == ["t4", "t5", "t6"]
      assert Enum.map(turn.tools, & &1.done) == [true, true, false]
      assert turn.current == "Bash"
    end

    test "with every tool finished, the latest one is the strip's name" do
      turn =
        MessageComponents.voice_turn([
          user("u1", "go"),
          assistant("a1", [tool_use("t1", "Edit")]),
          tool_result("r1", "t1")
        ])

      assert turn.current == "Edit"
    end

    test "a subagent's own tool calls never count; its Agent call does" do
      turn =
        MessageComponents.voice_turn([
          user("u1", "go"),
          assistant("a1", [tool_use("agent1", "Agent", %{"description" => "dig"})]),
          assistant("sa1", [tool_use("st1", "Bash")], %{"parent_tool_use_id" => "agent1"}),
          tool_result("sr1", "st1", %{"parent_tool_use_id" => "agent1"}),
          user("su1", "subagent prompt", %{"parent_tool_use_id" => "agent1"})
        ])

      assert turn.count == 1
      assert [%{name: "Agent", done: false}] = turn.tools
    end

    test "a turn whose prompt is outside the loaded window is incomplete, with no start time" do
      turn = MessageComponents.voice_turn([assistant("a1", [tool_use("t1", "Read")])])

      refute turn.complete
      assert turn.started_at == nil
      assert MessageComponents.voice_tool_count(turn) == "1+ tools"
    end

    test "no tools yet" do
      turn = MessageComponents.voice_turn([user("u1", "hi")])
      assert turn == %{started_at: nil, tools: [], count: 0, complete: true, current: nil}
    end

    test "nothing loaded" do
      assert %{count: 0, tools: [], complete: false, current: nil} =
               MessageComponents.voice_turn([])
    end

    test "string and DateTime timestamps both convert to epoch ms, as UTC" do
      want = DateTime.to_unix(~U[2026-10-02 12:00:00Z], :millisecond)

      for ts <- ["2026-10-02T12:00:00", "2026-10-02T12:00:00Z", ~U[2026-10-02 12:00:00Z]] do
        assert MessageComponents.voice_turn([user("u1", "go", %{"timestamp" => ts})]).started_at ==
                 want
      end

      assert MessageComponents.voice_turn([user("u1", "go", %{"timestamp" => "soon"})]).started_at ==
               nil
    end

    test "a plain-string user prompt is a boundary too" do
      turn =
        MessageComponents.voice_turn([
          assistant("a0", [tool_use("t0", "Read")]),
          %{"type" => "user", "uuid" => "u1", "message" => %{"content" => "string prompt"}},
          assistant("a1", [tool_use("t1", "Bash")])
        ])

      assert turn.complete
      assert Enum.map(turn.tools, & &1.id) == ["t1"]
    end
  end

  describe "voice_tool_count/1 and short_tool_name/1" do
    test "counts" do
      assert MessageComponents.voice_tool_count(%{count: 1, complete: true}) == "1 tool"
      assert MessageComponents.voice_tool_count(%{count: 4, complete: true}) == "4 tools"
      assert MessageComponents.voice_tool_count(%{count: 4, complete: false}) == "4+ tools"
    end

    test "MCP namespacing is dropped from one-liners" do
      assert MessageComponents.short_tool_name("mcp__orca__run_elixir") == "run_elixir"
      assert MessageComponents.short_tool_name("Bash") == "Bash"
      assert MessageComponents.short_tool_name("mcp__weird") == "weird"
      assert MessageComponents.short_tool_name(nil) == "tool"
    end
  end

  describe "voice_activity/1" do
    defp render_activity(msgs) do
      render_component(&MessageComponents.voice_activity/1, %{
        turn: MessageComponents.voice_turn(msgs)
      })
    end

    test "finished calls are checked, the running one spins, each is a one-line summary" do
      html =
        render_activity([
          user("u1", "go"),
          assistant("a1", [tool_use("t1", "Read", %{"file_path" => "scripts/deploy.sh"})]),
          tool_result("r1", "t1"),
          assistant("a2", [tool_use("t2", "Bash", %{"command" => "ssh gb10 journalctl"})])
        ])

      doc = LazyHTML.from_fragment(html)
      items = LazyHTML.query(doc, "#voice-activity [data-voice-activity-item]") |> Enum.to_list()
      assert length(items) == 2

      [done, running] = items
      assert LazyHTML.attribute(done, "data-done") == ["true"]
      assert LazyHTML.text(done) =~ "scripts/deploy.sh"
      assert LazyHTML.query(done, ".hero-check-micro") |> Enum.count() == 1

      assert LazyHTML.attribute(running, "data-done") == ["false"]
      assert LazyHTML.text(running) =~ "ssh gb10 journalctl"
      assert LazyHTML.query(running, ".loading-spinner") |> Enum.count() == 1

      assert html =~ "2 tools so far"
    end

    test "the elapsed clock is an empty, hook-owned (phx-update=ignore) span" do
      html = render_activity([user("u1", "go")])
      doc = LazyHTML.from_fragment(html)

      assert [span] = LazyHTML.query(doc, "#voice-activity-elapsed") |> Enum.to_list()
      assert LazyHTML.attribute(span, "phx-update") == ["ignore"]
      assert LazyHTML.attribute(span, "data-voice-elapsed") == [""]
      assert String.trim(LazyHTML.text(span)) == ""
      assert html =~ "No tools yet"
    end

    test "an MCP tool reads by its short name, with the same summary the feed shows" do
      html =
        render_activity([
          user("u1", "go"),
          assistant("a1", [
            tool_use("t1", "mcp__orca__run_elixir", %{"code" => ~s|Tools.list_issues(%{})|})
          ])
        ])

      assert html =~ "run_elixir"
      refute html =~ "mcp__orca__run_elixir"
      assert html =~ "list_issues"
    end
  end
end
