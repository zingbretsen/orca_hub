defmodule OrcaHub.SessionRunnerFallbackTitleTest do
  @moduledoc """
  `SessionRunner.fallback_title/1` — the dumb truncation fallback that
  replaced LLM-based title generation. Only exercised when a turn ends and
  no one (orchestrator at spawn, agent via report_progress) has already set
  a title; see `OrcaHub.MCP.Tools.Sessions` for the agent-managed paths.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.SessionRunner

  test "uses the first non-empty line of the prompt" do
    assert SessionRunner.fallback_title("Fix the login bug\n\nSteps:\n1. ...") ==
             "Fix the login bug"
  end

  test "skips leading blank lines" do
    assert SessionRunner.fallback_title("\n\n  \nActually start here") == "Actually start here"
  end

  test "collapses internal whitespace" do
    assert SessionRunner.fallback_title("Fix   the    login\tbug   please") ==
             "Fix the login bug please"
  end

  test "truncates long lines to ~60 chars with an ellipsis" do
    long_line = String.duplicate("a", 100)
    title = SessionRunner.fallback_title(long_line)

    assert String.length(title) == 60
    assert String.ends_with?(title, "…")
    assert title == String.duplicate("a", 59) <> "…"
  end

  test "leaves short titles untouched (no ellipsis)" do
    assert SessionRunner.fallback_title("short prompt") == "short prompt"
  end

  test "empty prompt yields an empty title" do
    assert SessionRunner.fallback_title("") == ""
  end
end
