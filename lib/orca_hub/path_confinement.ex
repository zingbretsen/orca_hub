defmodule OrcaHub.PathConfinement do
  @moduledoc """
  Shared REALPATH-based path confinement — resolves a (relative or
  absolute) path against a base directory, follows every symlink along the
  way, and verifies the fully-resolved absolute path is actually inside an
  allowed root's subtree. Refuses the escape hatches a naive `Path.expand/2`
  + prefix check would miss: `..` segments, and a symlink INSIDE the
  confined directory pointing anywhere else on the filesystem.

  Used by any MCP tool that lets a session reference a local file by path:
  `OrcaHub.MCP.Tools.Discord` (`send_discord_message`'s `file_paths`) and
  `OrcaHub.MCP.Tools.Files` (`put_file`'s `path`).
  """

  @doc """
  Resolves `path` (expanded against `directory` if relative) and confines
  it to `roots` (default `[directory]`) — `roots` is a list so a caller
  with more than one allowed root (e.g. a future shared read-only assets
  dir) is a one-line change at the call site, not a signature change here.
  Returns `{:ok, resolved}` or `{:error, :outside_root}`.
  """
  def confine(directory, path, roots \\ nil) do
    resolved = resolve(directory, path)

    if within_any_root?(resolved, roots || [directory]) do
      {:ok, resolved}
    else
      {:error, :outside_root}
    end
  end

  @doc "Expands `path` against `directory` and fully resolves symlinks."
  def resolve(directory, path) do
    path |> Path.expand(directory) |> realpath()
  end

  @doc false
  def within_any_root?(resolved, roots) do
    Enum.any?(roots, fn root ->
      resolved_root = realpath(Path.expand(root))
      resolved == resolved_root or String.starts_with?(resolved, resolved_root <> "/")
    end)
  end

  # Bounds how many symlink hops `realpath/1` will follow before giving up —
  # specifically so a symlink LOOP (a -> b -> a) can't hang this call. Well
  # above any legitimate chain length.
  @max_realpath_iterations 40

  @doc """
  A small `realpath`-style resolver: walks `path` (already absolute)
  component by component, resolving any symlink encountered along the way,
  and returns the fully-resolved absolute path. Nonexistent components are
  passed through literally (not an error) — resolving `.../missing.txt`
  still confines correctly even though the file doesn't exist yet, letting
  the caller's separate existence check report "not found" instead of a
  confusing confinement error. Bounded to `#{@max_realpath_iterations}`
  symlink hops so a loop can't hang the caller — if the bound is hit, the
  partially-resolved path is returned as-is (almost certain to then fail
  `within_any_root?/2`, which is the safe outcome for something we couldn't
  fully resolve). Public + directly unit-testable with real tmp symlinks —
  no session/HubRPC dependency.
  """
  def realpath(path) do
    path
    |> Path.split()
    |> do_realpath("/", 0)
  end

  defp do_realpath(_remaining, resolved, iterations) when iterations > @max_realpath_iterations,
    do: resolved

  defp do_realpath([], resolved, _iterations), do: resolved
  defp do_realpath(["/" | rest], _resolved, iterations), do: do_realpath(rest, "/", iterations)

  defp do_realpath(["." | rest], resolved, iterations),
    do: do_realpath(rest, resolved, iterations)

  defp do_realpath([".." | rest], resolved, iterations),
    do: do_realpath(rest, Path.dirname(resolved), iterations)

  defp do_realpath([comp | rest], resolved, iterations) do
    candidate = Path.join(resolved, comp)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_symlink(candidate, rest, iterations)

      _not_a_symlink_or_missing ->
        do_realpath(rest, candidate, iterations)
    end
  end

  defp follow_symlink(candidate, rest, iterations) do
    case File.read_link(candidate) do
      {:ok, target} ->
        target_parts = Path.split(target)

        if Path.type(target) == :absolute do
          do_realpath(target_parts ++ rest, "/", iterations + 1)
        else
          # A relative symlink target is relative to the symlink's OWN
          # directory, not to `candidate` itself (which is the symlink, not
          # a directory).
          do_realpath(target_parts ++ rest, Path.dirname(candidate), iterations + 1)
        end

      {:error, _reason} ->
        # lstat said symlink but the link couldn't be read (race, permission)
        # — treat the path literally rather than raising.
        do_realpath(rest, candidate, iterations)
    end
  end
end
