defmodule Mix.Tasks.Orca.ReindexIssuesTest do
  @moduledoc """
  Coverage for the CLI layer of `mix orca.reindex_issues` — flag parsing and
  the printed report.

  Deliberately does NOT call `run/1`: that invokes `Mix.Task.run("app.start")`,
  which compiles the project, and this worktree is shared with other agent
  sessions — a sibling mid-edit would fail this test for reasons that have
  nothing to do with it. The bulk logic itself is covered against a stubbed
  endpoint in `OrcaHub.Issues.BackfillTest`, and end-to-end against the live
  embedder by hand.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Orca.ReindexIssues

  describe "parse_args/1" do
    test "maps every documented flag" do
      assert ReindexIssues.parse_args([]) == []
      assert ReindexIssues.parse_args(["--force"]) == [force: true]
      assert ReindexIssues.parse_args(["--dry-run"]) == [dry_run: true]
      assert ReindexIssues.parse_args(["--concurrency", "2"]) == [concurrency: 2]
      assert ReindexIssues.parse_args(["--limit", "7"]) == [limit: 7]

      assert ReindexIssues.parse_args(["--force", "--concurrency", "3"]) ==
               [force: true, concurrency: 3]
    end

    test "an unknown flag fails immediately, before anything boots" do
      assert_raise Mix.Error, ~r/Unknown or malformed option/, fn ->
        ReindexIssues.parse_args(["--turbo"])
      end
    end

    test "a non-integer value for an integer flag is rejected" do
      assert_raise Mix.Error, ~r/Unknown or malformed option/, fn ->
        ReindexIssues.parse_args(["--concurrency", "lots"])
      end
    end
  end

  describe "report/2" do
    defp summary(overrides \\ %{}) do
      Map.merge(
        %{
          visited: 12,
          indexed: 11,
          embedded: 34,
          unchanged: 5,
          deleted: 2,
          failed: 1,
          errors: [{"abc-123", {:http_error, 400, %{}}}],
          aborted: nil,
          duration_ms: 987
        },
        overrides
      )
    end

    test "prints every counter and lists per-issue errors" do
      out = capture_io(fn -> ReindexIssues.report(summary(), []) end)

      assert out =~ "Issues visited:    12"
      assert out =~ "Issues indexed:    11"
      assert out =~ "Chunks embedded:   34"
      assert out =~ "Chunks unchanged:  5"
      assert out =~ "Chunks deleted:    2"
      assert out =~ "Failures:          1"
      assert out =~ "987ms"
      assert out =~ "abc-123"
      refute out =~ "ABORTED"
    end

    test "calls out an aborted run and that nothing indexed was lost" do
      out = capture_io(fn -> ReindexIssues.report(summary(%{aborted: :endpoint}), []) end)

      assert out =~ "ABORTED (endpoint)"
      assert out =~ "Nothing already indexed was lost"
    end

    test "a dry run reports only what it would have done" do
      out = capture_io(fn -> ReindexIssues.report(summary(%{visited: 40}), dry_run: true) end)

      assert out =~ "Would visit 40 issue(s)"
      assert out =~ "nothing was indexed"
      refute out =~ "Chunks embedded"
    end
  end

  test "the disabled-embedder message names the env var to set" do
    assert ReindexIssues.disabled_message() =~ "EMBEDDING_URL"
  end
end
