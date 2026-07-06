defmodule OrcaHub.MCP.CodeExecTest do
  # async: false — these tests generate the GLOBAL `Tools` module, so they must
  # not run concurrently with anything else that (re)generates it.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.CodeExec.{MetaTools, Sandbox, ToolGen}

  # A stub dispatcher returning canned MCP envelopes, baked into the generated
  # `Tools.*` functions so we can exercise auto-unwrap / raise without a live
  # upstream. `dispatch/3` is the only seam ToolGen needs.
  defmodule StubDispatcher do
    def dispatch("ok_json", _args, _state) do
      body = Jason.encode!([%{"number" => 1, "title" => "a"}, %{"number" => 2, "title" => "b"}])
      %{"content" => [%{"type" => "text", "text" => body}], "isError" => false}
    end

    def dispatch("ok_text", _args, _state) do
      %{"content" => [%{"type" => "text", "text" => "plain string"}], "isError" => false}
    end

    def dispatch("boom", _args, _state) do
      %{"content" => [%{"type" => "text", "text" => "repo not found"}], "isError" => true}
    end

    def dispatch("github__get_issue", _args, _state) do
      %{
        "content" => [%{"type" => "text", "text" => "flat upstream call worked"}],
        "isError" => false
      }
    end
  end

  @stub_tools [
    %{"name" => "ok_json", "description" => "returns JSON", "inputSchema" => %{}},
    %{"name" => "ok_text", "description" => "returns text", "inputSchema" => %{}},
    %{"name" => "boom", "description" => "always errors", "inputSchema" => %{}},
    %{
      "name" => "github__get_issue",
      "description" => "Get an issue from a github repo",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "repo" => %{"type" => "string"},
          "number" => %{"type" => "integer"}
        },
        "required" => ["repo"]
      }
    },
    %{
      "name" => "github__weird name!not-valid",
      "description" => "invalid raw name",
      "inputSchema" => %{}
    }
  ]

  describe "generated Tools.* surface (auto-unwrap + raise)" do
    setup do
      # Regenerate the global stub surface immediately before each test body so a
      # peer test (or the live Generator) can't leave a different `Tools` behind.
      ToolGen.generate(root: Tools, dispatcher: StubDispatcher, tools: @stub_tools)
      :ok
    end

    test "JSON content auto-unwraps to a decoded term" do
      assert {:ok, %{value: value}} = Sandbox.eval("Tools.ok_json()")
      assert value == [%{"number" => 1, "title" => "a"}, %{"number" => 2, "title" => "b"}]
    end

    test "text content auto-unwraps to a string" do
      assert {:ok, %{value: "plain string"}} = Sandbox.eval("Tools.ok_text()")
    end

    test "named functions compose with the standard library" do
      code = """
      Tools.ok_json()
      |> Enum.filter(fn i -> i["number"] > 1 end)
      |> Enum.map(fn i -> i["title"] end)
      """

      assert {:ok, %{value: ["b"]}} = Sandbox.eval(code)
    end

    test "isError raises Tools.Error carrying the tool name + upstream text" do
      assert {:error, {:exception, %{banner: banner}}} = Sandbox.eval("Tools.boom()")
      assert banner =~ "(Tools.Error)"
      assert banner =~ "tool boom failed: repo not found"
    end

    test "Tools.try_call/2 returns {:error, reason} instead of raising" do
      assert {:ok, %{value: {:error, reason}}} = Sandbox.eval(~s|Tools.try_call("boom")|)
      assert reason == "tool boom failed: repo not found"
    end

    test "Tools.call/2 is faithful to the full MCP envelope (escape hatch)" do
      assert {:ok, %{value: %{"isError" => true, "content" => content}}} =
               Sandbox.eval(~s|Tools.call("boom")|)

      assert [%{"text" => "repo not found"}] = content
    end

    test "upstream tools are callable flat on the root under their raw MCP name" do
      assert {:ok, %{value: "flat upstream call worked"}} =
               Sandbox.eval("Tools.github__get_issue()")
    end

    test "upstream tools are still callable via the per-prefix submodule (sugar)" do
      assert {:ok, %{value: "flat upstream call worked"}} =
               Sandbox.eval("Tools.Github.get_issue()")
    end
  end

  describe "ToolGen sanity filter on raw tool names" do
    setup do
      ToolGen.generate(root: Tools, dispatcher: StubDispatcher, tools: @stub_tools)
      :ok
    end

    test "a valid upstream raw name gets a flat def on the root" do
      assert function_exported?(Tools, :github__get_issue, 1)
    end

    test "an invalid raw name gets no flat def, but generation still succeeds" do
      # Still discoverable (list/search see every tool) — just not callable via
      # dot syntax; Tools.call/2 remains the raw-dispatch escape hatch for it.
      assert {:ok, %{value: names}} = Sandbox.eval(~S/Tools.list() |> Enum.map(& &1["name"])/)
      assert "github__weird name!not-valid" in names

      refute function_exported?(Tools, :"weird name!not-valid", 1)
      refute function_exported?(Tools, :"github__weird name!not-valid", 1)
    end
  end

  describe "generated Tools.search/1 and Tools.list/0 (map-shaped)" do
    setup do
      ToolGen.generate(root: Tools, dispatcher: StubDispatcher, tools: @stub_tools)
      :ok
    end

    test "list/0 returns name/description maps" do
      assert {:ok, %{value: entries}} = Sandbox.eval("Tools.list()")
      assert %{"name" => "boom", "description" => "always errors"} in entries
      refute Enum.any?(entries, &is_tuple/1)
    end

    test "search/1 returns name/description/args maps" do
      assert {:ok, %{value: [entry]}} = Sandbox.eval(~s|Tools.search("get issue")|)

      assert %{
               "name" => "github__get_issue",
               "description" => "Get an issue from a github repo",
               "args" => ["number?", "repo"]
             } = entry
    end

    test "search/1 requires every whitespace-separated token to match" do
      assert {:ok, %{value: []}} = Sandbox.eval(~s|Tools.search("get nonexistentword")|)

      assert {:ok, %{value: [%{"name" => "github__get_issue"}]}} =
               Sandbox.eval(~s|Tools.search("issue github")|)
    end
  end

  describe "sandbox allowlist (blocks OrcaHub internals + dangerous stdlib)" do
    test "OrcaHub.* internals are rejected before running, with a Tools.* pointer" do
      assert {:error, {:rejected, reason}} =
               Sandbox.eval("OrcaHub.Repo.all(OrcaHub.Sessions.Session)")

      assert reason =~ "OrcaHub.* internals are not accessible"
      assert reason =~ "call the corresponding Tools.* function instead"
    end

    test "System is rejected with a no-filesystem/OS-access hint pointing at Tools.search" do
      assert {:error, {:rejected, reason}} = Sandbox.eval(~s|System.cmd("whoami", [])|)
      assert reason =~ "System"
      assert reason =~ "no filesystem/OS access"
      assert reason =~ "Tools.search"
    end

    test "File is rejected with the same no-filesystem/OS-access hint" do
      assert {:error, {:rejected, reason}} = Sandbox.eval(~s|File.read!("/etc/passwd")|)
      assert reason =~ "File"
      assert reason =~ "no filesystem/OS access"
      assert reason =~ "Tools.search"
    end

    test "erlang :os shell-out is rejected with the same hint" do
      assert {:error, {:rejected, reason}} = Sandbox.eval(~S|:os.cmd(~c"id")|)
      assert reason =~ "no filesystem/OS access"
    end

    test "apply/3 dynamic dispatch is rejected" do
      assert {:error, {:rejected, reason}} =
               Sandbox.eval(~s|apply(File, :read!, ["/etc/passwd"])|)

      assert reason =~ "apply"
    end

    test "a module not on the allowlist at all gets a generic stdlib/Tools.* hint" do
      assert {:error, {:rejected, reason}} = Sandbox.eval("SomeUnknownModule.foo()")

      assert reason =~ "not on the allowlist"
      assert reason =~ "only pure stdlib"
      assert reason =~ "Tools.* are available"
    end

    test "allowed stdlib still works" do
      assert {:ok, %{value: "A,B,C"}} =
               Sandbox.eval(
                 ~S/["b", "a", "c"] |> Enum.sort() |> Enum.join(",") |> String.upcase()/
               )
    end
  end

  describe "resource limits + error classification" do
    test "an infinite loop is killed by the wall-clock timeout" do
      assert {:error, {:timeout, 200}} =
               Sandbox.eval("Enum.each(Stream.cycle([1]), fn _ -> :ok end)", timeout_ms: 200)
    end

    test "exceptions preserve the snippet's real line number (not line 1)" do
      code = """
      a = 1
      b = 0
      a / b
      """

      assert {:error, {:exception, %{line: 3}}} = Sandbox.eval(code)
    end

    test "stdout is captured" do
      assert {:ok, %{value: 2, stdout: "hi\n"}} = Sandbox.eval(~s|IO.puts("hi"); 1 + 1|)
    end
  end

  describe "run_elixir result text distinguishes rejected vs ran-and-failed" do
    test "a rejected snippet tells the model to fix its code" do
      result = MetaTools.call("run_elixir", %{"code" => ~s|File.read!("x")|}, %{})

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "rejected before running"
    end

    test "a snippet that runs and raises is reported as ran-and-failed" do
      result = MetaTools.call("run_elixir", %{"code" => "1 / 0"}, %{})

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "Code ran but raised"
      refute text =~ "rejected before running"
    end

    test "a successful snippet returns the value" do
      result = MetaTools.call("run_elixir", %{"code" => "1 + 2"}, %{})

      assert result["isError"] == false
      assert hd(result["content"])["text"] =~ "=> 3"
    end

    test "a big returned value is capped with a teaching nudge" do
      code = ~S|Enum.map(1..3000, fn i -> %{a: i, b: "value#{i}"} end)|
      result = MetaTools.call("run_elixir", %{"code" => code}, %{})

      assert result["isError"] == false
      text = hd(result["content"])["text"]
      assert text =~ "…[truncated"
      assert text =~ "filter/project the value in your code before returning it"
    end
  end

  describe "search_tools / read_tool (read-only over the live registry)" do
    test "search_tools returns matching tools" do
      result = MetaTools.call("search_tools", %{"query" => "session"}, %{})
      assert result["isError"] == false
      %{"count" => count} = Jason.decode!(hd(result["content"])["text"])
      assert count > 0
    end

    test "search_tools requires every whitespace-separated token to match" do
      result = MetaTools.call("search_tools", %{"query" => "open file"}, %{})
      assert result["isError"] == false
      %{"tools" => tools} = Jason.decode!(hd(result["content"])["text"])
      assert Enum.any?(tools, &(&1["name"] == "open_file"))

      no_match = MetaTools.call("search_tools", %{"query" => "open nonexistentword"}, %{})
      %{"count" => 0} = Jason.decode!(hd(no_match["content"])["text"])
    end

    test "search_tools includes args, with optional properties suffixed \"?\"" do
      result = MetaTools.call("search_tools", %{"query" => "open_file"}, %{})
      %{"tools" => tools} = Jason.decode!(hd(result["content"])["text"])

      assert %{"name" => "open_file", "args" => args} =
               Enum.find(tools, &(&1["name"] == "open_file"))

      assert args == ["file_path", "line?"]
    end

    test "read_tool returns a known first-party tool's schema" do
      result = MetaTools.call("read_tool", %{"name" => "open_file"}, %{})
      assert result["isError"] == false

      %{"name" => "open_file", "inputSchema" => schema} =
        Jason.decode!(hd(result["content"])["text"])

      assert is_map(schema)
    end

    test "read_tool reports unknown tools" do
      result = MetaTools.call("read_tool", %{"name" => "does_not_exist"}, %{})
      assert result["isError"] == true
    end
  end

  describe "MCP.Server tools/list collapse" do
    alias OrcaHub.MCP.Server

    defp tool_names(mcp_session_id) do
      %{"result" => %{"tools" => tools}} =
        Server.handle_jsonrpc(mcp_session_id, %{"method" => "tools/list", "id" => 1})

      Enum.map(tools, & &1["name"])
    end

    test "collapses to the meta-tools when code_exec is on" do
      {:ok, sid} = Server.start_session(orca_session_id: "t1", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      assert Enum.sort(tool_names(sid)) == ["read_tool", "run_elixir", "search_tools"]
    end

    test "is unchanged (full set, no meta-tools) when code_exec is off" do
      {:ok, sid} =
        Server.start_session(orca_session_id: "t2", orchestrator: true, code_exec: false)

      on_exit(fn -> Server.stop_session(sid) end)

      names = tool_names(sid)
      assert "open_file" in names
      assert "send_message_to_session" in names
      refute "run_elixir" in names
    end

    test "the ORCA_DISABLE_CODE_EXEC kill switch forces code_exec off" do
      Application.put_env(:orca_hub, :disable_code_exec, true)
      on_exit(fn -> Application.put_env(:orca_hub, :disable_code_exec, false) end)

      {:ok, sid} = Server.start_session(orca_session_id: "t3", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      names = tool_names(sid)
      refute "run_elixir" in names
      assert "open_file" in names
    end
  end
end
