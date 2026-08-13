defmodule OrcaHub.ForkGate.ServingProfile do
  @moduledoc """
  Per-node serving-profile knobs for pi session forking (pi_fork_spec.md §9).

  §9 splits the fork feature in two: the engine-agnostic bulk (the
  `fork_from_parent` surface, `--fork` mechanics, prompt determinism, the
  UI/DB treatment) and a small llama.cpp-specific slice — first-turn
  SERIALIZATION (§6), the cache-MISS threshold (§6.1), and the unified-KV
  BUDGET guard (§7). Those three are properties of *what serves the tokens*,
  not of forking, so they live here rather than being hardcoded at their use
  sites: a vLLM cutover (whose automatic prefix caching shares KV blocks
  across concurrent requests, so §1's 1-warm + N−1-cold pathology doesn't
  exist) turns serialization off by CONFIGURATION, without touching
  `OrcaHub.ForkGate` or the spawn path.

  ## Profiles

    * `:llama_cpp` (default) — the gb10 posture the spec measured against.
      Serialize first turns, detect misses at >25% fresh input, pause the
      remaining fan-out on a detected miss.
    * `:vllm` — serialization off, miss detection still ON (§9: "miss
      detection stays useful as a cheap assertion") but non-blocking: a miss
      warns without pausing, since there is no serialized queue to pause.

  ## Selection + overrides

  Profile choice is per-node, so the env var wins over app config:

      ORCA_FORK_SERVING_PROFILE=vllm          # profile name
      ORCA_FORK_RELEASE_TIMEOUT_MS=600000     # individual knob overrides
      ORCA_FORK_MISS_RATIO=0.25
      ORCA_FORK_PAUSE_ON_MISS=false
      ORCA_FORK_SERIALIZE=false
      ORCA_FORK_KV_BUDGET=262144

  ...then `config :orca_hub, :fork_serving_profile, :vllm` (and
  `:fork_serving_profile_overrides`, a map of the same keys, for tests), then
  the built-in profile defaults. Everything is resolved at CALL time (no
  caching): a knob flipped in `Application.put_env/3` takes effect on the
  next fork, which is what makes these testable and operator-tunable without
  a redeploy.

  `ORCA_FORK_KV_BUDGET` predates this module (§7's soft guard in
  `OrcaHub.MCP.Tools.Sessions`) and is kept as-is for back-compat — that
  guard now reads `kv_budget/0` so both halves of the llama.cpp-specific
  slice have one home.
  """

  require Logger

  @profiles %{
    llama_cpp: %{
      serialize_first_turns: true,
      miss_threshold_ratio: 0.25,
      pause_on_miss: true,
      release_timeout_ms: 600_000,
      kv_budget: 262_144
    },
    vllm: %{
      serialize_first_turns: false,
      miss_threshold_ratio: 0.25,
      pause_on_miss: false,
      release_timeout_ms: 600_000,
      kv_budget: 262_144
    }
  }

  @default_profile :llama_cpp

  @doc "The resolved profile name for this node."
  def name do
    case System.get_env("ORCA_FORK_SERVING_PROFILE") do
      value when is_binary(value) and value != "" ->
        parse_name(value)

      _ ->
        case Application.get_env(:orca_hub, :fork_serving_profile) do
          nil -> @default_profile
          value -> parse_name(value)
        end
    end
  end

  @doc "The fully-resolved knob map (profile defaults + app-env + env-var overrides)."
  def config do
    base = Map.fetch!(@profiles, name())
    overrides = Application.get_env(:orca_hub, :fork_serving_profile_overrides) || %{}

    base
    |> Map.merge(Map.new(overrides))
    |> put_env_override(:serialize_first_turns, "ORCA_FORK_SERIALIZE", &parse_bool/1)
    |> put_env_override(:pause_on_miss, "ORCA_FORK_PAUSE_ON_MISS", &parse_bool/1)
    |> put_env_override(:miss_threshold_ratio, "ORCA_FORK_MISS_RATIO", &parse_float/1)
    |> put_env_override(:release_timeout_ms, "ORCA_FORK_RELEASE_TIMEOUT_MS", &parse_int/1)
    |> put_env_override(:kv_budget, "ORCA_FORK_KV_BUDGET", &parse_int/1)
  end

  @doc """
  Whether forked children's first turns must be serialized (§6). `false`
  makes `OrcaHub.ForkGate` a pass-through that still runs §6.1's miss
  detection.
  """
  def serialize_first_turns?, do: config().serialize_first_turns == true

  @doc """
  §6.1's miss threshold, as a fraction of the parent's context size: fresh
  `input_tokens` above `ratio * parent_context_tokens` on a fork child's
  first `result` means the child paid a (near-)full cold prefill. 0.25 by
  default — chosen so checkpoint-granularity partial hits (≤8k reprocess on
  this hybrid arch, §1) don't false-positive.
  """
  def miss_threshold_ratio, do: config().miss_threshold_ratio

  @doc "Whether a detected miss pauses the rest of the fan-out (§6.1, default ON)."
  def pause_on_miss?, do: config().pause_on_miss == true

  @doc """
  Per-child release timeout (§6): how long the gate waits for a child's first
  turn to end before releasing the next one anyway. ~10 min, roughly one
  worst-case long first turn.
  """
  def release_timeout_ms, do: config().release_timeout_ms

  @doc "§7's unified-KV soft budget, in tokens."
  def kv_budget, do: config().kv_budget

  # ── Private ──────────────────────────────────────────────────────────

  defp put_env_override(config, key, env_var, parser) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" ->
        case parser.(value) do
          {:ok, parsed} ->
            Map.put(config, key, parsed)

          :error ->
            Logger.warning(
              "[fork gate] ignoring unparseable #{env_var}=#{inspect(value)} — " <>
                "using #{inspect(Map.get(config, key))}"
            )

            config
        end

      _ ->
        config
    end
  end

  defp parse_name(value) when is_atom(value), do: parse_name(Atom.to_string(value))

  defp parse_name(value) when is_binary(value) do
    key = value |> String.trim() |> String.downcase() |> String.replace([".", "-"], "_")

    Enum.find_value(@profiles, @default_profile, fn {profile, _} ->
      if Atom.to_string(profile) == key, do: profile
    end)
  end

  defp parse_name(_value), do: @default_profile

  defp parse_bool(value) do
    case value |> String.trim() |> String.downcase() do
      v when v in ~w(1 true yes on) -> {:ok, true}
      v when v in ~w(0 false no off) -> {:ok, false}
      _ -> :error
    end
  end

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {f, ""} when f >= 0 -> {:ok, f}
      _ -> :error
    end
  end
end
