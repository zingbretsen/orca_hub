defmodule OrcaHub.Claude.ConfigTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Claude.Config

  @base_args [
    "-p",
    "hello",
    "--output-format",
    "stream-json",
    "--verbose",
    "--dangerously-skip-permissions"
  ]

  test "basic args with just prompt" do
    {args, port_opts} = Config.build_args("hello")
    assert args == @base_args
    assert port_opts == []
  end

  test "session_id adds --resume" do
    {args, _} = Config.build_args("hello", session_id: "abc")
    assert "--resume" in args
    assert "abc" in args
  end

  test "allowed_tools joined with commas" do
    {args, _} = Config.build_args("hello", allowed_tools: ["Read", "Edit"])
    assert "--allowedTools" in args
    assert "Read,Edit" in args
  end

  test "max_turns adds --max-turns" do
    {args, _} = Config.build_args("hello", max_turns: 5)
    assert "--max-turns" in args
    assert "5" in args
  end

  test "max_budget adds --max-budget-usd" do
    {args, _} = Config.build_args("hello", max_budget: 1.0)
    assert "--max-budget-usd" in args
    assert "1.0" in args
  end

  test "system_prompt adds --append-system-prompt" do
    {args, _} = Config.build_args("hello", system_prompt: "be nice")
    assert "--append-system-prompt" in args
    assert "be nice" in args
  end

  test "model adds --model" do
    {args, _} = Config.build_args("hello", model: "sonnet")
    assert "--model" in args
    assert "sonnet" in args
  end

  test "cwd returns in port_opts not args" do
    {args, port_opts} = Config.build_args("hello", cwd: "/tmp")
    assert port_opts == [cd: ~c"/tmp"]
    refute "/tmp" in args
  end

  test "callback and send_to not in args" do
    {args, _} = Config.build_args("hello", callback: fn _ -> nil end, send_to: self())
    assert args == @base_args
  end

  test "verbose false omits --verbose" do
    {args, _} = Config.build_args("hello", verbose: false)
    refute "--verbose" in args
  end

  test "skip_permissions false omits --dangerously-skip-permissions" do
    {args, _} = Config.build_args("hello", skip_permissions: false)
    refute "--dangerously-skip-permissions" in args
  end
end
