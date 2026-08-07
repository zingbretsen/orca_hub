defmodule OrcaHubWeb.UsageLiveTest do
  @moduledoc """
  LiveView coverage for `/usage`: OrcaHub.Claude.Usage.fetch/0 shells out to
  `claude -p 'hi'`/`curl` for real, so every test here swaps in a fast stub
  via the `:orca_hub, :usage_fetcher` Application env seam (mirrors
  `OrcaHub.BackendInstaller`'s executable-override pattern) instead of
  hitting a real CLI or the Anthropic API.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    original = Application.get_env(:orca_hub, :usage_fetcher)

    on_exit(fn ->
      if original,
        do: Application.put_env(:orca_hub, :usage_fetcher, original),
        else: Application.delete_env(:orca_hub, :usage_fetcher)
    end)

    :ok
  end

  defp stub_fetcher(fun), do: Application.put_env(:orca_hub, :usage_fetcher, fun)

  test "first paint doesn't wait on the fetch; usage fills in once it resolves" do
    stub_fetcher(fn ->
      {:ok,
       %OrcaHub.Claude.Usage{
         session: %{utilization: 12.3, resets_at: "2099-01-01T00:00:00Z"},
         weekly: %{utilization: 45.0, resets_at: "2099-01-08T00:00:00Z"}
       }}
    end)

    {:ok, view, html} = live(build_conn(), ~p"/usage")

    # The disconnected/dead render never had the stub's chance to run.
    refute html =~ "12.3"

    rendered = render_async(view)
    assert rendered =~ "12.3"
    assert rendered =~ "45.0"
    assert rendered =~ "Session"
    assert rendered =~ "Weekly"
    refute rendered =~ "Loading usage"
  end

  test "surfaces an expired-credential failure with a distinct, actionable message" do
    stub_fetcher(fn -> {:error, {:credential_expired, {:refresh_cli_exit, 1}}} end)

    {:ok, view, _html} = live(build_conn(), ~p"/usage")

    render_async(view)
    assert has_element?(view, "#usage-error.alert-warning", "expired")
    assert has_element?(view, "#usage-error", "re-login")
    refute has_element?(view, "#usage-error.alert-error")
  end

  test "falls back to a generic error for non-credential failures" do
    stub_fetcher(fn -> {:error, :claude_not_found} end)

    {:ok, view, _html} = live(build_conn(), ~p"/usage")

    render_async(view)
    assert has_element?(view, "#usage-error.alert-error", "claude_not_found")
    refute has_element?(view, "#usage-error", "re-login")
  end

  test "clicking Refresh re-runs the fetch" do
    counter = :counters.new(1, [])

    stub_fetcher(fn ->
      :counters.add(counter, 1, 1)
      {:ok, %OrcaHub.Claude.Usage{session: nil, weekly: nil}}
    end)

    {:ok, view, _html} = live(build_conn(), ~p"/usage")
    render_async(view)
    assert :counters.get(counter, 1) == 1

    view |> element("button", "Refresh") |> render_click()
    render_async(view)
    assert :counters.get(counter, 1) == 2
  end
end
