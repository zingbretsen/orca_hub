defmodule OrcaHubWeb.SessionLive.ErrorDetailTest do
  @moduledoc """
  ORCAHUB3-83 — an errored session has to TELL the user why, in the page.

  Before this, `sessions.error_detail` was rendered in exactly one place: the
  `title=` attribute of the status badge on the show page. A hover tooltip is
  not an affordance — nothing on the page said a reason even existed, and the
  text could not be selected or copied.

  The other half of the same defect is covered here too: the detail is
  arbitrary CLI/stderr output, so it must render as ESCAPED PLAIN TEXT. This
  repo has a known unresolved earmark XSS item (see CLAUDE.md), so anything
  that pushed this through `OrcaHubWeb.Markdown.render/2` / `raw/1` would be a
  script-injection vector fed straight from agent output.
  """

  # async: false for the same reason as session_live/show_test.exs — visiting
  # the page can start a real SessionRunner under the shared supervisor.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{SessionSupervisor, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "err_detail_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  # `runner_node: nil` keeps the page from auto-starting a live runner, so
  # @status is resolved from the persisted column — which is exactly the
  # dead-runner path a user hits when they open an errored session later.
  defp create_session(dir, attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: dir, backend: "claude", runner_node: nil}, attrs)
      )

    on_exit(fn ->
      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)
    end)

    session
  end

  describe "the session show page" do
    test "renders the error detail in the page, not just as a tooltip", %{conn: conn, dir: dir} do
      session =
        create_session(dir, %{
          status: "error",
          error_detail: "Error: model not found: sonnet-5\n  at Config.resolve"
        })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "session-error-detail"
      assert html =~ "This session ended in error"
      assert html =~ "Error: model not found: sonnet-5"
      assert html =~ "at Config.resolve"
    end

    test "an errored session with NO detail still says so rather than showing nothing", %{
      conn: conn,
      dir: dir
    } do
      session = create_session(dir, %{status: "error", error_detail: nil})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      assert html =~ "session-error-detail"
      assert html =~ "No detail was recorded"
    end

    test "a healthy session shows no error chrome at all", %{conn: conn, dir: dir} do
      session = create_session(dir, %{status: "idle", error_detail: "stale detail from last run"})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ "session-error-detail"
      refute html =~ "This session ended in error"
      refute html =~ "stale detail from last run"
    end

    test "the detail is escaped, never rendered as HTML", %{conn: conn, dir: dir} do
      session =
        create_session(dir, %{
          status: "error",
          error_detail: "<script>alert(1)</script> <img src=x onerror=\"alert(2)\">"
        })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<img src=x onerror="
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  describe "the sessions index" do
    test "an errored row hints that a reason exists", %{conn: conn, dir: dir} do
      _session =
        create_session(dir, %{
          status: "error",
          title: "Trigger: Keene Activities",
          error_detail: "Error: model not found: sonnet-5\nstack frame nobody needs in a row"
        })

      {:ok, _view, html} = live(conn, ~p"/sessions?filter=all")

      # The tooltip carries the first line verbatim...
      assert html =~ ~s(title="Error: model not found: sonnet-5")
      # ...and only the first line — the rest stays on the show page.
      refute html =~ "stack frame nobody needs in a row"

      # ...and the badge itself carries a visible marker, so the tooltip is
      # discoverable rather than something you have to already know about.
      # (Scoped to OUR row: these tests share the dev DB with other errored
      # sessions, so a bare `html =~ "hero-information-circle-micro"` would
      # pass even with the icon removed.)
      assert [row] =
               Regex.run(~r{<span[^>]*title="Error: model not found: sonnet-5".*?</span>}s, html)

      assert row =~ "hero-information-circle-micro"
      assert row =~ "cursor-help"
    end

    test "a healthy row gains nothing", %{conn: conn, dir: dir} do
      _session =
        create_session(dir, %{
          status: "idle",
          title: "a fine session",
          error_detail: "stale detail from last run"
        })

      {:ok, _view, html} = live(conn, ~p"/sessions?filter=all")

      refute html =~ "stale detail from last run"
    end
  end

  describe "error_hint/1" do
    test "is nil unless the session is actually errored with a detail" do
      alias OrcaHubWeb.SessionLive.Index

      assert Index.error_hint(%{status: "idle", error_detail: "boom"}) == nil
      assert Index.error_hint(%{status: "error", error_detail: nil}) == nil
      assert Index.error_hint(%{status: "error", error_detail: "   \n  "}) == nil
      assert Index.error_hint(%{status: "error", error_detail: "boom\nmore"}) == "boom"
    end

    test "caps a single runaway line" do
      alias OrcaHubWeb.SessionLive.Index

      hint = Index.error_hint(%{status: "error", error_detail: String.duplicate("x", 500)})

      assert String.ends_with?(hint, "…")
      assert String.length(hint) == 161
    end
  end
end
