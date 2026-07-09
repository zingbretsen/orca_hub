defmodule OrcaHub.MCP.ToolsTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools
  alias OrcaHub.{DiscordChannels, Projects, Sessions}

  # async: false — the Discord-visibility tests flip the process-wide
  # :orca_hub, :discord_bot app-env flag read by OrcaHub.Discord.enabled?/0.

  describe "list/1 tool visibility (role carried on connection state)" do
    test "orchestrator connections see every tool" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])

      assert "start_session" in names
      assert "search_sessions" in names
      assert "send_message_to_session" in names
      assert "open_file" in names
    end

    test "regular connections see only the regular tool set" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "open_file" in names
      refute "start_session" in names
      refute "search_sessions" in names
    end

    test "an absent role defaults to a regular connection" do
      names = Tools.list(%{orca_session_id: "abc"}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      refute "start_session" in names
    end

    test "regular connections never see send_discord_message when the node has no linked session" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])
      refute "send_discord_message" in names
    end

    test "orchestrator connections always see send_discord_message (full tool set)" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])
      assert "send_discord_message" in names
    end
  end

  describe "list/1 send_discord_message visibility for regular connections" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "mcp_tools_discord_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, project} =
        Projects.create_project(%{name: "mcp-tools-discord", directory: dir, node: "n1@x"})

      {:ok, session} =
        Sessions.create_session(%{directory: dir, project_id: project.id})

      {:ok, project: project, session: session}
    end

    test "hidden when the session has no Discord channel mapping, even if Discord is enabled", %{
      session: session
    } do
      Application.put_env(:orca_hub, :discord_bot, true)
      Application.put_env(:nostrum, :token, "fake-test-token")

      on_exit(fn ->
        Application.put_env(:orca_hub, :discord_bot, false)
        Application.delete_env(:nostrum, :token)
      end)

      names =
        Tools.list(%{orchestrator: false, orca_session_id: session.id}) |> Enum.map(& &1["name"])

      refute "send_discord_message" in names
    end

    test "hidden when a mapping exists but Discord.enabled?() is false (the test default)", %{
      project: project,
      session: session
    } do
      refute OrcaHub.Discord.enabled?()

      {:ok, channel} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "9001",
          project_id: project.id
        })

      {:ok, _channel} = DiscordChannels.set_session(channel, session.id)

      names =
        Tools.list(%{orchestrator: false, orca_session_id: session.id}) |> Enum.map(& &1["name"])

      refute "send_discord_message" in names
    end

    test "visible only when Discord is enabled AND the session is bridged", %{
      project: project,
      session: session
    } do
      Application.put_env(:orca_hub, :discord_bot, true)
      Application.put_env(:nostrum, :token, "fake-test-token")

      on_exit(fn ->
        Application.put_env(:orca_hub, :discord_bot, false)
        Application.delete_env(:nostrum, :token)
      end)

      {:ok, channel} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "9002",
          project_id: project.id
        })

      {:ok, _channel} = DiscordChannels.set_session(channel, session.id)

      names =
        Tools.list(%{orchestrator: false, orca_session_id: session.id}) |> Enum.map(& &1["name"])

      assert "send_discord_message" in names
    end
  end

  describe "call/3 dispatch (no role gate)" do
    test "unknown tool names return an error result" do
      result = Tools.call("not_a_real_tool", %{}, %{orchestrator: false})
      assert %{"isError" => true} = result

      [%{"text" => text}] = result["content"]
      assert text =~ "Unknown tool"
    end

    test "known orchestrator tools are dispatched even for a regular connection" do
      # No role gate on call/3: the tool enters its own body (which may fail on
      # missing args/linkage) — but is never rejected as permission-denied.
      result =
        try do
          Tools.call("start_session", %{}, %{orchestrator: false, orca_session_id: nil})
        rescue
          _ -> :entered_tool_body
        end

      case result do
        %{"isError" => true, "content" => [%{"text" => text}]} ->
          refute text =~ "only available to orchestrator sessions"

        _ ->
          :ok
      end
    end
  end
end
