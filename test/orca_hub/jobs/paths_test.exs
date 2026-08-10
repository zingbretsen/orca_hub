defmodule OrcaHub.Jobs.PathsTest do
  use ExUnit.Case, async: false

  alias OrcaHub.Jobs.Paths

  describe "jobs_dir/0" do
    test "defaults to $HOME/.orca_hub/jobs" do
      assert Paths.jobs_dir() == Path.expand("~/.orca_hub/jobs")
    end

    test "ORCA_JOBS_DIR overrides the default" do
      System.put_env("ORCA_JOBS_DIR", "/tmp/orca-jobs-override")
      on_exit(fn -> System.delete_env("ORCA_JOBS_DIR") end)

      assert Paths.jobs_dir() == "/tmp/orca-jobs-override"
    end
  end

  describe "per-job path helpers" do
    test "derive stable, distinct paths from a job id" do
      id = "abc-123"

      assert Paths.cmd_script_path(id) == Path.join(Paths.jobs_dir(), "abc-123.cmd.sh")
      assert Paths.log_path(id) == Path.join(Paths.jobs_dir(), "abc-123.log")
      assert Paths.sentinel_path(id) == Path.join(Paths.jobs_dir(), "abc-123.exit")
      assert Paths.verify_log_path(id) == Path.join(Paths.jobs_dir(), "abc-123.verify.log")
      assert Paths.verify_sentinel_path(id) == Path.join(Paths.jobs_dir(), "abc-123.verify.exit")

      # Main and verify paths never collide with each other.
      refute Paths.log_path(id) == Paths.verify_log_path(id)
      refute Paths.sentinel_path(id) == Paths.verify_sentinel_path(id)
    end
  end

  describe "relevant_sentinel_path/1 and relevant_log_path/1" do
    test "point at the main phase's paths while running" do
      job = %{id: "j1", status: "running"}
      assert Paths.relevant_sentinel_path(job) == Paths.sentinel_path("j1")
      assert Paths.relevant_log_path(job) == Paths.log_path("j1")
    end

    test "point at the verify phase's paths while verifying" do
      job = %{id: "j1", status: "verifying"}
      assert Paths.relevant_sentinel_path(job) == Paths.verify_sentinel_path("j1")
      assert Paths.relevant_log_path(job) == Paths.verify_log_path("j1")
    end

    test "fall back to main paths for any other status" do
      for status <- ~w(succeeded failed verification_failed timed_out cancelled) do
        job = %{id: "j1", status: status}
        assert Paths.relevant_sentinel_path(job) == Paths.sentinel_path("j1")
      end
    end
  end

  describe "shq/1" do
    test "wraps a plain value in single quotes" do
      assert Paths.shq("/tmp/foo") == "'/tmp/foo'"
    end

    test "escapes embedded single quotes so the shell sees a literal quote" do
      quoted = Paths.shq("it's a trap")
      # Round-trip through a real shell to prove this isn't just string math.
      {out, 0} = System.cmd("sh", ["-c", "printf '%s' #{quoted}"])
      assert out == "it's a trap"
    end

    test "handles a path with spaces and multiple quotes" do
      quoted = Paths.shq("dir 'a' / 'b'")
      {out, 0} = System.cmd("sh", ["-c", "printf '%s' #{quoted}"])
      assert out == "dir 'a' / 'b'"
    end
  end
end
