defmodule OrcaHubWeb.UsageLive do
  use OrcaHubWeb, :live_view

  # OrcaHub.Claude.Usage.fetch/0 shells out to `claude -p 'hi'` to refresh an
  # expired OAuth token before it can even ask the API for usage — up to
  # ~4.3s per CLI invocation, observed at ~8.7s total (two invocations) on a
  # hub whose stored credential is permanently expired
  # (perf_audit_projects_queue.md §1). Off the synchronous mount/event path
  # via start_async, same pattern as SessionLive.Show's commits panel:
  # @usage/@error start nil, @loading paints a spinner, and the real result
  # fills in (or fails) once the async fetch lands — first paint never waits
  # on it.
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Usage", usage: nil, error: nil, loading: false)
     |> fetch_usage()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_usage(socket)}
  end

  @impl true
  def handle_async(:usage, {:ok, result}, socket) do
    socket =
      case result do
        {:ok, usage} -> assign(socket, usage: usage, error: nil)
        {:error, reason} -> assign(socket, usage: nil, error: reason)
      end

    {:noreply, assign(socket, loading: false)}
  end

  def handle_async(:usage, {:exit, reason}, socket) do
    {:noreply, assign(socket, usage: nil, error: {:crashed, reason}, loading: false)}
  end

  defp fetch_usage(socket) do
    if connected?(socket) do
      socket
      |> assign(loading: true)
      |> start_async(:usage, usage_fetcher())
    else
      socket
    end
  end

  # Test seam (mirrors OrcaHub.BackendInstaller's :npm_executable/etc.
  # pattern) — real callers always get OrcaHub.Claude.Usage.fetch/0, tests
  # swap in a fast stub instead of shelling out to `claude`/`curl`.
  defp usage_fetcher,
    do: Application.get_env(:orca_hub, :usage_fetcher, &OrcaHub.Claude.Usage.fetch/0)

  # `{:credential_expired, _}` is OrcaHub.Claude.Usage's tag for "the stored
  # OAuth token is bad and the CLI-driven refresh to fix it also failed" —
  # an operational re-login problem, not a transient/generic failure. Every
  # other reason shape (CLI missing, credentials file missing, network/parse
  # error) falls back to a plain inspect.
  defp error_message({:credential_expired, cli_reason}) do
    "Claude OAuth credential is expired on this node and could not be refreshed automatically " <>
      "(#{inspect(cli_reason)}). Someone needs to re-login (Claude login) on this node — see its " <>
      "page under Nodes — then click Refresh."
  end

  defp error_message(reason), do: inspect(reason)

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

    <div :if={@loading} class="flex items-center gap-2 text-sm text-base-content/50 p-4">
      <span class="loading loading-spinner loading-xs" /> Loading usage&hellip;
    </div>

    <div
      :if={@error && !@loading}
      id="usage-error"
      class={"alert #{if match?({:credential_expired, _}, @error), do: "alert-warning", else: "alert-error"}"}
    >
      {error_message(@error)}
    </div>

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
