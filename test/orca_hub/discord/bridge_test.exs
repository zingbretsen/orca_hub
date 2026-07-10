defmodule OrcaHub.Discord.BridgeTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Discord.Bridge

  describe "format_prompt/2" do
    test "empty history: just the id-tagged mention line" do
      msg = %{message_id: 111, text: "hello", author: %{global_name: "Zach"}}

      assert Bridge.format_prompt([], msg) == "[id: 111] [Zach mentioned you]: hello"
    end

    test "empty history with no author falls back to a neutral label" do
      msg = %{message_id: 111, text: "hello"}

      assert Bridge.format_prompt([], msg) == "[id: 111] [someone mentioned you]: hello"
    end

    test "with history: id-tagged transcript lines plus the id-tagged mention line" do
      history = [
        %{id: 1, author: %{username: "alice"}, content: "hi"},
        %{id: 2, author: %{global_name: "Bob"}, content: "yo"}
      ]

      msg = %{message_id: 3, text: "what up", author: %{global_name: "Zach"}}

      assert Bridge.format_prompt(history, msg) ==
               """
               [Channel messages since your last reply]
               [id: 1] alice: hi
               [id: 2] Bob: yo

               [id: 3] [Zach mentioned you]: what up
               """
               |> String.trim_trailing()
    end
  end

  describe "sanitize_filename/1" do
    test "keeps a plain safe filename intact" do
      assert Bridge.sanitize_filename("report.pdf") == "report.pdf"
      assert Bridge.sanitize_filename("my_file-2.tar.gz") == "my_file-2.tar.gz"
    end

    test "strips any directory component (no traversal)" do
      assert Bridge.sanitize_filename("../../etc/passwd") == "passwd"
      assert Bridge.sanitize_filename("/abs/path/x.txt") == "x.txt"
      assert Bridge.sanitize_filename("nested/dir/name.png") == "name.png"
    end

    test "collapses unsafe characters to a single dash" do
      assert Bridge.sanitize_filename("my file (1).PNG") == "my-file-1-.PNG"
      assert Bridge.sanitize_filename("a  b__c.txt") == "a-b__c.txt"
    end

    test "falls back to \"file\" when it sanitizes to empty" do
      assert Bridge.sanitize_filename("") == "file"
      assert Bridge.sanitize_filename("..") == "file"
      assert Bridge.sanitize_filename("...") == "file"
      assert Bridge.sanitize_filename("   ") == "file"
      assert Bridge.sanitize_filename("😀") == "file"
    end

    test "never returns an absolute path or a traversal token" do
      for name <- ["../../../root", "/etc/shadow", "..\\..\\win", "....//x"] do
        result = Bridge.sanitize_filename(name)
        refute String.starts_with?(result, "/")
        refute String.contains?(result, "/")
        refute result == ".."
      end
    end

    test "is defensive against non-binary input" do
      assert Bridge.sanitize_filename(nil) == "file"
      assert Bridge.sanitize_filename(123) == "file"
    end
  end
end
