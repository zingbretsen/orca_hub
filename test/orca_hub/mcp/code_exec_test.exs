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
  end

  @stub_tools [
    %{"name" => "ok_json", "description" => "returns JSON", "inputSchema" => %{}},
    %{"name" => "ok_text", "description" => "returns text", "inputSchema" => %{}},
    %{"name" => "boom", "description" => "always errors", "inputSchema" => %{}}
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
  end

  describe "sandbox allowlist (blocks OrcaHub internals + dangerous stdlib)" do
    test "OrcaHub.* internals are rejected before running" do
      assert {:error, {:rejected, reason}} =
               Sandbox.eval("OrcaHub.Repo.all(OrcaHub.Sessions.Session)")

      assert reason =~ "OrcaHub.* internals are not accessible"
    end

    test "System is rejected" do
      assert {:error, {:rejected, reason}} = Sandbox.eval(~s|System.cmd("whoami", [])|)
      assert reason =~ "System"
    end

    test "File is rejected" do
      assert {:error, {:rejected, reason}} = Sandbox.eval(~s|File.read!("/etc/passwd")|)
      assert reason =~ "File"
    end

    test "erlang :os shell-out is rejected" do
      assert {:error, {:rejected, _}} = Sandbox.eval(~S|:os.cmd(~c"id")|)
    end

    test "apply/3 dynamic dispatch is rejected" do
      assert {:error, {:rejected, reason}} =
               Sandbox.eval(~s|apply(File, :read!, ["/etc/passwd"])|)

      assert reason =~ "apply"
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
  end

  describe "search_tools / read_tool (read-only over the live registry)" do
    test "search_tools returns matching tools" do
      result = MetaTools.call("search_tools", %{"query" => "session"}, %{})
      assert result["isError"] == false
      %{"count" => count} = Jason.decode!(hd(result["content"])["text"])
      assert count > 0
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
