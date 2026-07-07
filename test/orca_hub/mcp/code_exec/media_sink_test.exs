defmodule OrcaHub.MCP.CodeExec.MediaSinkTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.MediaSink

  defp unique_session, do: "media-sink-#{System.unique_integer([:positive])}"

  defp put_session(session_id) do
    CodeExec.put_state(%{orca_session_id: session_id})

    on_exit(fn ->
      File.rm_rf!(Path.join([System.tmp_dir!(), "orca_hub", "tool_media", session_id]))
    end)
  end

  defp path_from_note(note) do
    [path] = Regex.run(~r{saved to (\S+) —}, note, capture: :all_but_first)
    path
  end

  describe "render/2" do
    test "text blocks pass through unchanged, with no notes" do
      content = [%{"type" => "text", "text" => "hello"}, %{"type" => "text", "text" => "world"}]
      assert {["hello", "world"], false} = MediaSink.render(content, "some_tool")
    end

    test "a nil text field renders as an empty string instead of raising" do
      content = [%{"type" => "text", "text" => nil}]
      assert {[""], false} = MediaSink.render(content, "some_tool")
    end

    test "image block is base64-decoded and written under the session's tmp dir" do
      session_id = unique_session()
      put_session(session_id)
      bytes = "fake png bytes"

      content = [%{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "take_screenshot")

      path = path_from_note(note)

      assert Path.dirname(path) ==
               Path.join([System.tmp_dir!(), "orca_hub", "tool_media", session_id])

      assert Path.basename(path) =~ ~r/^take_screenshot-\d+-1\.png$/
      assert File.read!(path) == bytes
    end

    test "falls back to a shared session dir when orca_session_id is nil" do
      CodeExec.put_state(%{orca_session_id: nil})
      bytes = "audio bytes"

      on_exit(fn ->
        File.rm_rf!(Path.join([System.tmp_dir!(), "orca_hub", "tool_media", "shared"]))
      end)

      content = [%{"type" => "audio", "data" => Base.encode64(bytes), "mimeType" => "audio/wav"}]
      assert {[note], true} = MediaSink.render(content, "record")

      path = path_from_note(note)
      assert path =~ "/tool_media/shared/"
      assert File.read!(path) == bytes
    end

    test "a path-traversal-shaped session id is sanitized before use as a path segment" do
      root = Path.join([System.tmp_dir!(), "orca_hub", "tool_media"])
      malicious_id = "../../../../tmp/evil"
      CodeExec.put_state(%{orca_session_id: malicious_id})

      bytes = "danger bytes"
      content = [%{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "escape_attempt")

      path = path_from_note(note)
      session_dir = Path.dirname(path)

      on_exit(fn -> File.rm_rf!(session_dir) end)

      # The "/" separators in the malicious id were sanitized away, so the
      # whole id collapses into a single literal path component — the file
      # lands in a direct child of tool_media/, never escaping it.
      assert Path.dirname(session_dir) == root
      refute String.contains?(Path.basename(session_dir), "/")
      assert File.read!(path) == bytes
    end

    test "a session id of exactly \"..\" falls back to the shared dir instead of climbing out" do
      root = Path.join([System.tmp_dir!(), "orca_hub", "tool_media"])
      CodeExec.put_state(%{orca_session_id: ".."})

      on_exit(fn -> File.rm_rf!(Path.join(root, "shared")) end)

      bytes = "danger bytes"
      content = [%{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "escape_attempt")

      path = path_from_note(note)

      # sanitize_for_filename/1 keeps dots (they're legal filename chars), so
      # ".." sanitizes to itself — unlike the slash-laden case above, that's a
      # single path COMPONENT the filesystem treats specially (climbs up one
      # level). session_dir/0 has to catch this exact value explicitly.
      assert Path.dirname(path) == Path.join(root, "shared")
      assert File.read!(path) == bytes
    end

    test "resource block with text is passed through like a text block" do
      content = [
        %{
          "type" => "resource",
          "resource" => %{"text" => "resource contents", "uri" => "file:///x"}
        }
      ]

      assert {["resource contents"], false} = MediaSink.render(content, "some_tool")
    end

    test "resource block with a blob is written to disk like image/audio" do
      session_id = unique_session()
      put_session(session_id)
      bytes = "pdf bytes"

      content = [
        %{
          "type" => "resource",
          "resource" => %{
            "blob" => Base.encode64(bytes),
            "mimeType" => "application/pdf",
            "uri" => "file:///x.pdf"
          }
        }
      ]

      assert {[note], true} = MediaSink.render(content, "export_pdf")
      path = path_from_note(note)
      assert File.read!(path) == bytes
      assert Path.extname(path) == ".pdf"
    end

    test "resource block with neither text nor blob is dropped visibly" do
      content = [%{"type" => "resource", "resource" => %{"uri" => "file:///x"}}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert note =~ "[dropped unsupported content block: resource (no text/blob)]"
    end

    test "resource_link renders a visible line with title and uri" do
      content = [%{"type" => "resource_link", "uri" => "file:///a/b.txt", "title" => "b.txt"}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert note == "[resource_link] b.txt — file:///a/b.txt"
    end

    test "an unsupported content type is dropped visibly, not silently" do
      content = [%{"type" => "annotation", "foo" => "bar"}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert note == "[dropped unsupported content block: annotation]"
    end

    test "invalid base64 does not raise and is surfaced visibly" do
      content = [%{"type" => "image", "data" => "not-valid-base64!!", "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert note == "[failed to decode image block]"
    end

    test "a missing data field does not raise and is surfaced visibly" do
      content = [%{"type" => "image", "mimeType" => "image/png"}]
      assert {[note], true} = MediaSink.render(content, "some_tool")
      assert note == "[failed to decode image block]"
    end

    test "an unknown mimeType falls back to a .bin extension" do
      session_id = unique_session()
      put_session(session_id)

      content = [
        %{
          "type" => "image",
          "data" => Base.encode64("x"),
          "mimeType" => "application/x-totally-made-up"
        }
      ]

      assert {[note], true} = MediaSink.render(content, "weird")
      path = path_from_note(note)
      assert Path.extname(path) == ".bin"
    end

    test "more than the max media blocks per call are capped, with a visible skip note" do
      session_id = unique_session()
      put_session(session_id)

      content =
        for _ <- 1..9,
            do: %{"type" => "image", "data" => Base.encode64("x"), "mimeType" => "image/png"}

      assert {notes, true} = MediaSink.render(content, "many")

      saved = Enum.count(notes, &String.contains?(&1, "saved to"))
      skipped = Enum.count(notes, &String.contains?(&1, "over media cap"))

      assert saved == 8
      assert skipped == 1
    end
  end
end
