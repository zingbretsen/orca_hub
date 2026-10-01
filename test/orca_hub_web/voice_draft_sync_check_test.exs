defmodule OrcaHubWeb.VoiceDraftSyncCheckTest do
  @moduledoc """
  Runs `assets/js/voice/draft_sync.check.mjs` — the standalone node checks for
  the voice draft sink's write rule (ORCAHUB3-120) — so the suite actually
  gates them.

  The rolling cleanup rewrites text the composer already shows, so a server
  snapshot may only overwrite a box that still holds exactly what the hook
  last wrote; anything else was typed and goes back up as a `draft_edit`.
  Losing that is SILENT — the user's typing would simply be overwritten by a
  cleanup that raced it, with nothing failing anywhere else. The server half
  (which spans a cleanup may replace) is pinned in
  `OrcaHub.Voice.SessionTest`.

  Asserts `node` is present rather than skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/voice/draft_sync.check.mjs", __DIR__)

  test "the voice draft-sync checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    draft_sync.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
