defmodule OrcaHub.MCP.Tools.CodePushTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.Tools
  alias OrcaHub.MCP.Tools.CodePush

  @tool_names ~w(publish_code_generation code_generation_status supersede_code_generation
                 reconcile_code purge_orphaned_modules)

  test "every tool is registered on the shared facade" do
    registered = Enum.map(Tools.list(), & &1["name"])

    for name <- @tool_names do
      assert name in registered, "#{name} is missing from OrcaHub.MCP.Tools.list/0"
    end
  end

  test "the tools are ORCHESTRATOR-ONLY" do
    # Publishing a generation reconciles every node's running code — that is
    # not a capability an ordinary worker session should hold. Absence from
    # the regular-session set is what enforces it.
    regular = Tools.list(%{}) |> Enum.map(& &1["name"])

    for name <- @tool_names do
      refute name in regular, "#{name} leaked into the regular-session tool set"
    end

    orchestrator = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])
    for name <- @tool_names, do: assert(name in orchestrator)
  end

  test "each definition carries a usable JSON schema" do
    for tool <- CodePush.list() do
      assert is_binary(tool["name"])
      assert String.length(tool["description"]) > 40
      assert tool["inputSchema"]["type"] == "object"
      assert is_map(tool["inputSchema"]["properties"])

      for required <- tool["inputSchema"]["required"] || [] do
        assert Map.has_key?(tool["inputSchema"]["properties"], required),
               "#{tool["name"]} requires #{required} but does not declare it"
      end
    end
  end

  test "publish's description states both refusals and that it does not restart anything" do
    [publish] = Enum.filter(CodePush.list(), &(&1["name"] == "publish_code_generation"))

    assert publish["description"] =~ "dirty"
    assert publish["description"] =~ "allow_dirty"
    assert publish["description"] =~ "force"
    assert publish["description"] =~ "Does NOT restart"
  end

  test "publish compiles in the release toolchain by default and says so" do
    [publish] = Enum.filter(CodePush.list(), &(&1["name"] == "publish_code_generation"))

    assert publish["description"] =~ "beams-export"
    assert publish["description"] =~ "RELEASE TOOLCHAIN"
    assert publish["inputSchema"]["properties"]["compile"]["enum"] == ["docker", "host"]
  end

  test "purge's description names it as destructive and states it never kills a process" do
    [purge] = Enum.filter(CodePush.list(), &(&1["name"] == "purge_orphaned_modules"))

    # The one destructive tool in this category. An operator reading only the
    # description should learn both that hot loading cannot remove a module
    # (why the tool exists) and that a module in use is refused rather than
    # forced (why it is safe to run).
    assert purge["description"] =~ "never kills a process"
    assert purge["description"] =~ "wedged"
    assert purge["description"] =~ "deleted from source"
  end

  describe "render_node/2: a reconcile line is checkable at a glance" do
    test "changed modules lead; cold loads are named as expected, not folded into one count" do
      # The shape orca-agent-dell produced on the first real publish: one
      # module genuinely changed, 256 loaded only because that interactive
      # node had not demanded them yet. Printed as "257 module(s) loaded"
      # it read as an alarm next to five nodes reporting 1.
      dell = %{
        status: :reconciled,
        pushed: 257,
        changed: 1,
        cold: 256,
        loaded_by_state: %{drifted: 1, absent: 0, stale_on_disk: 0, not_loaded: 256, unknown: 0},
        wedged: [],
        orphaned: []
      }

      warm = %{
        dell
        | pushed: 1,
          cold: 0,
          loaded_by_state: %{dell.loaded_by_state | not_loaded: 0}
      }

      dell_line = CodePush.render_node(dell, "orca-dell")
      warm_line = CodePush.render_node(warm, "orca-hub")

      assert dell_line =~ "reconciled — 1 changed module(s) loaded (1 drifted)"
      assert dell_line =~ "+256 cold module(s) loaded to make the generation authoritative"
      assert dell_line =~ "[257 total]"

      assert warm_line =~ "reconciled — 1 changed module(s) loaded (1 drifted)"
      refute warm_line =~ "cold"
    end

    test "a stale-on-disk load is a CHANGE, named as such" do
      line =
        CodePush.render_node(%{
          status: :reconciled,
          pushed: 3,
          changed: 3,
          cold: 0,
          loaded_by_state: %{drifted: 1, absent: 1, stale_on_disk: 1, not_loaded: 0, unknown: 0},
          wedged: [],
          orphaned: []
        })

      assert line =~ "3 changed module(s) loaded (1 drifted, 1 absent, 1 stale on disk)"
    end

    test "a result recorded before the changed/cold split still renders" do
      assert CodePush.render_node(%{status: :reconciled, pushed: 4, wedged: [], orphaned: []}) =~
               "reconciled — 4 module(s) loaded"
    end
  end

  test "publish_code_generation requires a directory" do
    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             CodePush.call("publish_code_generation", %{}, %{})

    assert text =~ "directory is required"
  end
end
