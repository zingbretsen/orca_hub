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

  describe "search_tools (read-only over the live registry)" do
    test "search_tools returns matching tools" do
      result = MetaTools.call("search_tools", %{"query" => "session"}, %{})
      assert result["isError"] == false
      %{"count" => count} = Jason.decode!(hd(result["content"])["text"])
      assert count > 0
    end

    test "search_tools ranks by shared tokens instead of requiring every token to match" do
      result = MetaTools.call("search_tools", %{"query" => "open file"}, %{})
      assert result["isError"] == false
      %{"tools" => tools} = Jason.decode!(hd(result["content"])["text"])
      assert Enum.any?(tools, &(&1["name"] == "open_file"))

      # a token matching nothing just contributes no score — it doesn't
      # AND-fail the whole query the way substring search used to.
      partial = MetaTools.call("search_tools", %{"query" => "open zzznotarealword"}, %{})
      %{"tools" => partial_tools} = Jason.decode!(hd(partial["content"])["text"])
      assert Enum.any?(partial_tools, &(&1["name"] == "open_file"))

      no_match = MetaTools.call("search_tools", %{"query" => "zzznotarealword"}, %{})
      %{"count" => 0} = Jason.decode!(hd(no_match["content"])["text"])
    end

    test "search_tools includes args, with optional properties suffixed \"?\"" do
      result = MetaTools.call("search_tools", %{"query" => "open_file"}, %{})
      %{"tools" => tools} = Jason.decode!(hd(result["content"])["text"])

      assert %{"name" => "open_file", "args" => args} =
               Enum.find(tools, &(&1["name"] == "open_file"))

      assert args == ["file_path", "line?"]
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
      assert text =~ "run_elixir, search_tools, send_message_to_session"
      assert text =~ "Tools.schema"
      refute text =~ "read_tool;"
    end
  end

  describe "MetaTools.list/0 tool definitions" do
    test "the meta-tools plus the send_message_to_session passthrough are exposed" do
      assert Enum.map(MetaTools.list(), & &1["name"]) |> Enum.sort() == [
               "run_elixir",
               "search_tools",
               "send_message_to_session"
             ]
    end

    test "send_message_to_session's definition matches the real first-party schema" do
      passthrough = Enum.find(MetaTools.list(), &(&1["name"] == "send_message_to_session"))
      real = Enum.find(OrcaHub.MCP.Tools.list(), &(&1["name"] == "send_message_to_session"))

      assert passthrough == real
    end

    test "passthrough_tool_names/0 is the single source of truth for what's promoted to standalone" do
      assert MetaTools.passthrough_tool_names() == ["send_message_to_session"]
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

    test "search_tools' description points at Tools.schema for full schemas" do
      search_tools = Enum.find(MetaTools.list(), &(&1["name"] == "search_tools"))
      assert search_tools["description"] =~ "Tools.schema"
    end
  end

  describe "MCP.Server tools/list collapse" do
    alias OrcaHub.MCP.Server

    defp tool_names(mcp_session_id) do
      %{"result" => %{"tools" => tools}} =
        Server.handle_jsonrpc(mcp_session_id, %{"method" => "tools/list", "id" => 1})

      Enum.map(tools, & &1["name"])
    end

    test "collapses to the meta-tools (plus send_message_to_session) when code_exec is on" do
      {:ok, sid} = Server.start_session(orca_session_id: "t1", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      assert Enum.sort(tool_names(sid)) == [
               "run_elixir",
               "search_tools",
               "send_message_to_session"
             ]
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

  describe "send_message_to_session passthrough in code-exec mode" do
    alias OrcaHub.MCP.Server
    alias OrcaHub.Sessions

    setup do
      # This describe block is the only one in the file that touches the DB —
      # shared mode (matching DataCase's async:false default) lets the
      # SessionsTool call's internal Repo access see this test's data.
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(OrcaHub.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

      dir =
        Path.join(
          System.tmp_dir!(),
          "code_exec_send_message_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, target} =
        Sessions.create_session(%{
          directory: dir,
          backend: "claude",
          runner_node: "debian@totally-offline-host"
        })

      {:ok, target: target}
    end

    test "MetaTools.call/3 delegates to the real Sessions implementation, not the unknown-tool fallback",
         %{target: target} do
      result =
        MetaTools.call(
          "send_message_to_session",
          %{"session_id" => target.id, "message" => "hi"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not currently connected"
      refute text =~ "Unknown tool"
    end

    test "MCP.Server tools/call routes it through end to end in code-exec mode", %{
      target: target
    } do
      {:ok, sid} = Server.start_session(orca_session_id: "t-passthrough", code_exec: true)
      on_exit(fn -> Server.stop_session(sid) end)

      %{"result" => result} =
        Server.handle_jsonrpc(sid, %{
          "method" => "tools/call",
          "id" => 1,
          "params" => %{
            "name" => "send_message_to_session",
            "arguments" => %{"session_id" => target.id, "message" => "hi"}
          }
        })

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "not currently connected"
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

    test "an exception leaves the previously stored binding untouched" do
      state = %{orca_session_id: unique_key("exception")}

      assert {:ok, %{value: 1}} = CodeExec.run("x = 1", state)
      assert {:error, {:exception, _}} = CodeExec.run("x = 2; raise \"boom\"", state)

      # x is still 1 — the failed eval's reassignment never got saved.
      assert {:ok, %{value: 1}} = CodeExec.run("x", state)
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
