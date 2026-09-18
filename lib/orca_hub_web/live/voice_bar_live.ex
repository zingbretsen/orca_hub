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
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.HubRPC

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

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:voice_on, false)
     |> assign(:target_session_id, nil)
     |> assign(:nav_paths, @nav_paths)
     |> assign(:sessions, list_sessions()), layout: false}
  end

  @impl true
  def handle_event("voice-on", params, socket) do
    {:noreply, assign(socket, :voice_on, params["on"] == true)}
  end

  def handle_event("voice-target", %{"session_id" => id}, socket) when is_binary(id) do
    {:noreply, socket |> assign(:target_session_id, id) |> ensure_listed(id)}
  end

  # An explicit null means "the page stopped being a session page". The
  # target PERSISTS (C4): the user can still dictate at the session they
  # were last looking at from anywhere in the app.
  def handle_event("voice-target", _params, socket), do: {:noreply, socket}

  def handle_event("set_target", %{"session_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("set_target", %{"session_id" => id}, socket) do
    {:noreply, socket |> assign(:target_session_id, id) |> ensure_listed(id)}
  end

  def handle_event("refresh_sessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:sessions, list_sessions())
     |> ensure_listed(socket.assigns.target_session_id)}
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
           only once voice is already on cannot be turned on. --%>
      <button
        type="button"
        data-voice-action="toggle"
        aria-pressed={to_string(@voice_on)}
        class={["btn btn-ghost btn-sm btn-circle shrink-0", @voice_on && "text-primary"]}
        title={if @voice_on, do: "Turn off voice mode", else: "Turn on voice mode"}
      >
        <.icon name="hero-microphone" class="size-5" />
      </button>

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

      <%!-- The second line, and the ONLY thing voice mode costs vertically.
           `basis-full` wraps it below the header row; the header's `gap-y-0`
           keeps the wrap itself free. --%>
      <div
        :if={@voice_on}
        id="voice-bar-strip-row"
        class="basis-full w-full min-w-0 flex items-center gap-2 text-xs"
      >
        <%!-- Height-clamped on purpose: a stock `select-xs` is 24px and would
             blow §8.2's 16px budget on its own. --%>
        <form phx-change="set_target" class="shrink-0 flex">
          <select
            name="session_id"
            phx-focus="refresh_sessions"
            aria-label="Voice target session"
            class="select select-ghost h-4 min-h-0 py-0 pl-1 pr-5 text-[11px] leading-none max-w-[9rem] border-0 focus:outline-none"
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

        <%!-- Everything below is the hook's, verbatim from §8.1's DOM
             contract: same `data-voice-*` selectors, same hidden-by-default
             children, same native <details> log. phx-update="ignore" is what
             lets the hook write here without LiveView patching it back. --%>
        <div id="voice-strip" phx-update="ignore" class="min-w-0 flex-1 flex flex-col gap-1">
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
              <span data-voice-arming class="hidden badge badge-warning badge-xs shrink-0">
                sending in <span data-voice-arming-ms></span>
              </span>
              <span class="shrink-0 opacity-50 flex items-center gap-0.5">
                events
                <.icon
                  name="hero-chevron-right"
                  class="size-3 transition-transform group-open:rotate-90"
                />
              </span>
            </summary>
            <ol
              data-voice-log
              class="mt-1 text-[11px] leading-snug opacity-60 max-h-24 overflow-y-auto"
            >
            </ol>
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
    </div>
    """
  end

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
  defp ensure_listed(socket, nil), do: socket

  defp ensure_listed(socket, id) do
    if Enum.any?(socket.assigns.sessions, &(&1.id == id)) do
      socket
    else
      case HubRPC.get_session(id) do
        %{} = session -> assign(socket, :sessions, [session | socket.assigns.sessions])
        _ -> socket
      end
    end
  end
end
