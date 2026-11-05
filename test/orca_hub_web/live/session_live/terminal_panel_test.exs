defmodule OrcaHubWeb.SessionLive.TerminalPanelTest do
  @moduledoc """
  The session page's embedded terminal panel.

  Zach's report (2026-11-05): Ctrl+D in the embedded terminal exited the
  shell, then the page force-reloaded with an error toast. The Terminal JS
  hook pushes `terminal_exited` / `terminal_status_changed` to whichever
  LiveView hosts it, and only `TerminalLive.Show` handled them: on the
  session page the push raised FunctionClauseError and crashed the view.
  """
  # async: false — opening the panel starts a real TerminalRunner (and the
  # page a SessionRunner) under the shared supervisors.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.{SessionSupervisor, Sessions, TerminalSupervisor, Terminals}

  unless System.find_executable("script") && match?({:unix, :linux}, :os.type()) do
    @moduletag skip: "needs util-linux script(1) and /proc"
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "term_panel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "claude",
        code_exec: false,
        orchestrator: false,
        runner_node: Atom.to_string(node())
      })

    on_exit(fn ->
      for {_n, t} <- OrcaHub.Cluster.list_terminals(), t.directory == dir do
        TerminalSupervisor.stop_terminal(t.id)
      end

      if SessionSupervisor.session_alive?(session.id),
        do: SessionSupervisor.stop_session(session.id)

      File.rm_rf(dir)
    end)

    {:ok, session: session, dir: dir}
  end

  defp open_panel(conn, session) do
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")
    render_click(view, "open_terminal", %{})
    [terminal] = Enum.filter(Terminals.list_terminals(), &(&1.directory == session.directory))
    {view, terminal}
  end

  # bash's readline is up and has drawn its prompt (which may predate our
  # subscription, so read the runner's scrollback). Readline turns on
  # bracketed paste as it draws; "$ " covers a build without it.
  defp wait_for_prompt(terminal_id, attempts \\ 100) do
    scrollback = OrcaHub.TerminalRunner.get_scrollback(terminal_id)

    cond do
      scrollback =~ "\e[?2004h" or scrollback =~ "$ " ->
        :ok

      attempts > 0 ->
        Process.sleep(20)
        wait_for_prompt(terminal_id, attempts - 1)

      true ->
        flunk("bash never drew a prompt")
    end
  end

  test "terminal_exited from the hook does not crash the session page", %{
    conn: conn,
    session: session
  } do
    {view, terminal} = open_panel(conn, session)

    html = render_hook(view, "terminal_exited", %{"terminal_id" => terminal.id, "code" => 0})

    assert Process.alive?(view.pid)
    assert html =~ "terminal-exited-#{terminal.id}"
  end

  test "terminal_status_changed from the hook does not crash the session page", %{
    conn: conn,
    session: session
  } do
    {view, terminal} = open_panel(conn, session)

    render_hook(view, "terminal_status_changed", %{
      "terminal_id" => terminal.id,
      "status" => "stopped"
    })

    assert Process.alive?(view.pid)
  end

  test "Ctrl+D end to end: the exited tab offers Restart, and Restart brings the shell back", %{
    conn: conn,
    session: session
  } do
    {view, terminal} = open_panel(conn, session)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal.id}")
    wait_for_prompt(terminal.id)

    # What xterm sends for Ctrl+D.
    OrcaHub.TerminalRunner.write(terminal.id, <<4>>)
    assert_receive {:terminal_exit, 0}, 2_000

    html = render_hook(view, "terminal_exited", %{"terminal_id" => terminal.id, "code" => 0})
    assert html =~ "Shell exited"
    assert has_element?(view, "#terminal-exited-#{terminal.id} button", "Restart")

    view |> element("#terminal-exited-#{terminal.id} button", "Restart") |> render_click()

    assert TerminalSupervisor.terminal_alive?(terminal.id)
    refute has_element?(view, "#terminal-exited-#{terminal.id}")
  end

  test "a tab for an exited terminal can be closed", %{conn: conn, session: session} do
    {view, terminal} = open_panel(conn, session)
    render_hook(view, "terminal_exited", %{"terminal_id" => terminal.id, "code" => 0})

    render_click(view, "close_terminal_tab", %{"id" => terminal.id})

    refute has_element?(view, "#terminal-#{terminal.id}")
    refute has_element?(view, "#terminal-exited-#{terminal.id}")
  end
end
