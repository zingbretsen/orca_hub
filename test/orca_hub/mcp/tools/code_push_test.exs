defmodule OrcaHub.MCP.Tools.CodePushTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.Tools
  alias OrcaHub.MCP.Tools.CodePush

  @tool_names ~w(publish_code_generation code_generation_status supersede_code_generation
                 reconcile_code)

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

  test "publish_code_generation requires a directory" do
    assert %{"isError" => true, "content" => [%{"text" => text}]} =
             CodePush.call("publish_code_generation", %{}, %{})

    assert text =~ "directory is required"
  end
end
