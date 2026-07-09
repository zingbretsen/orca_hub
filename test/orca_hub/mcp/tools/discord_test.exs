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
