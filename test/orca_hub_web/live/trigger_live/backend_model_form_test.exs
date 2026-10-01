defmodule OrcaHubWeb.TriggerLive.BackendModelFormTest do
  @moduledoc """
  The trigger form's backend select + model input: a blank choice persists
  nil ("inherit the node default"), a pinned pair round-trips, and the model
  datalist follows the selected backend.
  """

  use OrcaHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.{Projects, Triggers}

  setup do
    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "trigger_backend_model_#{suffix}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: "backend model project #{suffix}", directory: dir})

    %{project: project, name: "backend model trigger #{suffix}"}
  end

  defp params(project, name, overrides) do
    Map.merge(
      %{
        "project_id" => project.id,
        "name" => name,
        "prompt" => "do the thing",
        "schedule_minute" => "0",
        "schedule_hour" => "9"
      },
      overrides
    )
  end

  defp created_trigger(name), do: Triggers.list_triggers() |> Enum.find(&(&1.name == name))

  test "blank backend/model persist as nil", %{project: project, name: name} do
    {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

    view
    |> form("form", trigger: params(project, name, %{"backend" => "", "model" => ""}))
    |> render_submit()

    trigger = created_trigger(name)
    assert trigger.backend == nil
    assert trigger.model == nil
  end

  test "a pinned backend/model round-trips and shows on the trigger page", %{
    project: project,
    name: name
  } do
    {:ok, view, _html} = live(build_conn(), ~p"/triggers/new")

    view
    |> form("form",
      trigger: params(project, name, %{"backend" => "claude", "model" => "claude-opus-5-5"})
    )
    |> render_submit()

    trigger = created_trigger(name)
    assert trigger.backend == "claude"
    assert trigger.model == "claude-opus-5-5"

    {:ok, _show, html} = live(build_conn(), ~p"/triggers/#{trigger.id}")
    assert html =~ "Backend / model"
    assert html =~ "claude / claude-opus-5-5"
  end

  test "the model datalist follows the selected backend", %{project: project, name: name} do
    {:ok, view, html} = live(build_conn(), ~p"/triggers/new")

    # Blank backend = claude suggestions.
    assert html =~ ~s(value="claude-opus-5-5")

    html =
      view
      |> form("form", trigger: params(project, name, %{"backend" => "codex"}))
      |> render_change()

    assert html =~ ~s(value="gpt-5.5")
    refute html =~ ~s(<option value="claude-opus-5-5")
  end
end
