defmodule OrcaHub.ProcessIsolation.Limits do
  @moduledoc """
  Resolves the `:agent_isolation` limit settings (config/runtime.exs, the
  `ORCA_AGENT*` / `ORCA_BEAM_MEMORY_LOW` env vars) into the values
  `OrcaHub.ProcessIsolation.Cgroup` writes to cgroupfs.

  A size is bytes, a number with a binary `K`/`M`/`G`/`T` suffix
  (`512M`, `1.5G`), `max`, or a percentage. A percentage is of the
  service's own budget: the delegated unit's `memory.max` (its systemd
  `MemoryMax=`) when it has one, otherwise host RAM. Defaults:

    * `agents_memory_max` 80%: every agent CLI tree together. Whatever is
      left of the unit's MemoryMax belongs to the BEAM (and whatever it
      spawns itself: start_job jobs, terminals, git), so an agent runaway
      is OOM-killed inside `agents/` before the unit-level OOM killer can
      pick the BEAM.
    * `agent_memory_max` 60%: one spawn's tree, so a single runaway is
      killed inside its own leaf and always leaves its siblings headroom.
    * `agent_swap_max` 0: per spawn AND for `agents/` as a whole. Swap is
      what turned 2026-10-11's runaway build into an 11-hour stall instead
      of an OOM kill; with none, the kernel kills as soon as reclaim fails.
    * `agent_pids_max` 8192 tasks (threads count) per spawn: fork-bomb
      insurance far above what a 20-job cargo build or headless Chrome uses.
    * `beam_memory_low` 1G: reclaim protection for the BEAM's own cgroup
      when the unit nears its MemoryMax.

  `memory.high` is deliberately never set: a soft limit far below the hard
  one is exactly what stalled gb10.

  An unparseable value falls back to its default with a warning in
  `warnings`; nothing here raises.
  """

  @defaults [
    agents_memory_max: "80%",
    agent_memory_max: "60%",
    agent_swap_max: "0",
    agent_pids_max: "8192",
    beam_memory_low: "1G"
  ]

  @size_keys [:agents_memory_max, :agent_memory_max, :agent_swap_max, :beam_memory_low]

  defstruct [
    :base,
    :agents_memory_max,
    :agent_memory_max,
    :agent_swap_max,
    :agent_pids_max,
    :beam_memory_low,
    warnings: []
  ]

  @type value :: non_neg_integer() | :max
  @type t :: %__MODULE__{
          base: pos_integer() | nil,
          agents_memory_max: value(),
          agent_memory_max: value(),
          agent_swap_max: value(),
          agent_pids_max: value(),
          beam_memory_low: value(),
          warnings: [String.t()]
        }

  @doc "The default spec for every limit key."
  def defaults, do: @defaults

  @doc """
  Resolves every limit from `config` (the `:agent_isolation` keyword list;
  `nil`/`""` means the default) against `base`, the byte budget percentages
  are taken of. `base` may be `nil` when it is unknowable, in which case a
  percentage resolves to `:max` with a warning.
  """
  @spec resolve(keyword(), pos_integer() | nil) :: t()
  def resolve(config, base) do
    {sizes, warnings} =
      Enum.map_reduce(@size_keys, [], fn key, warnings ->
        {value, warnings} = resolve_size(key, Keyword.get(config, key), base, warnings)
        {{key, value}, warnings}
      end)

    {pids, warnings} = resolve_pids(Keyword.get(config, :agent_pids_max), warnings)

    struct!(
      __MODULE__,
      sizes ++ [agent_pids_max: pids, base: base, warnings: Enum.reverse(warnings)]
    )
  end

  defp resolve_size(key, raw, base, warnings) do
    default = Keyword.fetch!(@defaults, key)

    {spec, warnings} =
      case parse_size(raw) do
        :default ->
          {parse_size(default), warnings}

        :error ->
          {parse_size(default),
           ["#{key}=#{inspect(raw)} is not a size; using the default #{default}" | warnings]}

        parsed ->
          {parsed, warnings}
      end

    case spec do
      {:percent, pct} when is_integer(base) ->
        {trunc(base * pct / 100), warnings}

      {:percent, _pct} ->
        {:max, ["#{key} is a percentage but the memory budget is unknown; using max" | warnings]}

      {:ok, value} ->
        {value, warnings}
    end
  end

  defp resolve_pids(raw, warnings) do
    default = Keyword.fetch!(@defaults, :agent_pids_max)

    case parse_count(raw) do
      :default ->
        {elem(parse_count(default), 1), warnings}

      {:ok, value} ->
        {value, warnings}

      :error ->
        {elem(parse_count(default), 1),
         [
           "agent_pids_max=#{inspect(raw)} is not a count; using the default #{default}"
           | warnings
         ]}
    end
  end

  @doc """
  Parses one size spec: `:default` for nil/blank, `{:ok, bytes | :max}`,
  `{:percent, number}`, or `:error`.
  """
  def parse_size(nil), do: :default

  def parse_size(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def parse_size(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :default

      String.downcase(value) in ["max", "infinity"] ->
        {:ok, :max}

      match = Regex.run(~r/\A(\d+(?:\.\d+)?)\s*%\z/, value) ->
        [_, number] = match
        pct = parse_number(number)
        if pct <= 100, do: {:percent, pct}, else: :error

      match = Regex.run(~r/\A(\d+(?:\.\d+)?)\s*([kmgt]?)(?:i?b)?\z/i, value) ->
        [_, number, unit] = match
        {:ok, trunc(parse_number(number) * multiplier(String.downcase(unit)))}

      true ->
        :error
    end
  end

  def parse_size(_), do: :error

  defp parse_count(nil), do: :default
  defp parse_count(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_count(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :default

      String.downcase(value) in ["max", "infinity"] ->
        {:ok, :max}

      Regex.match?(~r/\A\d+\z/, value) and String.to_integer(value) > 0 ->
        {:ok, String.to_integer(value)}

      true ->
        :error
    end
  end

  defp parse_count(_), do: :error

  defp parse_number(number) do
    case Integer.parse(number) do
      {int, ""} -> int
      _ -> String.to_float(number)
    end
  end

  defp multiplier(""), do: 1
  defp multiplier("k"), do: 1024
  defp multiplier("m"), do: 1024 * 1024
  defp multiplier("g"), do: 1024 * 1024 * 1024
  defp multiplier("t"), do: 1024 * 1024 * 1024 * 1024

  @doc "The string cgroupfs expects for a resolved value."
  def to_cgroup(:max), do: "max"
  def to_cgroup(value) when is_integer(value), do: Integer.to_string(value)

  @doc "Human-readable rendering for logs: `max`, or GiB/MiB with one decimal."
  def format(:max), do: "max"

  def format(bytes) when is_integer(bytes) and bytes >= 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)}G"

  def format(bytes) when is_integer(bytes) and bytes >= 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)}M"

  def format(value) when is_integer(value), do: Integer.to_string(value)
end
