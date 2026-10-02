defmodule OrcaHubWeb.VoiceViewFlagCheckTest do
  @moduledoc """
  Runs `assets/js/voice/voice_view_flag.check.mjs` — the standalone node
  checks for the mobile voice view's global flag (`voice_view_flag.js`) and
  the `Voice` hook's half of it (ORCAHUB3-113 phase C) — so the suite
  actually gates them.

  Gated rather than run-by-hand for the reason `OrcaHubWeb.TtsHoldCheckTest`
  is: everything it pins is client-side, invisible to every other test here,
  and fails SILENTLY. A voice view that drops on an OS-killed microphone, an
  End that quietly re-arms instead of ending, a Resume that turns voice off on
  its second tap, a page event that can drive the toggle — none of them would
  break anything else in the suite.

  The `node`-prerequisite pattern is lifted from that sibling test: assert the
  tool is present rather than silently skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/voice/voice_view_flag.check.mjs", __DIR__)

  test "the voice view flag and Voice hook checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    voice_view_flag.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
