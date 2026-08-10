defmodule OrcaHub.Jobs.ProgressTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Jobs.Progress

  describe "sample/1 — no declared metric" do
    test "returns :unchanged when progress_kind is nil" do
      assert Progress.sample(%{progress_kind: nil}) == :unchanged
    end
  end

  describe "sample/1 — file_bytes" do
    setup do
      path = Path.join(System.tmp_dir!(), "progress-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "reports the current file size as progress_value", %{path: path} do
      File.write!(path, String.duplicate("x", 1234))

      assert {:ok, attrs} =
               Progress.sample(%{
                 progress_kind: "file_bytes",
                 progress_path: path,
                 progress_expect_bytes: nil
               })

      assert attrs.progress_value == 1234.0
      assert attrs.progress_total == nil
      assert %DateTime{} = attrs.progress_updated_at
    end

    test "uses progress_expect_bytes as the total when given", %{path: path} do
      File.write!(path, "hello")

      assert {:ok, attrs} =
               Progress.sample(%{
                 progress_kind: "file_bytes",
                 progress_path: path,
                 progress_expect_bytes: 46_000_000_000
               })

      assert attrs.progress_value == 5.0
      assert attrs.progress_total == 46_000_000_000.0
    end

    test "returns :unchanged (not an error) when the file doesn't exist yet" do
      assert Progress.sample(%{
               progress_kind: "file_bytes",
               progress_path: "/nonexistent/path/does-not-exist",
               progress_expect_bytes: nil
             }) == :unchanged
    end
  end

  describe "sample/1 — command, bare number" do
    test "parses a bare integer" do
      assert {:ok, attrs} =
               Progress.sample(%{progress_kind: "command", progress_command: "echo 42"})

      assert attrs.progress_value == 42.0
      assert attrs.progress_total == nil
    end

    test "parses a bare float" do
      assert {:ok, attrs} =
               Progress.sample(%{progress_kind: "command", progress_command: "echo 3.5"})

      assert attrs.progress_value == 3.5
    end
  end

  describe "sample/1 — command, ratio" do
    test "parses value/total" do
      assert {:ok, attrs} =
               Progress.sample(%{
                 progress_kind: "command",
                 progress_command: "echo '1234/5678'"
               })

      assert attrs.progress_value == 1234.0
      assert attrs.progress_total == 5678.0
    end
  end

  describe "sample/1 — command, JSON" do
    test "parses a JSON object with value/total/note" do
      cmd = ~s(echo '{"value": 12.5, "total": 100, "note": "part 2 of 8"}')

      assert {:ok, attrs} =
               Progress.sample(%{progress_kind: "command", progress_command: cmd})

      assert attrs.progress_value == 12.5
      assert attrs.progress_total == 100.0
      assert attrs.progress_note == "part 2 of 8"
    end
  end

  describe "sample/1 — command, unparseable free text" do
    test "falls back to storing the raw output as progress_note" do
      assert {:ok, attrs} =
               Progress.sample(%{
                 progress_kind: "command",
                 progress_command: "echo 'downloading part 3 of 8, no clean number here'"
               })

      assert attrs.progress_value == nil
      assert attrs.progress_note =~ "downloading part 3 of 8"
    end
  end

  describe "sample/1 — command, bounded execution" do
    test "a hanging command times out and returns :unchanged rather than blocking forever" do
      assert Progress.sample(%{progress_kind: "command", progress_command: "sleep 30"}) ==
               :unchanged
    end
  end
end
