defmodule OrcaHub.MCP.ToolsTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools
  alias OrcaHub.ToolPolicy
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

    test "regular connections can now spawn/peek-at/archive children, but not the full session-management surface" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "open_file" in names
      # Child spawning is first-class for every session now, not just
      # orchestrators — a regular connection can spawn a child, peek at its
      # progress, and clean it up when done.
      assert "start_session" in names
      assert "get_session_tail" in names
      assert "archive_session" in names
      # ...but not the full session-management surface: these stay
      # orchestrator-only.
      refute "search_sessions" in names
      refute "schedule_heartbeat" in names
      refute "cancel_heartbeat" in names
    end

    test "an absent role defaults to a regular connection" do
      names = Tools.list(%{orca_session_id: "abc"}) |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "start_session" in names
      refute "search_sessions" in names
    end

    test "regular connections never see any Discord tool when the node has no linked session" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])
      refute "send_discord_message" in names
      refute "list_discord_attachments" in names
      refute "fetch_discord_attachments" in names
    end

    test "orchestrator connections always see every Discord tool (full tool set)" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])
      assert "send_discord_message" in names
      assert "list_discord_attachments" in names
      assert "fetch_discord_attachments" in names
    end
  end

  describe "list/1 Discord tool visibility for regular connections" do
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
      refute "list_discord_attachments" in names
      refute "fetch_discord_attachments" in names
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
      refute "list_discord_attachments" in names
      refute "fetch_discord_attachments" in names
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
      assert "list_discord_attachments" in names
      assert "fetch_discord_attachments" in names
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

  describe "list/1 under a per-session tool policy" do
    defp policy_state(role, allow, deny) do
      %{orchestrator: role, tool_policy: ToolPolicy.new(allow, deny)}
    end

    test "an orchestrator connection's full set is narrowed by an allowlist" do
      names =
        policy_state(true, ["report_progress", "search_*"], nil)
        |> Tools.list()
        |> Enum.map(& &1["name"])

      assert "report_progress" in names
      assert "search_sessions" in names
      refute "start_session" in names
      refute "schedule_heartbeat" in names
    end

    test "a denylist removes tools from a regular connection's set" do
      names =
        policy_state(false, nil, ["start_session", "*_issue"])
        |> Tools.list()
        |> Enum.map(& &1["name"])

      assert "send_message_to_session" in names
      assert "report_progress" in names
      refute "start_session" in names
      refute "create_issue" in names
      refute "close_issue" in names
      # ...but the glob is anchored: list_issues is not *_issue
      assert "list_issues" in names
    end

    test "deny wins over allow" do
      names =
        policy_state(true, ["start_session", "report_progress"], ["start_session"])
        |> Tools.list()
        |> Enum.map(& &1["name"])

      assert names == ["report_progress"]
    end

    test "a deny-all policy leaves no first-party tools at all" do
      assert Tools.list(policy_state(true, nil, ["*"])) == []
      assert Tools.list(policy_state(false, nil, ["*"])) == []
    end

    test "a policy can only narrow, never widen: an orchestrator-only tool stays hidden from a regular connection that allowlists it" do
      names =
        policy_state(false, ["schedule_heartbeat", "report_progress"], nil)
        |> Tools.list()
        |> Enum.map(& &1["name"])

      assert names == ["report_progress"]
    end

    test "an empty allowlist/denylist is no restriction at all" do
      with_empty = Tools.list(policy_state(true, [], [])) |> Enum.map(& &1["name"])
      without = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])

      assert with_empty == without
      assert "start_session" in with_empty
    end

    test "a state carrying no policy is unrestricted (old connections, tests)" do
      assert Tools.list(%{orchestrator: true}) ==
               Tools.list(%{orchestrator: true, tool_policy: nil})
    end
  end

  describe "call/3 under a per-session tool policy" do
    test "a denied tool is refused before dispatch, naming the tool" do
      state = %{
        orchestrator: true,
        orca_session_id: nil,
        tool_policy: ToolPolicy.new(nil, ["start_session"])
      }

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               Tools.call("start_session", %{}, state)

      assert text =~ "start_session"
      assert text =~ "restricted for this session"
    end

    test "a tool outside the allowlist is refused" do
      state = %{orchestrator: true, tool_policy: ToolPolicy.new(["report_progress"], nil)}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               Tools.call("search_sessions", %{}, state)

      assert text =~ "restricted for this session"
    end

    test "an allowed tool still reaches its own body (not refused by policy)" do
      state = %{orchestrator: true, tool_policy: ToolPolicy.new(nil, ["start_session"])}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               Tools.call("not_a_real_tool", %{}, state)

      assert text =~ "Unknown tool"
      refute text =~ "restricted for this session"
    end

    test "an unknown tool name that a deny glob happens to match is reported as restricted, not unknown" do
      # Deny is checked first, deliberately: the policy is the operator's
      # statement about names, and it shouldn't leak which of them exist.
      state = %{orchestrator: true, tool_policy: ToolPolicy.new(nil, ["*"])}

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               Tools.call("not_a_real_tool", %{}, state)

      assert text =~ "restricted for this session"
    end
  end
end
