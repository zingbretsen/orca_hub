defmodule OrcaHubWeb.VoiceViewCheckTest do
  @moduledoc """
  Runs `assets/js/voice_view.check.mjs` — the standalone node checks for the
  session page's mobile VOICE VIEW (ORCAHUB3-113 phase C): which one message
  is on screen in each state, how the pager steps (including through
  `load_older_messages`), and what returns the view to live — so the suite
  actually gates them.

  Same reasoning as `OrcaHubWeb.TtsHoldCheckTest`: the repo has no JS test
  runner, the rules are entirely client-side and so invisible to every other
  test here, and the regressions they guard against are SILENT ones — a
  return-to-live trigger nobody listens for any more leaves the screen frozen
  on an old message while the agent replies underneath it, with nothing
  failing anywhere.

  The `node`-prerequisite pattern is lifted from that sibling test: assert the
  tool is present rather than silently skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/voice_view.check.mjs", __DIR__)

  test "the voice view state-rule checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    voice_view.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
