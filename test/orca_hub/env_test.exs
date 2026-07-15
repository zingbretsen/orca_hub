defmodule OrcaHub.EnvTest do
  use ExUnit.Case, async: false

  alias OrcaHub.Env

  # Save and restore every release-related env var (and PATH) so the tests can
  # mutate them freely without corrupting the real test runner's environment —
  # which, when running under a prod release, actually has RELEASE_* set.
  setup do
    release_keys =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "RELEASE_"))

    keys =
      Enum.uniq(
        ["RELEASE_ROOT", "RELEASE_NAME", "BINDIR", "ROOTDIR", "PROGNAME", "PATH"] ++ release_keys
      )

    saved = Enum.map(keys, fn k -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    {:ok, release_keys: release_keys}
  end

  test "unsets RELEASE_* and standalone release vars" do
    System.put_env("RELEASE_ROOT", "/app/_build/prod/rel/orca_hub")
    System.put_env("RELEASE_NAME", "orca_hub")
    System.put_env("BINDIR", "/app/_build/prod/rel/orca_hub/erts-14/bin")
    System.put_env("ROOTDIR", "/app/_build/prod/rel/orca_hub")
    System.put_env("PROGNAME", "erl")

    env = Env.sanitized_env()

    assert {~c"RELEASE_ROOT", false} in env
    assert {~c"RELEASE_NAME", false} in env
    assert {~c"BINDIR", false} in env
    assert {~c"ROOTDIR", false} in env
    assert {~c"PROGNAME", false} in env
  end

  test "strips PATH entries under the release root, keeps system entries" do
    root = "/app/_build/prod/rel/orca_hub"
    System.put_env("RELEASE_ROOT", root)
    System.put_env("PATH", "#{root}/erts-14/bin:/usr/local/bin:/usr/bin:/bin")

    env = Env.sanitized_env()
    {_, path} = List.keyfind(env, ~c"PATH", 0)
    path = to_string(path)

    refute String.contains?(path, root)
    assert String.contains?(path, "/usr/local/bin")
    assert String.contains?(path, "/usr/bin")
    assert String.contains?(path, "/bin")
  end

  test "falls back to heuristic PATH cleaning when RELEASE_ROOT is unset" do
    System.delete_env("RELEASE_ROOT")

    System.put_env(
      "PATH",
      "/some/_build/prod/rel/orca_hub/erts-14/bin:/opt/app/erts-15/bin:/usr/bin"
    )

    env = Env.sanitized_env()
    {_, path} = List.keyfind(env, ~c"PATH", 0)
    path = to_string(path)

    refute String.contains?(path, "/rel/")
    refute String.contains?(path, "/erts-")
    assert String.contains?(path, "/usr/bin")
  end

  test "is a harmless no-op when no release vars are set", %{release_keys: release_keys} do
    Enum.each(
      release_keys ++ ["RELEASE_ROOT", "BINDIR", "ROOTDIR", "PROGNAME"],
      &System.delete_env/1
    )

    System.delete_env("PATH")

    # No RELEASE_* keys present in env (the test runner shouldn't have any).
    refute Enum.any?(System.get_env(), fn {k, _} -> String.starts_with?(k, "RELEASE_") end)

    assert Env.sanitized_env() == []
  end

  test "merges extra vars on top of the sanitized base" do
    System.put_env("RELEASE_ROOT", "/app/rel/orca_hub")

    extra = [
      {~c"TERM", ~c"xterm-256color"},
      {~c"COLUMNS", ~c"120"},
      {~c"LINES", ~c"40"}
    ]

    env = Env.sanitized_env(extra)

    assert {~c"RELEASE_ROOT", false} in env
    assert {~c"TERM", ~c"xterm-256color"} in env
    assert {~c"COLUMNS", ~c"120"} in env
    assert {~c"LINES", ~c"40"} in env

    # Extra vars come after the sanitizer's tuples.
    assert List.last(env) == {~c"LINES", ~c"40"}
  end

  describe "strict_env/1" do
    test "unsets a var not on the base allow-list" do
      System.put_env("ORCA_TEST_SECRET", "super-secret")
      on_exit(fn -> System.delete_env("ORCA_TEST_SECRET") end)

      env = Env.strict_env()

      assert {~c"ORCA_TEST_SECRET", false} in env
    end

    test "keeps base allow-listed vars (PATH/HOME/USER/LOGNAME/SHELL/TERM/LANG/TMPDIR/COLUMNS/LINES) unmentioned-as-unset" do
      allow_listed = ~w(PATH HOME USER LOGNAME SHELL TERM LANG TMPDIR COLUMNS LINES)

      Enum.each(allow_listed, fn name -> System.put_env(name, "test-value-#{name}") end)
      on_exit(fn -> Enum.each(allow_listed, &System.delete_env/1) end)

      env = Env.strict_env()

      Enum.each(allow_listed, fn name ->
        refute {String.to_charlist(name), false} in env
      end)
    end

    test "keeps LC_* vars (any suffix) unmentioned-as-unset" do
      System.put_env("LC_ALL", "en_US.UTF-8")
      System.put_env("LC_TIME", "en_US.UTF-8")
      on_exit(fn -> Enum.each(["LC_ALL", "LC_TIME"], &System.delete_env/1) end)

      env = Env.strict_env()

      refute {~c"LC_ALL", false} in env
      refute {~c"LC_TIME", false} in env
    end

    test "extra vars layered on top win over the strict unset, even for a var that IS unset" do
      System.put_env("ORCA_TEST_TOKEN", "should-not-survive-unreinjected")
      on_exit(fn -> System.delete_env("ORCA_TEST_TOKEN") end)

      env = Env.strict_env([{~c"ORCA_TEST_TOKEN", ~c"reinjected-value"}])

      assert {~c"ORCA_TEST_TOKEN", false} in env
      assert {~c"ORCA_TEST_TOKEN", ~c"reinjected-value"} in env
      # The value tuple must come after the unset tuple — Erlang port :env
      # semantics take the LAST tuple for a repeated name (verified empirically,
      # see moduledoc).
      unset_index = Enum.find_index(env, &(&1 == {~c"ORCA_TEST_TOKEN", false}))
      value_index = Enum.find_index(env, &(&1 == {~c"ORCA_TEST_TOKEN", ~c"reinjected-value"}))
      assert value_index > unset_index
    end

    test "PATH is still cleaned of release entries, and not additionally unset" do
      root = "/app/_build/prod/rel/orca_hub"
      System.put_env("RELEASE_ROOT", root)
      System.put_env("PATH", "#{root}/erts-14/bin:/usr/local/bin:/usr/bin:/bin")

      env = Env.strict_env()

      refute {~c"PATH", false} in env
      {_, path} = List.keyfind(env, ~c"PATH", 0)
      path = to_string(path)

      refute String.contains?(path, root)
      assert String.contains?(path, "/usr/local/bin")
    end

    test "merges extra vars on top of the strict base, same convention as sanitized_env/1" do
      extra = [{~c"TERM", ~c"xterm-256color"}, {~c"COLUMNS", ~c"120"}]

      env = Env.strict_env(extra)

      assert {~c"TERM", ~c"xterm-256color"} in env
      assert {~c"COLUMNS", ~c"120"} in env
      assert List.last(env) == {~c"COLUMNS", ~c"120"}
    end
  end
end
