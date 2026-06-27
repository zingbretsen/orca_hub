defmodule OrcaHub.Streaming.WarmPool do
  @moduledoc """
  Per-node admission control for warm (process-alive) streaming SessionRunners.

  Each warm `claude` process costs ~150–300 MB. On a 2Gi pod that is only
  ~6–12 concurrent warm sessions before OOM, so we cap the number of warm
  streaming processes per node and evict the least-recently-used idle one when a
  new warm process would breach the cap.

  ## How it fits together

    * A runner calls `request_slot/2` at the streaming cold path, BEFORE opening
      its persistent port. Admission is serialized through this GenServer so two
      simultaneous opens can't both think there's room.
    * Under cap → admit. At/over cap → evict the LRU victim among `:idle`/`:error`
      runners (never a `:running` turn). The victim double-checks and replies
      `:busy` if it just started a turn; we try the next LRU. If every warm runner
      is running, we admit **over-cap** with a WARN — we never block a user's turn
      or kill live work.
    * Runners `touch/2` their activity (`:running` at turn start, `:idle`/`:error`
      at finalize) and `release/1` on teardown/crash/terminate (idempotent).

  Admission NEVER blocks the user: `request_slot/2` always returns `:ok` (or
  `{:ok, :over_cap}`); it only decides whether to evict someone first.

  The cap is `OrcaHub.Streaming.warm_cap/0` (env `ORCA_MAX_WARM_SESSIONS`,
  default 6, runtime-tunable via `set_warm_cap/1`). A cap of `0`/`nil` disables
  admission control entirely (unlimited warm — ships the bookkeeping "dark").

  Composes with the 15-min idle-timeout teardown in `SessionRunner`: the
  idle-timeout drains warm count over time (lowering steady-state), the LRU cap
  bounds the peak. Both funnel through `teardown_port` + `release/1`.
  """

  use GenServer
  require Logger

  alias OrcaHub.Streaming

  @table __MODULE__
  @evict_timeout 2_000

  # ETS row: {session_id, pid, last_active_monotonic, status :: :running | :idle | :error}

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request a warm slot before opening a streaming port. Serialized; may evict an
  LRU idle victim. Returns `:ok` or `{:ok, :over_cap}`. Never blocks the caller's
  turn (admission is best-effort). Safe to call if the pool isn't running.
  """
  def request_slot(session_id, pid) do
    GenServer.call(__MODULE__, {:request_slot, session_id, pid}, 10_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Record activity/status for a warm runner (`:running` | `:idle` | `:error`)."
  def touch(session_id, status) when status in [:running, :idle, :error] do
    safe_cast({:touch, session_id, status})
  end

  @doc "Drop a runner from the warm pool. Idempotent; safe if absent or pool down."
  def release(session_id), do: safe_cast({:release, session_id})

  @doc "Number of warm runners currently tracked on this node."
  def warm_count do
    :ets.info(@table, :size) || 0
  catch
    _, _ -> 0
  end

  @doc "All warm rows (for status/inspection)."
  def warm_rows do
    :ets.tab2list(@table)
  catch
    _, _ -> []
  end

  defp safe_cast(msg) do
    GenServer.cast(__MODULE__, msg)
  catch
    :exit, _ -> :ok
  end

  # ── Pure eviction-selection core (testable without a live runner) ────

  @doc """
  Decide whether admitting one more warm process requires eviction, given the
  current warm `rows` and `cap`:

    * `nil`            — room (under cap, or cap disabled) — admit without eviction
    * `:over_cap`      — at/over cap but no evictable (idle/error) victim — admit over-cap
    * `{sid,...}` row  — evict this LRU idle/error victim first

  `:running` rows are never selected.
  """
  def pick_lru_victim(rows, cap) do
    cond do
      cap in [0, nil] -> nil
      length(rows) < cap -> nil
      true -> lru_idle(rows)
    end
  end

  defp lru_idle(rows) do
    rows
    |> Enum.filter(fn {_sid, _pid, _ts, status} -> status in [:idle, :error] end)
    |> Enum.sort_by(fn {_sid, _pid, ts, _status} -> ts end)
    |> case do
      [] -> :over_cap
      [victim | _] -> victim
    end
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:request_slot, session_id, pid}, _from, state) do
    cap = Streaming.warm_cap()
    rows = :ets.tab2list(@table)

    result =
      cond do
        cap in [0, nil] or length(rows) < cap ->
          register(session_id, pid)
          :ok

        true ->
          candidates =
            rows
            |> Enum.filter(fn {_sid, _pid, _ts, status} -> status in [:idle, :error] end)
            |> Enum.sort_by(fn {_sid, _pid, ts, _status} -> ts end)

          case evict_one(candidates) do
            :ok ->
              register(session_id, pid)
              :ok

            :none ->
              Logger.warning(
                "[streaming] warm cap #{cap} reached and all warm sessions are running on " <>
                  "#{node()} — admitting #{session_id} over-cap"
              )

              register(session_id, pid)
              {:ok, :over_cap}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:touch, session_id, status}, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, _ts, _old}] ->
        :ets.insert(@table, {session_id, pid, now(), status})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:release, session_id}, state) do
    :ets.delete(@table, session_id)
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp register(session_id, pid), do: :ets.insert(@table, {session_id, pid, now(), :running})

  # Evict the first LRU idle/error candidate that's still evictable. A victim that
  # just went :running replies :busy → try the next. None evictable → :none.
  defp evict_one([]), do: :none

  defp evict_one([{vsid, vpid, _ts, _status} | rest]) do
    case evict(vpid) do
      :ok ->
        :ets.delete(@table, vsid)
        :ok

      :busy ->
        evict_one(rest)
    end
  end

  defp evict(vpid) do
    :gen_statem.call(vpid, :evict_warm, @evict_timeout)
  catch
    # Victim gone/unreachable — its slot is effectively freed.
    _, _ -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
