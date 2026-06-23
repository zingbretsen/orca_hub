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
end
