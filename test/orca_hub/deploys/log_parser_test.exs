defmodule OrcaHub.Deploys.LogParserTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Deploys.LogParser

  @fixtures Path.expand("../../support/fixtures/deploy_logs", __DIR__)

  # The fixtures are hand-written to reproduce the real scripts' output
  # byte-for-byte: the shared banner() (62 '='), step_skipped(), fatal()
  # (76 '#') and content-studio's warn() (76 '!'). No deploy script was run
  # to produce them — the formats were transcribed from
  # ~/homelab/scripts/*.sh.
  defp fixture(name), do: File.read!(Path.join(@fixtures, name <> ".log"))
  defp parse(name, opts \\ []), do: name |> fixture() |> LogParser.parse(opts)

  describe "the shared banner() gives ordered steps for every target" do
    test "orca_hub: all seven steps plus the final banner, in order" do
      result = parse("orca_hub_exit0_gb10_warning")

      assert result.steps_seen == [
               "Step 1/7 — Pushing current branch to origin",
               "Step 2/7 — Building image + extracting release artifact(s) (linux/amd64,linux/arm64)",
               "Step 3/7 — Updating k3s manifests for Flux",
               "Step 4/7 — Installing per-host env files (sops-decrypt)",
               "Step 5/7 — Installing release on mini + restarting its systemd service",
               "Step 6/7 — Installing arm64 release on gb10 + restarting its systemd service",
               "Step 7/7 — Installing release locally + restarting systemd service: orca-hub",
               "Deploy complete"
             ]

      assert result.last_step == "Deploy complete"
    end

    test "content-studio and video-search use the same banner, so the same parser works" do
      assert parse("content_studio_fatal").steps_seen == [
               "Step 1: preflight",
               "Step 2: source provenance",
               "Step 4: build + push"
             ]

      assert parse("video_search_fatal").last_step == "Step 3: build + push"
    end

    test "a log that aborts before the first banner has no steps at all" do
      # deploy-orca-hub.sh's preflight guards (dirty checkout, empty
      # LOCK_SHA, gb10 reachability, …) all run BEFORE step 1's banner.
      result = parse("orca_hub_abort_dirty_checkout")

      assert result.steps_seen == []
      assert result.last_step == nil
      assert result.skipped_steps == []
    end

    test "a docker '#1 [internal] …' build line is not mistaken for a step or a frame" do
      result = parse("orca_hub_exit0_gb10_warning")

      refute Enum.any?(result.steps_seen, &String.contains?(&1, "[internal]"))
      assert result.errors == []
    end
  end

  describe "skipped steps" do
    test "step_skipped() lines are collected in order and excluded from steps_seen" do
      result = parse("orca_hub_skipped_steps")

      assert result.skipped_steps == [
               "Step 2/7 — docker buildx builds + artifact extraction (--skip-build)",
               "Step 5/7 — install release on mini + restart (--skip-mini)",
               "Step 6/7 — install arm64 release on gb10 + restart (--skip-arm64 or --skip-gb10)"
             ]

      assert result.steps_seen == [
               "Step 1/7 — Pushing current branch to origin",
               "Step 3/7 — Updating k3s manifests for Flux",
               "Step 4/7 — Installing per-host env files (sops-decrypt)",
               "Step 7/7 — Installing release locally + restarting systemd service: orca-hub"
             ]
    end

    test "content-studio's inline SKIPPED echo is picked up too" do
      assert parse("content_studio_fatal").skipped_steps == ["build + push (--skip-build)"]
    end
  end

  describe "errors" do
    test "bare ERROR: lines are captured" do
      assert parse("orca_hub_skipped_steps").errors == [
               "ERROR: no artifact available (Step 2 was skipped with --skip-build) — cannot install locally."
             ]
    end

    test "only the ERROR:-prefixed line of a multi-line guard is captured" do
      # Stated limit, not an accident: deploy-orca-hub.sh's guards echo their
      # explanation as unprefixed continuation lines, which the regex cannot
      # see. log_tail carries the rest.
      result = parse("orca_hub_abort_dirty_checkout")

      assert result.errors == ["ERROR: /home/zach/orca_hub has uncommitted changes."]
      assert result.log_tail =~ "pass --allow-dirty to deploy anyway"
    end

    test "a ####-framed fatal() block is captured, and its FATAL: line only once" do
      # The first body line matches BOTH the ^FATAL: rule and the frame
      # block, so the parser must de-duplicate.
      assert parse("content_studio_fatal").errors == [
               "FATAL: --skip-build, but registry.lab.ingbretsenhome.com/content-studio:0.18.0 does not exist in the registry."
             ]
    end

    test "every line of a multi-line fatal() block is captured, in order" do
      assert parse("video_search_fatal").errors == [
               "FATAL: video-transcript-search:7b3d0c9 is NOT a single linux/amd64 image.",
               "manifest platforms: linux/amd64, linux/arm64",
               "Refusing to deploy a multi-arch manifest here."
             ]
    end

    test "verify-orca-deploy.sh's '  FAIL:' lines are errors, its '  OK:' lines are not" do
      log = """
      Verifying every instance reports sha=01a1b00
        OK: local systemd (http://127.0.0.1:4001/api/version) -> sha=01a1b00
        FAIL: gb10 (zach@192.168.1.77, http://127.0.0.1:4001/api/version) still reports sha='4dc631d' after 120s (want 01a1b00)
      One or more instances did NOT confirm sha=01a1b00 — see FAIL lines above.
      """

      result = LogParser.parse(log)

      assert result.errors == [
               "  FAIL: gb10 (zach@192.168.1.77, http://127.0.0.1:4001/api/version) still reports sha='4dc631d' after 120s (want 01a1b00)"
             ]
    end
  end

  describe "warnings are separate because a deploy can exit 0 with a failed stage" do
    test "exit 0 + a completely failed gb10 stage still surfaces warnings[]" do
      # THE case this field exists for: six paths in deploy-orca-hub.sh warn
      # and continue, so "exit 0" must not read as "everything worked".
      result = parse("orca_hub_exit0_gb10_warning")

      assert result.errors == []
      assert result.last_step == "Deploy complete"

      assert result.warnings == [
               "  TIMEOUT: gb10 (zach@192.168.1.77, http://127.0.0.1:4001/api/version) still reports sha='4dc631d' after 60s (want 01a1b00)",
               "WARNING: gb10 did not report sha=01a1b00 after restart — check it manually."
             ]

      assert Enum.all?(result.warnings, &String.contains?(&1, "gb10"))
    end

    test "warn-only prune and k3s-poll failures are warnings, never errors" do
      result = parse("orca_hub_skipped_steps")

      assert result.warnings == [
               "WARNING: image tag cleanup failed — continuing.",
               "  TIMEOUT: k8s orca-hub (https://orca.lab.ingbretsenhome.com/api/version) still reports sha='dc6d8cc' after 180s (want 4dc631d)",
               "WARNING: k8s orca-hub did not report sha=4dc631d in time — check Flux/rollout status manually."
             ]
    end

    test "content-studio's '!!'-framed warn() is captured with the frame stripped" do
      # content-studio never echoes a bare "WARNING:" — every warning it has
      # is the framed form, so this is the only way to see one.
      assert parse("content_studio_fatal").warnings == [
               "The app repo is 2 commit(s) AHEAD of its remote.",
               "The images are built from your LOCAL tree, so what ships may not be pushed."
             ]
    end

    test "an unterminated frame block collects to the end of the log" do
      # A log truncated mid-fatal (the process was killed) should still show
      # what it was complaining about.
      log =
        [
          ">>> Step 3: build + push",
          String.duplicate("#", 76),
          "FATAL: the registry went away mid-push"
        ]
        |> Enum.join("\n")

      assert LogParser.parse(log).errors == ["FATAL: the registry went away mid-push"]
    end
  end

  describe "log_tail" do
    test "defaults to the last 4000 bytes and keeps the end of the log" do
      log = String.duplicate("x", 5000) <> "\nTHE END\n"
      result = LogParser.parse(log)

      assert byte_size(result.log_tail) <= 4000
      assert String.ends_with?(result.log_tail, "THE END\n")
    end

    test "a shorter log is returned whole" do
      assert LogParser.parse("hello\n").log_tail == "hello\n"
    end

    test "log_tail_bytes: nil returns the whole log; parsing is always over the whole log" do
      log = fixture("orca_hub_exit0_gb10_warning")
      result = LogParser.parse(log, log_tail_bytes: nil)

      assert result.log_tail == log

      # Truncating the tail must not change anything that was parsed.
      tiny = LogParser.parse(log, log_tail_bytes: 20)
      assert tiny.steps_seen == result.steps_seen
      assert tiny.warnings == result.warnings
      assert byte_size(tiny.log_tail) <= 20
    end

    test "byte truncation that lands mid-character still yields valid UTF-8" do
      # Every orca-hub step banner contains an em dash (3 bytes), so this is
      # the normal case, not a contrived one — and invalid UTF-8 would make
      # the tool result unencodable as JSON.
      log = "aaaa" <> String.duplicate("—", 50)

      for bytes <- 1..40 do
        tail = LogParser.tail(log, bytes)
        assert String.valid?(tail), "tail of #{bytes} bytes was not valid UTF-8"
        assert byte_size(tail) <= bytes
      end
    end
  end

  describe "degenerate input" do
    test "an empty or nil log parses to empty everything" do
      for log <- ["", nil] do
        assert LogParser.parse(log) == %{
                 steps_seen: [],
                 last_step: nil,
                 skipped_steps: [],
                 errors: [],
                 warnings: [],
                 log_tail: ""
               }
      end
    end

    test "CRLF line endings are handled and do not leak into captures" do
      log = ">>> Step 1/7 — Pushing current branch to origin\r\nWARNING: something\r\n"
      result = LogParser.parse(log)

      assert result.steps_seen == ["Step 1/7 — Pushing current branch to origin"]
      assert result.warnings == ["WARNING: something"]
    end
  end
end
