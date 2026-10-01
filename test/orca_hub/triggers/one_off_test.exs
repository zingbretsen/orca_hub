defmodule OrcaHub.Triggers.OneOffTest do
  @moduledoc """
  Pure coverage for one-off trigger timing (`OrcaHub.Triggers.OneOff`) and
  the `type: "once"` changeset rules on `OrcaHub.Triggers.Trigger`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Triggers.{OneOff, Trigger}

  @now ~U[2026-10-01 12:00:00Z]

  describe "parse_delay/1" do
    test "single units and aliases" do
      assert OneOff.parse_delay("4h") == {:ok, 4 * 3600}
      assert OneOff.parse_delay("3 days") == {:ok, 3 * 86_400}
      assert OneOff.parse_delay("90m") == {:ok, 90 * 60}
      assert OneOff.parse_delay("2 weeks") == {:ok, 14 * 86_400}
      assert OneOff.parse_delay("1 year") == {:ok, 365 * 86_400}
      assert OneOff.parse_delay("30 SECONDS") == {:ok, 30}
    end

    test "months are a fixed 30 days, so fractions are meaningful" do
      assert OneOff.parse_delay("2.5 months") == {:ok, 75 * 86_400}
      assert OneOff.parse_delay("1mo") == {:ok, 30 * 86_400}
    end

    test "segments are summed" do
      assert OneOff.parse_delay("1 day 6 hours") == {:ok, 86_400 + 6 * 3600}
      assert OneOff.parse_delay("1d, 2h and 30m") == {:ok, 86_400 + 2 * 3600 + 30 * 60}
    end

    test "rejects junk, unknown units, and zero" do
      assert {:error, _} = OneOff.parse_delay("soon")
      assert {:error, _} = OneOff.parse_delay("3 fortnights")
      assert {:error, _} = OneOff.parse_delay("3 days from now")
      assert {:error, _} = OneOff.parse_delay("0h")
      assert {:error, _} = OneOff.parse_delay("")
    end
  end

  describe "parse_run_at/1" do
    test "an explicit offset is used as-is" do
      assert OneOff.parse_run_at("2026-12-15T09:00:00-05:00") == {:ok, ~U[2026-12-15 14:00:00Z]}
      assert OneOff.parse_run_at("2026-12-15T09:00:00Z") == {:ok, ~U[2026-12-15 09:00:00Z]}
    end

    test "naive input is America/New_York local time (DST-aware)" do
      # December: EST, UTC-5
      assert OneOff.parse_run_at("2026-12-15T09:00:00") == {:ok, ~U[2026-12-15 14:00:00Z]}
      assert OneOff.parse_run_at("2026-12-15T09:00") == {:ok, ~U[2026-12-15 14:00:00Z]}
      # July: EDT, UTC-4
      assert OneOff.parse_run_at("2027-07-01T09:00:00") == {:ok, ~U[2027-07-01 13:00:00Z]}
    end

    test "a bare date means 09:00 local" do
      assert OneOff.parse_run_at("2026-12-15") == {:ok, ~U[2026-12-15 14:00:00Z]}
    end

    test "rejects unparseable input" do
      assert {:error, msg} = OneOff.parse_run_at("next tuesday")
      assert msg =~ "ISO8601"
    end
  end

  describe "resolve/2" do
    test "delay is relative to now" do
      assert OneOff.resolve(%{"delay" => "2.5 months"}, @now) ==
               {:ok, ~U[2026-12-15 12:00:00Z]}
    end

    test "run_at wins the branch when it is the only one given" do
      assert OneOff.resolve(%{"run_at" => "2026-12-15T09:00:00Z"}, @now) ==
               {:ok, ~U[2026-12-15 09:00:00Z]}
    end

    test "both or neither is an error" do
      assert {:error, msg} = OneOff.resolve(%{"run_at" => "2026-12-15", "delay" => "1d"}, @now)
      assert msg =~ "not both"
      assert {:error, msg} = OneOff.resolve(%{}, @now)
      assert msg =~ "required"
    end
  end

  describe "Trigger.changeset/2 for type once" do
    defp attrs(extra) do
      Map.merge(
        %{name: "r", prompt: "p", project_id: Ecto.UUID.generate(), type: "once"},
        extra
      )
    end

    test "requires run_at" do
      cs = Trigger.changeset(%Trigger{}, attrs(%{}))
      assert %{run_at: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects a run_at in the past" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      cs = Trigger.changeset(%Trigger{}, attrs(%{run_at: past}))
      assert %{run_at: ["must be in the future"]} = errors_on(cs)
    end

    test "accepts a future run_at and needs no cron expression" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      cs = Trigger.changeset(%Trigger{}, attrs(%{run_at: future}))
      assert cs.valid?
    end

    test "an update that leaves a now-past run_at alone still validates" do
      existing = %Trigger{
        type: "once",
        name: "r",
        prompt: "p",
        project_id: Ecto.UUID.generate(),
        run_at: ~U[2020-01-01 00:00:00Z]
      }

      cs = Trigger.changeset(existing, %{enabled: false, last_fired_at: DateTime.utc_now()})
      assert cs.valid?
    end
  end
end
