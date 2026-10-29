defmodule OrcaHub.FakeKill do
  @moduledoc """
  Puts a recording `kill` executable first on the BEAM's `PATH` for one
  test (ORCAHUB3-150). It writes its argv to a log and signals nothing.

  An external `kill` given a bare negative pid is exactly what took gb10
  down: procps 4.0.4's getopt reads `-1997685` as option `-1`, so the call
  becomes `kill(-1, SIGTERM)`. Group signals must go through the shell
  builtin (`OrcaHub.OSProcess`), which this double never sees, so a test
  asserts `invocations/1` stays empty.

  `PATH` is OS-global: only `async: false` tests may call `install!/0`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Installs the double for the calling test. Returns the argv log path."
  def install! do
    dir = Path.join(System.tmp_dir!(), "fake_kill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "argv.log")
    script = Path.join(dir, "kill")

    File.write!(script, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{log}'
    exit 0
    """)

    File.chmod!(script, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf(dir)
    end)

    log
  end

  @doc "Each recorded `kill` invocation's argv, one string per call."
  def invocations(log) do
    case File.read(log) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
