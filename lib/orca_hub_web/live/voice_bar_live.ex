defmodule OrcaHubWeb.VoiceBarLive do
  @moduledoc """
  The GLOBAL voice bar — `voice_mode_spec.md` §8.2 (C4), resolving
  ORCAHUB3-88 ("voice mode is per-session and dies on navigation").

  Rendered once, in the app header, as a STICKY nested LiveView:

      live_render(@socket, OrcaHubWeb.VoiceBarLive,
        id: "voice-bar", sticky: true, container: {:div, class: "contents"})

  Sticky is the whole point: a sticky child survives LIVE navigation, so the
  hook's microphone, `AudioContext`, VAD session and `voice:<id>` channel
  survive a walk from `/sessions/:id` to `/queue` and back. That only holds
  while every internal header link is a `<.link navigate>` — which
  `OrcaHubWeb.LayoutsTest` pins.

  ## Two `display: contents` wrappers

  The header is ONE flex row. The bar needs its mic button to be an ordinary
  item in that row and its strip to be a full-width SECOND line, which a
  nested LiveView's own container would prevent — so both the LiveView
  container and this template's root are `display: contents` and the real
  children become flex items of the header itself. The header carries
  `flex-wrap` + `gap-y-0` so the strip wraps onto its own line at zero extra
  row gap.

  ## The vertical budget (§8.2, a hard one)

  IDLE is exactly one `btn-sm btn-circle` in the existing header row: no
  extra row, no extra pixels, on desktop AND mobile. It must never live
  behind the `md:hidden` burger — a bar you cannot reach on a phone is not a
  global bar. ARMED adds ONE line, budgeted at the 16 px phase 1 spent a
  whole cycle earning (spec §12, v0.4.1 -> v0.4.2), which is why the picker
  is height-clamped rather than a stock `select-xs` (24 px).

  ## The help affordance (§8.3.10)

  A "?" next to the mic opens a panel listing the spoken vocabulary grouped by
  `OrcaHub.Voice.Intent.class/1`. It is rendered from `Intent.command_vocab/0`
  and `Intent.payload/1` — never from a copy of the phrases — so reword a
  command in `Intent` and the help reworks itself. `vocab_groups/0` carries
  only the group ORDER and the prose; `voice_bar_live_test.exs` fails if any
  vocabulary entry stops appearing.

  It costs nothing vertically: collapsed it is not in the DOM at all, and open
  it is `position: fixed`, i.e. out of the header's flow. Both the trigger and
  the panel exist only while voice is on, exactly like §8.3.9's nav anchors.
  In the phone voice view the "?" is hidden, and the events popover's "What
  can I say?" opens the panel instead (ORCAHUB3-140).

  ## Who owns what

  This LiveView owns structure and the one piece of server data (the
  target-session picker). The `Voice` hook owns every byte of text inside
  `#voice-strip`, which is `phx-update="ignore"` for exactly that reason,
  and reports back through three events:

    * `"voice-on"` — the user toggled the mic. Drives the strip's existence.
    * `"voice-target"` — the page changed session under the bar (the session
      page's composer form / `body[data-voice-composer-for]`), so the picker
      follows. `data-target-session-id` on the root is the ONE source of
      truth for the target: the hook only ever asks for a change and then
      reacts to the re-render, so picker and channel cannot diverge.
    * `"refresh_sessions"` — the picker was focused; re-read the list rather
      than re-querying on every session status broadcast.

  ## The mobile voice view (ORCAHUB3-113 phase C)

  On a phone, a page that draws a voice layout turns full-screen while voice
  is on. The bar's half of that is a RESTYLE, never a second set of controls:
  everything below is a `voice-view:` utility (the custom variant in
  `app.css`: phone width + `html[data-voice-view]` + `html[data-voice-layout]`),
  so off the voice view — desktop, or any page without a layout — nothing
  here renders any differently. In it:

    * the mic button is the red "End" pill — the same `toggle` element, so
      the same gesture and the same click listener. Since ORCAHUB3-140 it
      also shows the listening state (starting, listening, speech,
      transcribing, muted for playback, stopped, error) from the hook's
      `html[data-voice-pill]`, through CSS in `app.css`;
    * "?", the sounds toggle and `#voice-tts-transport` are hidden (the page
      rail takes over the transport), and so is the rest of the header
      (`OrcaHubWeb.Layouts`);
    * ONE header line (ORCAHUB3-140): End, the picker as the screen's
      title, then two small buttons. One is auto-read (the page's
      `toggle_tts`, reached through a window event, styled off the page's
      `#voice-view[data-tts-autoplay]`). The other is "events", which opens
      the hook's log as a popover (`html[data-voice-events]`) with "What can
      I say?" in its header;
    * the strip still takes the line below, but its summary row is hidden,
      so that line is empty until something must be seen there: the arming
      countdown or "restore draft" (enlarged), the banner, an error and its
      Retry, or "Start listening";
    * a big "Tap to resume" (D8) shows while `html[data-voice-mic="stopped"]`.

  One server-side piece: `set_target` (the picker, a MANUAL choice) pushes
  `voice-picked`, which the hook answers on a phone in voice mode by
  live-navigating to that session (C5). `voice-target` (auto-follow) never
  pushes it.

  ## The target session's turn state (ORCAHUB3-93)

  The waiting tick has to follow the TARGET session's turn, not whatever page
  the browser happens to be on — the bar is global and the session being
  dictated at is very often not the one on screen, so nothing in the page's
  DOM can answer "is it answering yet". This LiveView therefore subscribes to
  the target's existing `session:<id>` topic (re-subscribed on every retarget,
  never more than one at a time) and pushes ONE event at the hook:

      voice-turn  %{session_id: id, stop: true, reason: ...}

  The flag is `stop`, not `answering`: `"stream_start"` (`Backend.Deltas`'
  first delta, the earliest reliable "it is answering") and `"assistant"` (a
  persisted assistant event) really are an answer, but `"idle"` and
  `"error"` — the backstops for a backend that streams no deltas — mean the
  turn ENDED with nobody answering. One flag, one meaning; `reason` carries
  which it was. Nothing here starts the tick: that is the hook's `"sent"`
  handler, because only the hook knows the send was a VOICE send.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC
  alias OrcaHub.Voice.Intent

  # The picker is a jump list, not a session browser — /sessions is one
  # header link away.
  @picker_limit 20

  # voice_mode_spec.md §8.3.3's FIXED navigate set, and §8.3.9's rule for
  # getting there: one HIDDEN `<.link navigate>` per path, which the hook
  # clicks. `window.location` (or a plain `<a href>`) would reload the
  # document, and a reload takes this bar — with the mic, the AudioContext
  # and the voice channel — down with it. Clicking a `data-phx-link` anchor
  # instead routes through the live socket, so the bar never unmounts.
  #
  # They are rendered only while voice is on: `ui_action navigate` can only
  # arrive over a joined channel, and §8.2's idle budget is "the mic button
  # and nothing else".
  @nav_paths ~w(/sessions /sessions/new)

  # §8.3.10's group order, and the one line of prose each class is worth. ONLY
  # the order and the prose live here — the phrases themselves are read out of
  # `Intent.command_vocab/0` on every render, so the panel cannot drift from
  # the matcher. A class that appears in `Intent.class/1` and NOT in this list
  # still renders, at the end, under its own name (see `vocab_groups/0`).
  @class_order [:action, :insert, :select, :navigate, :ignore]

  @class_headings %{
    action: "Send and cancel",
    insert: "Type something for me",
    select: "Pick from a list",
    navigate: "Go somewhere",
    ignore: "Heard, then ignored"
  }

  @class_notes %{
    action:
      "Both count down for 1.5 seconds first, and any further speech calls them off. " <>
        "While the command palette is open, orca send is ignored and orca cancel " <>
        "just closes the palette — your draft is never touched from there.",
    insert:
      "The command word is removed; anything you said before it is dictated first. " <>
        "After # or ## the next thing you say lands straight in the search box.",
    select:
      "Say the whole three-token phrase — the word \"select\" and the ordinal. " <>
        "A bare \"orca second\" or \"orca ninth\" is heard as orca send instead, " <>
        "and a bare \"orca select\" picks the third row. Say \"third\", not \"3rd\". " <>
        "Picks from the command palette, or from the # / ## autocomplete list " <>
        "when that is open.",
    navigate: "Navigation stays in-app, so the microphone keeps listening across the move.",
    ignore:
      "Things you say to a person mid-sentence. The command word is dropped and the " <>
        "rest of the sentence still lands in the draft — but nothing is ever sent."
  }

  # The two `:action` and two `:ignore` commands carry an EMPTY `payload/1`, so
  # their effect cannot be derived the way every other class's can. Anything
  # not listed here and not described by its payload simply renders with no
  # hint — never dropped from the list.
  @bare_hints %{
    send: "sends the draft to the target session",
    cancel:
      "clears the draft — after a 1.5 s countdown you can talk over, and \"restore draft\" puts it back",
    stop: "nothing — it will not stop a reply (that is phase 3)",
    pause: "nothing — it will not pause a reply (that is phase 3)"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:voice_on, false)
     |> assign(:help_open, false)
     # ORCAHUB3-93 — default ON, then corrected by the client's localStorage
     # via "voice-sounds-init". Default ON is defensible because a cue only
     # ever follows a send the user asked for out loud a moment earlier.
     |> assign(:sounds_on, true)
     |> assign(:target_session_id, nil)
     |> assign(:watching, nil)
     |> assign(:nav_paths, @nav_paths)
     |> assign(:vocab_groups, vocab_groups())
     |> assign(:sessions, list_sessions()), layout: false}
  end

  @impl true
  def handle_event("voice-on", params, socket) do
    on? = params["on"] == true
    # Turning the mic off takes the help with it: its trigger lives in the
    # armed bar, so an open panel would otherwise outlive the only control
    # that can close it.
    {:noreply,
     socket |> assign(:voice_on, on?) |> assign(:help_open, on? && socket.assigns.help_open)}
  end

  def handle_event("toggle_help", _params, socket) do
    {:noreply, assign(socket, :help_open, !socket.assigns.help_open)}
  end

  def handle_event("close_help", _params, socket) do
    {:noreply, assign(socket, :help_open, false)}
  end

  # ORCAHUB3-93's toggle. It is a sibling of the mic and the "?" in the same
  # header flex row, so it costs width and exactly zero of §8.2's height
  # budget, and — like the "?" — it exists only while voice is on, because
  # there is nothing it could affect while the mic is off.
  def handle_event("toggle_sounds", _params, socket) do
    enabled = !socket.assigns.sounds_on

    {:noreply,
     socket
     |> assign(:sounds_on, enabled)
     |> push_event("voice-sounds-persisted", %{enabled: enabled})}
  end

  def handle_event("voice-sounds-init", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :sounds_on, !!enabled)}
  end

  def handle_event("voice-target", %{"session_id" => id}, socket) when is_binary(id) do
    {:noreply, socket |> assign(:target_session_id, id) |> ensure_listed(id) |> watch_turn(id)}
  end

  # An explicit null means "the page stopped being a session page". The
  # target PERSISTS (C4): the user can still dictate at the session they
  # were last looking at from anywhere in the app.
  def handle_event("voice-target", _params, socket), do: {:noreply, socket}

  def handle_event("set_target", %{"session_id" => ""}, socket), do: {:noreply, socket}

  # The picker — and only the picker — also pushes `voice-picked`
  # (ORCAHUB3-113 C5): on a phone in voice mode the hook follows a MANUAL
  # retarget onto that session's page. Auto-follow arrives as `voice-target`
  # above and deliberately pushes nothing, so a page moving the target can
  # never navigate the page. Whether to navigate at all (voice view flag,
  # phone width, not already there) is the client's call; this only says
  # that the user chose.
  def handle_event("set_target", %{"session_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:target_session_id, id)
     |> ensure_listed(id)
     |> watch_turn(id)
     |> push_event("voice-picked", %{session_id: id})}
  end

  def handle_event("refresh_sessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:sessions, list_sessions())
     |> ensure_listed(socket.assigns.target_session_id)}
  end

  # ORCAHUB3-93 — the target session's turn, off its own `session:<id>` topic.
  #
  # Only ONE direction is reported, and the flag is named for it: `stop: true`,
  # "stop the tick". It is deliberately NOT called `answering`, because two of
  # the four cases are not an answer at all — an errored or idle turn has
  # ENDED, and nobody is answering. All four share exactly one thing, so the
  # field says exactly that thing and `reason` carries the detail.
  #
  # Starting the tick is the hook's job, because only the hook knows the send
  # that opened this wait was a spoken one.
  #
  # `Backend.Deltas`' stream_start is the earliest reliable signal and the one
  # that makes this feel right; the rest are backstops for a backend that
  # streams nothing. `:error` matters most of all: a failed turn is when the
  # user is likeliest to be sitting in front of a silent screen, and a tick
  # that outlived it would be the worst version of this feature.
  @impl true
  def handle_info({:assistant_stream_start, _payload}, socket),
    do: {:noreply, stop_ticking(socket, "stream_start")}

  def handle_info({:event, %{"type" => "assistant"}}, socket),
    do: {:noreply, stop_ticking(socket, "assistant")}

  def handle_info({:status, status}, socket) when status in [:idle, :error],
    do: {:noreply, stop_ticking(socket, to_string(status))}

  # `session:<id>` carries far more than the three above — progress, queue
  # updates, every other event type, `:running`, `:compacting`. None of it
  # ends the wait, and none of it may crash the header.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp stop_ticking(socket, reason) do
    case socket.assigns.watching do
      nil ->
        socket

      id ->
        push_event(socket, "voice-turn", %{
          session_id: id,
          stop: true,
          reason: reason
        })
    end
  end

  # Exactly one subscription at a time: retargeting the bar must stop the old
  # session's turn from ever stopping the new session's tick.
  defp watch_turn(socket, id) do
    cond do
      not connected?(socket) ->
        socket

      socket.assigns.watching == id ->
        socket

      true ->
        if socket.assigns.watching do
          Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "session:#{socket.assigns.watching}")
        end

        if id, do: Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{id}")
        assign(socket, :watching, id)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="voice-panel"
      phx-hook="Voice"
      class="contents"
      data-target-session-id={@target_session_id}
    >
      <%!-- The mic is ALWAYS rendered and always clickable: it is the user
           gesture (sticky activation) that lets the hook resume a suspended
           AudioContext at all — spec §9 trap 2. A bar that renders its mic
           only once voice is already on cannot be turned on.

           ORCAHUB3-113 D2: in the mobile voice view this SAME element is the
           red "End" pill — same `data-voice-action="toggle"`, same click
           listener, purely a `voice-view:` restyle plus a label that is
           display:none everywhere else. A second, page-rendered End would sit
           outside `#voice-panel`, where the hook's click listener never
           hears it.

           ORCAHUB3-140: the pill also SHOWS the listening state, from
           `html[data-voice-pill]` (the hook) through app.css's "voice view
           header" block: a halo that pulses while listening and strengthens
           on speech, animated dots while transcribing, grey with a speaker while
           a reply plays, dashed when stopped, solid red on an error. The
           three extra icons are display:none except under their state's
           rule, and `#voice-pill-say` is the hook's sr-only state text, so
           the accessible name reads "End voice mode (listening)". Off the
           voice view all four are display:none, so the desktop mic is the
           bare icon it always was. --%>
      <button
        type="button"
        data-voice-action="toggle"
        aria-pressed={to_string(@voice_on)}
        class={[
          "btn btn-ghost btn-sm btn-circle shrink-0",
          @voice_on && "text-primary",
          "voice-view:w-auto voice-view:gap-1.5 voice-view:pl-2.5 voice-view:pr-3.5 voice-view:h-9",
          "voice-view:bg-error/15 voice-view:text-error voice-view:font-semibold"
        ]}
        title={if @voice_on, do: "Turn off voice mode", else: "Turn on voice mode"}
      >
        <.icon name="hero-microphone" class="size-5" />
        <span data-voice-pill-icon="busy" class="hidden loading loading-dots loading-sm"></span>
        <span data-voice-pill-icon="muted" class="hidden hero-speaker-wave size-5"></span>
        <span data-voice-pill-icon="error" class="hidden hero-exclamation-triangle size-5"></span>
        <span data-voice-end-label class="hidden voice-view:inline">End</span>
        <span
          id="voice-pill-say"
          phx-update="ignore"
          data-voice-pill-say
          class="hidden voice-view:inline sr-only"
        >
        </span>
      </button>

      <%!-- §8.3.10's help trigger. It is a SIBLING of the mic in the same
           header flex row, so it costs width and exactly zero height, and it
           only exists while voice is on — §8.2's idle budget is "the mic
           button and nothing else", and the vocabulary is unusable until the
           channel is joined anyway.

           Hidden in the voice view (ORCAHUB3-113), as are the sounds toggle
           and the transport below: that header is End, the session title,
           the autoplay toggle and the events button (ORCAHUB3-140), nothing
           else. The events popover's "What can I say?" and "orca help" both
           still open the panel. --%>
      <button
        :if={@voice_on}
        type="button"
        phx-click="toggle_help"
        aria-expanded={to_string(@help_open)}
        aria-controls="voice-help"
        data-voice-help-toggle
        class={[
          "btn btn-ghost btn-sm btn-circle shrink-0 voice-view:hidden",
          @help_open && "text-primary"
        ]}
        title="What can I say?"
      >
        <.icon name="hero-question-mark-circle" class="size-5" />
      </button>

      <%!-- ORCAHUB3-93's sound toggle. Same shape and same budget as the "?"
           above: a sibling in the header row, so it costs width and zero
           height, and present only while voice is on. The label says what it
           covers — these are SPOKEN sends only, never a typed one. --%>
      <button
        :if={@voice_on}
        type="button"
        phx-click="toggle_sounds"
        aria-pressed={to_string(@sounds_on)}
        data-voice-sounds-toggle
        class={[
          "btn btn-ghost btn-sm btn-circle shrink-0 voice-view:hidden",
          @sounds_on && "text-primary"
        ]}
        title={
          if @sounds_on,
            do: "Sounds on: a chime when a spoken message is sent, a tick while it is answered",
            else: "Sounds off for spoken sends"
        }
      >
        <.icon
          name={if @sounds_on, do: "hero-speaker-wave", else: "hero-speaker-x-mark"}
          class="size-5"
        />
      </button>

      <%!-- ORCAHUB3-113 item 6: the read-aloud transport. A sibling of the
           mic in the same header flex row (so it costs width and zero
           height, exactly like the "?" and speaker buttons above), and
           deliberately NOT behind `:if={@voice_on}` — a reply can be read
           aloud with voice mode off, and a pause you have to turn the
           microphone on to reach is not a pause.

           Everything inside is written by `TTSMethods.ttsRenderBar` in
           app.js, which lives in the FEED's hook rather than this LiveView
           (the player is per-page, the bar is sticky). Hence
           `phx-update="ignore"`: this bar re-renders on every target change
           and session refresh, and morphdom would otherwise put the idle
           markup back over a live transport. `class="contents"` on the
           ignored wrapper keeps the strip itself an item of the header row,
           the same trick `#voice-panel` uses one level up.

           Item 7's HELD state renders here too ("Reply ready"): an autoplay
           that declines to start while the user is writing must never be
           silent, so the thing that did not speak is always one tap away.

           ORCAHUB3-113: hidden in the voice view, whose page rail
           (`#voice-rail`) and held strip (`#voice-held`) carry both jobs at
           full size. Hidden on THIS wrapper rather than on `[data-tts-bar]`,
           whose `hidden` class app.js owns and toggles. --%>
      <div id="voice-tts-transport" phx-update="ignore" class="contents voice-view:hidden">
        <div data-tts-bar class="hidden items-center gap-0.5 shrink-0">
          <span
            data-tts-bar-label
            class="text-[11px] leading-none opacity-70 whitespace-nowrap"
          >
          </span>
          <button
            type="button"
            data-tts-bar-action="toggle"
            aria-label="Read aloud"
            class="btn btn-ghost btn-sm btn-circle shrink-0"
          >
          </button>
          <button
            type="button"
            data-tts-bar-action="stop"
            aria-label="Stop reading"
            class="btn btn-ghost btn-sm btn-circle shrink-0"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- §8.3.9's live-navigation anchors. `hidden` is display:none, so
           they are not flex items of the header and cost exactly zero of
           §8.2's height budget; the hook reaches them by their
           `data-voice-nav` path and clicks them. --%>
      <.link
        :for={path <- @nav_paths}
        :if={@voice_on}
        navigate={path}
        data-voice-nav={path}
        class="hidden"
        tabindex="-1"
        aria-hidden="true"
      >
        {path}
      </.link>

      <%!-- ORCAHUB3-113 C5: the same trick for the picker. After a MANUAL
           retarget (`set_target` pushes `voice-picked`) on a phone in voice
           mode, the hook clicks this so the screen shows the session being
           talked to. It always points at the CURRENT target; push events are
           dispatched after the patch that carried them, so by the time the
           hook hears `voice-picked` this already names the new session. --%>
      <.link
        :if={@voice_on && @target_session_id}
        navigate={~p"/sessions/#{@target_session_id}"}
        data-voice-retarget-nav={@target_session_id}
        class="hidden"
        tabindex="-1"
        aria-hidden="true"
      >
        session
      </.link>

      <%!-- §8.3.10's panel. Two things keep it inside §8.2's budget: while
           collapsed it is not rendered AT ALL (no node, so no box to measure),
           and while open it is `position: fixed`, i.e. out of flow, so it
           cannot grow the header either. It is deliberately OUTSIDE
           `#voice-strip` — that region is `phx-update="ignore"` and belongs to
           the hook, and a LiveView-patched panel in there would fight the
           hook's writes.

           Every phrase below comes from `Intent.command_vocab/0` via
           `vocab_groups/0`; nothing spoken is spelled out in this template, so
           the help cannot drift from the matcher. --%>
      <div
        :if={@voice_on and @help_open}
        id="voice-help"
        role="dialog"
        aria-label="Voice commands"
        phx-window-keydown="close_help"
        phx-key="Escape"
        class="fixed z-50 top-16 left-2 right-2 sm:left-auto sm:right-4 sm:w-96 max-h-[70vh] overflow-y-auto rounded-box border border-base-300 bg-base-100 shadow-xl p-3 text-xs"
      >
        <div class="flex items-center gap-2 mb-2">
          <h2 class="font-semibold text-sm grow">What can I say?</h2>
          <button
            type="button"
            phx-click="close_help"
            aria-label="Close voice commands"
            class="btn btn-ghost btn-xs btn-circle"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <section :for={group <- @vocab_groups} class="mb-3 last:mb-0">
          <h3 class="font-semibold opacity-70 uppercase tracking-wide text-[10px]">
            {group.heading}
          </h3>
          <ul class="mt-1 space-y-0.5">
            <li :for={entry <- group.entries} class="flex flex-wrap items-baseline gap-x-2">
              <code class="font-mono text-[11px] bg-base-200 rounded px-1 py-px">
                {entry.phrase}
              </code>
              <span :if={entry.hint != ""} class="opacity-60">{entry.hint}</span>
            </li>
          </ul>
          <p :if={group.note} class="mt-1 opacity-60 leading-snug">{group.note}</p>
        </section>

        <p class="mt-3 pt-2 border-t border-base-300 opacity-60 leading-snug">
          Spaces are ignored when matching, so "orca newline" and "orca new line" are the
          same command. Say a command at the END of a sentence — anything in front of it
          is dictated first.
        </p>

        <%!-- ORCAHUB3-93. The control itself is the speaker button in the
             header; this is where someone reading the help finds out what it
             does and that it is spoken sends only. --%>
        <p class="mt-2 opacity-60 leading-snug">
          The speaker button next to the mic is <strong>{if @sounds_on, do: "on", else: "off"}</strong>:
          a short chime when a spoken message is actually delivered, then a quiet tick every
          few seconds until the session starts answering. Typed sends never make a sound.
        </p>
      </div>

      <%!-- The second line, and the ONLY thing voice mode costs vertically.
           `basis-full` wraps it below the header row; the header's `gap-y-0`
           keeps the wrap itself free.

           ORCAHUB3-113: in the voice view this row DISSOLVES
           (`voice-view:contents`), the same `display: contents` trick that
           puts the bar in the header at all. Its children become header
           items: the picker grows into the session title on the End pill's
           line, followed by the autoplay and events buttons (ORCAHUB3-140),
           and `#voice-strip` takes the full-width line below.

           ORCAHUB3-140: that line is EMPTY in the steady state, so the voice
           view's chrome is one line. `#voice-strip`'s summary row is hidden
           there (the pill carries its state), and app.css brings back only
           what must be seen while it is showing: the arming countdown and
           "restore draft" at full size, the banner, the error and its Retry,
           and "Start listening". With all of them hidden the strip is a
           zero-height line, which the header's `gap-y-0` keeps free. --%>
      <div
        :if={@voice_on}
        id="voice-bar-strip-row"
        class="basis-full w-full min-w-0 flex items-center gap-2 text-xs voice-view:contents"
      >
        <%!-- Height-clamped on purpose: a stock `select-xs` is 24px and would
             blow §8.2's 16px budget on its own. The voice view has no such
             budget (the whole screen is voice), so there it unclamps into
             the screen's title — still the same <select>, so tapping the
             title IS retargeting. --%>
        <form
          phx-change="set_target"
          class="shrink-0 flex voice-view:flex-1 voice-view:min-w-0"
        >
          <select
            name="session_id"
            phx-focus="refresh_sessions"
            aria-label="Voice target session"
            class={[
              "select select-ghost h-4 min-h-0 py-0 pl-1 pr-5 text-[11px] leading-none max-w-[9rem] border-0 focus:outline-none",
              "voice-view:h-9 voice-view:w-full voice-view:max-w-none voice-view:pr-7",
              "voice-view:text-[15px] voice-view:font-semibold"
            ]}
          >
            <option :if={is_nil(@target_session_id)} value="">pick a session…</option>
            <option
              :for={session <- @sessions}
              value={session.id}
              selected={session.id == @target_session_id}
            >
              {session_label(session)}
            </option>
          </select>
        </form>

        <%!-- ORCAHUB3-140: the voice view's auto-read toggle, the composer's
             speaker button (`toggle_tts`, hidden in the view) brought up to
             the header row. Display:none everywhere else.

             The state belongs to the PAGE: SessionLive.Show's
             `:tts_autoplay`, persisted in localStorage `orca:tts-autoplay`.
             This sticky bar never holds a copy. A click dispatches
             `orca:tts-autoplay-toggle` on window, where the page's TTS hook
             (TTSMethods in app.js) pushes `toggle_tts` to its own LiveView,
             and the look follows the page's server-rendered
             `#voice-view[data-tts-autoplay]` through a `:has()` rule in
             app.css. The two halves swap by that rule too, sr-only text and
             all, so the accessible name says "on" or "off" with no patch of
             this LiveView involved. --%>
        <button
          type="button"
          data-voice-autoplay-toggle
          phx-click={JS.dispatch("orca:tts-autoplay-toggle")}
          class="hidden voice-view:inline-flex btn btn-ghost btn-sm btn-circle shrink-0"
          title="Read each reply aloud when it finishes"
        >
          <span data-autoplay="off" class="hero-speaker-x-mark size-5"></span>
          <span data-autoplay="off" class="sr-only">Auto-read replies: off</span>
          <span data-autoplay="on" class="hero-speaker-wave size-5"></span>
          <span data-autoplay="on" class="sr-only">Auto-read replies: on</span>
        </button>

        <%!-- ORCAHUB3-140: the voice view's "events", a small button where
             the strip's "events >" summary used to need a line of its own.
             It opens the hook's log as a popover (`_toggleEvents`, keyed on
             `html[data-voice-events]`), so it is a `data-voice-action` inside
             `#voice-panel`, and `phx-update="ignore"` lets the hook keep its
             `aria-expanded` true across this LiveView's patches. --%>
        <span id="voice-events-toggle" phx-update="ignore" class="hidden voice-view:contents">
          <button
            type="button"
            data-voice-action="events"
            data-voice-events-toggle
            aria-expanded="false"
            aria-controls="voice-events"
            class="btn btn-ghost btn-sm btn-circle shrink-0"
            title="Voice events"
          >
            <.icon name="hero-queue-list" class="size-5" />
          </button>
        </span>

        <%!-- Everything below is the hook's, verbatim from §8.1's DOM
             contract: same `data-voice-*` selectors, same hidden-by-default
             children, same native <details> log. phx-update="ignore" is what
             lets the hook write here without LiveView patching it back. --%>
        <div
          id="voice-strip"
          phx-update="ignore"
          class="min-w-0 flex-1 flex flex-col gap-1 voice-view:basis-full"
        >
          <%!-- §9 trap 1: no secure context means navigator.mediaDevices is
               simply absent, with no error thrown. The hook fills this in. --%>
          <div data-voice-banner class="hidden alert alert-error py-1 text-xs"></div>
          <%!-- The retry button is a SIBLING of the error box, not a child:
               the hook renders errors with `textContent =`, which would
               delete any nested node the first time an error appeared.
               `peer` gives it the error's visibility with no extra JS. --%>
          <div data-voice-error class="peer hidden alert alert-error py-1 text-xs"></div>
          <button
            type="button"
            data-voice-action="retry"
            class="hidden peer-[:not(.hidden)]:inline-flex btn btn-xs btn-outline btn-error self-start"
          >
            Retry warm-up
          </button>
          <details data-voice-log-details class="group">
            <summary class="flex items-center gap-2 list-none cursor-pointer h-4 leading-4">
              <.icon name="hero-microphone" class="size-4 shrink-0" />
              <span data-voice-status class="font-medium shrink-0">starting…</span>
              <span data-voice-mic class="opacity-60 truncate min-w-0 flex-1"></span>
              <%!-- §8.3.11: the countdown now belongs to EITHER action, so the verb
                   is written by the hook off `state.arming` rather than baked
                   in here. A cancel's countdown is the whole point of
                   ORCAHUB3-99 — it is the 1500 ms in which the user can talk a
                   false positive away — so it has to say which one it is. --%>
              <span data-voice-arming class="hidden badge badge-warning badge-xs shrink-0">
                <span data-voice-arming-label>sending in</span>
                <span data-voice-arming-ms></span>
              </span>
              <%!-- §8.3.11's undo. It lives in the summary ROW, clamped to the
                   same h-4 as everything else in it, so the affordance that
                   makes a cancel non-destructive costs zero of §8.2's vertical
                   budget. The hook shows it only while there is something to
                   put back, and swallows the click so it does not toggle the
                   <details> it sits inside. --%>
              <button
                type="button"
                data-voice-action="restore"
                class="hidden btn btn-xs btn-outline btn-warning h-4 min-h-0 px-1 leading-none shrink-0"
                title="Put back the draft that was just cancelled"
              >
                restore draft
              </button>
              <span class="shrink-0 opacity-50 flex items-center gap-0.5">
                events
                <.icon
                  name="hero-chevron-right"
                  class="size-3 transition-transform group-open:rotate-90"
                />
              </span>
            </summary>
            <%!-- ORCAHUB3-140: a plain block off the voice view, so the log
                 renders exactly as before. In the view it is the events
                 popover (`position: fixed`, app.css) while
                 `html[data-voice-events]` is set and display:none otherwise,
                 whatever the <details>' own remembered open state. Its header
                 is display:none off the view: the title, the status and mic
                 lines the view's hidden summary row would have shown (the
                 hook writes every copy), "What can I say?" and a close. Both
                 buttons are `data-voice-action="events"`, which closes the
                 popover; the help button also opens the help panel. --%>
            <div id="voice-events" data-voice-log-panel>
              <div class="hidden voice-view:block mb-2">
                <div class="flex items-center gap-2">
                  <h2 class="font-semibold text-sm grow">Voice events</h2>
                  <button
                    type="button"
                    phx-click="toggle_help"
                    data-voice-action="events"
                    class="btn btn-ghost btn-xs"
                  >
                    What can I say?
                  </button>
                  <button
                    type="button"
                    data-voice-action="events"
                    aria-label="Close voice events"
                    class="btn btn-ghost btn-xs btn-circle"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <p class="flex flex-wrap gap-x-2 opacity-70">
                  <span data-voice-status class="font-medium"></span>
                  <span data-voice-mic></span>
                </p>
              </div>
              <ol
                data-voice-log
                class="mt-1 text-[11px] leading-snug opacity-60 max-h-24 overflow-y-auto"
              >
              </ol>
            </div>
          </details>
          <%!-- The bar's OWN draft sink, for pages with no composer bound to
               the target (e.g. /queue). The hook unhides it only then — when
               a composer IS present the transcript goes there instead, which
               is what keeps the single send path honest. --%>
          <textarea
            data-voice-bar-draft
            rows="1"
            placeholder="dictating…"
            class="hidden textarea textarea-bordered textarea-xs w-full min-h-8 max-h-24 leading-snug"
          ></textarea>
          <%!-- Fallback gesture, unhidden by the hook only if the
               AudioContext is still suspended after resume(). --%>
          <button
            type="button"
            data-voice-action="start"
            class="hidden btn btn-warning btn-xs self-start"
          >
            Start listening
          </button>
        </div>
      </div>

      <%!-- ORCAHUB3-113 D8: the voice view's "Tap to resume". When the OS
           takes the microphone (a phone backgrounded), the view STAYS — it
           follows the user's intent, not the mic — and this is how the mic
           comes back. Display:none everywhere except the voice view with
           `html[data-voice-mic="stopped"]`; a deliberate release during
           playback ("released", ORCAHUB3-105) is not a failure and shows
           nothing. Pure CSS off two <html> attributes the hook maintains, so
           no LiveView patch can fight it.

           Bar-rendered inside `#voice-panel` because the hook's click
           listener is bound there. Its own action, never "toggle": the
           toggle's second press turns voice OFF, and Resume must never. --%>
      <button
        :if={@voice_on}
        type="button"
        data-voice-action="resume"
        class={[
          "hidden btn btn-warning btn-lg basis-full w-full mt-2 gap-2",
          "voice-view:[&:where(html[data-voice-mic=stopped]_*)]:inline-flex"
        ]}
      >
        <.icon name="hero-microphone" class="size-6" /> Tap to resume
      </button>
    </div>
    """
  end

  # §8.3.10: the help is a projection of the matcher's own vocabulary, grouped
  # by `Intent.class/1`. Built once at mount — `command_vocab/0` is a compile
  # time constant — but built from the FUNCTION, never from a copy of the list,
  # which is the whole point: a phrase added to (or reworded in) `Intent` shows
  # up here with no edit to this file, and cannot silently go missing.
  defp vocab_groups do
    grouped = Enum.group_by(Intent.command_vocab(), fn {name, _phrase} -> Intent.class(name) end)

    # Known classes in §8.3.10's reading order, then any class this file has
    # never heard of — so a new class degrades into "shown under its own name"
    # rather than into "silently omitted".
    order = @class_order ++ (Map.keys(grouped) -- @class_order)

    for class <- order, entries = grouped[class] do
      %{
        class: class,
        heading: Map.get(@class_headings, class, to_string(class)),
        note: Map.get(@class_notes, class),
        entries:
          Enum.map(entries, fn {name, phrase} ->
            %{name: name, phrase: phrase, hint: hint(name)}
          end)
      }
    end
  end

  # What the command does, derived from `Intent.payload/1` wherever the payload
  # says it — so insert text, ordinals and navigation targets are quoted from
  # the same map the session routes on.
  defp hint(name) do
    case Intent.payload(name) do
      %{text: "\n"} -> "starts a new line"
      %{text: "\n\n"} -> "starts a new paragraph"
      %{text: text} -> "types #{text} and searches on what you say next"
      %{ordinal: n} -> "picks item #{n}"
      %{kind: "navigate", path: path} -> "goes to #{path}"
      %{kind: "open_palette"} -> "opens the command palette"
      %{kind: "close_palette"} -> "closes the command palette"
      %{kind: "back"} -> "goes back a page"
      %{kind: "open_help"} -> "opens this list — \"orca help\" on its own works too"
      _empty -> Map.get(@bare_hints, name, "")
    end
  end

  defp session_label(%{unavailable: true, id: id}),
    do: "session " <> String.slice(id, 0, 8) <> " (unavailable)"

  defp session_label(%{title: title}) when is_binary(title) and title != "",
    do: String.slice(title, 0, 30)

  defp session_label(%{id: id}), do: "session " <> String.slice(id, 0, 8)

  defp list_sessions do
    HubRPC.list_sessions(:all)
    |> Enum.take(@picker_limit)
  end

  # Keep the selected session in the list even when it has fallen off the
  # recent window — otherwise the <select> would silently render a DIFFERENT
  # session as selected and the next spoken send would go to it.
  #
  # ORCAHUB3-91: that has to hold even when the session cannot be RESOLVED.
  # The hook restores its target after a reconnect re-mounts this LiveView, and
  # by then the session may be gone (deleted, or on a hub this node can no
  # longer reach). Giving up here left a <select> with nothing selected, which
  # a browser renders as its FIRST option — the bar then displays a session it
  # is not targeting, which is the reported symptom. A placeholder row carrying
  # the target's own id keeps the control's value equal to the target and says
  # out loud that it is unavailable.
  defp ensure_listed(socket, nil), do: socket

  defp ensure_listed(socket, id) do
    if Enum.any?(socket.assigns.sessions, &(&1.id == id)) do
      socket
    else
      listed =
        case HubRPC.get_session(id) do
          %{} = session -> session
          _ -> %{id: id, title: nil, unavailable: true}
        end

      assign(socket, :sessions, [listed | socket.assigns.sessions])
    end
  end
end
