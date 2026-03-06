defmodule OrcaHubWeb.UsageLive do
  use OrcaHubWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Usage") |> fetch_usage()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_usage(socket)}
  end

  defp fetch_usage(socket) do
    case OrcaHub.Claude.Usage.fetch() do
      {:ok, usage} -> assign(socket, usage: usage, error: nil)
      {:error, reason} -> assign(socket, usage: nil, error: reason)
    end
  end

  defp bar_color(pct) when pct >= 80, do: "progress-error"
  defp bar_color(pct) when pct >= 50, do: "progress-warning"
  defp bar_color(_pct), do: "progress-success"

  defp format_reset_time(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(dt, DateTime.utc_now(), :minute)

        cond do
          diff <= 0 -> "now"
          diff < 60 -> "in #{diff}m"
          diff < 1440 -> "in #{div(diff, 60)}h #{rem(diff, 60)}m"
          true -> "in #{div(diff, 1440)}d #{div(rem(diff, 1440), 60)}h"
        end

      _ ->
        iso_string
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Usage
      <:actions>
        <button phx-click="refresh" class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
      </:actions>
    </.header>

    <div :if={@error} class="alert alert-error">{inspect(@error)}</div>

    <div :if={@usage} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <.usage_card
        :if={@usage.session}
        label="Session"
        subtitle="5-hour window"
        window={@usage.session}
      />
      <.usage_card
        :if={@usage.weekly}
        label="Weekly"
        subtitle="7-day window"
        window={@usage.weekly}
      />
    </div>
    """
  end

  defp usage_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-5 gap-3">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="font-semibold">{@label}</h3>
            <p class="text-xs text-base-content/50">{@subtitle}</p>
          </div>
          <span class="text-2xl font-bold">{Float.round(@window.utilization, 1)}%</span>
        </div>
        <progress
          class={"progress #{bar_color(@window.utilization)} w-full"}
          value={@window.utilization}
          max="100"
        />
        <p class="text-xs text-base-content/50">
          Resets {format_reset_time(@window.resets_at)}
        </p>
      </div>
    </div>
    """
  end
end
