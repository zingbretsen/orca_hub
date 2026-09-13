defmodule OrcaHubWeb.SessionLive.ToolPolicyTest do
  @moduledoc """
  The session show page's read-only MCP tool-restriction chrome.

  The property that matters most here is the NEGATIVE one: an unrestricted
  session — nil or `[]` on both lists, which is nearly every session — must
  show nothing new at all. See `OrcaHub.ToolPolicy` for why `[]` is the
  neutral value rather than "deny everything".
  """

  # async: false for the same reason as session_live/show_test.exs — visiting
  # the page starts a real SessionRunner under the shared supervisor.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{SessionSupervisor, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "tool_policy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  defp create_session(dir, attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{
            directory: dir,
            backend: "claude",
            code_exec: false,
            orchestrator: false,
            runner_node: Atom.to_string(node())
          },
          attrs
        )
      )

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    session
  end

  describe "an unrestricted session" do
    test "shows no tool-restriction chrome at all (nil lists)", %{conn: conn, dir: dir} do
      session = create_session(dir, %{})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ "tool-policy-toggle"
      refute html =~ "Tool restrictions"
      refute html =~ "MCP tool restrictions in effect"
    end

    test "shows no chrome for EMPTY lists either — [] is not a restriction", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir, %{tool_allowlist: [], tool_denylist: []})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ "tool-policy-toggle"
      refute html =~ "Tool restrictions"
    end
  end

  describe "a restricted session" do
    test "offers a header toggle whose panel is collapsed until clicked", %{conn: conn, dir: dir} do
      session = create_session(dir, %{tool_denylist: ["retire_memory"]})

      {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

      # Toggle present, panel not yet rendered.
      assert html =~ "tool-policy-toggle"
      refute html =~ "tool-policy-panel"

      opened = view |> element("#tool-policy-toggle") |> render_click()

      assert opened =~ "tool-policy-panel"
      assert opened =~ "retire_memory"
      assert opened =~ "MCP tool restrictions in effect"

      # ...and it toggles back closed.
      closed = view |> element("#tool-policy-toggle") |> render_click()
      refute closed =~ "tool-policy-panel"
    end

    test "shows both lists with deny-wins and MCP-only spelled out", %{conn: conn, dir: dir} do
      session =
        create_session(dir, %{
          tool_allowlist: ["report_progress", "github__*"],
          tool_denylist: ["retire_memory"]
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      html = view |> element("#tool-policy-toggle") |> render_click()

      assert html =~ "allow only"
      assert html =~ "report_progress, github__*"
      assert html =~ "deny"
      assert html =~ "retire_memory"
      assert html =~ "Deny wins over allow"
      assert html =~ "MCP tools only"
      assert html =~ "Bash, Read, Write, WebFetch"
    end

    test "an allow-only session shows just the allow row", %{conn: conn, dir: dir} do
      session = create_session(dir, %{tool_allowlist: ["report_progress"]})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      html = view |> element("#tool-policy-toggle") |> render_click()

      assert html =~ "allow only"
      assert html =~ "report_progress"
      refute html =~ ~s(badge-xs badge-error shrink-0)
    end

    test "is read-only — no form or editing control in the panel", %{conn: conn, dir: dir} do
      session = create_session(dir, %{tool_denylist: ["retire_memory"]})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
      html = view |> element("#tool-policy-toggle") |> render_click()

      panel =
        html
        |> Floki.parse_document!()
        |> Floki.find("#tool-policy-panel")

      assert panel != []
      assert Floki.find(panel, "input") == []
      assert Floki.find(panel, "textarea") == []
      assert Floki.find(panel, "form") == []
      assert Floki.find(panel, "button") == []
      assert Floki.find(panel, "[phx-click]") == []
    end
  end
end
