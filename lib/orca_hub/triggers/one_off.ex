defmodule OrcaHub.Triggers.OneOff do
  @moduledoc """
  Resolves when a one-off (`type: "once"`) trigger should fire, from either
  an absolute `run_at` or a relative `delay`.

  ## `run_at`

  ISO8601. An explicit offset (`2026-12-15T09:00:00-05:00`, `...Z`) is taken
  as-is. A NAIVE datetime (`2026-12-15T09:00`) or a bare date (`2026-12-15`,
  meaning 09:00) is interpreted in `America/New_York`, the user's local
  zone — the same zone the message feed renders timestamps in. A local time
  that falls in a DST gap resolves to the instant just after the gap; an
  ambiguous one (fall-back hour) resolves to the earlier instant.

  ## `delay`

  One or more `<number><unit>` segments, summed: `"2.5 months"`, `"3 days"`,
  `"4h"`, `"1 day 6 hours"`, `"90m"`. Fractions are allowed. Units:

    * `s`, `sec(s)`, `second(s)`
    * `m`, `min(s)`, `minute(s)` — NOTE `m` is minutes, not months
    * `h`, `hr(s)`, `hour(s)`
    * `d`, `day(s)`
    * `w`, `wk(s)`, `week(s)`
    * `mo`, `mos`, `month(s)` — a FIXED 30 days, so fractions are meaningful
      ("2.5 months" = 75 days) rather than a calendar shift
    * `y`, `yr(s)`, `year(s)` — a fixed 365 days

  Results are truncated to the second (the column is `:utc_datetime`).
  """

  @local_tz "America/New_York"

  @unit_seconds %{
    "s" => 1,
    "sec" => 1,
    "secs" => 1,
    "second" => 1,
    "seconds" => 1,
    "m" => 60,
    "min" => 60,
    "mins" => 60,
    "minute" => 60,
    "minutes" => 60,
    "h" => 3600,
    "hr" => 3600,
    "hrs" => 3600,
    "hour" => 3600,
    "hours" => 3600,
    "d" => 86_400,
    "day" => 86_400,
    "days" => 86_400,
    "w" => 604_800,
    "wk" => 604_800,
    "wks" => 604_800,
    "week" => 604_800,
    "weeks" => 604_800,
    "mo" => 2_592_000,
    "mos" => 2_592_000,
    "month" => 2_592_000,
    "months" => 2_592_000,
    "y" => 31_536_000,
    "yr" => 31_536_000,
    "yrs" => 31_536_000,
    "year" => 31_536_000,
    "years" => 31_536_000
  }

  @segment ~r/(\d+(?:\.\d+)?|\.\d+)\s*([a-z]+)/

  def local_tz, do: @local_tz

  @doc """
  Resolve tool-style args (`"run_at"` or `"delay"`, exactly one) to a UTC
  `DateTime`, relative to `now` for a delay.
  """
  def resolve(args, now \\ DateTime.utc_now())

  def resolve(%{"run_at" => run_at, "delay" => delay}, _now)
      when is_binary(run_at) and run_at != "" and is_binary(delay) and delay != "" do
    {:error, "Pass either run_at or delay, not both."}
  end

  def resolve(%{"run_at" => run_at}, _now) when is_binary(run_at) and run_at != "",
    do: parse_run_at(run_at)

  def resolve(%{"delay" => delay}, now) when is_binary(delay) and delay != "" do
    with {:ok, seconds} <- parse_delay(delay) do
      {:ok, now |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)}
    end
  end

  def resolve(_args, _now), do: {:error, "Either run_at or delay is required."}

  @doc "Parse a relative delay string into a positive whole number of seconds."
  def parse_delay(delay) when is_binary(delay) do
    normalized = delay |> String.downcase() |> String.trim()
    segments = Regex.scan(@segment, normalized)
    leftover = normalized |> String.replace(@segment, "") |> String.replace(~r/[\s,]|and/, "")

    cond do
      segments == [] or leftover != "" ->
        {:error, "Could not parse delay #{inspect(delay)} (expected e.g. \"3 days\", \"4h\")."}

      true ->
        Enum.reduce_while(segments, {:ok, 0}, fn [_, number, unit], {:ok, acc} ->
          case Map.fetch(@unit_seconds, unit) do
            {:ok, unit_seconds} -> {:cont, {:ok, acc + parse_number(number) * unit_seconds}}
            :error -> {:halt, {:error, "Unknown time unit #{inspect(unit)} in delay."}}
          end
        end)
        |> case do
          {:ok, total} when total >= 1 -> {:ok, round(total)}
          {:ok, _} -> {:error, "Delay must be at least one second."}
          error -> error
        end
    end
  end

  @doc """
  Parse an ISO8601 `run_at` into a UTC `DateTime`; naive input (or a bare
  date, meaning 09:00) is local time in `local_tz/0`.
  """
  def parse_run_at(run_at) when is_binary(run_at) do
    # Elixir's ISO8601 parsers require seconds; accept "HH:MM" (what a
    # datetime-local input submits) by padding ":00" before any zone suffix.
    run_at = run_at |> String.trim() |> String.replace(~r/(T\d{2}:\d{2})(?=$|Z|[+-])/, "\\1:00")

    case DateTime.from_iso8601(run_at) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.truncate(dt, :second)}

      {:error, _} ->
        with {:error, _} <- NaiveDateTime.from_iso8601(run_at),
             {:error, _} <- date_at_nine(run_at) do
          {:error,
           "Could not parse run_at #{inspect(run_at)} (expected ISO8601, e.g. " <>
             "\"2026-12-15T09:00:00-05:00\" or \"2026-12-15T09:00\" in #{@local_tz})."}
        else
          {:ok, naive} -> local_to_utc(naive)
        end
    end
  end

  @doc """
  Parse an "ends on" value. Like `parse_run_at/1`, except a bare date means
  the END of that local day (23:59:59), the way a calendar app's "ends on
  Dec 15" still includes Dec 15.
  """
  def parse_end_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date |> NaiveDateTime.new!(~T[23:59:59]) |> local_to_utc()
      {:error, _} -> parse_run_at(value)
    end
  end

  @doc "Interpret a naive local (`local_tz/0`) datetime as a UTC `DateTime`."
  def local_to_utc(%NaiveDateTime{} = naive) do
    case DateTime.from_naive(naive, @local_tz) do
      {:ok, dt} -> {:ok, to_utc(dt)}
      {:ambiguous, first, _second} -> {:ok, to_utc(first)}
      {:gap, _before, just_after} -> {:ok, to_utc(just_after)}
      {:error, reason} -> {:error, "Could not resolve local time: #{inspect(reason)}"}
    end
  end

  @doc "Render a UTC `DateTime` in `local_tz/0`, e.g. for a tool reply."
  def to_local(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, @local_tz) do
      {:ok, local} -> local
      _ -> dt
    end
  end

  defp to_utc(dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  defp date_at_nine(string) do
    with {:ok, date} <- Date.from_iso8601(string) do
      NaiveDateTime.new(date, ~T[09:00:00])
    end
  end

  defp parse_number("." <> _ = number), do: parse_number("0" <> number)

  defp parse_number(number) do
    {value, ""} = Float.parse(number)
    value
  end
end
