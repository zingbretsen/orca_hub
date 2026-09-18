defmodule OrcaHubWeb.LayoutsTest do
  @moduledoc """
  Guards the header nav's live-navigation contract.

  The header hosts `live_render(..., sticky: true)` children (the idle badge
  today, a voice panel next), and a sticky nested LiveView only survives LIVE
  navigation — a plain `<a href="/queue">` is a full page reload that tears the
  whole socket (and therefore the sticky child) down and rebuilds it. So every
  INTERNAL header link must be a `<.link navigate={...}>`, which renders as an
  anchor carrying `data-phx-link="redirect"`. This test fails if one regresses
  back to a bare anchor.
  """

  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Every internal path the header links to (nav_links + the settings menu).
  @nav_paths ~w(
    / /queue /projects /issues /triggers /skills /terminals /sessions
    /artifacts /nodes /settings /usage
  )

  defp header_anchors(html) do
    html
    |> Floki.parse_document!()
    # Scoped to the app shell's own header (a page's content can have its own
    # nested <header>, e.g. /projects' "New project" patch link).
    |> Floki.find("div.h-dvh > header a")
  end

  test "every internal header link live-navigates instead of reloading the page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/projects")

    anchors = header_anchors(html)
    assert anchors != [], "expected the header to render some links"

    internal =
      for a <- anchors,
          href = Floki.attribute([a], "href") |> List.first(),
          is_binary(href),
          String.starts_with?(href, "/"),
          Floki.attribute([a], "target") == [],
          do: {href, Floki.attribute([a], "data-phx-link") |> List.first()}

    # 1. No plain internal anchor survives in the header.
    plain = for {href, nil} <- internal, do: href
    assert plain == [], "header still has full-reload anchors for: #{inspect(plain)}"

    for {href, link_type} <- internal do
      assert link_type == "redirect",
             "header link #{href} should be <.link navigate> (data-phx-link=redirect), " <>
               "got #{inspect(link_type)}"
    end

    # 2. Every nav destination is actually present as a live-nav link, so the
    #    assertion above can't pass vacuously by the links disappearing.
    hrefs = for {href, _} <- internal, do: href

    for path <- @nav_paths do
      assert path in hrefs, "expected a live-nav header link to #{path}"
    end
  end

  # The other half of the same contract: live navigation only buys anything
  # if the sticky child is actually IN the header, and the voice bar's
  # controls only work if they are not inside one of the links above.
  test "the voice bar is a header child and no link contains it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/projects")
    doc = Floki.parse_document!(html)

    assert [_ | _] = Floki.find(doc, "div.h-dvh > header #voice-bar"),
           "OrcaHubWeb.VoiceBarLive must be live_render'd inside the app header"

    # A button inside an <a data-phx-link="redirect"> navigates on click, so
    # the mic would arm and immediately be carried off the page.
    assert Floki.find(doc, "header a #voice-bar") == [],
           "the voice bar must not be nested inside a header link"

    # Sticky is what carries the mic/AudioContext/channel across navigation;
    # without it the bar is just the old per-page panel in a new place.
    assert Floki.find(doc, "#voice-bar[data-phx-sticky]") != [],
           "the voice bar must be rendered with sticky: true"
  end
end
