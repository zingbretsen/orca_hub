defmodule OrcaHubWeb.SkillLive.IndexTest do
  @moduledoc """
  LiveView coverage for the global Skills page (`OrcaHub.Skills` CRUD, plus
  the `{:skills_updated}` PubSub-driven live refresh). Never touches disk —
  materializing a skill onto a node's `skills/` dir is `OrcaHub.SkillSync`'s
  job, and that GenServer's boot/broadcast loop is disabled entirely in
  `config/test.exs` (see its moduledoc), so nothing here reaches the real
  `~/.claude`, `~/.codex`, or `~/.pi/agent`.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Skills

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      result ->
        result
    end
  end

  describe "index" do
    test "lists skills with enabled/backend badges and a truncated description", %{conn: conn} do
      {:ok, _skill} =
        Skills.create_skill(%{
          name: "my-skill",
          description: "Use when doing X",
          backends: ["claude", "codex"]
        })

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ "my-skill"
      assert html =~ "Use when doing X"
      assert html =~ "enabled"
      assert html =~ "claude"
      assert html =~ "codex"
    end

    test "shows an empty state with no skills", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/skills")
      assert html =~ "No skills yet."
    end
  end

  describe "create" do
    test "creates a skill from the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{
            "name" => "new-skill",
            "description" => "A new skill",
            "body" => "Do the thing.",
            "backends" => ["claude"],
            "enabled" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Skill saved"
      assert html =~ "new-skill"
      assert Skills.get_skill_by_name("new-skill")
      assert Skills.get_skill_by_name("new-skill").backends == ["claude"]
    end

    test "shows validation errors for a bad name and does not create it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills/new")

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "Not Kebab Case", "backends" => ["claude"]}
        })
        |> render_submit()

      assert html =~ "kebab-case"
      refute Skills.get_skill_by_name("Not Kebab Case")
    end
  end

  describe "edit" do
    test "updates an existing skill", %{conn: conn} do
      {:ok, skill} = Skills.create_skill(%{name: "editable-skill", description: "old"})

      {:ok, view, html} = live(conn, ~p"/skills/#{skill.id}/edit")
      assert html =~ "Edit Skill"

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "editable-skill", "description" => "new description"}
        })
        |> render_submit()

      assert html =~ "Skill saved"
      assert html =~ "new description"
      assert Skills.get_skill(skill.id).description == "new description"
    end
  end

  describe "toggle enabled" do
    test "flips enabled without opening the form", %{conn: conn} do
      {:ok, skill} = Skills.create_skill(%{name: "toggle-skill"})
      {:ok, view, _html} = live(conn, ~p"/skills")

      html = render_click(view, "toggle", %{"id" => skill.id})

      assert html =~ "disabled"
      refute Skills.get_skill(skill.id).enabled

      html = render_click(view, "toggle", %{"id" => skill.id})
      assert html =~ "enabled"
      assert Skills.get_skill(skill.id).enabled
    end
  end

  describe "delete" do
    test "removes the skill", %{conn: conn} do
      {:ok, skill} = Skills.create_skill(%{name: "doomed-skill"})
      {:ok, view, _html} = live(conn, ~p"/skills")

      html = render_click(view, "delete", %{"id" => skill.id})

      assert html =~ "Skill deleted"
      refute html =~ "doomed-skill"
      assert Skills.get_skill(skill.id) == nil
    end
  end

  describe "live refresh on {:skills_updated}" do
    test "a concurrent create refreshes the index without a page reload", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/skills")
      refute html =~ "concurrent-skill"

      {:ok, _skill} = Skills.create_skill(%{name: "concurrent-skill"})

      html =
        wait_until(fn ->
          html = render(view)
          if html =~ "concurrent-skill", do: html, else: false
        end)

      assert html =~ "concurrent-skill"
    end
  end
end
