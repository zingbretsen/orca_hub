defmodule OrcaHub.ProcessIsolation.LimitsTest do
  use ExUnit.Case, async: true

  alias OrcaHub.ProcessIsolation.Limits

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024

  describe "parse_size/1" do
    test "bytes, binary suffixes in any case, decimals and an optional B/iB" do
      assert Limits.parse_size("1048576") == {:ok, 1_048_576}
      assert Limits.parse_size("512M") == {:ok, 512 * @mib}
      assert Limits.parse_size("512m") == {:ok, 512 * @mib}
      assert Limits.parse_size("2G") == {:ok, 2 * @gib}
      assert Limits.parse_size("1.5G") == {:ok, trunc(1.5 * @gib)}
      assert Limits.parse_size("2GiB") == {:ok, 2 * @gib}
      assert Limits.parse_size(" 4 GB ") == {:ok, 4 * @gib}
      assert Limits.parse_size("1T") == {:ok, 1024 * @gib}
      assert Limits.parse_size(0) == {:ok, 0}
    end

    test "max/infinity, percentages, and blanks" do
      assert Limits.parse_size("max") == {:ok, :max}
      assert Limits.parse_size("infinity") == {:ok, :max}
      assert Limits.parse_size("60%") == {:percent, 60}
      assert Limits.parse_size("12.5 %") == {:percent, 12.5}
      assert Limits.parse_size(nil) == :default
      assert Limits.parse_size("  ") == :default
    end

    test "rejects anything else, including percentages over 100" do
      for bad <- ["lots", "-1G", "1X", "150%", "G", "1,5G"] do
        assert Limits.parse_size(bad) == :error, "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  describe "resolve/2" do
    test "defaults: 80% / 60% of the budget, no swap, 8192 tasks, 1G for the BEAM" do
      limits = Limits.resolve([], 10 * @gib)

      assert limits.agents_memory_max == 8 * @gib
      assert limits.agent_memory_max == 6 * @gib
      assert limits.agent_swap_max == 0
      assert limits.agent_pids_max == 8192
      assert limits.beam_memory_low == @gib
      assert limits.base == 10 * @gib
      assert limits.warnings == []
    end

    test "explicit values win, nil/blank keep the default" do
      limits =
        Limits.resolve(
          [
            agents_memory_max: "28G",
            agent_memory_max: "20G",
            agent_swap_max: "max",
            agent_pids_max: "max",
            beam_memory_low: nil
          ],
          32 * @gib
        )

      assert limits.agents_memory_max == 28 * @gib
      assert limits.agent_memory_max == 20 * @gib
      assert limits.agent_swap_max == :max
      assert limits.agent_pids_max == :max
      assert limits.beam_memory_low == @gib
    end

    test "an invalid value falls back to its default and says so" do
      limits = Limits.resolve([agent_memory_max: "lots", agent_pids_max: "-3"], 10 * @gib)

      assert limits.agent_memory_max == 6 * @gib
      assert limits.agent_pids_max == 8192
      assert [memory_warning, pids_warning] = limits.warnings
      assert memory_warning =~ "agent_memory_max"
      assert pids_warning =~ "agent_pids_max"
    end

    test "a percentage with no known budget resolves to max with a warning" do
      limits = Limits.resolve([], nil)

      assert limits.agents_memory_max == :max
      assert limits.agent_memory_max == :max
      # Absolute defaults don't need the budget.
      assert limits.agent_swap_max == 0
      assert limits.beam_memory_low == @gib
      assert length(limits.warnings) == 2
    end
  end

  test "to_cgroup/1 and format/1" do
    assert Limits.to_cgroup(:max) == "max"
    assert Limits.to_cgroup(4096) == "4096"
    assert Limits.format(:max) == "max"
    assert Limits.format(6 * @gib) == "6.0G"
    assert Limits.format(512 * @mib) == "512.0M"
    assert Limits.format(8192) == "8192"
  end
end
