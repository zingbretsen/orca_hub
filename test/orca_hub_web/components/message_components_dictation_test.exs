defmodule OrcaHubWeb.MessageComponentsDictationTest do
  @moduledoc """
  The user bubble for a voice-dictated message: the `OrcaHub.Voice.Dictation`
  note is for the MODEL, so the bubble hides it and shows a small "dictated"
  marker instead — display-only, like the leading `<orca-memory>` block.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OrcaHub.Voice.Dictation
  alias OrcaHubWeb.MessageComponents

  defp user_msg(text) do
    %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp render_feed(msg) do
    render_component(&MessageComponents.message_feed/1, %{messages: [msg], session_node: nil})
  end

  test "a dictated message shows the marker and not the note" do
    html = render_feed(user_msg(Dictation.prefix("look at the Nemo Tron config")))

    assert html =~ "look at the Nemo Tron config"
    assert html =~ "data-dictated"
    assert html =~ "dictated"
    refute html =~ "speech recognition —"
    refute html =~ "infer the intended meaning"
  end

  test "a typed message gets no marker" do
    html = render_feed(user_msg("typed by hand"))

    assert html =~ "typed by hand"
    refute html =~ "data-dictated"
  end

  test "behind a leading <orca-memory> block (a cold-open first turn)" do
    text = "<orca-memory>\n- a fact\n</orca-memory>\n\n" <> Dictation.prefix("hello there")
    html = render_feed(user_msg(text))

    assert html =~ "hello there"
    assert html =~ "data-dictated"
    refute html =~ "a fact"
    refute html =~ "infer the intended meaning"
  end

  test "behind a queued-delivery header (the :queue path)" do
    text =
      "[Message delivery note]\n\nThis message was sent with queued delivery.\n\n" <>
        Dictation.prefix("ship it")

    html = render_feed(user_msg(text))

    assert html =~ "ship it"
    assert html =~ "data-dictated"
    refute html =~ "infer the intended meaning"
  end
end
