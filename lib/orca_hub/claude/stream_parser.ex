defmodule OrcaHub.Claude.StreamParser do
  @moduledoc """
  Parses NDJSON data with buffering for incomplete lines.
  """

  @ansi_regex ~r/\e\[[^\e]*?[a-zA-Z]|\e\][^\a]*?\a/

  @doc """
  Parses incoming data combined with an existing buffer.

  Returns `{parsed_events, new_buffer}`.
  """
  @spec parse(String.t(), String.t()) :: {[map()], String.t()}
  def parse(data, buffer \\ "") do
    combined = buffer <> data
    lines = String.split(combined, "\n")

    {complete, [remainder]} = Enum.split(lines, -1)

    events =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&strip_ansi/1)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, decoded} -> [decoded]
          {:error, _} -> []
        end
      end)

    {events, remainder}
  end

  defp strip_ansi(str) do
    Regex.replace(@ansi_regex, str, "")
  end
end
