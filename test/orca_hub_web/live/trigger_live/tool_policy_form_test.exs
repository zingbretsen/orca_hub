defmodule OrcaHubWeb.TriggerLive.ToolPolicyFormTest do
  @moduledoc """
  The trigger form's four newer fields: `tool_allowlist`/`tool_denylist`
  (free text -> `{:array, :string}`), `setup_script` and
  `setup_timeout_seconds`.

  The load-bearing property, and the reason most of these tests exist: a
  BLANK list field must round-trip to "no restriction" (nil/[]), never to
  something that silently restricts a session — see `OrcaHub.ToolPolicy`,
  where `nil` and `[]` are both the neutral value and an explicit deny-all is
  spelled `["*"]`.
  """

  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{HubRPC, Projects, ToolPolicy, Triggers}

  setup do
    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "trigger_tool_policy_#{suffix}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "tool policy project #{suffix}", directory: dir})

    %{project: project, suffix: suffix}
  end

  # The default "daily" schedule mode builds the cron expression server-side
  # from these two selects — there is no cron_expression input in the DOM
  # unless the mode is "custom".
  defp base_params(project, suffix, overrides) do
    Map.merge(
      %{
        "project_id" => project.id,
        "name" => "tool policy trigger #{suffix}",
        "prompt" => "do the thing",
        "schedule_minute" => "0",
        "schedule_hour" => "9"
      },
      overrides
    )
  end

  # The tool-policy/setup-script fields live in a section that starts
  # collapsed for a NEW trigger — their inputs aren't in the DOM until it's
  # expanded, which is itself the behaviour the "fields omitted entirely"
  # test below relies on.
  defp open_advanced(view) do
    view |> element("#trigger-advanced-toggle") |> render_click()
    view
  end

  defp created_trigger(name) do
    Triggers.list_triggers() |> Enum.find(&(&1.name == name))
  end

  describe "creating a trigger" do
    test "a blank allow/deny field means NO restriction", %{project: project, suffix: suffix} do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      view
      |> open_advanced()
      |> form("form",
        trigger:
          base_params(project, suffix, %{"tool_allowlist" => "", "tool_denylist" => "   \n  "})
      )
      |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")

      assert trigger.tool_allowlist in [nil, []]
      assert trigger.tool_denylist in [nil, []]

      # The whole point: an untouched form must not produce a restriction.
      refute ToolPolicy.restricted?(ToolPolicy.from_session(trigger))
      assert ToolPolicy.allowed?(ToolPolicy.from_session(trigger), "send_message_to_session")
    end

    test "fields omitted entirely (advanced section collapsed) also mean no restriction", %{
      project: project,
      suffix: suffix
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      # The advanced section starts collapsed for a NEW trigger, so its
      # inputs are not in the DOM and never appear in the params at all.
      view |> form("form", trigger: base_params(project, suffix, %{})) |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")

      assert trigger.tool_allowlist in [nil, []]
      assert trigger.tool_denylist in [nil, []]
      assert trigger.setup_script in [nil, ""]
      refute ToolPolicy.restricted?(ToolPolicy.from_session(trigger))
    end

    test "a populated list round-trips intact, one entry per line", %{
      project: project,
      suffix: suffix
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      view
      |> open_advanced()
      |> form("form",
        trigger:
          base_params(project, suffix, %{
            "tool_allowlist" => "report_progress\ngithub__*\n\n  send_message_to_session  \n",
            "tool_denylist" => "retire_memory"
          })
      )
      |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")

      assert trigger.tool_allowlist == [
               "report_progress",
               "github__*",
               "send_message_to_session"
             ]

      assert trigger.tool_denylist == ["retire_memory"]

      policy = ToolPolicy.from_session(trigger)
      assert ToolPolicy.restricted?(policy)
      assert ToolPolicy.allowed?(policy, "github__get_issue")
      refute ToolPolicy.allowed?(policy, "start_session")
      refute ToolPolicy.allowed?(policy, "retire_memory")
    end

    test "comma-separated entries parse the same way", %{project: project, suffix: suffix} do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      view
      |> open_advanced()
      |> form("form",
        trigger:
          base_params(project, suffix, %{"tool_denylist" => "retire_memory, start_session"})
      )
      |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")
      assert trigger.tool_denylist == ["retire_memory", "start_session"]
    end

    test "an explicit deny-all is spelled *", %{project: project, suffix: suffix} do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      view
      |> open_advanced()
      |> form("form", trigger: base_params(project, suffix, %{"tool_denylist" => "*"}))
      |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")
      policy = ToolPolicy.from_session(trigger)

      assert trigger.tool_denylist == ["*"]
      refute ToolPolicy.allowed?(policy, "anything_at_all")
    end

    test "the setup script and its timeout round-trip", %{project: project, suffix: suffix} do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      view
      |> open_advanced()
      |> form("form",
        trigger:
          base_params(project, suffix, %{
            "setup_script" => "date -u\ngit log -1 --oneline",
            "setup_timeout_seconds" => "45"
          })
      )
      |> render_submit()

      trigger = created_trigger("tool policy trigger #{suffix}")

      assert trigger.setup_script == "date -u\ngit log -1 --oneline"
      assert trigger.setup_timeout_seconds == 45
    end
  end

  describe "setup_timeout_seconds validation" do
    test "the bound is surfaced on the input itself, not only on submit", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "bounded #{System.unique_integer([:positive])}",
          prompt: "x",
          cron_expression: "0 9 * * *",
          project_id: project.id,
          setup_script: "date -u"
        })

      # A trigger that already uses the section renders it expanded.
      {:ok, _view, html} = live(build_conn(), ~p"/triggers/#{trigger.id}/edit")

      assert html =~ ~s(name="trigger[setup_timeout_seconds]")
      assert html =~ ~s(min="1")
      assert html =~ ~s(max="3600")
      assert html =~ "1–3600"
    end

    test "an out-of-range value is rejected and its error is revealed", %{
      project: project,
      suffix: suffix
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      html =
        view
        |> open_advanced()
        |> form("form",
          trigger:
            base_params(project, suffix, %{
              "setup_script" => "date -u",
              "setup_timeout_seconds" => "99999"
            })
        )
        |> render_submit()

      assert html =~ "must be less than or equal to 3600"
      # Revealed rather than hidden inside the collapsed section.
      assert html =~ ~s(name="trigger[setup_timeout_seconds]")
      assert created_trigger("tool policy trigger #{suffix}") == nil
    end

    test "zero is rejected too", %{project: project, suffix: suffix} do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

      html =
        view
        |> open_advanced()
        |> form("form",
          trigger: base_params(project, suffix, %{"setup_timeout_seconds" => "0"})
        )
        |> render_submit()

      assert html =~ "must be greater than 0"
      assert created_trigger("tool policy trigger #{suffix}") == nil
    end
  end

  describe "editing an existing trigger" do
    setup %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "editable #{System.unique_integer([:positive])}",
          prompt: "x",
          cron_expression: "0 9 * * *",
          project_id: project.id,
          tool_allowlist: ["report_progress", "github__*"],
          tool_denylist: ["retire_memory"],
          setup_script: "date -u",
          setup_timeout_seconds: 30
        })

      %{trigger: trigger}
    end

    test "renders the current values back into the form", %{trigger: trigger} do
      {:ok, _view, html} = live(build_conn(), ~p"/triggers/#{trigger.id}/edit")

      assert html =~ "report_progress\ngithub__*"
      assert html =~ "retire_memory"
      assert html =~ "date -u"
      assert html =~ ~s(value="30")
    end

    test "clearing both list fields removes the restriction rather than tightening it", %{
      trigger: trigger,
      project: project
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/#{trigger.id}/edit")

      view
      |> form("form",
        trigger: %{
          "project_id" => project.id,
          "name" => trigger.name,
          "prompt" => trigger.prompt,
          "tool_allowlist" => "",
          "tool_denylist" => "",
          "setup_script" => "date -u",
          "setup_timeout_seconds" => "30"
        }
      )
      |> render_submit()

      reloaded = HubRPC.get_trigger!(trigger.id)

      assert reloaded.tool_allowlist in [nil, []]
      assert reloaded.tool_denylist in [nil, []]
      refute ToolPolicy.restricted?(ToolPolicy.from_session(reloaded))
    end

    test "clearing the setup script leaves the trigger with no script", %{
      trigger: trigger,
      project: project
    } do
      {:ok, view, _html} = live(build_conn(), ~p"/triggers/#{trigger.id}/edit")

      view
      |> form("form",
        trigger: %{
          "project_id" => project.id,
          "name" => trigger.name,
          "prompt" => trigger.prompt,
          "setup_script" => "",
          "setup_timeout_seconds" => "30"
        }
      )
      |> render_submit()

      reloaded = HubRPC.get_trigger!(trigger.id)
      refute OrcaHub.Triggers.SetupScript.configured?(reloaded)
    end
  end

  describe "form copy" do
    test "says plainly that blank means unrestricted and that only MCP tools are covered", %{
      project: project
    } do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "copy #{System.unique_integer([:positive])}",
          prompt: "x",
          cron_expression: "0 9 * * *",
          project_id: project.id,
          tool_denylist: ["retire_memory"]
        })

      {:ok, _view, html} = live(build_conn(), ~p"/triggers/#{trigger.id}/edit")

      assert html =~ "blank for no restriction"
      assert html =~ "restricts MCP tools only"
      assert html =~ "deny wins"
      assert html =~ "every firing"
    end
  end

  describe "trigger show page" do
    test "surfaces the tool policy and setup script when set", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "shown #{System.unique_integer([:positive])}",
          prompt: "x",
          cron_expression: "0 9 * * *",
          project_id: project.id,
          tool_allowlist: ["report_progress"],
          tool_denylist: ["retire_memory"],
          setup_script: "date -u",
          setup_timeout_seconds: 45
        })

      {:ok, _view, html} = live(build_conn(), ~p"/triggers/#{trigger.id}")

      assert html =~ "MCP tool restrictions"
      assert html =~ "report_progress"
      assert html =~ "retire_memory"
      assert html =~ "Setup script"
      assert html =~ "date -u"
      assert html =~ "Timeout 45s"
    end

    test "shows nothing for an unrestricted trigger with no script", %{project: project} do
      {:ok, trigger} =
        Triggers.create_trigger(%{
          name: "plain #{System.unique_integer([:positive])}",
          prompt: "x",
          cron_expression: "0 9 * * *",
          project_id: project.id
        })

      {:ok, _view, html} = live(build_conn(), ~p"/triggers/#{trigger.id}")

      refute html =~ "MCP tool restrictions"
      refute html =~ "Setup script"
    end
  end
end
