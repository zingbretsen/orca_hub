defmodule OrcaHubWeb.MessageComponentsTimestampTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OrcaHubWeb.MessageComponents

  @now ~U[2026-10-28 12:00:00Z]

  describe "format_timestamp/2" do
    test "current year omits the year" do
      assert %{text: "Oct 28, 3:04 PM"} =
               MessageComponents.format_timestamp(~N[2026-10-28 19:04:12], @now)
    end

    test "other year includes the year" do
      assert %{text: "Oct 28, 2025, 3:04 PM"} =
               MessageComponents.format_timestamp(~N[2025-10-28 19:04:12], @now)
    end

    test "year is compared in New York time" do
      # 2027-01-01 02:00 UTC is still 2026-12-31 in New York.
      assert %{text: "Dec 31, 9:00 PM"} =
               MessageComponents.format_timestamp(~N[2027-01-01 02:00:00], @now)
    end

    test "title has the full form and datetime is ISO 8601 UTC" do
      assert %{
               title: "Wednesday, October 28, 2026 3:04:12 PM EDT",
               datetime: "2026-10-28T19:04:12Z"
             } = MessageComponents.format_timestamp(~N[2026-10-28 19:04:12], @now)
    end

    test "non-NaiveDateTime input gives nil" do
      assert MessageComponents.format_timestamp("2026-10-28", @now) == nil
      assert MessageComponents.format_timestamp(nil, @now) == nil
    end
  end

  describe "timestamp/1" do
    test "renders a time element with title and datetime" do
      html = render_component(&MessageComponents.timestamp/1, value: ~N[2020-10-28 19:04:12])

      assert html =~ "<time"
      assert html =~ "Oct 28, 2020, 3:04 PM"
      assert html =~ ~s(datetime="2020-10-28T19:04:12Z")
      assert html =~ ~s(title="Wednesday, October 28, 2020 3:04:12 PM EDT")
    end

    test "renders nothing for a non-NaiveDateTime value" do
      html = render_component(&MessageComponents.timestamp/1, value: "nope")
      refute html =~ "<time"
    end
  end
end
