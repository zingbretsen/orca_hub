defmodule OrcaHub.Streaming do
  @moduledoc """
  Runtime controls for the long-lived streaming SessionRunner engine.

  Two levers, both **per-node**:

    * **Runtime kill switch** — an IEx-settable, absolute, per-node emergency stop
      that forces every runner on this node onto the one-shot engine WITHOUT a
      redeploy. Backed by `:persistent_term` (lock-free, read-hot, write-rare).
      It is intentionally NOT durable across a VM/pod restart — the durable
      per-node default remains the `ORCA_DISABLE_STREAMING` env var, re-read at
      boot. To make a disable survive restarts, set that env (redeploy).

    * **Warm-cap** (Feature B, lands separately) — `warm_cap/0` / `set_warm_cap/1`
      are provided here; the `OrcaHub.Streaming.WarmPool` process that enforces
      them arrives in a later change. `warm_cap/0` is safe to call now.

  ## Kill-switch usage (from IEx on the node you want to protect)

      OrcaHub.Streaming.disable!()           # graceful: idle/warm procs torn down
                                             # now; running turns finish then drop
      OrcaHub.Streaming.disable!(:interrupt) # also interrupts running turns now
      OrcaHub.Streaming.status()             # inspect current state
      OrcaHub.Streaming.enable!()            # lift the switch; sessions re-resolve
                                             # to streaming on their next turn

  Precedence enforced by `SessionRunner.resolve_engine/1`:
  **runtime kill switch > per-session `streaming` column > env default**. The
  kill switch is ABSOLUTE — it overrides even a per-session `streaming: true`.
  """

  require Logger

  @kill_key {__MODULE__, :runtime_kill}
  @warm_cap_key {__MODULE__, :warm_cap}
  @default_warm_cap 6

  # ── Runtime kill switch ──────────────────────────────────────────────

  @doc "True if the runtime kill switch is engaged on this node."
  def kill_engaged?, do: :persistent_term.get(@kill_key, false)

  @doc """
  Engage the runtime kill switch on THIS node and convert live streaming runners
  to one-shot.

  `mode`:
    * `:graceful` (default) — idle/warm runners are torn down immediately; a
      runner mid-turn finishes its current turn, then drops to one-shot.
    * `:interrupt` — a runner mid-turn is interrupted (control_request) so it
      drops to one-shot promptly.

  Continuity is preserved in all cases via `claude_session_id` + `--resume`.
  Returns a summary map of what happened to live runners on this node.
  """
  def disable!(mode \\ :graceful) when mode in [:graceful, :interrupt] do
    :persistent_term.put(@kill_key, true)
    Logger.warning("[streaming] runtime kill switch ENGAGED on #{node()} (mode=#{mode})")

    summary =
      live_runners()
      |> Enum.map(fn {_sid, pid} -> downgrade(pid, mode) end)
      |> summarize()

    Logger.warning("[streaming] kill switch downgrade summary on #{node()}: #{inspect(summary)}")
    summary
  end

  @doc """
  Lift the runtime kill switch on this node. New runners resolve to the normal
  default again, and existing downgraded runners are asked to re-resolve — idle/
  ready/error ones flip back to streaming and cold-reopen a persistent process
  (with the warm-up turn) on their next turn. A runner mid-turn keeps its current
  engine for that turn (best-effort; re-run `enable!/0` or it upgrades on restart).
  """
  def enable! do
    :persistent_term.put(@kill_key, false)
    Logger.warning("[streaming] runtime kill switch LIFTED on #{node()}")

    for {_sid, pid} <- live_runners() do
      :gen_statem.cast(pid, :reresolve_engine)
    end

    :ok
  end

  @doc "Snapshot of the streaming controls on this node."
  def status do
    %{
      node: node(),
      runtime_kill: kill_engaged?(),
      env_default_disabled: env_disabled?(),
      effective_default: if(kill_engaged?() or env_disabled?(), do: :one_shot, else: :streaming),
      live_runners: length(live_runners()),
      warm_count: __MODULE__.WarmPool.warm_count(),
      warm_cap: warm_cap()
    }
  end

  # ── Cluster-wide variants (thin fan-out; per-node is the primitive) ──

  @doc "Engage the kill switch on every connected node. Returns `{node, result}` pairs."
  def disable_cluster!(mode \\ :graceful) when mode in [:graceful, :interrupt] do
    fan_out(:disable!, [mode])
  end

  @doc "Lift the kill switch on every connected node."
  def enable_cluster! do
    fan_out(:enable!, [])
  end

  # ── Warm-cap config (enforcement lands with WarmPool, Feature B) ─────

  @doc "Per-node warm-process cap. Env `ORCA_MAX_WARM_SESSIONS` default, else #{@default_warm_cap}."
  def warm_cap do
    :persistent_term.get(@warm_cap_key, nil) || env_warm_cap()
  end

  @doc "Set the per-node warm cap at runtime (no redeploy). `nil` reverts to the env default."
  def set_warm_cap(nil) do
    :persistent_term.erase(@warm_cap_key)
    :ok
  end

  def set_warm_cap(n) when is_integer(n) and n >= 0 do
    :persistent_term.put(@warm_cap_key, n)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp downgrade(pid, mode) do
    :gen_statem.call(pid, {:downgrade, mode}, 5_000)
  catch
    # A runner that dies / is unreachable during the sweep is effectively already
    # not holding a warm process — don't let it abort the whole kill switch.
    kind, reason ->
      Logger.warning(
        "[streaming] downgrade call failed for #{inspect(pid)}: #{inspect({kind, reason})}"
      )

      :error
  end

  defp summarize(results) do
    Enum.reduce(
      results,
      %{torn_down_now: 0, pending_after_turn: 0, already_one_shot: 0, error: 0},
      fn
        :torn_down_now, acc -> %{acc | torn_down_now: acc.torn_down_now + 1}
        :pending_after_turn, acc -> %{acc | pending_after_turn: acc.pending_after_turn + 1}
        :already_one_shot, acc -> %{acc | already_one_shot: acc.already_one_shot + 1}
        _, acc -> %{acc | error: acc.error + 1}
      end
    )
  end

  # Node-local enumeration of live SessionRunner processes -> [{session_id, pid}].
  defp live_runners do
    Registry.select(OrcaHub.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp fan_out(fun, args) do
    Enum.map(OrcaHub.Cluster.nodes(), fn n ->
      result =
        try do
          :erpc.call(n, __MODULE__, fun, args, 10_000)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {n, result}
    end)
  end

  defp env_disabled?, do: Application.get_env(:orca_hub, :disable_streaming, false)

  defp env_warm_cap do
    case System.get_env("ORCA_MAX_WARM_SESSIONS") do
      nil ->
        @default_warm_cap

      str ->
        case Integer.parse(str) do
          {n, _} when n >= 0 -> n
          _ -> @default_warm_cap
        end
    end
  end
end
