defmodule OrcaHubWeb.VoiceBarLiveTest do
  @moduledoc """
  The global voice bar (`voice_mode_spec.md` §8.2 / ORCAHUB3-88).

  Three things are worth pinning here and are all cheap to break:

    * the bar is rendered by the app LAYOUT, so it is on every page rather
      than one — a regression looks like "voice only works on /sessions/:id",
      which is the issue this replaced;
    * IDLE is exactly ONE control. The mic button plus nothing else is the
      whole §8.2 mobile budget: the strip, the target picker and the bar's
      own draft box may only appear once voice mode is on;
    * the target-session picker actually lists sessions and follows both the
      page and the user's choice.

  The armed half is driven by the `Voice` hook (`pushEvent("voice-on")`),
  which `render_hook/3` stands in for here. Everything the hook WRITES
  (status text, the log, errors) is inside `phx-update="ignore"` and belongs
  to the browser check, not to this file.
  """

  # async: false — shared dev DB (see CLAUDE.md), and the bar queries the
  # real session list.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Sessions

  defp new_session(attrs) do
    dir = Path.join(System.tmp_dir!(), "voice_bar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} =
      Sessions.create_session(
        Map.merge(
          %{directory: dir, status: "idle", runner_node: Atom.to_string(node())},
          attrs
        )
      )

    session
  end

  # The bar is a nested LiveView; `live_children/1` is how the parent reaches
  # it, and finding it there is itself the proof that the layout rendered it.
  defp voice_bar(view) do
    view
    |> live_children()
    |> Enum.find(fn child -> render(child) =~ ~s(id="voice-panel") end)
  end

  describe "placement" do
    for path <- ["/sessions", "/queue", "/projects"] do
      test "the bar renders in the header on #{path}", %{conn: conn} do
        {:ok, view, html} = live(conn, unquote(path))

        assert html =~ ~s(id="voice-bar")
        assert voice_bar(view), "expected a sticky VoiceBarLive child on #{unquote(path)}"
      end
    end

    test "it sits inside the app header and outside every link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects")
      doc = Floki.parse_document!(html)

      # The layout's own header, not a page's nested one.
      assert [_ | _] = Floki.find(doc, "div.h-dvh > header #voice-bar"),
             "the voice bar must be rendered inside the app header"

      # An interactive control inside an <a> navigates on click, which would
      # make the mic button unusable (A1's caveat on the live-nav header).
      assert Floki.find(doc, "a #voice-bar") == [],
             "the voice bar must not be nested inside a link"

      assert Floki.find(doc, "#voice-bar [data-voice-action='toggle']") != [],
             "the mic button must be rendered on every page"
    end

    test "the mic is not hidden behind the mobile burger menu", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects")

      [button] =
        html
        |> Floki.parse_document!()
        |> Floki.find("#voice-bar [data-voice-action='toggle']")

      classes = button |> Floki.attribute("class") |> List.first() || ""
      refute classes =~ "md:hidden", "the mic must be reachable on a phone"
      refute classes =~ "hidden ", "the mic must never render hidden"
    end
  end

  describe "the idle state" do
    test "is the mic button and nothing else", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      html = view |> voice_bar() |> render()

      assert html =~ ~s(data-voice-action="toggle")
      # §8.2's budget: no strip, no picker, no draft box, no help until voice
      # is on.
      refute html =~ "voice-bar-strip-row"
      refute html =~ "voice-strip"
      refute html =~ "data-voice-help-toggle"
      refute html =~ ~s(id="voice-help")
      refute html =~ "data-voice-bar-draft"
      refute html =~ ~s(name="session_id")
    end
  end

  describe "the armed state" do
    test "adds the strip, the picker and the DOM contract's selectors", %{conn: conn} do
      session = new_session(%{title: "a target session"})

      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)

      html = render_hook(bar, "voice-on", %{"on" => true})

      # Every §8.1 selector the hook drives has to survive the move.
      for selector <- ~w(
            data-voice-banner data-voice-error data-voice-status data-voice-mic
            data-voice-arming data-voice-arming-ms data-voice-log
            data-voice-log-details data-voice-bar-draft
          ) do
        assert html =~ selector, "missing #{selector} in the armed bar"
      end

      assert html =~ ~s(data-voice-action="retry")
      assert html =~ ~s(data-voice-action="start")
      # The hook writes in here, so LiveView must not patch it back.
      assert html =~ ~s(phx-update="ignore")

      # The picker lists real sessions.
      assert html =~ "a target session"
      assert html =~ session.id

      # ...and turning it off takes the whole line away again.
      off = render_hook(bar, "voice-on", %{"on" => false})
      refute off =~ "voice-bar-strip-row"
    end
  end

  describe "the target session" do
    test "the picker sets it, and the root advertises it to the hook", %{conn: conn} do
      session = new_session(%{title: "picked by hand"})

      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)
      render_hook(bar, "voice-on", %{"on" => true})

      html =
        render_change(form(bar, "form[phx-change='set_target']"), %{"session_id" => session.id})

      assert html =~ ~s(data-target-session-id="#{session.id}")
    end

    test "a page can push the target, and it PERSISTS when the page clears it",
         %{conn: conn} do
      session = new_session(%{title: "followed from the page"})

      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)

      html = render_hook(bar, "voice-target", %{"session_id" => session.id})
      assert html =~ ~s(data-target-session-id="#{session.id}")

      # Off a session page the target is KEPT (C4) — the user can still
      # dictate at whatever they were last looking at.
      html = render_hook(bar, "voice-target", %{"session_id" => nil})
      assert html =~ ~s(data-target-session-id="#{session.id}")
    end

    test "a session missing from the recent window is still selectable", %{conn: conn} do
      session = new_session(%{title: "off the end of the list"})

      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)
      render_hook(bar, "voice-on", %{"on" => true})

      # Force the picker to a short list that cannot contain the target, the
      # way a busy hub would.
      html = render_hook(bar, "voice-target", %{"session_id" => session.id})

      assert html =~ session.id,
             "the selected session must appear as an <option> or the select would " <>
               "silently show a DIFFERENT session as selected"
    end

    # ORCAHUB3-91. The hook restores its target after a reconnect re-mounts the
    # bar (see the `updated()` restore in voice_hook.js), and the session it
    # restores may no longer be resolvable — the phone slept for hours, the
    # session was deleted, the hub it lived on is gone. `ensure_listed/2` used
    # to give up there, leaving a <select> in which NO option is selected: the
    # browser then displays the FIRST option, so the bar claims to be pointed
    # at a session it is not pointed at. That is the server-side half of the
    # reported "the bar was attached to a different (earlier) session".
    test "ORCAHUB3-91: an unresolvable target never shows a DIFFERENT session as selected",
         %{conn: conn} do
      _decoy = new_session(%{title: "definitely not the target"})
      gone = Ecto.UUID.generate()

      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)
      render_hook(bar, "voice-on", %{"on" => true})

      html = render_hook(bar, "voice-target", %{"session_id" => gone})

      assert selected_value(html) == gone,
             "the picker must show the TARGET as its value (or say it is unavailable); " <>
               "with nothing selected the browser silently displays the first option"
    end

    # What the browser would report as the <select>'s value: the first option
    # carrying `selected`, else the first option. Anything else is the picker
    # disagreeing with `data-target-session-id`.
    defp selected_value(html) do
      options =
        html
        |> Floki.parse_document!()
        |> Floki.find("form[phx-change='set_target'] option")

      selected = Enum.find(options, &(Floki.attribute(&1, "selected") != []))

      case selected || List.first(options) do
        nil -> nil
        option -> option |> Floki.attribute("value") |> List.first()
      end
    end
  end

  describe "the help affordance (§8.3.10)" do
    # Everything here reads the vocabulary out of `Intent` at RUN time. That is
    # the point of the slice: add or reword an entry in `command_vocab/0` and
    # these tests demand the help panel show it, without anyone remembering to
    # edit this file or the template.
    alias OrcaHub.Voice.Intent

    defp armed_bar(conn) do
      {:ok, view, _html} = live(conn, ~p"/projects")
      bar = voice_bar(view)
      render_hook(bar, "voice-on", %{"on" => true})
      bar
    end

    defp open_help(bar) do
      bar |> element("[data-voice-help-toggle]") |> render_click()
    end

    # Scoped to the panel on purpose: these phrases are ordinary English and
    # the picker lists real sessions off the shared dev DB, so an unscoped
    # `html =~ phrase` could pass on a session TITLE.
    defp help_text(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#voice-help")
      |> Floki.text(sep: " ")
    end

    test "is collapsed by default — armed costs a trigger and no panel", %{conn: conn} do
      html = armed_bar(conn) |> render()

      assert html =~ "data-voice-help-toggle"

      # Collapsed means ABSENT, not hidden: there is no node, so there is no
      # box, so §8.2's 64 px armed budget cannot move.
      refute html =~ ~s(id="voice-help")

      for {_name, phrase} <- Intent.command_vocab() do
        refute html =~ phrase,
               "#{inspect(phrase)} is in the DOM while the help is collapsed — collapsed " <>
                 "must mean not rendered at all"
      end

      # The trigger sits in the header row beside the mic, NOT in the strip
      # row and NOT inside the hook-owned region.
      doc = Floki.parse_document!(html)
      assert Floki.find(doc, "#voice-strip [data-voice-help-toggle]") == []
      assert Floki.find(doc, "#voice-bar-strip-row [data-voice-help-toggle]") == []
    end

    test "opens, and lists EVERY entry of Intent.command_vocab/0", %{conn: conn} do
      bar = armed_bar(conn)
      text = bar |> open_help() |> help_text()

      vocab = Intent.command_vocab()
      assert length(vocab) >= 24, "the vocabulary shrank — check §8.3.3 before touching this"

      for {name, phrase} <- vocab do
        assert text =~ phrase,
               "the help panel does not teach #{inspect(name)} (#{phrase}). It must render " <>
                 "from Intent.command_vocab/0, not from a hand-written list."
      end
    end

    test "groups them by Intent.class/1, with a heading per class", %{conn: conn} do
      bar = armed_bar(conn)
      html = open_help(bar)

      sections =
        html
        |> Floki.parse_document!()
        |> Floki.find("#voice-help section")

      classes =
        Intent.command_vocab() |> Enum.map(fn {n, _} -> Intent.class(n) end) |> Enum.uniq()

      assert length(sections) == length(classes),
             "expected one section per class in #{inspect(classes)}, got #{length(sections)}"

      # Each section's phrases all belong to that section's class — i.e. the
      # grouping is real, not decorative.
      by_class = Enum.group_by(Intent.command_vocab(), fn {n, _} -> Intent.class(n) end)

      for section <- sections do
        phrases =
          section |> Floki.find("code") |> Enum.map(&Floki.text/1) |> Enum.map(&String.trim/1)

        assert [{class, _} | _] =
                 Enum.filter(by_class, fn {_c, entries} ->
                   Enum.map(entries, fn {_n, p} -> p end) == phrases
                 end),
               "a help section lists #{inspect(phrases)}, which is not any one class's " <>
                 "entries in order"

        assert class in classes
      end
    end

    test "teaches the FULL ordinal phrase and the truncated-ninth hazard", %{conn: conn} do
      text = armed_bar(conn) |> open_help() |> help_text()

      # Three tokens, straight from the vocabulary.
      for {name, phrase} <- Intent.command_vocab(), Intent.class(name) == :select do
        assert length(String.split(phrase)) == 3
        assert text =~ phrase
      end

      # §8.3.4's measured hazard: "orca ninth" alone scores higher against
      # "orca send" than against its own phrase. A help panel that lets the
      # user think the ordinal word is enough is worse than none.
      assert text =~ "orca ninth", "the ninth ordinal must be shown in full"
      assert text =~ ~r/truncated .*orca ninth.* is heard as\s+orca send/i
    end

    test "the close button and a second click on the trigger both collapse it", %{conn: conn} do
      bar = armed_bar(conn)

      assert open_help(bar) =~ ~s(id="voice-help")

      refute bar |> element("#voice-help button[phx-click='close_help']") |> render_click() =~
               ~s(id="voice-help")

      assert open_help(bar) =~ ~s(id="voice-help")
      refute open_help(bar) =~ ~s(id="voice-help")
    end

    test "turning voice off takes an open panel with it", %{conn: conn} do
      bar = armed_bar(conn)
      assert open_help(bar) =~ ~s(id="voice-help")

      off = render_hook(bar, "voice-on", %{"on" => false})
      refute off =~ ~s(id="voice-help")
      refute off =~ "data-voice-help-toggle"

      # ...and it does not spring back open when the mic returns.
      on_again = render_hook(bar, "voice-on", %{"on" => true})
      assert on_again =~ "data-voice-help-toggle"
      refute on_again =~ ~s(id="voice-help")
    end
  end
end
