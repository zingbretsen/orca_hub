defmodule OrcaHubWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OrcaHubWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # `capabilities` is an optional assign set by SessionLive.Show (Phase 3,
  # spec §7) — the layout receives the current LiveView's full assign set
  # (same pattern as `node_filter_visible` below), so a session page can hide
  # chrome that doesn't apply to its backend without every other page having
  # to know about capabilities at all. `OrcaHub.Claude.Usage.fetch/0` scrapes
  # this NODE's local Claude credentials — nothing session-specific — but
  # while viewing a session whose backend has no usage capability (Codex),
  # the link is still the wrong thing to dangle in front of the user.
  defp nav_links(_assigns) do
    [
      %{href: ~p"/queue", label: "Queue", badge: true},
      %{href: ~p"/projects", label: "Projects"},
      %{href: ~p"/issues", label: "Issues"},
      %{href: ~p"/triggers", label: "Triggers"},
      %{href: ~p"/skills", label: "Skills"},
      %{href: ~p"/terminals", label: "Terminals"},
      %{href: ~p"/sessions", label: "Sessions"},
      %{href: ~p"/artifacts", label: "Artifacts"},
      %{href: ~p"/nodes", label: "Nodes"}
    ]
  end

  # Settings dropdown entries (desktop) / flat trailing links (mobile).
  defp settings_menu_links(assigns) do
    [
      %{href: ~p"/settings", label: "Settings"},
      %{href: ~p"/usage", label: "Usage", visible: usage_nav_visible?(assigns)}
    ]
    |> Enum.filter(&Map.get(&1, :visible, true))
  end

  defp usage_nav_visible?(assigns) do
    case assigns[:capabilities] do
      %OrcaHub.Backend.Capabilities{usage: usage} -> usage
      _ -> true
    end
  end

  @doc """
  Renders your app layout.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block

  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_links, nav_links(assigns))
      |> assign(:settings_menu_links, settings_menu_links(assigns))

    ~H"""
    <header class="flex items-center gap-2 px-4 py-2 sm:px-6 lg:px-8">
      <a href="/" class="flex items-center gap-2 font-semibold">
        <img src={~p"/images/logo.png"} alt="OrcaHub" class="h-8 w-auto" /> OrcaHub
      </a>

      <nav class="hidden md:flex items-center gap-1 ml-4 mr-auto">
        <a :for={link <- @nav_links} href={link.href} class="btn btn-ghost btn-sm">
          {link.label}
          <.idle_badge :if={link[:badge]} socket={@socket} id="idle-badge-desktop" />
        </a>
        <.settings_nav_dropdown links={@settings_menu_links} />
      </nav>

      <div class="hidden md:flex items-center gap-2 ml-auto">
        <.theme_toggle />
      </div>

      <button
        class="btn btn-ghost btn-sm btn-circle md:hidden ml-auto"
        phx-click={JS.dispatch("command-palette:toggle", to: "body", bubbles: true)}
      >
        <.icon name="hero-magnifying-glass" class="size-5" />
      </button>

      <div class="dropdown dropdown-end md:hidden">
        <div tabindex="0" role="button" class="btn btn-ghost btn-sm btn-circle">
          <.icon name="hero-bars-3-micro" class="size-5" />
        </div>
        <ul
          tabindex="0"
          class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-200 rounded-box w-52"
        >
          <li :for={link <- @nav_links}>
            <a href={link.href}>
              {link.label}
              <.idle_badge :if={link[:badge]} socket={@socket} id="idle-badge-mobile" />
            </a>
          </li>
          <li :for={link <- @settings_menu_links}>
            <a href={link.href}>{link.label}</a>
          </li>

          <li class="menu-title text-xs uppercase opacity-60 mt-2">Theme</li>
          <li><.theme_toggle /></li>
        </ul>
      </div>
    </header>

    <.node_filter_chips
      :if={assigns[:node_filter_visible]}
      nodes={assigns[:node_filter_nodes] || []}
      filter={assigns[:node_filter] || :all}
    />

    <main class="px-4 py-6 sm:px-6 sm:py-10 lg:px-8">
      <div class="mx-auto max-w-5xl space-y-4">
        {@inner_content}
      </div>
    </main>

    <.flash_group flash={@flash} />

    <.live_component module={OrcaHubWeb.CommandPaletteLive} id="command-palette" />
    """
  end

  defp idle_badge(assigns) do
    ~H"""
    {live_render(@socket, OrcaHubWeb.IdleBadgeLive, id: @id, sticky: true)}
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # Degrades to a plain "Settings" link when there's only one entry (e.g.
  # Usage hidden by capabilities) — a dropdown with a single item is just
  # extra clicks.
  defp settings_nav_dropdown(%{links: [single]} = assigns) do
    assigns = assign(assigns, :single, single)

    ~H"""
    <a href={@single.href} class="btn btn-ghost btn-sm">{@single.label}</a>
    """
  end

  defp settings_nav_dropdown(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-1">
        Settings <.icon name="hero-chevron-down-micro" class="size-3" />
      </div>
      <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-200 rounded-box w-40">
        <li :for={link <- @links}><a href={link.href}>{link.label}</a></li>
      </ul>
    </div>
    """
  end

  defp node_filter_chips(assigns) do
    ~H"""
    <div id="node-filter" phx-hook="NodeFilter" class="flex flex-wrap gap-1 px-2 py-1">
      <button
        phx-click="node_filter_select_all"
        class="btn btn-xs btn-ghost"
      >
        All nodes
      </button>
      <button
        :for={node <- @nodes}
        phx-click="toggle_node_filter"
        phx-value-node={node.name}
        data-solo-node={node.name}
        class={"btn btn-xs #{if OrcaHubWeb.NodeFilter.node_selected?(@filter, node.name), do: "btn-active btn-primary", else: "btn-ghost"}"}
      >
        {node.name}
      </button>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
