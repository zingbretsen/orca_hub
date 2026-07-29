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

    test "history entries with no :attachments key at all render exactly as before" do
      history = [%{id: 1, author: %{username: "alice"}, content: "hi"}]
      msg = %{message_id: 2, text: "yo", author: %{global_name: "Zach"}}

      assert Bridge.format_prompt(history, msg) ==
               """
               [Channel messages since your last reply]
               [id: 1] alice: hi

               [id: 2] [Zach mentioned you]: yo
               """
               |> String.trim_trailing()
    end

    test "a history line with text and attachments annotates them after the content" do
      history = [
        %{
          id: 1,
          author: %{username: "alice"},
          content: "here you go",
          attachments: [%{filename: "report.pdf"}, %{filename: "chart.png"}]
        }
      ]

      msg = %{message_id: 2, text: "yo", author: %{global_name: "Zach"}}

      assert Bridge.format_prompt(history, msg) =~
               "[id: 1] alice: here you go [attachments: report.pdf, chart.png]"
    end

    test "a history line with blank content and attachments renders just the annotation" do
      history = [
        %{
          id: 1,
          author: %{username: "alice"},
          content: "",
          attachments: [%{filename: "report.pdf"}]
        }
      ]

      msg = %{message_id: 2, text: "yo", author: %{global_name: "Zach"}}

      assert Bridge.format_prompt(history, msg) =~
               "[id: 1] alice: [attachments: report.pdf]"
    end

    test "attachments on the triggering mention line are annotated too" do
      msg = %{
        message_id: 1,
        text: "check this out",
        author: %{global_name: "Zach"},
        attachments: [%{filename: "cat.jpg"}]
      }

      assert Bridge.format_prompt([], msg) ==
               "[id: 1] [Zach mentioned you]: check this out [attachments: cat.jpg]"
    end
  end

  describe "filter_history/3" do
    defp msg(id, author_id, content, attachments \\ nil) do
      base = %{id: id, author: %{id: author_id}, content: content}
      if attachments, do: Map.put(base, :attachments, attachments), else: base
    end

    test "drops a message with blank content and no attachments" do
      messages = [msg(1, 999, "")]

      assert Bridge.filter_history(messages, 100, nil) == []
    end

    test "keeps a message with blank content but a non-empty attachments list" do
      messages = [msg(1, 999, "", [%{filename: "report.pdf"}])]

      assert Bridge.filter_history(messages, 100, nil) == messages
    end

    test "a missing :attachments key at all is treated the same as [] — dropped when blank" do
      messages = [%{id: 1, author: %{id: 999}, content: ""}]

      assert Bridge.filter_history(messages, 100, nil) == []
    end

    test "still drops the current mention and anything at/below the watermark" do
      messages = [
        # the current mention itself
        msg(10, 111, "this is the mention"),
        # at/below the watermark
        msg(3, 222, "old message")
      ]

      assert Bridge.filter_history(messages, 10, 3) == []
    end

    test "keeps a normal text message above the watermark" do
      messages = [msg(50, 222, "hello there")]

      assert Bridge.filter_history(messages, 100, 3) == messages
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
