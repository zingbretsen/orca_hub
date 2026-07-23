defmodule OrcaHubWeb.ArtifactSendTest do
  @moduledoc """
  Unit coverage for the shared guards behind the orca.send bidirectional
  bridge (Artifacts Phase 3) — see `SessionLive.ArtifactTest` and
  `ArtifactLive.ShowTest` for the end-to-end LiveView delivery paths that
  call these.
  """

  use ExUnit.Case, async: true

  alias OrcaHubWeb.ArtifactSend

  describe "format_message/2" do
    test "wraps the pretty-printed payload with an artifact-named marker" do
      message = ArtifactSend.format_message("dashboard", %{"choice" => "b"})

      assert message =~ ~s([Artifact "dashboard" interaction])
      assert message =~ Jason.encode!(%{"choice" => "b"}, pretty: true)
    end
  end

  describe "too_large?/1" do
    test "false for a small payload" do
      refute ArtifactSend.too_large?(%{"a" => 1})
    end

    test "true once the encoded JSON exceeds 16KB" do
      big = %{"blob" => String.duplicate("x", 17 * 1024)}
      assert ArtifactSend.too_large?(big)
    end
  end

  describe "check_throttle/2" do
    test "allows the first send for an artifact id and records it" do
      assert {:ok, throttle} = ArtifactSend.check_throttle(%{}, "artifact-1")
      assert is_integer(Map.fetch!(throttle, "artifact-1"))
    end

    test "throttles a second send for the same artifact id within the window" do
      {:ok, throttle} = ArtifactSend.check_throttle(%{}, "artifact-1")
      assert ArtifactSend.check_throttle(throttle, "artifact-1") == :throttled
    end

    test "a different artifact id is independently throttled" do
      {:ok, throttle} = ArtifactSend.check_throttle(%{}, "artifact-1")
      assert {:ok, _throttle} = ArtifactSend.check_throttle(throttle, "artifact-2")
    end

    test "allows another send once the window has passed" do
      old_throttle = %{"artifact-1" => System.monotonic_time(:millisecond) - 1000}
      assert {:ok, _throttle} = ArtifactSend.check_throttle(old_throttle, "artifact-1")
    end
  end
end
