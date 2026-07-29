defmodule OrcaHub.MCP.Tools.DiscordTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Discord, as: DiscordTool
  alias OrcaHub.{DiscordChannels, Projects, Sessions}

  # async: false — several tests flip the process-wide :orca_hub, :discord_bot
  # app-env flag that OrcaHub.Discord.enabled?/0 reads.

  defp fixture_project(name, dir) do
    {:ok, project} =
      Projects.create_project(%{name: name, directory: dir, node: Atom.to_string(node())})

    project
  end

  defp fixture_session(project) do
    {:ok, session} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    session
  end

  defp with_discord_enabled(fun) do
    Application.put_env(:orca_hub, :discord_bot, true)
    Application.put_env(:nostrum, :token, "fake-test-token")

    try do
      fun.()
    after
      Application.put_env(:orca_hub, :discord_bot, false)
      Application.delete_env(:nostrum, :token)
    end
  end

  describe "validate_present/2" do
    test "errors when both message and file_paths are empty" do
      assert {:error, msg} = DiscordTool.validate_present(nil, [])
      assert msg =~ "at least one is required"
    end

    test "ok when only message is present" do
      assert DiscordTool.validate_present("hi", []) == :ok
    end

    test "ok when only file_paths is present" do
      assert DiscordTool.validate_present(nil, ["a.txt"]) == :ok
    end

    test "ok when both are present" do
      assert DiscordTool.validate_present("hi", ["a.txt"]) == :ok
    end
  end

  describe "validate_reply_to_message_id/1" do
    test "nil (omitted) is valid and means no reply" do
      assert DiscordTool.validate_reply_to_message_id(nil) == {:ok, nil}
    end

    test "a numeric snowflake string is valid and parsed to an integer" do
      assert DiscordTool.validate_reply_to_message_id("123456789012345678") ==
               {:ok, 123_456_789_012_345_678}
    end

    test "rejects a non-numeric string" do
      assert {:error, msg} = DiscordTool.validate_reply_to_message_id("not-a-snowflake")
      assert msg =~ "numeric"
      assert msg =~ "reply_to_message_id"
    end

    test "rejects a string with any non-digit characters, even mixed with digits" do
      assert {:error, msg} = DiscordTool.validate_reply_to_message_id("123abc")
      assert msg =~ "numeric"
    end

    test "rejects a non-string type" do
      assert {:error, msg} = DiscordTool.validate_reply_to_message_id(123_456)
      assert msg =~ "numeric"
    end
  end

  describe "validate_file_paths/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "discord_tool_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "no files is trivially ok", %{dir: dir} do
      assert DiscordTool.validate_file_paths(dir, []) == {:ok, []}
    end

    test "resolves a relative path against the given directory", %{dir: dir} do
      path = Path.join(dir, "report.txt")
      File.write!(path, "hello")

      assert DiscordTool.validate_file_paths(dir, ["report.txt"]) == {:ok, [path]}
    end

    test "accepts an absolute path as-is", %{dir: dir} do
      abs = Path.join(dir, "abs.txt")
      File.write!(abs, "hello")

      assert DiscordTool.validate_file_paths(dir, [abs]) == {:ok, [abs]}
    end

    test "rejects a non-existent file with a clear per-file error", %{dir: dir} do
      assert {:error, msg} = DiscordTool.validate_file_paths(dir, ["missing.txt"])
      assert msg =~ "not found"
      assert msg =~ "missing.txt"
    end

    test "lists every missing file, not just the first", %{dir: dir} do
      File.write!(Path.join(dir, "exists.txt"), "hi")

      assert {:error, msg} =
               DiscordTool.validate_file_paths(dir, ["exists.txt", "gone1.txt", "gone2.txt"])

      assert msg =~ "gone1.txt"
      assert msg =~ "gone2.txt"
      refute msg =~ "exists.txt"
    end

    test "rejects more than 10 files", %{dir: dir} do
      paths =
        for n <- 1..11 do
          name = "f#{n}.txt"
          File.write!(Path.join(dir, name), "x")
          name
        end

      assert {:error, msg} = DiscordTool.validate_file_paths(dir, paths)
      assert msg =~ "Too many files"
      assert msg =~ "11"
    end

    test "rejects when total size exceeds the 8MB cap, naming the offending file", %{dir: dir} do
      big = Path.join(dir, "big.bin")
      File.write!(big, :binary.copy(<<0>>, 9 * 1024 * 1024))

      assert {:error, msg} = DiscordTool.validate_file_paths(dir, ["big.bin"])
      assert msg =~ "exceeds"
      assert msg =~ "big.bin"
    end
  end

  describe "call/3 — no OrcaHub session linked" do
    test "friendly error when orca_session_id is nil" do
      result =
        DiscordTool.call("send_discord_message", %{"message" => "hi"}, %{orca_session_id: nil})

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "No OrcaHub session linked"
    end
  end

  describe "call/3 — missing message and file_paths" do
    test "errors before even checking the session" do
      result = DiscordTool.call("send_discord_message", %{}, %{orca_session_id: nil})

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "at least one is required"
    end
  end

  describe "call/3 — invalid reply_to_message_id" do
    test "errors before even checking the session" do
      result =
        DiscordTool.call(
          "send_discord_message",
          %{"message" => "hi", "reply_to_message_id" => "not-a-snowflake"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "numeric"
    end
  end

  describe "call/3 — this node does not run the Discord worker" do
    test "friendly error when Discord.enabled?() is false (the default in tests)" do
      refute OrcaHub.Discord.enabled?()

      project = fixture_project("discord-tool-disabled", "/tmp/discord-tool-disabled")
      session = fixture_session(project)

      result =
        DiscordTool.call(
          "send_discord_message",
          %{"message" => "hi"},
          %{orca_session_id: session.id}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "does not run the Discord worker"
    end
  end

  describe "call/3 — session not bridged to a Discord channel" do
    test "friendly error when Discord is enabled but no mapping references the session" do
      project = fixture_project("discord-tool-unbridged", "/tmp/discord-tool-unbridged")
      session = fixture_session(project)

      with_discord_enabled(fn ->
        result =
          DiscordTool.call(
            "send_discord_message",
            %{"message" => "hi"},
            %{orca_session_id: session.id}
          )

        assert %{"isError" => true, "content" => [%{"text" => text}]} = result
        assert text =~ "not bridged to a Discord channel"
      end)
    end
  end

  describe "validate_message_id/1 (required snowflake, used by fetch_discord_attachments)" do
    test "nil (omitted) is an error — unlike reply_to_message_id, this arg is required" do
      assert {:error, msg} = DiscordTool.validate_message_id(nil)
      assert msg =~ "required"
    end

    test "a numeric snowflake string is valid and parsed to an integer" do
      assert DiscordTool.validate_message_id("123456789012345678") ==
               {:ok, 123_456_789_012_345_678}
    end

    test "rejects a non-numeric string" do
      assert {:error, msg} = DiscordTool.validate_message_id("not-a-snowflake")
      assert msg =~ "numeric"
      assert msg =~ "message_id"
    end

    test "rejects a non-string type" do
      assert {:error, msg} = DiscordTool.validate_message_id(123_456)
      assert msg =~ "numeric"
    end
  end

  describe "save_selected/5 (fetch_discord_attachments filenames/attachment_ids filter + size cap)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "discord_tool_save_selected_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      project = fixture_project("discord-tool-save-selected", dir)
      session = fixture_session(project)
      {:ok, session_id: session.id, message_id: 42, dir: dir}
    end

    test "no filenames/attachment_ids given: falls straight through to the size cap over every attachment",
         %{session_id: session_id, message_id: message_id} do
      attachments = [%{id: 1, filename: "a.txt", size: 10}]

      # No size violation and no real download target: hits the download
      # branch and (since these fixtures have no real :url) reports a clean
      # "failed to download" error rather than crashing — proving the
      # filenames-omitted path reached the save step at all.
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(attachments, [], [], message_id, session_id)

      assert text =~ "Failed to download"
    end

    test "requesting a filename not present on the message errors clearly, listing what IS available",
         %{session_id: session_id, message_id: message_id} do
      attachments = [
        %{id: 1, filename: "a.txt", size: 10},
        %{id: 2, filename: "b.txt", size: 10}
      ]

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(attachments, ["missing.txt"], [], message_id, session_id)

      assert text =~ "not found on that message"
      assert text =~ "missing.txt"
      assert text =~ "a.txt"
      assert text =~ "b.txt"
    end

    test "filenames filter selects only the matching attachment for the size-cap check", %{
      session_id: session_id,
      message_id: message_id
    } do
      small = %{id: 1, filename: "small.txt", size: 10}
      big = %{id: 2, filename: "big.bin", size: 30 * 1024 * 1024}

      # Requesting only the oversized file: the cap error must name it.
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected([small, big], ["big.bin"], [], message_id, session_id)

      assert text =~ "big.bin"
      assert text =~ "exceeding"

      # Requesting only the small file: the big one must be excluded from
      # consideration entirely, so the cap never trips (falls through to the
      # download attempt instead, which fails cleanly with no real :url).
      assert %{"isError" => true, "content" => [%{"text" => text2}]} =
               DiscordTool.save_selected([small, big], ["small.txt"], [], message_id, session_id)

      refute text2 =~ "exceeding"
      assert text2 =~ "Failed to download"
    end

    test "a filename shared by two attachments selects BOTH, not just the last one", %{
      session_id: session_id,
      message_id: message_id
    } do
      dup1 = %{id: 1, filename: "screenshot.png", size: 15 * 1024 * 1024}
      dup2 = %{id: 2, filename: "screenshot.png", size: 15 * 1024 * 1024}

      # Neither is individually oversized, but the two together exceed the
      # 25MB cap — this only trips if BOTH same-named attachments made it
      # into the selected set (the old Map.new-by-filename bug would have
      # kept only the last one and never crossed the cap).
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(
                 [dup1, dup2],
                 ["screenshot.png"],
                 [],
                 message_id,
                 session_id
               )

      assert text =~ "Total attachment size"
    end

    test "requesting the same filename twice does not download it twice", %{
      session_id: session_id,
      message_id: message_id
    } do
      only = %{id: 1, filename: "a.txt", size: 26 * 1024 * 1024}

      # If the dedupe were missing, "a.txt" would be selected twice and the
      # (doubled) total would trip the cap even though a single copy alone
      # would trip the PER-FILE cap instead — assert the per-file message,
      # proving only one copy was selected.
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected([only], ["a.txt", "a.txt"], [], message_id, session_id)

      assert text =~ "per-file limit"
    end

    test "attachment_ids selects the precise attachment among duplicate filenames", %{
      session_id: session_id,
      message_id: message_id
    } do
      small = %{id: 1, filename: "screenshot.png", size: 10}
      big = %{id: 2, filename: "screenshot.png", size: 30 * 1024 * 1024}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected([small, big], [], [2], message_id, session_id)

      assert text =~ "exceeding"

      assert %{"isError" => true, "content" => [%{"text" => text2}]} =
               DiscordTool.save_selected([small, big], [], [1], message_id, session_id)

      refute text2 =~ "exceeding"
      assert text2 =~ "Failed to download"
    end

    test "requesting an attachment_id not present on the message errors clearly", %{
      session_id: session_id,
      message_id: message_id
    } do
      attachments = [%{id: 1, filename: "a.txt", size: 10}]

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(attachments, [], [999], message_id, session_id)

      assert text =~ "not found on that message"
      assert text =~ "999"
    end

    test "providing both filenames and attachment_ids is a clear error, not a silent precedence",
         %{session_id: session_id, message_id: message_id} do
      attachments = [%{id: 1, filename: "a.txt", size: 10}]

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(attachments, ["a.txt"], [1], message_id, session_id)

      assert text =~ "at most one"
    end

    test "size-cap rejection names the offending file and does not silently truncate", %{
      session_id: session_id,
      message_id: message_id
    } do
      oversized = %{id: 1, filename: "huge.zip", size: 26 * 1024 * 1024}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected([oversized], [], [], message_id, session_id)

      assert text =~ "huge.zip"
      assert text =~ "exceeding"
      assert text =~ "per-file limit"
    end

    test "total size over the cap is rejected even when no single file is oversized", %{
      session_id: session_id,
      message_id: message_id
    } do
      attachments = [
        %{id: 1, filename: "a.bin", size: 15 * 1024 * 1024},
        %{id: 2, filename: "b.bin", size: 15 * 1024 * 1024}
      ]

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected(attachments, [], [], message_id, session_id)

      assert text =~ "Total attachment size"
      assert text =~ "exceeds"
    end

    test "an empty attachments list (message has none) errors clearly", %{
      session_id: session_id,
      message_id: message_id
    } do
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               DiscordTool.save_selected([], [], [], message_id, session_id)

      assert text =~ "no attachments"
    end

    test "idempotent re-fetch: an attachment already saved from an earlier fetch is reported as already present, not re-downloaded",
         %{session_id: session_id, message_id: message_id, dir: dir} do
      # Pre-seed the exact path a prior save would have produced, with
      # sentinel content — if `save_selected` attempted a real download it
      # would either overwrite this content or (since there's no real
      # :url here) fail and be omitted from the result entirely. Getting
      # a clean "already present" success back proves neither happened —
      # no live HTTP needed.
      target = Path.join([dir, "inbox", to_string(message_id), "report-7.pdf"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "already downloaded")

      attachment = %{id: 7, filename: "report.pdf", size: 10}

      result = DiscordTool.save_selected([attachment], [], [], message_id, session_id)
      assert %{"content" => [%{"text" => text}]} = result

      refute result["isError"]
      assert text =~ "already present"
      refute text =~ "downloaded"
      assert text =~ "inbox/#{message_id}/report-7.pdf"
      assert File.read!(target) == "already downloaded"
    end
  end

  describe "call/3 — invalid message_id on fetch_discord_attachments" do
    test "errors before even checking the session" do
      result =
        DiscordTool.call(
          "fetch_discord_attachments",
          %{"message_id" => "not-a-snowflake"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "numeric"
    end

    test "errors when message_id is omitted entirely" do
      result = DiscordTool.call("fetch_discord_attachments", %{}, %{orca_session_id: nil})

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "required"
    end
  end

  describe "call/3 — invalid before_message_id on list_discord_attachments" do
    test "errors before even checking the session" do
      result =
        DiscordTool.call(
          "list_discord_attachments",
          %{"before_message_id" => "not-a-snowflake"},
          %{orca_session_id: nil}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "numeric"
    end
  end

  describe "call/3 — bridged session with a missing file" do
    test "surfaces the file-not-found error before ever touching Nostrum" do
      dir =
        Path.join(System.tmp_dir!(), "discord_tool_call_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      project = fixture_project("discord-tool-bridged", dir)
      session = fixture_session(project)

      {:ok, channel} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "555",
          project_id: project.id
        })

      {:ok, _channel} = DiscordChannels.set_session(channel, session.id)

      with_discord_enabled(fn ->
        result =
          DiscordTool.call(
            "send_discord_message",
            %{"file_paths" => ["nope.txt"]},
            %{orca_session_id: session.id}
          )

        assert %{"isError" => true, "content" => [%{"text" => text}]} = result
        assert text =~ "not found"
        assert text =~ "nope.txt"
      end)
    end
  end
end
