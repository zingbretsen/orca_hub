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

  defp nav_links do
    [
      %{href: ~p"/queue", label: "Queue", badge: true},
      %{href: ~p"/projects", label: "Projects"},
      %{href: ~p"/issues", label: "Issues"},
      %{href: ~p"/triggers", label: "Triggers"},
      %{href: ~p"/terminals", label: "Terminals"},
      %{href: ~p"/sessions", label: "Sessions"},
      %{href: ~p"/usage", label: "Usage"},
      %{href: ~p"/settings", label: "Settings"}
    ]
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
    assigns = assign(assigns, :nav_links, nav_links())

    ~H"""
    <header class="flex items-center gap-2 px-4 py-2 sm:px-6 lg:px-8">
      <a href="/" class="flex items-center gap-2 font-semibold">
        <img src={~p"/images/logo.png"} alt="OrcaHub" class="h-8 w-auto" />
        OrcaHub
      </a>

      <nav class="hidden md:flex items-center gap-1 ml-4 mr-auto">
        <a :for={link <- @nav_links} href={link.href} class="btn btn-ghost btn-sm">
          {link.label}
          <.idle_badge :if={link[:badge]} socket={@socket} id="idle-badge-desktop" />
        </a>
      </nav>

      <div class="hidden md:flex items-center gap-2 ml-auto">
        <.node_filter_dropdown
          :if={assigns[:node_filter_visible]}
          nodes={assigns[:node_filter_nodes] || []}
          filter={assigns[:node_filter] || :all}
        />
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
        <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-200 rounded-box w-52">
          <li :for={link <- @nav_links}>
            <a href={link.href}>
              {link.label}
              <.idle_badge :if={link[:badge]} socket={@socket} id="idle-badge-mobile" />
            </a>
          </li>
          <li :if={assigns[:node_filter_visible]} class="menu-title text-xs uppercase opacity-60 mt-2">Nodes</li>
          <li :if={assigns[:node_filter_visible]}>
            <.node_filter_items
              nodes={assigns[:node_filter_nodes] || []}
              filter={assigns[:node_filter] || :all}
            />
          </li>
          <li class="menu-title text-xs uppercase opacity-60 mt-2">Theme</li>
          <li><.theme_toggle /></li>
        </ul>
      </div>
    </header>

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

  defp node_filter_dropdown(assigns) do
    ~H"""
    <div id="node-filter" phx-hook="NodeFilter" class="dropdown dropdown-end">
      <div tabindex="0" role="button" class={"btn btn-sm gap-1 #{if @filter == :all, do: "btn-ghost", else: "btn-soft btn-primary"}"}>
        <.icon name="hero-server-stack-micro" class="size-4" />
        <span class="text-xs">
          <%= if @filter == :all do %>
            All nodes
          <% else %>
            {MapSet.size(@filter)}/{length(@nodes)} nodes
          <% end %>
        </span>
        <.icon name="hero-chevron-down-micro" class="size-3" />
      </div>
      <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-200 rounded-box w-56">
        <li>
          <button phx-click="node_filter_select_all" class="flex items-center gap-2">
            <span class={"size-4 flex items-center justify-center #{if @filter == :all, do: "text-primary", else: "opacity-0"}"}>
              <.icon name="hero-check-micro" class="size-4" />
            </span>
            All nodes
          </button>
        </li>
        <li class="menu-title text-xs uppercase opacity-60">Nodes</li>
        <li :for={node <- @nodes}>
          <button phx-click="toggle_node_filter" phx-value-node={node.name} class="flex items-center gap-2">
            <span class={"size-4 flex items-center justify-center #{if OrcaHubWeb.NodeFilter.node_selected?(@filter, node.name), do: "text-primary", else: "opacity-0"}"}>
              <.icon name="hero-check-micro" class="size-4" />
            </span>
            {node.name}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp node_filter_items(assigns) do
    ~H"""
    <div id="node-filter-mobile" phx-hook="NodeFilter" class="flex flex-col gap-1">
      <button phx-click="node_filter_select_all" class={"btn btn-xs gap-1 #{if @filter == :all, do: "btn-active", else: "btn-ghost"}"}>
        <.icon :if={@filter == :all} name="hero-check-micro" class="size-3" />
        All nodes
      </button>
      <button
        :for={node <- @nodes}
        phx-click="toggle_node_filter"
        phx-value-node={node.name}
        class={"btn btn-xs gap-1 #{if OrcaHubWeb.NodeFilter.node_selected?(@filter, node.name), do: "btn-active", else: "btn-ghost"}"}
      >
        <.icon :if={OrcaHubWeb.NodeFilter.node_selected?(@filter, node.name)} name="hero-check-micro" class="size-3" />
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
