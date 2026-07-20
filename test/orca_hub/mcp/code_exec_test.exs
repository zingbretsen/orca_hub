defmodule OrcaHub.MCP.CodeExecTest do
  # async: false — these tests generate the GLOBAL `Tools` module, so they must
  # not run concurrently with anything else that (re)generates it.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.{BindingStore, MetaTools, Sandbox, ToolGen}

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

    def dispatch("playwright__browser_take_screenshot", _args, _state) do
      png = Base.encode64("not-really-a-png")

      %{
        "content" => [
          %{"type" => "text", "text" => "screenshot captured"},
          %{"type" => "image", "data" => png, "mimeType" => "image/png"}
        ],
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
    },
    %{
      "name" => "playwright__browser_take_screenshot",
      "description" => "takes a screenshot",
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

    test "an image content block is written to disk and referenced by path, text preserved" do
      session_id = "screenshot-#{System.unique_integer([:positive])}"

      assert {:ok, %{value: value}} =
               Sandbox.eval("Tools.playwright__browser_take_screenshot()",
                 state: %{orca_session_id: session_id}
               )

      assert is_binary(value)
      assert value =~ "screenshot captured"
      assert value =~ "view it with the Read tool"

      [path] = Regex.run(~r{(/\S+\.png)}, value, capture: :all_but_first)
      assert File.read!(path) == "not-really-a-png"
      assert path =~ session_id

      on_exit(fn ->
        File.rm_rf!(Path.join([System.tmp_dir!(), "orca_hub", "tool_media", session_id]))
      end)
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

    test "search/1 ranks by shared tokens instead of requiring every token to match" do
      # "nonexistentword" contributes nothing to the score but doesn't AND-fail
      # the query the way substring search used to — "get" alone still surfaces
      # the doc containing it.
      assert {:ok, %{value: [%{"name" => "github__get_issue"}]}} =
               Sandbox.eval(~s|Tools.search("get nonexistentword")|)

      # github__weird name!not-valid also shares the "github" token (via its
      # name), so it may trail behind, but the doc matching BOTH tokens ranks
      # first.
      assert {:ok, %{value: [%{"name" => "github__get_issue"} | _]}} =
               Sandbox.eval(~s|Tools.search("issue github")|)
    end

    test "search/1 returns [] when zero query tokens match" do
      assert {:ok, %{value: []}} = Sandbox.eval(~s|Tools.search("zzznotarealword")|)
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

  describe "compile errors (e.g. an unbound variable) surface the real compiler diagnostic" do
    test "an undefined variable reference includes the diagnostic message and line, not the generic banner" do
      assert {:error, {:exception, %{banner: banner, line: 1}}} = Sandbox.eval("worker")

      assert banner =~ ~s|undefined variable "worker"|
      assert banner =~ "(line 1)"
      refute banner =~ "cannot compile file (errors have been logged)"
    end

    test "the line points at the statement referencing the unbound variable, not line 1" do
      code = """
      x = 1
      worker
      """

      assert {:error, {:exception, %{banner: banner, line: 2}}} = Sandbox.eval(code)
      assert banner =~ ~s|undefined variable "worker"|
      assert banner =~ "(line 2)"
    end

    test "bindings from statements before the undefined-variable statement are kept as partial_binding" do
      code = """
      x = 1
      y = 2
      worker
      """

      assert {:error, {:exception, %{statement: 3, statement_count: 3, partial_binding: partial}}} =
               Sandbox.eval(code)

      assert Keyword.get(partial, :x) == 1
      assert Keyword.get(partial, :y) == 2
    end

    test "a non-compile-error exception's banner/line are unaffected (still built from the stacktrace)" do
      code = """
      a = 1
      b = 0
      a / b
      """

      assert {:error, {:exception, %{banner: banner, line: 3}}} = Sandbox.eval(code)
      assert banner =~ "(ArithmeticError)"
    end

    test "a successful eval is unaffected" do
      assert {:ok, %{value: 3}} = Sandbox.eval("1 + 2")
    end
  end

  describe "sequential top-level statement evaluation" do
    test "a multi-statement snippet that never raises behaves exactly like a whole-block eval" do
      code = """
      x = 1
      x = x + 1
      x * 10
      """

      assert {:ok, %{value: 20, binding: binding}} = Sandbox.eval(code)
      assert Keyword.get(binding, :x) == 2
    end

    test "a single-expression snippet (no block at all) still works" do
      assert {:ok, %{value: 3}} = Sandbox.eval("1 + 2")
    end

    test "on raise, the exception carries which statement failed, of how many, plus the partial binding" do
      code = """
      a = 1
      b = 2
      raise "boom"
      """

      assert {:error, {:exception, %{statement: 3, statement_count: 3, partial_binding: partial}}} =
               Sandbox.eval(code)

      assert Keyword.get(partial, :a) == 1
      assert Keyword.get(partial, :b) == 2
    end

    test "a raise on the very first statement reports statement 1 of N with an empty partial binding" do
      code = """
      raise "boom"
      b = 2
      """

      assert {:error, {:exception, %{statement: 1, statement_count: 2, partial_binding: []}}} =
               Sandbox.eval(code)
    end

    test "a single-expression snippet that raises reports statement 1 of 1" do
      assert {:error, {:exception, %{statement: 1, statement_count: 1, partial_binding: []}}} =
               Sandbox.eval("1 / 0")
    end

    test "stdout from statements before the raise is still captured" do
      code = """
      IO.puts("one")
      IO.puts("two")
      raise "boom"
      """

      assert {:error, {:exception, %{stdout: "one\ntwo\n"}}} = Sandbox.eval(code)
    end

    test "a variable rebound across statements keeps the latest value in the partial binding" do
      code = """
      x = 1
      x = 2
      raise "boom"
      """

      assert {:error, {:exception, %{partial_binding: partial}}} = Sandbox.eval(code)
      assert Keyword.get(partial, :x) == 2
    end

    test "require in one top-level statement is still in scope for the next" do
      code = """
      require Integer
      Integer.is_even(4)
      """

      assert {:ok, %{value: true}} = Sandbox.eval(code)
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

    test "a raise after earlier statements bound variables notes that those bindings were kept" do
      state = %{orca_session_id: "meta-partial-#{System.unique_integer([:positive])}"}
      code = "worker = 1\nraise \"boom\""

      result = MetaTools.call("run_elixir", %{"code" => code}, state)

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "Code ran but raised"
      assert text =~ "bindings from statement 1 of 2 were kept"
    end

    test "a raise on the only statement carries no partial-binding note" do
      result = MetaTools.call("run_elixir", %{"code" => "1 / 0"}, %{})

      text = hd(result["content"])["text"]
      refute text =~ "were kept"
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

  describe "removed search_tools meta-tool" do
    test "meta_tool?/1 no longer recognizes it" do
      refute MetaTools.meta_tool?("search_tools")
    end

    test "calling it falls through to the unknown-tool error, pointing at Tools.search" do
      result = MetaTools.call("search_tools", %{"query" => "open_file"}, %{})

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "exposes only run_elixir"
      assert text =~ "Tools.search"
      refute text =~ "search_tools;"
    end
  end

  describe "removed read_tool meta-tool" do
    test "meta_tool?/1 no longer recognizes it" do
      refute MetaTools.meta_tool?("read_tool")
    end

    test "calling it falls through to the unknown-tool error, pointing at Tools.schema" do
      result = MetaTools.call("read_tool", %{"name" => "open_file"}, %{})

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "exposes only run_elixir"
      assert text =~ "Tools.schema"
      assert text =~ "Tools.search"
      refute text =~ "read_tool;"
    end
  end

  describe "MetaTools.list/0 tool definitions" do
    test "only run_elixir is exposed" do
      assert Enum.map(MetaTools.list(), & &1["name"]) == ["run_elixir"]
    end

    test "run_elixir's description lists the live first-party Tools.* names" do
      run_elixir = Enum.find(MetaTools.list(), &(&1["name"] == "run_elixir"))
      first_party_names = OrcaHub.MCP.Tools.list() |> Enum.map(& &1["name"])

      assert first_party_names != []
      assert Enum.all?(first_party_names, &(run_elixir["description"] =~ &1))
    end

    test "run_elixir's description reflects the live upstream server prefixes" do
      run_elixir = Enum.find(MetaTools.list(), &(&1["name"] == "run_elixir"))
      description = run_elixir["description"]

      case OrcaHub.MCP.UpstreamClient.prefixes() do
        [] ->
          assert description =~ "No upstream MCP servers are currently connected."

        prefixes ->
          assert description =~ "Connected upstream MCP servers:"
          assert Enum.all?(prefixes, &(description =~ &1))
      end
    end

    test "run_elixir's description documents discovery and advertises frequently-used tools" do
      run_elixir = Enum.find(MetaTools.list(), &(&1["name"] == "run_elixir"))
      description = run_elixir["description"]

      assert description =~ "Tools.search("
      assert description =~ "Tools.list()"
      assert description =~ "Tools.schema("
      assert description =~ "Tools.send_message_to_session"
      assert description =~ "Tools.get_session_tail"
      assert description =~ "Tools.report_progress"
      assert description =~ "Tools.start_session"
      assert description =~ "Tools.search_sessions"
      assert description =~ "Tools.schedule_heartbeat"
      assert description =~ "Tools.file_feature_request"
    end
  end

  describe "MCP.Server tools/list collapse" do
    alias OrcaHub.MCP.Server

    defp tool_names(mcp_session_id) do
      %{"result" => %{"tools" => tools}} =
        Server.handle_jsonrpc(mcp_session_id, %{"method" => "tools/list", "id" => 1})

      Enum.map(tools, & &1["name"])
    end

    test "collapses to exactly [run_elixir] when code_exec is on" do
      {:ok, sid} = Server.start_session(orca_session_id: "t1", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      assert tool_names(sid) == ["run_elixir"]
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

  describe "send_message_to_session is no longer a standalone tool in code-exec mode" do
    alias OrcaHub.MCP.Server

    test "MetaTools.call/3 falls through to the unknown-tool steering error, not the real Sessions implementation" do
      result =
        MetaTools.call(
          "send_message_to_session",
          %{"session_id" => "whatever", "message" => "hi"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "exposes only run_elixir"
      refute text =~ "not currently connected"
    end

    test "MCP.Server tools/call gets the same steering error end to end in code-exec mode" do
      {:ok, sid} = Server.start_session(orca_session_id: "t-no-passthrough", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      %{"result" => result} =
        Server.handle_jsonrpc(sid, %{
          "method" => "tools/call",
          "id" => 1,
          "params" => %{
            "name" => "send_message_to_session",
            "arguments" => %{"session_id" => "whatever", "message" => "hi"}
          }
        })

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "exposes only run_elixir"
    end
  end

  describe "run_elixir variable binding persistence (REPL across calls)" do
    # Unique key per test so tests can't see each other's bindings via the
    # shared, app-supervised BindingStore.
    defp unique_key(label), do: "#{label}-#{System.unique_integer([:positive])}"

    test "a variable assigned in one eval is visible in the next, for the same session key" do
      state = %{orca_session_id: unique_key("persist")}

      assert {:ok, %{value: 1}} = CodeExec.run("sessions = 1", state)
      assert {:ok, %{value: 2}} = CodeExec.run("sessions + 1", state)
    end

    test "different session keys are isolated from each other" do
      state_a = %{orca_session_id: unique_key("iso-a")}
      state_b = %{orca_session_id: unique_key("iso-b")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state_a)
      assert {:ok, %{value: 99}} = CodeExec.run("x = 99", state_b)

      # state_a's `x` is unaffected by state_b's assignment.
      assert {:ok, %{value: 1}} = CodeExec.run("x", state_a)
      assert {:ok, %{value: 99}} = CodeExec.run("x", state_b)
    end

    test "a raise on the snippet's only (or first) top-level statement leaves the previous binding untouched" do
      state = %{orca_session_id: unique_key("exception-first-stmt")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state)
      assert {:error, {:exception, _}} = CodeExec.run("raise \"boom\"", state)

      # x is still 1 — the raising statement never got to run, let alone bind anything.
      assert {:ok, %{value: 1}} = CodeExec.run("x", state)
    end

    test "bindings from top-level statements that completed before a raise are still persisted" do
      state = %{orca_session_id: unique_key("exception-partial")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state)

      # `x = 2` completes before `raise` blows up the third statement — the
      # real-world incident this fixes: `worker = Tools.start_session(...)`
      # succeeding, then a later statement in the same snippet raising, must
      # not make the orchestrator lose track of `worker`.
      assert {:error, {:exception, info}} = CodeExec.run("x = 2\ny = 3\nraise \"boom\"", state)
      assert %{statement: 3, statement_count: 3} = info
      assert info.note =~ "bindings from statements 1-2 of 3 were kept"

      assert {:ok, %{value: 2}} = CodeExec.run("x", state)
      assert {:ok, %{value: 3}} = CodeExec.run("y", state)
    end

    test "a timeout leaves the previously stored binding untouched" do
      state = %{orca_session_id: unique_key("timeout")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state)

      assert {:error, {:timeout, 50}} =
               CodeExec.run("x = 2; Enum.each(Stream.cycle([1]), fn _ -> :ok end)", state,
                 timeout_ms: 50
               )

      assert {:ok, %{value: 1}} = CodeExec.run("x", state)
    end

    test "reset: true clears the stored binding before evaluating" do
      state = %{orca_session_id: unique_key("reset")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state)
      assert {:ok, %{value: 1}} = CodeExec.run("x", state)

      # With a fresh binding, `x` is no longer defined.
      assert {:error, {:exception, _}} = CodeExec.run("x", state, reset: true)
    end

    test "run_elixir's \"reset\" arg reaches CodeExec via MetaTools" do
      state = %{orca_session_id: unique_key("meta-reset")}

      result = MetaTools.call("run_elixir", %{"code" => "y = 42"}, state)
      assert result["isError"] == false

      result = MetaTools.call("run_elixir", %{"code" => "y"}, state)
      assert hd(result["content"])["text"] =~ "=> 42"

      result = MetaTools.call("run_elixir", %{"code" => "y", "reset" => true}, state)
      assert result["isError"] == true
    end

    test "falls back to the MCP session_id when orca_session_id is nil" do
      state = %{orca_session_id: nil, session_id: unique_key("mcp-fallback")}

      assert {:ok, %{value: 1}} = CodeExec.run("z = 1", state)
      assert {:ok, %{value: 1}} = CodeExec.run("z", state)
    end

    test "an over-budget binding is not saved and a notice is appended" do
      Application.put_env(:orca_hub, :code_exec_binding_budget_bytes, 100)
      on_exit(fn -> Application.delete_env(:orca_hub, :code_exec_binding_budget_bytes) end)

      state = %{orca_session_id: unique_key("budget")}

      assert {:ok, %{value: 1}} = CodeExec.run("small = 1", state)

      # Comfortably over a 100-byte budget.
      assert {:ok, %{value: _big, note: note}} =
               CodeExec.run("big = String.duplicate(\"a\", 10_000)", state)

      assert note =~ "bindings not saved"
      assert note =~ "exceeds the 100 byte budget"

      # The old (small) binding is still there — the oversized `big` never got saved.
      assert {:ok, %{value: 1}} = CodeExec.run("small", state)
      assert {:error, {:exception, _}} = CodeExec.run("big", state)
    end

    test "run_elixir's result text includes the not-saved notice" do
      Application.put_env(:orca_hub, :code_exec_binding_budget_bytes, 100)
      on_exit(fn -> Application.delete_env(:orca_hub, :code_exec_binding_budget_bytes) end)

      state = %{orca_session_id: unique_key("budget-meta")}
      code = ~s|big = String.duplicate("a", 10_000)|

      result = MetaTools.call("run_elixir", %{"code" => code}, state)
      assert result["isError"] == false
      assert hd(result["content"])["text"] =~ "bindings not saved"
    end
  end

  describe "BindingStore" do
    setup do
      {:ok, pid} = BindingStore.start_link(name: nil)
      %{store: pid}
    end

    test "get/1 defaults to an empty binding for an unknown key", %{store: store} do
      assert BindingStore.get(:unknown, store) == []
    end

    test "put/2 then get/1 round-trips the binding for the same key", %{store: store} do
      BindingStore.put(:k, [x: 1, y: 2], store)
      assert BindingStore.get(:k, store) == [x: 1, y: 2]
    end

    test "different keys don't see each other's bindings", %{store: store} do
      BindingStore.put(:a, [x: 1], store)
      BindingStore.put(:b, [x: 2], store)

      assert BindingStore.get(:a, store) == [x: 1]
      assert BindingStore.get(:b, store) == [x: 2]
    end

    test "reset/1 clears a key", %{store: store} do
      BindingStore.put(:k, [x: 1], store)
      BindingStore.reset(:k, store)
      assert BindingStore.get(:k, store) == []
    end

    test "a later put/2 overwrites an earlier one for the same key (last-write-wins)", %{
      store: store
    } do
      BindingStore.put(:k, [x: 1], store)
      BindingStore.put(:k, [x: 2], store)
      assert BindingStore.get(:k, store) == [x: 2]
    end

    test "sweep evicts entries idle past ttl_ms, without waiting for the real clock" do
      {:ok, store} = BindingStore.start_link(name: nil, ttl_ms: 10, sweep_interval_ms: 3_600_000)

      BindingStore.put(:stale, [x: 1], store)
      Process.sleep(20)
      BindingStore.sweep(store)

      assert BindingStore.get(:stale, store) == []
    end

    test "sweep does not evict entries touched within ttl_ms" do
      {:ok, store} = BindingStore.start_link(name: nil, ttl_ms: 3_600_000)

      BindingStore.put(:fresh, [x: 1], store)
      BindingStore.sweep(store)

      assert BindingStore.get(:fresh, store) == [x: 1]
    end
  end
end
