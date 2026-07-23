defmodule OrcaHubWeb.ArtifactSend do
  @moduledoc """
  Shared validation + message formatting for the orca.send bidirectional
  bridge (Artifacts Phase 3): an artifact's `window.orca.send(payload)` call
  is forwarded by the `ArtifactData` JS hook to an `"artifact_send"` LiveView
  event, delivered here into a session as a user-visible message.

  Used by both `SessionLive.Show` (split panel — delivers to the viewed
  session) and `ArtifactLive.Show` (fullscreen — delivers to the artifact's
  creator session), which each own their own delivery target but share these
  guards. See `save_artifact`'s tool description
  (`OrcaHub.MCP.Tools.Artifacts`) for the full client-side contract.
  """

  @max_payload_bytes 16 * 1024
  @min_interval_ms 500

  @doc "Formats the payload as the message text delivered into the session."
  def format_message(artifact_name, payload) do
    "[Artifact \"#{artifact_name}\" interaction] #{Jason.encode!(payload, pretty: true)}"
  end

  @doc "Whether the payload's encoded JSON size exceeds the 16KB cap."
  def too_large?(payload), do: byte_size(Jason.encode!(payload)) > @max_payload_bytes

  @doc """
  Checks (and, if allowed, advances) a per-artifact throttle map keyed by
  artifact id to the monotonic ms of its last accepted send. Returns
  `{:ok, updated_throttle}` if this send is allowed, or `:throttled` if one
  landed for the same artifact_id less than #{@min_interval_ms}ms ago.
  """
  def check_throttle(throttle, artifact_id) do
    now = System.monotonic_time(:millisecond)

    case Map.get(throttle, artifact_id) do
      last when is_integer(last) and now - last < @min_interval_ms ->
        :throttled

      _ ->
        {:ok, Map.put(throttle, artifact_id, now)}
    end
  end
end
