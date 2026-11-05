defmodule OrcaHubWeb.IdleBadgeLiveTest do
  @moduledoc """
  The Queue link's idle-session badge is rendered twice by the layout
  (desktop nav, mobile menu). Only the desktop ("primary") instance may
  subscribe to `"sessions"` and count; the mobile ("mirror") one is fed by
  it, and the two must always show the same number.
  """

  # async: false — the badges are sticky LiveView processes that query the
  # shared dev DB in shared sandbox mode, and the count is global.
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.Sessions

  @count_sql ~s|SELECT count(s0."id") FROM "sessions"|

  defp badges(view) do
    children = live_children(view)

    {Enum.find(children, &(&1.id == "idle-badge-desktop")),
     Enum.find(children, &(&1.id == "idle-badge-mobile"))}
  end

  defp badge_text(badge), do: badge |> render() |> Floki.parse_fragment!() |> Floki.text()

  # Idle-count queries, from any process, while `fun` runs.
  defp count_queries(fun) do
    me = self()
    ref = make_ref()

    :telemetry.attach(
      {ref, __MODULE__},
      [:orca_hub, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if String.starts_with?(meta.query, @count_sql) and meta.query =~ "'idle'",
          do: send(me, {ref, self()})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach({ref, __MODULE__})
    {result, drain(ref, [])}
  end

  defp drain(ref, pids) do
    receive do
      {^ref, pid} -> drain(ref, [pid | pids])
    after
      0 -> pids
    end
  end

  defp mirrors?(desktop, mobile, attempts \\ 40) do
    cond do
      badge_text(mobile) == badge_text(desktop) -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && mirrors?(desktop, mobile, attempts - 1)
    end
  end

  defp new_idle_session do
    {:ok, session} =
      Sessions.create_session(%{
        directory: System.tmp_dir!(),
        status: "idle",
        runner_node: Atom.to_string(node())
      })

    session
  end

  test "only the desktop instance subscribes to sessions; a page load counts twice, not four times",
       %{conn: conn} do
    new_idle_session()

    {{:ok, view, _html}, counts} = count_queries(fn -> live(conn, ~p"/usage") end)
    {desktop, mobile} = badges(view)
    assert desktop && mobile

    # One count on the dead render, one on the connected mount, both by the
    # primary. Before: each instance counted on both passes.
    assert length(counts) == 2

    subscribers = OrcaHub.PubSub |> Registry.lookup("sessions") |> Enum.map(&elem(&1, 0))
    assert desktop.pid in subscribers
    refute mobile.pid in subscribers

    # The mirror got its number from the primary, not from a query. Its
    # hello and the primary's reply are asynchronous, so wait for it.
    assert mirrors?(desktop, mobile)
    assert badge_text(desktop) =~ ~r/^\s*\d+\s*$/
  end

  test "a status change costs one count, and both badges follow it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/usage")
    {desktop, mobile} = badges(view)

    before =
      badge_text(desktop)
      |> String.trim()
      |> then(&if(&1 == "", do: 0, else: String.to_integer(&1)))

    session = new_idle_session()

    {_, counts} =
      count_queries(fn ->
        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :idle}})
        # Sync on both processes: the primary handles the broadcast, then the
        # mirror handles the count the primary shared.
        _ = render(desktop)
        _ = render(mobile)
      end)

    assert counts == [desktop.pid]

    expected = Integer.to_string(before + 1)
    assert String.trim(badge_text(desktop)) == expected
    assert String.trim(badge_text(mobile)) == expected
  end
end
