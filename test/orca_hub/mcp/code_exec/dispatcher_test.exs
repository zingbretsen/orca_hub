defmodule OrcaHub.MCP.CodeExec.DispatcherTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.{Dispatcher, MediaSink}

  setup do
    session_id = "dispatcher-media-#{System.unique_integer([:positive])}"
    CodeExec.put_state(%{orca_session_id: session_id})

    on_exit(fn ->
      File.rm_rf!(Path.join([System.tmp_dir!(), "orca_hub", "tool_media", session_id]))
    end)

    %{session_id: session_id}
  end

  describe "unwrap!/2 regression: pure-text/JSON results are unaffected" do
    test "JSON text still auto-decodes to a term" do
      body = Jason.encode!(%{"a" => 1})
      result = %{"content" => [%{"type" => "text", "text" => body}], "isError" => false}
      assert Dispatcher.unwrap!(result, "some_tool") == %{"a" => 1}
    end

    test "plain text still returns a plain string" do
      result = %{"content" => [%{"type" => "text", "text" => "hello"}], "isError" => false}
      assert Dispatcher.unwrap!(result, "some_tool") == "hello"
    end

    test "isError still raises Tools.Error carrying the text" do
      result = %{
        "content" => [%{"type" => "text", "text" => "repo not found"}],
        "isError" => true
      }

      assert_raise Tools.Error, "tool some_tool failed: repo not found", fn ->
        Dispatcher.unwrap!(result, "some_tool")
      end
    end
  end

  describe "unwrap!/2 with media content" do
    test "image block: text preserved, JSON-decode skipped, saved-file note appended", %{
      session_id: session_id
    } do
      png = "fake-png-bytes"

      result = %{
        "content" => [
          %{"type" => "text", "text" => "screenshot taken"},
          %{"type" => "image", "data" => Base.encode64(png), "mimeType" => "image/png"}
        ],
        "isError" => false
      }

      value = Dispatcher.unwrap!(result, "browser_take_screenshot")
      assert is_binary(value)
      assert value =~ "screenshot taken"
      assert value =~ "view it with the Read tool"

      [path] = Regex.run(~r{(/\S+\.png)}, value, capture: :all_but_first)
      assert File.read!(path) == png
      assert path =~ session_id
    end

    test "resource_link renders a visible line" do
      result = %{
        "content" => [
          %{"type" => "resource_link", "uri" => "file:///a/b.txt", "title" => "b.txt"}
        ],
        "isError" => false
      }

      assert Dispatcher.unwrap!(result, "some_tool") ==
               "[resource_link] b.txt — file:///a/b.txt"
    end

    test "unsupported content type is dropped visibly, not silently" do
      result = %{"content" => [%{"type" => "annotation", "foo" => "bar"}], "isError" => false}

      assert Dispatcher.unwrap!(result, "some_tool") ==
               "[dropped unsupported content block: annotation]"
    end

    test "invalid base64 does not raise and is surfaced visibly" do
      result = %{
        "content" => [
          %{"type" => "image", "data" => "not-valid-base64!!", "mimeType" => "image/png"}
        ],
        "isError" => false
      }

      assert Dispatcher.unwrap!(result, "some_tool") == "[failed to decode image block]"
    end
  end

  describe "isError envelopes with non-text content" do
    test "resource-only error text is not empty" do
      result = %{
        "content" => [%{"type" => "resource", "resource" => %{"text" => "boom details"}}],
        "isError" => true
      }

      assert_raise Tools.Error, "tool some_tool failed: boom details", fn ->
        Dispatcher.unwrap!(result, "some_tool")
      end
    end

    test "image-only error envelope still produces a non-empty message and writes the file", %{
      session_id: session_id
    } do
      png = "fake-png-bytes"

      result = %{
        "content" => [
          %{"type" => "image", "data" => Base.encode64(png), "mimeType" => "image/png"}
        ],
        "isError" => true
      }

      error =
        assert_raise Tools.Error, fn ->
          Dispatcher.unwrap!(result, "some_tool")
        end

      assert error.upstream =~ "view it with the Read tool"
      [path] = Regex.run(~r{(/\S+\.png)}, error.upstream, capture: :all_but_first)
      assert File.read!(path) == png
      assert path =~ session_id
    end
  end

  describe "extract_requested_filename/2" do
    test "strips filename from an upstream browser_take_screenshot call, tagged :media" do
      assert Dispatcher.extract_requested_filename(
               "playwright__browser_take_screenshot",
               %{"filename" => "shot.png", "raw" => true}
             ) == {%{"raw" => true}, {:media, "shot.png"}}
    end

    for suffix <- [
          "browser_snapshot",
          "browser_console_messages",
          "browser_network_requests",
          "browser_network_request",
          "browser_evaluate"
        ] do
      test "strips filename from an upstream #{suffix} call, tagged :text" do
        assert Dispatcher.extract_requested_filename(
                 "playwright__#{unquote(suffix)}",
                 %{"filename" => "out.txt", "raw" => true}
               ) == {%{"raw" => true}, {:text, "out.txt"}}
      end
    end

    test "the plural and singular network_request(s) suffixes are distinguished, not cross-matched" do
      assert {_args, {:text, "a.txt"}} =
               Dispatcher.extract_requested_filename(
                 "playwright__browser_network_requests",
                 %{"filename" => "a.txt"}
               )

      assert {_args, {:text, "b.txt"}} =
               Dispatcher.extract_requested_filename(
                 "playwright__browser_network_request",
                 %{"filename" => "b.txt"}
               )
    end

    test "leaves args untouched when there's no filename arg" do
      assert Dispatcher.extract_requested_filename(
               "playwright__browser_take_screenshot",
               %{"raw" => true}
             ) == {%{"raw" => true}, nil}
    end

    test "leaves args untouched for a tool that isn't a known filename-trap tool" do
      args = %{"filename" => "shot.png"}

      assert Dispatcher.extract_requested_filename("playwright__browser_navigate", args) ==
               {args, nil}
    end

    test "ignores a non-string filename value" do
      args = %{"filename" => 123}

      assert Dispatcher.extract_requested_filename(
               "playwright__browser_take_screenshot",
               args
             ) == {args, nil}

      assert Dispatcher.extract_requested_filename(
               "playwright__browser_evaluate",
               args
             ) == {args, nil}
    end
  end

  describe "unwrap!/2 with a pending text-mode request" do
    test "saves the full joined text output to disk and returns a single saved-to note", %{
      session_id: session_id
    } do
      MediaSink.put_requested_filename({:text, "snapshot.txt"})

      result = %{
        "content" => [
          %{"type" => "text", "text" => "line one"},
          %{"type" => "text", "text" => "line two"}
        ],
        "isError" => false
      }

      value = Dispatcher.unwrap!(result, "playwright__browser_snapshot")

      assert value =~ "view it with the Read tool"
      path = path_from_note(value)
      assert File.read!(path) == "line one\nline two"
      assert path =~ session_id
      assert Path.basename(path) == "snapshot.txt"
    end

    test "on isError, no file is written and the error text comes back inline as usual", %{
      session_id: session_id
    } do
      MediaSink.put_requested_filename({:text, "should-not-exist.txt"})

      result = %{
        "content" => [%{"type" => "text", "text" => "evaluate failed: boom"}],
        "isError" => true
      }

      assert_raise Tools.Error,
                   "tool playwright__browser_evaluate failed: evaluate failed: boom",
                   fn ->
                     Dispatcher.unwrap!(result, "playwright__browser_evaluate")
                   end

      refute File.exists?(
               Path.join([
                 System.tmp_dir!(),
                 "orca_hub",
                 "tool_media",
                 session_id,
                 "should-not-exist.txt"
               ])
             )
    end

    test "a pending text-mode request does not leak into a later call with no request" do
      MediaSink.put_requested_filename({:text, "first.txt"})

      result = %{"content" => [%{"type" => "text", "text" => "first output"}], "isError" => false}
      Dispatcher.unwrap!(result, "playwright__browser_snapshot")

      # No new put_requested_filename here — the stash must already be clear.
      result2 = %{"content" => [%{"type" => "text", "text" => "unrelated"}], "isError" => false}
      assert Dispatcher.unwrap!(result2, "some_other_tool") == "unrelated"
    end
  end

  describe "dispatch/3 clears any pending requested filename for non-upstream tools" do
    test "so a stale screenshot filename can't leak into an unrelated tool's saved media", %{
      session_id: session_id
    } do
      MediaSink.put_requested_filename({:media, "stale-name"})

      # "unknown_first_party_tool" isn't a real tool, but Tools.call/3 handles
      # that gracefully (an error envelope) — good enough to exercise the
      # non-upstream branch of dispatch/3 without any live upstream server.
      Dispatcher.dispatch("unknown_first_party_tool", %{}, %{orca_session_id: session_id})

      content = [%{"type" => "image", "data" => Base.encode64("x"), "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert Path.basename(path_from_note(note)) =~ ~r/^some_tool-\d+-1\.png$/
    end

    test "a stale TEXT-mode request also can't leak into an unrelated tool's result", %{
      session_id: session_id
    } do
      MediaSink.put_requested_filename({:text, "stale.txt"})

      Dispatcher.dispatch("unknown_first_party_tool", %{}, %{orca_session_id: session_id})

      result = %{"content" => [%{"type" => "text", "text" => "unrelated"}], "isError" => false}
      assert Dispatcher.unwrap!(result, "some_tool") == "unrelated"
    end
  end

  describe "unwrap!/2 screenshot (media-mode) behavior is unaffected by the text-mode addition" do
    test "still saves the image block and keeps text inline", %{session_id: session_id} do
      MediaSink.put_requested_filename({:media, "shot"})
      png = "fake-png-bytes"

      result = %{
        "content" => [
          %{"type" => "text", "text" => "screenshot taken"},
          %{"type" => "image", "data" => Base.encode64(png), "mimeType" => "image/png"}
        ],
        "isError" => false
      }

      value = Dispatcher.unwrap!(result, "playwright__browser_take_screenshot")
      assert value =~ "screenshot taken"
      assert value =~ "view it with the Read tool"

      path = path_from_note(value)
      assert Path.basename(path) == "shot.png"
      assert File.read!(path) == png
      assert path =~ session_id
    end
  end

  defp path_from_note(note) do
    [path] = Regex.run(~r{saved to (\S+) —}, note, capture: :all_but_first)
    path
  end
end
