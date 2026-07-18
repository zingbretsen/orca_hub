defmodule OrcaHub.MCP.CodeExec.AnalyzerTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.CodeExec.Analyzer

  describe "analyze/1 — named calls" do
    test "captures a single Tools.foo(args) call" do
      assert Analyzer.analyze(~s[Tools.search_sessions(%{"status" => "error"})]) == %{
               tools: ["search_sessions"],
               meta: []
             }
    end

    test "captures a zero-arg Tools.foo() call" do
      assert Analyzer.analyze("Tools.list_projects()") == %{
               tools: ["list_projects"],
               meta: []
             }
    end

    test "captures a piped call — Tools.foo remains a call with an args list" do
      code = ~s"""
      sessions = Tools.search_sessions(%{"status" => "error"})
      sessions |> Enum.map(& &1["id"]) |> Tools.archive_session()
      """

      assert Analyzer.analyze(code) == %{
               tools: ["search_sessions", "archive_session"],
               meta: []
             }
    end

    test "dedups repeats and preserves first-appearance order" do
      code = ~s"""
      Tools.start_session(%{})
      Tools.search_sessions(%{})
      Tools.start_session(%{})
      """

      assert Analyzer.tool_calls(code) == ["start_session", "search_sessions"]
    end
  end

  describe "analyze/1 — Tools.call/try_call" do
    test "a literal string first arg is captured as the real tool name" do
      assert Analyzer.analyze(~s[Tools.call("search_sessions", %{})]) == %{
               tools: ["search_sessions"],
               meta: []
             }

      assert Analyzer.analyze(~s[Tools.try_call("start_session", %{})]) == %{
               tools: ["start_session"],
               meta: []
             }
    end

    test "a non-literal first arg falls back to recording call/try_call as meta" do
      assert Analyzer.analyze(~s[name = "x"\nTools.call(name, %{})]) == %{
               tools: [],
               meta: ["call"]
             }

      assert Analyzer.analyze(~s[Tools.try_call(pick_tool(), %{})]) == %{
               tools: [],
               meta: ["try_call"]
             }
    end
  end

  describe "analyze/1 — discovery/meta helpers" do
    test "search, list, schema are always meta, never tools" do
      code = ~s"""
      Tools.search("sessions")
      Tools.list()
      Tools.schema("start_session")
      """

      assert Analyzer.analyze(code) == %{tools: [], meta: ["search", "list", "schema"]}
    end
  end

  describe "analyze/1 — multi-statement snippets" do
    test "mixes real tool calls with meta helpers, split into separate lists" do
      code = ~s"""
      Tools.search("sessions")
      results = Tools.search_sessions(%{"status" => "error"})
      Tools.call("start_session", %{})
      Enum.count(results)
      """

      assert Analyzer.analyze(code) == %{
               tools: ["search_sessions", "start_session"],
               meta: ["search"]
             }
    end

    test "plain stdlib snippets with no Tools.* calls yield empty lists" do
      code = ~s"""
      x = [1, 2, 3]
      Enum.sum(x)
      """

      assert Analyzer.analyze(code) == %{tools: [], meta: []}
    end
  end

  describe "analyze/1 — never raises" do
    test "a syntax error returns empty lists" do
      assert Analyzer.analyze("def broken(") == %{tools: [], meta: []}
    end

    test "non-binary input returns empty lists" do
      assert Analyzer.analyze(nil) == %{tools: [], meta: []}
      assert Analyzer.analyze(%{}) == %{tools: [], meta: []}
      assert Analyzer.analyze(123) == %{tools: [], meta: []}
    end
  end

  describe "tool_calls/1" do
    test "returns just the tools list" do
      assert Analyzer.tool_calls(~s[Tools.search_sessions(%{})]) == ["search_sessions"]
    end

    test "returns [] when nothing was extracted" do
      assert Analyzer.tool_calls("1 + 1") == []
      assert Analyzer.tool_calls(nil) == []
    end
  end
end
