defmodule OrcaHub.GlobalGitignoreTest do
  # Uses only tmp-dir fixture homes — git subcommands run with HOME
  # pointed there and XDG_CONFIG_HOME/GIT_CONFIG_GLOBAL scrubbed, so the
  # real developer machine's git config is never read or written. Safe
  # to run async.
  use ExUnit.Case, async: true

  alias OrcaHub.GlobalGitignore

  @patterns [".agents/", ".orca_uploads/", ".worktrees/"]

  setup do
    home = Path.join(System.tmp_dir!(), "global_gitignore_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)

    {:ok, home: home, opts: [home_dir: home]}
  end

  defp default_path(home), do: Path.join([home, ".config", "git", "ignore"])

  describe "status/1" do
    test "reports unconfigured with all patterns missing on a fresh home", %{
      home: home,
      opts: opts
    } do
      status = GlobalGitignore.status(opts)

      assert status.git_available?
      refute status.configured?
      assert status.path == default_path(home)
      assert status.present == []
      assert status.missing == @patterns
    end

    test "reads the file at git's default path even before core.excludesfile is set", %{
      home: home,
      opts: opts
    } do
      path = default_path(home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "node_modules/\n.agents/\n")

      status = GlobalGitignore.status(opts)

      refute status.configured?
      assert status.present == [".agents/"]
      assert status.missing == [".orca_uploads/", ".worktrees/"]
    end

    test "resolves an explicitly configured core.excludesfile, expanding ~", %{
      home: home,
      opts: opts
    } do
      configure_excludesfile(home, "~/.my_global_ignore")
      File.write!(Path.join(home, ".my_global_ignore"), ".worktrees\n")

      status = GlobalGitignore.status(opts)

      assert status.configured?
      assert status.path == Path.join(home, ".my_global_ignore")
      # no-trailing-slash form still counts as covered
      assert status.present == [".worktrees/"]
      assert status.missing == [".agents/", ".orca_uploads/"]
    end
  end

  describe "ensure/1" do
    test "sets core.excludesfile to the default path and writes all patterns", %{
      home: home,
      opts: opts
    } do
      assert GlobalGitignore.ensure(opts) == :ok

      status = GlobalGitignore.status(opts)
      assert status.configured?
      assert status.path == default_path(home)
      assert status.missing == []

      assert File.read!(default_path(home)) == ".agents/\n.orca_uploads/\n.worktrees/\n"
    end

    test "is idempotent — a second run changes nothing", %{home: home, opts: opts} do
      assert GlobalGitignore.ensure(opts) == :ok
      content = File.read!(default_path(home))

      assert GlobalGitignore.ensure(opts) == :ok
      assert File.read!(default_path(home)) == content
    end

    test "preserves unrelated content and only appends what's missing", %{
      home: home,
      opts: opts
    } do
      configure_excludesfile(home, "~/.my_global_ignore")
      path = Path.join(home, ".my_global_ignore")
      File.write!(path, "*.swp\n.agents/\n")

      assert GlobalGitignore.ensure(opts) == :ok

      assert File.read!(path) == "*.swp\n.agents/\n.orca_uploads/\n.worktrees/\n"
    end

    test "adds a newline before appending to a file without a trailing one", %{
      home: home,
      opts: opts
    } do
      configure_excludesfile(home, "~/.my_global_ignore")
      path = Path.join(home, ".my_global_ignore")
      File.write!(path, "*.swp")

      assert GlobalGitignore.ensure(opts) == :ok

      assert File.read!(path) == "*.swp\n.agents/\n.orca_uploads/\n.worktrees/\n"
    end

    test "no-op when everything is already covered", %{home: home, opts: opts} do
      configure_excludesfile(home, "~/.my_global_ignore")
      path = Path.join(home, ".my_global_ignore")
      File.write!(path, ".agents/\n.orca_uploads/\n.worktrees/\n")

      assert GlobalGitignore.ensure(opts) == :ok
      assert File.read!(path) == ".agents/\n.orca_uploads/\n.worktrees/\n"
    end
  end

  # Writes core.excludesfile into the fixture home's global git config
  # the same scrubbed-env way the module itself shells out.
  defp configure_excludesfile(home, value) do
    {_, 0} =
      System.cmd("git", ["config", "--global", "core.excludesfile", value],
        env: [{"HOME", home}, {"XDG_CONFIG_HOME", nil}, {"GIT_CONFIG_GLOBAL", nil}]
      )
  end
end
