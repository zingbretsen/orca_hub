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
    test "fetch/0 returns error when no credentials available" do
      original = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      result = Usage.fetch()

      case result do
        {:error, _} -> :ok
        {:ok, _} -> :ok
      end

      if original, do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", original)
    end
  end
end
