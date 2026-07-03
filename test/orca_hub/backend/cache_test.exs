defmodule OrcaHub.Backend.CacheTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Backend.Cache

  # async-safe: every test uses its own unique key.
  defp key, do: {:cache_test, System.unique_integer([:positive])}

  test "runs the fun on miss and serves the cached value within the TTL" do
    k = key()
    assert Cache.get_or_run(k, 60_000, fn -> :computed end) == :computed
    assert Cache.get_or_run(k, 60_000, fn -> flunk("should have hit the cache") end) == :computed
  end

  test "re-runs the fun after expiry" do
    k = key()
    assert Cache.get_or_run(k, 0, fn -> :first end) == :first
    Process.sleep(1)
    assert Cache.get_or_run(k, 0, fn -> :second end) == :second
  end

  test "a raising fun is not cached — the next call retries" do
    k = key()

    assert_raise RuntimeError, fn ->
      Cache.get_or_run(k, 60_000, fn -> raise "boom" end)
    end

    assert Cache.get_or_run(k, 60_000, fn -> :recovered end) == :recovered
  end

  test "invalidate/1 drops a single entry" do
    k = key()
    Cache.get_or_run(k, 60_000, fn -> :stale end)
    Cache.invalidate(k)
    assert Cache.get_or_run(k, 60_000, fn -> :fresh end) == :fresh
  end
end
