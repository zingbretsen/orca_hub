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
      assert Bridge.sanitize_filename(".") == "file"
      assert Bridge.sanitize_filename("..") == "file"
      assert Bridge.sanitize_filename("...") == "file"
      assert Bridge.sanitize_filename("   ") == "file"
      assert Bridge.sanitize_filename("😀") == "file"
    end

    test "preserves a single leading dot on dotfiles instead of mangling their real name" do
      assert Bridge.sanitize_filename(".env") == ".env"
      assert Bridge.sanitize_filename(".gitignore") == ".gitignore"
      assert Bridge.sanitize_filename(".hidden-file_2.txt") == ".hidden-file_2.txt"
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

  describe "save_attachments_to_inbox/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bridge_inbox_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "path shape is nested under inbox/<message_id>/ and suffixed by the attachment id", %{
      dir: dir
    } do
      # Pre-seeded so this never attempts a real download — see the
      # idempotency test below for why a returned {:existing, _} here
      # already proves that.
      target = Path.join([dir, "inbox", "111", "report-222.pdf"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "seed")

      attachment = %{id: 222, filename: "report.pdf"}

      assert Bridge.save_attachments_to_inbox(dir, 111, [attachment]) ==
               [{:existing, "inbox/111/report-222.pdf"}]
    end

    test "idempotent: an attachment already saved on disk is skipped, not re-downloaded or overwritten",
         %{dir: dir} do
      # No :url key at all — if this were handed to a real download attempt,
      # `attachment.url` raises KeyError (see save_one), which is caught and
      # OMITS the attachment from the result entirely. Getting {:existing, _}
      # back therefore proves the download was never attempted — no live
      # HTTP needed to prove idempotency.
      attachment = %{id: 222, filename: "report.pdf"}

      target = Path.join([dir, "inbox", "111", "report-222.pdf"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "already here")

      assert Bridge.save_attachments_to_inbox(dir, 111, [attachment]) ==
               [{:existing, "inbox/111/report-222.pdf"}]

      assert File.read!(target) == "already here"

      # Calling again (e.g. fetch_discord_attachments re-run on the same
      # message) is still a clean no-op with the identical path.
      assert Bridge.save_attachments_to_inbox(dir, 111, [attachment]) ==
               [{:existing, "inbox/111/report-222.pdf"}]

      assert File.read!(target) == "already here"
    end

    test "a failed download (bad/missing url — never live HTTP in tests) is logged and omitted, not raised",
         %{dir: dir} do
      attachment = %{id: 5, filename: "x.bin"}
      assert Bridge.save_attachments_to_inbox(dir, 999, [attachment]) == []
    end

    test "two different attachments with the same filename get distinct paths, never colliding",
         %{dir: dir} do
      # a's target pre-seeded (idempotent hit); b shares a's filename but has
      # a different attachment id and no :url (download attempt, omitted on
      # failure). If the two ever shared a path, saving b would either
      # collide with (and skip) a's file too, or overwrite it — assert a's
      # content survives untouched and b never appears as :existing.
      a_target = Path.join([dir, "inbox", "42", "x-1.bin"])
      File.mkdir_p!(Path.dirname(a_target))
      File.write!(a_target, "a's bytes")

      a = %{id: 1, filename: "x.bin"}
      b = %{id: 2, filename: "x.bin"}

      assert Bridge.save_attachments_to_inbox(dir, 42, [a, b]) ==
               [{:existing, "inbox/42/x-1.bin"}]

      assert File.read!(a_target) == "a's bytes"
      refute File.exists?(Path.join([dir, "inbox", "42", "x-2.bin"]))
    end

    test "extension edge cases produce the expected stem/id/ext shape", %{dir: dir} do
      cases = [
        {"Makefile", "Makefile-1"},
        {".env", ".env-1"},
        {"archive.tar.gz", "archive.tar-1.gz"},
        {"v1.2.3", "v1.2-1.3"},
        {"😀", "file-1"}
      ]

      for {filename, expected_name} <- cases do
        target = Path.join([dir, "inbox", "77", expected_name])
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, "seed")

        attachment = %{id: 1, filename: filename}

        assert Bridge.save_attachments_to_inbox(dir, 77, [attachment]) ==
                 [{:existing, "inbox/77/#{expected_name}"}],
               "expected #{inspect(filename)} to resolve to #{inspect(expected_name)}"
      end
    end
  end
end
