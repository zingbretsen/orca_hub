defmodule OrcaHub.Claude.UsageTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Claude.Usage

  describe "struct" do
    test "has session and weekly fields" do
      usage = %Usage{
        session: %{utilization: 15.0, resets_at: "2025-11-04T04:59:59Z"},
        weekly: %{utilization: 8.0, resets_at: "2025-11-06T03:59:59Z"}
      }

      assert usage.session.utilization == 15.0
      assert usage.weekly.utilization == 8.0
      assert usage.session.resets_at == "2025-11-04T04:59:59Z"
      assert usage.weekly.resets_at == "2025-11-06T03:59:59Z"
    end

    test "allows nil windows" do
      usage = %Usage{session: nil, weekly: nil}
      assert usage.session == nil
      assert usage.weekly == nil
    end
  end

  describe "resolve_token" do
    # NOTE: The no-credentials error path cannot be tested deterministically on
    # a developer machine. When CLAUDE_CODE_OAUTH_TOKEN is absent,
    # resolve_token/0 falls back to token_from_file_or_keychain/0, which reads
    # from ~/.claude/.credentials.json (or macOS Keychain via `security`). Most
    # dev machines have this file present, so the test outcome is machine-state
    # dependent — tightening this to assert {:error, _} would create a flaky
    # test, which is strictly worse than the current vacuous assertion.
    #
    # Seam required for deterministic testing: `token_from_file_or_keychain/0`
    # would need to accept an injectable credentials path parameter (or
    # `read_credentials_file/0` would need to read a configurable Application
    # env key instead of using the hardcoded `@credentials_path` module
    # attribute), allowing tests to point to a temp file that's guaranteed to
    # be absent.
    #
    # Deterministic tests for error paths would require:
    # - An injectable credentials path (no hardcoding, no hardcoded
    #   ~/.claude/.credentials.json read)
    # - Or mocking System.cmd for `security` (no Mox/:meck in this suite)
    # - Or a lib/ refactor for injection (not done per hard rules)
  end
end
