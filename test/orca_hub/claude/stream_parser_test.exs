defmodule OrcaHub.Claude.StreamParserTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Claude.StreamParser

  test "parses complete JSON line" do
    {events, buffer} = StreamParser.parse("{\"type\":\"text\"}\n")
    assert events == [%{"type" => "text"}]
    assert buffer == ""
  end

  test "buffers partial line" do
    {events, buffer} = StreamParser.parse("{\"type\":\"te")
    assert events == []
    assert buffer == "{\"type\":\"te"
  end

  test "completes buffered line on next parse" do
    {[], buffer} = StreamParser.parse("{\"type\":\"te")
    {events, buffer2} = StreamParser.parse("xt\"}\n", buffer)
    assert events == [%{"type" => "text"}]
    assert buffer2 == ""
  end

  test "parses multiple lines at once" do
    data = "{\"a\":1}\n{\"b\":2}\n"
    {events, buffer} = StreamParser.parse(data)
    assert events == [%{"a" => 1}, %{"b" => 2}]
    assert buffer == ""
  end

  test "empty input returns empty" do
    {events, buffer} = StreamParser.parse("")
    assert events == []
    assert buffer == ""
  end

  test "skips unparseable lines" do
    data = "not json\n{\"a\":1}\n"
    {events, _buffer} = StreamParser.parse(data)
    assert events == [%{"a" => 1}]
  end
end
