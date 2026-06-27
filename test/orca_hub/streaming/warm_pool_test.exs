defmodule OrcaHub.Streaming.WarmPoolTest do
  # async: false — shares the node-wide WarmPool ETS table + persistent_term cap.
  use ExUnit.Case, async: false

  alias OrcaHub.Streaming
  alias OrcaHub.Streaming.WarmPool

  @table OrcaHub.Streaming.WarmPool

  # A stand-in "runner" that answers the :evict_warm gen call with a fixed reply.
  defmodule Victim do
    use GenServer
    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
    @impl true
    def init(reply), do: {:ok, %{reply: reply, evicts: 0}}
    @impl true
    def handle_call(:evict_warm, _from, s), do: {:reply, s.reply, %{s | evicts: s.evicts + 1}}
    def handle_call(:evicts, _from, s), do: {:reply, s.evicts, s}
    def evicts(pid), do: GenServer.call(pid, :evicts)
  end

  setup do
    :ets.delete_all_objects(@table)

    on_exit(fn ->
      :ets.delete_all_objects(@table)
      Streaming.set_warm_cap(nil)
    end)

    :ok
  end

  defp seed(sid, status, ts) do
    {:ok, pid} = Victim.start_link(:ok)
    :ets.insert(@table, {sid, pid, ts, status})
    pid
  end

  describe "pick_lru_victim/2 (pure)" do
    test "returns nil when under cap or cap disabled" do
      rows = [{"a", self(), 1, :idle}]
      assert WarmPool.pick_lru_victim(rows, 5) == nil
      assert WarmPool.pick_lru_victim(rows, 0) == nil
      assert WarmPool.pick_lru_victim(rows, nil) == nil
      assert WarmPool.pick_lru_victim([], 1) == nil
    end

    test "picks the smallest last_active among idle/error, skipping running" do
      rows = [
        {"old_running", self(), 1, :running},
        {"newest_idle", self(), 100, :idle},
        {"oldest_idle", self(), 5, :idle},
        {"mid_error", self(), 20, :error}
      ]

      assert {"oldest_idle", _, 5, :idle} = WarmPool.pick_lru_victim(rows, 3)
    end

    test "returns :over_cap when at/over cap but every warm runner is running" do
      rows = [
        {"r1", self(), 1, :running},
        {"r2", self(), 2, :running}
      ]

      assert WarmPool.pick_lru_victim(rows, 2) == :over_cap
    end
  end

  describe "request_slot/2 admission + eviction" do
    test "under cap admits without eviction" do
      Streaming.set_warm_cap(3)
      assert WarmPool.request_slot("s1", self()) == :ok
      assert WarmPool.warm_count() == 1
    end

    test "at cap evicts the LRU idle victim, keeping count == cap" do
      Streaming.set_warm_cap(2)
      lru = seed("lru", :idle, 1)
      _newer = seed("newer", :idle, 50)

      assert WarmPool.request_slot("incoming", self()) == :ok
      # evicted the oldest idle victim, admitted the newcomer -> still 2
      assert WarmPool.warm_count() == 2
      assert Victim.evicts(lru) == 1
      assert :ets.lookup(@table, "lru") == []
      assert :ets.lookup(@table, "incoming") != []
    end

    test "a :busy victim is skipped for the next LRU victim" do
      Streaming.set_warm_cap(2)
      busy = busy_victim("busy", 1)
      free = seed("free", :idle, 2)

      assert WarmPool.request_slot("incoming", self()) == :ok
      assert Victim.evicts(busy) == 1
      assert Victim.evicts(free) == 1
      # busy stayed, free evicted, incoming admitted -> busy + incoming = 2
      assert :ets.lookup(@table, "busy") != []
      assert :ets.lookup(@table, "free") == []
    end

    test "all-running admits over-cap with a warning instead of blocking" do
      Streaming.set_warm_cap(1)
      seed("running1", :running, 1)

      assert WarmPool.request_slot("incoming", self()) == {:ok, :over_cap}
      assert WarmPool.warm_count() == 2
    end

    test "serialized concurrent opens never exceed cap while idle victims exist" do
      cap = 3
      Streaming.set_warm_cap(cap)
      victims = for i <- 1..cap, do: seed("v#{i}", :idle, i)

      tasks =
        for i <- 1..cap do
          Task.async(fn -> WarmPool.request_slot("new#{i}", self()) end)
        end

      assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
      # cap victims evicted, cap newcomers admitted -> exactly cap
      assert WarmPool.warm_count() == cap
      assert Enum.all?(victims, fn pid -> Victim.evicts(pid) == 1 end)
    end

    test "cap = 0 disables admission control (unlimited, ships dark)" do
      Streaming.set_warm_cap(0)
      for i <- 1..5, do: assert(WarmPool.request_slot("s#{i}", self()) == :ok)
      assert WarmPool.warm_count() == 5
    end
  end

  describe "touch/2 + release/1 idempotency" do
    test "touch updates an existing row's status; no-op for an absent session" do
      Streaming.set_warm_cap(3)
      WarmPool.request_slot("s", self())
      WarmPool.touch("s", :idle)

      assert [{"s", _pid, _ts, :idle}] =
               wait_until(fn -> :ets.lookup(@table, "s") end, &match?([{_, _, _, :idle}], &1))

      WarmPool.touch("ghost", :idle)
      assert :ets.lookup(@table, "ghost") == []
    end

    test "release is idempotent" do
      Streaming.set_warm_cap(3)
      WarmPool.request_slot("s", self())
      WarmPool.release("s")
      WarmPool.release("s")
      assert wait_until(fn -> WarmPool.warm_count() end, &(&1 == 0)) == 0
    end
  end

  defp busy_victim(sid, ts) do
    {:ok, pid} = Victim.start_link(:busy)
    :ets.insert(@table, {sid, pid, ts, :idle})
    pid
  end

  # touch/release are casts; give the GenServer a moment to process.
  defp wait_until(fun, pred, tries \\ 50) do
    val = fun.()

    cond do
      pred.(val) -> val
      tries <= 0 -> val
      true -> Process.sleep(5) && wait_until(fun, pred, tries - 1)
    end
  end
end
