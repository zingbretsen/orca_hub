defmodule OrcaHub.Backend.JsonRpcFramingTest do
  @moduledoc """
  Coverage for the `:jsonrpc` decode layer (backend_abstraction_spec.md §6.1
  Step 2) — same `{data, buffer} -> {[map], new_buffer}` contract as
  `OrcaHub.Claude.StreamParser.parse/2`, but tolerant of non-JSON stdout
  noise (Codex's own ERROR/WARN log lines land interleaved on stdout because
  the port opens with `:stderr_to_stdout`).
  """

  # async: false — two tests below flip the GLOBAL Logger level to observe a
  # :debug-level log line (config/test.exs caps it at :warning); that must
  # not race other async tests' log expectations.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OrcaHub.Backend.JsonRpcFraming, as: Framing

  describe "parse/2" do
    test "decodes a single complete frame" do
      {events, buffer} = Framing.parse(~s({"id":0,"result":{"ok":true}}\n))

      assert events == [%{"id" => 0, "result" => %{"ok" => true}}]
      assert buffer == ""
    end

    test "decodes multiple frames in one chunk" do
      chunk = ~s({"method":"turn/started","params":{}}\n) <> ~s({"id":1,"result":{}}\n)
      {events, buffer} = Framing.parse(chunk)

      assert events == [
               %{"method" => "turn/started", "params" => %{}},
               %{"id" => 1, "result" => %{}}
             ]

      assert buffer == ""
    end

    test "buffers a partial (unterminated) line across calls" do
      {events1, buffer1} = Framing.parse(~s({"id":0,"resu))
      assert events1 == []
      assert buffer1 == ~s({"id":0,"resu)

      {events2, buffer2} = Framing.parse(~s(lt":{}}\n), buffer1)
      assert events2 == [%{"id" => 0, "result" => %{}}]
      assert buffer2 == ""
    end

    test "a partial frame split across three chunks reassembles correctly" do
      {e1, b1} = Framing.parse(~s({"method":"i))
      {e2, b2} = Framing.parse(~s(tem/started",), b1)
      {e3, b3} = Framing.parse(~s("params":{"x":1}}\n), b2)

      assert e1 == []
      assert e2 == []
      assert e3 == [%{"method" => "item/started", "params" => %{"x" => 1}}]
      assert b3 == ""
    end

    test "tolerates a non-JSON noise line (e.g. an ERROR log line) interleaved with frames" do
      chunk =
        ~s({"id":0,"result":{"ok":true}}\n) <>
          "ERROR codex_app_server: something went sideways\n" <>
          ~s({"method":"turn/completed","params":{"turn":{"status":"completed"}}}\n)

      # The "skipping non-JSON stdout noise" line logs at :debug (routine —
      # the app-server's own log lines land on stdout via :stderr_to_stdout,
      # so this fires often); config/test.exs caps the global Logger level at
      # :warning, so lower it for THIS process for the duration of the
      # capture (Logger.put_process_level/2 overrides the global floor).
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {events, buffer} = Framing.parse(chunk)

          assert events == [
                   %{"id" => 0, "result" => %{"ok" => true}},
                   %{
                     "method" => "turn/completed",
                     "params" => %{"turn" => %{"status" => "completed"}}
                   }
                 ]

          assert buffer == ""
        end)

      assert log =~ "skipping non-JSON stdout noise"
    end

    test "never crashes on garbage-only input — drops everything, logs, keeps going" do
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          assert Framing.parse("not json at all\nalso not json\n") == {[], ""}
        end)

      assert log =~ "skipping non-JSON stdout noise"
    end

    test "drops a non-object JSON line (e.g. a bare array or scalar) with a warning" do
      log =
        capture_log(fn ->
          assert Framing.parse(~s([1,2,3]\n"just a string"\n)) == {[], ""}
        end)

      assert log =~ "dropping non-object JSON-RPC line"
    end

    test "empty lines are skipped without producing events" do
      {events, buffer} = Framing.parse("\n\n" <> ~s({"id":5,"result":{}}\n) <> "\n")
      assert events == [%{"id" => 5, "result" => %{}}]
      assert buffer == ""
    end

    test "default buffer arg defaults to empty string" do
      assert Framing.parse(~s({"id":1,"result":{}}\n)) == {[%{"id" => 1, "result" => %{}}], ""}
    end
  end
end
