defmodule OrcaHub.NodeDialerTest do
  @moduledoc """
  Covers the pure target-selection and failure-tracking logic directly, plus
  `tick/1`'s handling of `Node.connect/1` returning `:ignored` — which is
  exactly what happens when this test VM (not started with `--name`/
  `--sname`) calls it, so no real distributed Erlang setup is needed here.
  See `cluster_distributed_test.exs` for genuine multi-node coverage.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.ClusterNodes
  alias OrcaHub.NodeDialer

  describe "select_targets/3" do
    test "excludes self and already-connected names, keeps the rest" do
      targets = ["orca@a", "orca@b", "orca@c"]

      assert NodeDialer.select_targets(targets, "orca@b", MapSet.new(["orca@c"])) == ["orca@a"]
    end

    test "returns [] when there are no dial targets" do
      assert NodeDialer.select_targets([], "orca@self", MapSet.new()) == []
    end

    test "returns everything when nothing is self or already connected" do
      targets = ["orca@a", "orca@b"]

      assert NodeDialer.select_targets(targets, "orca@self", MapSet.new()) == targets
    end
  end

  describe "record_success/2" do
    test "clears any tracked failure count and always logs :log_connected" do
      assert NodeDialer.record_success(%{"orca@a" => 3}, "orca@a") == {%{}, :log_connected}
    end

    test "is a no-op on the failure map when there was nothing tracked" do
      assert NodeDialer.record_success(%{}, "orca@a") == {%{}, :log_connected}
    end
  end

  describe "record_failure/2" do
    test "logs :log_first_failure on the very first consecutive failure" do
      assert NodeDialer.record_failure(%{}, "orca@a") == {%{"orca@a" => 1}, :log_first_failure}
    end

    test "stays quiet from the 2nd through the 59th consecutive failure" do
      {failures, actions} =
        Enum.reduce(2..59, {%{"orca@a" => 1}, []}, fn _, {acc, actions} ->
          {failures, action} = NodeDialer.record_failure(acc, "orca@a")
          {failures, [action | actions]}
        end)

      assert failures["orca@a"] == 59
      assert Enum.all?(actions, &(&1 == :quiet))
    end

    test "logs a repeat warning on the 61st consecutive failure (~5 min after the first, at a 5s tick), then quiet again" do
      failures =
        Enum.reduce(2..60, %{"orca@a" => 1}, fn _, acc ->
          {failures, _action} = NodeDialer.record_failure(acc, "orca@a")
          failures
        end)

      assert {sixty_first, :log_repeat_failure} = NodeDialer.record_failure(failures, "orca@a")
      assert sixty_first["orca@a"] == 61

      assert {sixty_second, :quiet} = NodeDialer.record_failure(sixty_first, "orca@a")
      assert sixty_second["orca@a"] == 62
    end

    test "tracks separate targets independently" do
      {failures, _action} = NodeDialer.record_failure(%{}, "orca@a")
      {failures, _action} = NodeDialer.record_failure(failures, "orca@b")

      assert failures == %{"orca@a" => 1, "orca@b" => 1}
    end
  end

  describe "tick/1 when this node is not running distributed Erlang" do
    test "Node.connect/1 returns :ignored, so the tick stops further ticking instead of crashing" do
      refute Node.alive?()
      {:ok, _} = ClusterNodes.create_node(%{name: "orca@totally-offline", dial: true})

      state = NodeDialer.tick(%{failures: %{}, stopped?: false})

      assert state.stopped? == true
    end

    test "no dial targets means Node.connect is never called and nothing changes" do
      refute Node.alive?()

      assert NodeDialer.tick(%{failures: %{}, stopped?: false}) == %{
               failures: %{},
               stopped?: false
             }
    end
  end
end
